#!/usr/bin/env python3
"""Synchronize recent Codex CLI JSONL transcripts into bb.

The script is dry-run by default. It uses the transcript's canonical provider
identity rather than its path, so duplicate files do not create duplicate bb
threads. When an existing source is newer, its imported content is replaced.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


CLIENT_REQUEST_ALPHABET = "23456789abcdefghijkmnpqrstuvwxyz"


def compact_text(value: str, limit: int = 240) -> str:
    value = " ".join(value.split())
    return value if len(value) <= limit else value[: limit - 1].rstrip() + "…"


def safe_id(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", value)


def short_hash(value: str) -> str:
    return hashlib.sha1(value.encode("utf-8")).hexdigest()[:12]


def iso_ms(value: Any, fallback: int) -> int:
    if not isinstance(value, str) or not value:
        return fallback
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.astimezone()
        return int(parsed.timestamp() * 1000)
    except (TypeError, ValueError, OverflowError):
        return fallback


def request_id(seed: int) -> str:
    value = seed
    suffix = ""
    for _ in range(10):
        suffix = CLIENT_REQUEST_ALPHABET[value % len(CLIENT_REQUEST_ALPHABET)] + suffix
        value //= len(CLIENT_REQUEST_ALPHABET)
    return "creq_" + suffix


def result_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = []
        for block in value:
            if isinstance(block, dict) and isinstance(block.get("text"), str):
                parts.append(block["text"])
            elif isinstance(block, str):
                parts.append(block)
        if parts:
            return "\n".join(parts)
    try:
        return json.dumps(value, ensure_ascii=False)
    except (TypeError, ValueError):
        return str(value)


def load_records(path: Path) -> Tuple[List[Dict[str, Any]], int]:
    records: List[Dict[str, Any]] = []
    parse_errors = 0
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                parse_errors += 1
                continue
            if isinstance(value, dict):
                records.append(value)
    return records, parse_errors


def raw_session_id(path: Path, records: Iterable[Dict[str, Any]]) -> str:
    for record in records:
        if record.get("type") == "session_meta":
            payload = record.get("payload") or {}
            value = payload.get("session_id")
            if isinstance(value, str) and value:
                return value
    return path.stem


def first_cwd(records: Iterable[Dict[str, Any]]) -> Optional[str]:
    for record in records:
        if record.get("type") == "session_meta":
            payload = record.get("payload") or {}
            value = payload.get("cwd")
            if isinstance(value, str) and value:
                return value
    return None


def load_external_imports(path: Path) -> set:
    """Return Codex session ids that are Claude Code imports.

    Codex keeps a record of external agent sessions (e.g. Claude) that were
    imported into the local Codex history. Importing those same sessions again
    as Codex threads would duplicate the Claude imports already handled by the
    claude-session-import skill.
    """
    imported: set = set()
    if not path.exists():
        return imported
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (json.JSONDecodeError, OSError):
        return imported
    records = data.get("records") if isinstance(data, dict) else data
    if not isinstance(records, list):
        return imported
    for record in records:
        if isinstance(record, dict):
            value = record.get("imported_thread_id")
            if isinstance(value, str) and value:
                imported.add(value)
    return imported


def load_session_index(path: Path) -> Dict[str, str]:
    index: Dict[str, str] = {}
    if not path.exists():
        return index
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                session_id = value.get("id")
                name = value.get("thread_name")
                if isinstance(session_id, str) and session_id and isinstance(name, str):
                    index[session_id] = name.strip()
    return index


def session_title(records: Iterable[Dict[str, Any]], index: Dict[str, str]) -> Optional[str]:
    session_id = raw_session_id(Path("."), records)
    return index.get(session_id)


def prompt_blocks(content: Any) -> Tuple[List[Dict[str, str]], bool]:
    if isinstance(content, str):
        return ([{"type": "text", "text": content}], bool(content.strip()))
    if not isinstance(content, list):
        return ([], False)
    blocks: List[Dict[str, str]] = []
    is_turn = False
    for block in content:
        if not isinstance(block, dict):
            continue
        block_type = block.get("type")
        if block_type in {"input_text", "output_text"} and isinstance(block.get("text"), str):
            text = block["text"]
            if text:
                blocks.append({"type": "text", "text": text})
                is_turn = is_turn or bool(text.strip())
        elif block_type == "image":
            blocks.append({"type": "text", "text": "[image attachment]"})
            is_turn = True
        elif block_type in {"document", "file"}:
            name = block.get("name") or block.get("file_name") or "file"
            blocks.append({"type": "text", "text": f"[{name} attachment]"})
            is_turn = True
    return blocks, is_turn


def user_text_for_title(record: Dict[str, Any]) -> Optional[str]:
    record_type = record.get("type")
    payload = record.get("payload") or {}
    if record_type == "event_msg" and payload.get("type") == "user_message":
        message = payload.get("message") or ""
        if isinstance(message, str) and message.strip():
            return message.strip()
    if record_type == "response_item" and payload.get("role") == "user" and payload.get("type") == "message":
        blocks, is_turn = prompt_blocks(payload.get("content"))
        if is_turn:
            return "\n".join(block["text"] for block in blocks).strip()
    return None


def item_id(source: str, record: Dict[str, Any], index: int, block_index: int) -> str:
    raw = str(record.get("uuid") or index)
    return f"codex_{short_hash(source)}_{safe_id(raw)}_{block_index}"


def add_event(
    events: List[Dict[str, Any]],
    event_type: str,
    scope: str,
    turn_id: Optional[str],
    provider_thread_id: Optional[str],
    data: Dict[str, Any],
    created_at: int,
    item: Optional[Dict[str, Any]] = None,
) -> None:
    events.append(
        {
            "type": event_type,
            "scope": scope,
            "turn_id": turn_id,
            "provider_thread_id": provider_thread_id,
            "data": data,
            "created_at": created_at,
            "item_id": item.get("id") if item else None,
            "item_kind": item.get("type") if item else None,
        }
    )


def build_entry(
    path: Path,
    root: Path,
    records: List[Dict[str, Any]],
    parse_errors: int,
    project_id: str,
    session_index: Dict[str, str],
) -> Dict[str, Any]:
    source = raw_session_id(path, records)
    source_mtime = int(path.stat().st_mtime_ns // 1_000_000)
    fallback_time = source_mtime
    raw_times = [iso_ms(record.get("timestamp"), fallback_time) for record in records]
    created_at = min(raw_times) if raw_times else fallback_time
    updated_at = max(max(raw_times) if raw_times else fallback_time, source_mtime)
    cwd = first_cwd(records)
    title = session_title(records, session_index)
    first_prompt = next(
        (prompt for record in records if (prompt := user_text_for_title(record))),
        None,
    )
    display_title = compact_text(title or first_prompt or "Untitled session")
    title_fallback = compact_text(
        f"Codex session {source} · {cwd or 'unknown cwd'}", 500
    )

    events: List[Dict[str, Any]] = []
    pending_tools: Dict[str, Dict[str, Any]] = {}
    active_turn: Optional[Dict[str, str]] = None
    turn_number = 0
    last_event_time = created_at
    thread_started = False

    def event_time(record: Dict[str, Any]) -> int:
        nonlocal last_event_time
        last_event_time = max(last_event_time, iso_ms(record.get("timestamp"), fallback_time))
        return last_event_time

    def ensure_thread(timestamp: int) -> None:
        nonlocal thread_started
        if thread_started:
            return
        add_event(events, "thread/started", "thread", None, None, {}, timestamp)
        add_event(events, "thread/identity", "thread", None, source, {}, timestamp)
        thread_started = True

    def start_turn(timestamp: int) -> Dict[str, str]:
        nonlocal active_turn, turn_number
        turn_number += 1
        turn_id = f"turn_{short_hash(source)}_{turn_number}"
        active_turn = {"turn_id": turn_id, "request_id": request_id(turn_number)}
        add_event(events, "turn/started", "turn", turn_id, source, {}, timestamp)
        return active_turn

    def close_turn(timestamp: int, interrupted: bool = False) -> None:
        nonlocal active_turn
        if active_turn is None:
            return
        for tool_key, tool in list(pending_tools.items()):
            if tool["turn_id"] != active_turn["turn_id"]:
                continue
            completed = dict(tool["item"])
            completed["status"] = "interrupted"
            completed["error"] = "Codex session ended before the tool result was recorded."
            add_event(
                events,
                "item/completed",
                "turn",
                active_turn["turn_id"],
                source,
                {"item": completed},
                timestamp,
                completed,
            )
            pending_tools.pop(tool_key, None)
        add_event(
            events,
            "turn/completed",
            "turn",
            active_turn["turn_id"],
            source,
            {"status": "interrupted" if interrupted else "completed"},
            timestamp,
        )
        active_turn = None

    for index, record in enumerate(records):
        timestamp = event_time(record)
        record_type = record.get("type")
        payload = record.get("payload") or {}

        if record_type == "response_item":
            item_type = payload.get("type")
            role = payload.get("role")

            if item_type == "message" and role == "assistant":
                ensure_thread(timestamp)
                content = payload.get("content")
                if not isinstance(content, list):
                    continue
                if active_turn is None:
                    start_turn(timestamp)
                for block_index, block in enumerate(content):
                    if not isinstance(block, dict):
                        continue
                    block_type = block.get("type")
                    if block_type == "output_text" and isinstance(block.get("text"), str) and block["text"]:
                        item = {
                            "type": "agentMessage",
                            "id": item_id(source, record, index, block_index),
                            "text": block["text"],
                        }
                        add_event(events, "item/completed", "turn", active_turn["turn_id"], source, {"item": item}, timestamp, item)
                    elif block_type == "reasoning_text" and isinstance(block.get("text"), str) and block["text"]:
                        item = {
                            "type": "reasoning",
                            "id": item_id(source, record, index, block_index),
                            "summary": [],
                            "content": [block["text"]],
                        }
                        add_event(events, "item/completed", "turn", active_turn["turn_id"], source, {"item": item}, timestamp, item)

            elif item_type == "reasoning":
                ensure_thread(timestamp)
                if active_turn is None:
                    start_turn(timestamp)
                reasoning_text = result_text(payload.get("content"))
                if reasoning_text:
                    item = {
                        "type": "reasoning",
                        "id": item_id(source, record, index, 0),
                        "summary": [],
                        "content": [reasoning_text],
                    }
                    add_event(events, "item/completed", "turn", active_turn["turn_id"], source, {"item": item}, timestamp, item)

            elif item_type in {"custom_tool_call", "function_call"}:
                ensure_thread(timestamp)
                if active_turn is None:
                    start_turn(timestamp)
                tool_key = str(payload.get("id") or item_id(source, record, index, 0))
                item = {
                    "type": "toolCall",
                    "id": item_id(source, record, index, 0),
                    "name": payload.get("name") or "tool",
                    "arguments": payload.get("arguments") or {},
                }
                add_event(events, "item/completed", "turn", active_turn["turn_id"], source, {"item": item}, timestamp, item)
                pending_tools[tool_key] = {"turn_id": active_turn["turn_id"], "item": item}

            elif item_type in {"custom_tool_call_output", "function_call_output"}:
                tool_key = str(payload.get("id") or payload.get("call_id") or item_id(source, record, index, 0))
                pending = pending_tools.pop(tool_key, None)
                if pending is None:
                    continue
                tool_item = dict(pending["item"])
                tool_item["status"] = "completed"
                tool_item["result"] = payload.get("output") or payload.get("content")
                add_event(events, "item/completed", "turn", pending["turn_id"], source, {"item": tool_item}, timestamp, tool_item)

            elif item_type == "message" and role == "user":
                ensure_thread(timestamp)
                close_turn(timestamp)
                turn = start_turn(timestamp)
                blocks, is_turn = prompt_blocks(payload.get("content"))
                if is_turn:
                    item = {
                        "type": "userMessage",
                        "id": item_id(source, record, index, 0),
                        "content": blocks,
                        "clientRequestId": turn["request_id"],
                    }
                    add_event(events, "item/completed", "turn", turn["turn_id"], source, {"item": item}, timestamp, item)
                    add_event(events, "turn/input/accepted", "turn", turn["turn_id"], source, {"clientRequestId": turn["request_id"]}, timestamp)

        elif record_type == "event_msg":
            event_type = payload.get("type")

            if event_type == "user_message":
                message = payload.get("message") or ""
                if isinstance(message, str) and message.strip():
                    ensure_thread(timestamp)
                    close_turn(timestamp)
                    turn = start_turn(timestamp)
                    blocks = [{"type": "text", "text": message.strip()}]
                    item = {
                        "type": "userMessage",
                        "id": item_id(source, record, index, 0),
                        "content": blocks,
                        "clientRequestId": turn["request_id"],
                    }
                    add_event(events, "item/completed", "turn", turn["turn_id"], source, {"item": item}, timestamp, item)
                    add_event(events, "turn/input/accepted", "turn", turn["turn_id"], source, {"clientRequestId": turn["request_id"]}, timestamp)

            elif event_type == "agent_message":
                message = payload.get("message") or ""
                if isinstance(message, str) and message.strip():
                    ensure_thread(timestamp)
                    if active_turn is None:
                        start_turn(timestamp)
                    item = {
                        "type": "agentMessage",
                        "id": item_id(source, record, index, 0),
                        "text": message.strip(),
                    }
                    add_event(events, "item/completed", "turn", active_turn["turn_id"], source, {"item": item}, timestamp, item)

            elif event_type == "task_started":
                ensure_thread(timestamp)
                if active_turn is not None:
                    close_turn(timestamp)
                start_turn(timestamp)

            elif event_type == "task_complete":
                if active_turn is not None:
                    close_turn(timestamp)

    if active_turn is not None:
        close_turn(last_event_time)
    if not thread_started:
        ensure_thread(created_at)

    segments: List[Dict[str, Any]] = [
        {"source_kind": "title", "source_key": "title", "source_seq": None, "text": display_title}
    ]
    for sequence, event in enumerate(events, start=1):
        if event["type"] != "item/completed":
            continue
        item = event["data"].get("item", {})
        if item.get("type") == "userMessage":
            text = "\n".join(block.get("text", "") for block in item.get("content", [])).strip()
            if text:
                segments.append({"source_kind": "user_message", "source_key": f"event:{sequence}", "source_seq": sequence, "text": text})
        elif item.get("type") == "agentMessage" and item.get("text"):
            segments.append({"source_kind": "assistant_message", "source_key": f"event:{sequence}", "source_seq": sequence, "text": item["text"]})

    return {
        "path": str(path),
        "source_key": source,
        "project_id": project_id,
        "cwd": cwd,
        "title": display_title,
        "title_fallback": title_fallback,
        "created_at": created_at,
        "updated_at": updated_at,
        "events": events,
        "segments": segments,
        "parse_errors": parse_errors,
    }


def local_cutoff(args: argparse.Namespace) -> Tuple[float, str]:
    now = datetime.now().astimezone()
    if args.since:
        value = datetime.strptime(args.since, "%Y-%m-%d").replace(tzinfo=now.tzinfo)
    else:
        value = now - timedelta(days=args.days)
    return value.timestamp(), value.isoformat()


def discover(
    root: Path,
    archived_root: Path,
    cutoff: float,
    include_archived: bool,
    claude_imports: set,
) -> Tuple[List[Tuple[Path, List[Dict[str, Any]], int]], int, int, int]:
    groups: Dict[str, List[Tuple[Path, List[Dict[str, Any]], int]]] = defaultdict(list)
    files_seen = 0
    skipped_claude_imports = 0
    for path in sorted(root.rglob("*.jsonl")):
        if not path.is_file() or path.stat().st_mtime < cutoff:
            continue
        records, parse_errors = load_records(path)
        sid = raw_session_id(path, records)
        if sid in claude_imports:
            skipped_claude_imports += 1
            continue
        groups[sid].append((path, records, parse_errors))
        files_seen += 1
    if include_archived and archived_root.exists():
        for path in sorted(archived_root.glob("*.jsonl")):
            if not path.is_file() or path.stat().st_mtime < cutoff:
                continue
            records, parse_errors = load_records(path)
            sid = raw_session_id(path, records)
            if sid in claude_imports:
                skipped_claude_imports += 1
                continue
            groups[sid].append((path, records, parse_errors))
            files_seen += 1

    selected: List[Tuple[Path, List[Dict[str, Any]], int]] = []
    duplicate_files = 0
    for candidates in groups.values():
        candidates.sort(key=lambda item: (item[0].stat().st_mtime_ns, item[0].stat().st_size, str(item[0])))
        selected.append(candidates[-1])
        duplicate_files += len(candidates) - 1
    selected.sort(key=lambda item: str(item[0]))
    return selected, files_seen, duplicate_files, skipped_claude_imports


def project_roots(db: sqlite3.Connection) -> List[Tuple[str, str]]:
    return [(str(row[0]), str(row[1])) for row in db.execute("SELECT path, project_id FROM project_sources WHERE path IS NOT NULL")]


def project_for_cwd(cwd: Optional[str], roots: List[Tuple[str, str]]) -> str:
    if cwd:
        matches = [(root, project_id) for root, project_id in roots if cwd == root or cwd.startswith(root + os.sep)]
        if matches:
            return max(matches, key=lambda value: len(value[0]))[1]
    return "proj_personal"


def existing_threads(db: sqlite3.Connection) -> Tuple[Dict[str, List[Dict[str, Any]]], set]:
    rows = db.execute(
        """
        SELECT t.id, t.project_id, t.title, t.title_fallback, t.created_at, t.updated_at,
               COALESCE((SELECT MAX(e.created_at) FROM events e
                         WHERE e.thread_id = t.id AND e.type != 'thread/name/updated'), t.created_at)
        FROM threads t
        WHERE t.id LIKE 'thr_codex_%'
        """
    ).fetchall()
    by_id = {
        row[0]: {
            "id": row[0], "project_id": row[1], "title": row[2], "title_fallback": row[3],
            "created_at": row[4], "updated_at": row[5], "content_at": row[6],
        }
        for row in rows
    }
    grouped: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    native_provider_ids: set = set()
    for thread_id, provider_id in db.execute(
        "SELECT thread_id, provider_thread_id FROM events WHERE type = 'thread/identity' AND provider_thread_id IS NOT NULL"
    ):
        if thread_id in by_id:
            grouped[str(provider_id)].append(by_id[thread_id])
        elif not thread_id.startswith("thr_codex_"):
            native_provider_ids.add(str(provider_id))
    return grouped, native_provider_ids


def canonical_thread_id(source: str) -> str:
    return "thr_codex_" + safe_id(source).replace("-", "")


def schema_check(db: sqlite3.Connection) -> None:
    required = {"threads", "events", "thread_search_segments", "project_sources"}
    found = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    missing = sorted(required - found)
    if missing:
        raise RuntimeError("bb database is missing required tables: " + ", ".join(missing))


def purge_children(db: sqlite3.Connection, thread_id: str) -> None:
    db.execute("DELETE FROM thread_search_segments WHERE thread_id = ?", (thread_id,))
    db.execute("DELETE FROM events WHERE thread_id = ?", (thread_id,))


def insert_entry(db: sqlite3.Connection, entry: Dict[str, Any], thread_id: str, now: int, replace: bool) -> int:
    if replace:
        purge_children(db, thread_id)
        db.execute(
            """
            UPDATE threads SET project_id = ?, provider_id = 'codex-cli', title = ?,
              title_fallback = ?, status = 'idle', visibility = 'visible',
              latest_attention_at = ?, created_at = ?, updated_at = ?
            WHERE id = ?
            """,
            (entry["project_id"], entry["title"], entry["title_fallback"], entry["updated_at"], entry["created_at"], entry["updated_at"], thread_id),
        )
    else:
        db.execute(
            """
            INSERT INTO threads
              (id, project_id, environment_id, provider_id, title, title_fallback,
               status, visibility, last_read_at, latest_attention_at, created_at, updated_at)
            VALUES (?, ?, NULL, 'codex-cli', ?, ?, 'idle', 'visible', ?, ?, ?, ?)
            """,
            (thread_id, entry["project_id"], entry["title"], entry["title_fallback"], now, entry["updated_at"], entry["created_at"], entry["updated_at"]),
        )

    event_prefix = "evt_codex_" + short_hash(thread_id)
    for sequence, event in enumerate(entry["events"], start=1):
        db.execute(
            """
            INSERT INTO events
              (id, thread_id, environment_id, scope_kind, turn_id,
               provider_thread_id, sequence, type, item_id, item_kind, data, created_at)
            VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                f"{event_prefix}_{sequence}", thread_id, event["scope"], event["turn_id"],
                event["provider_thread_id"], sequence, event["type"], event["item_id"],
                event["item_kind"], json.dumps(event["data"], ensure_ascii=False, separators=(",", ":")), event["created_at"],
            ),
        )
    for segment in entry["segments"]:
        db.execute(
            """
            INSERT INTO thread_search_segments
              (id, thread_id, source_kind, source_key, source_seq, text, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                f"{thread_id}:{segment['source_kind']}:{segment['source_key']}", thread_id,
                segment["source_kind"], segment["source_key"], segment["source_seq"],
                segment["text"], entry["updated_at"], entry["updated_at"],
            ),
        )
    return len(entry["events"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--since", help="inclusive local date, YYYY-MM-DD")
    parser.add_argument("--skip-archived", action="store_true", help="ignore ~/.codex/archived_sessions")
    parser.add_argument("--include-claude-imports", action="store_true", help="import sessions that originated as Claude imports")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--db", type=Path, default=Path.home() / ".bb" / "bb.db")
    parser.add_argument("--codex-home", type=Path, default=Path.home() / ".codex")
    args = parser.parse_args()
    if args.days < 0:
        parser.error("--days must be non-negative")
    if args.since and args.days != 30:
        parser.error("use either --since or --days, not both")

    cutoff, cutoff_iso = local_cutoff(args)
    if not args.db.exists():
        raise RuntimeError(f"bb database not found: {args.db}")
    if not args.codex_home.exists():
        raise RuntimeError(f"Codex home directory not found: {args.codex_home}")

    sessions_root = args.codex_home / "sessions"
    archived_root = args.codex_home / "archived_sessions"
    session_index_path = args.codex_home / "session_index.jsonl"
    external_imports_path = args.codex_home / "external_agent_session_imports.json"

    db = sqlite3.connect(str(args.db), timeout=60)
    db.execute("PRAGMA foreign_keys = ON")
    schema_check(db)
    roots = project_roots(db)
    session_index = load_session_index(session_index_path)
    claude_imports = set() if args.include_claude_imports else load_external_imports(external_imports_path)
    candidates, files_seen, duplicate_files, skipped_claude_imports = discover(sessions_root, archived_root, cutoff, not args.skip_archived, claude_imports)
    entries = [
        build_entry(path, sessions_root, records, parse_errors, project_for_cwd(first_cwd(records), roots), session_index)
        for path, records, parse_errors in candidates
    ]
    existing, native_provider_ids = existing_threads(db)
    actions: List[Dict[str, Any]] = []
    unchanged = 0
    replacements = 0
    new_threads = 0
    duplicate_existing = 0
    skipped_native = 0
    parse_errors = sum(entry["parse_errors"] for entry in entries)

    for entry in entries:
        if entry["source_key"] in native_provider_ids:
            actions.append({"entry": entry, "action": "skip_native", "thread_id": None, "remove_ids": []})
            skipped_native += 1
            continue
        matches = existing.get(entry["source_key"], [])
        primary = max(matches, key=lambda row: (row["content_at"] or 0, row["updated_at"] or 0, row["id"])) if matches else None
        remove_ids = [row["id"] for row in matches if primary and row["id"] != primary["id"]]
        duplicate_existing += len(remove_ids)
        if primary is None:
            action = "new"
            thread_id = canonical_thread_id(entry["source_key"])
            new_threads += 1
        elif entry["updated_at"] > (primary["content_at"] or 0):
            action = "replace"
            thread_id = primary["id"]
            replacements += 1
        else:
            action = "unchanged"
            thread_id = primary["id"]
            unchanged += 1
        actions.append({"entry": entry, "action": action, "thread_id": thread_id, "remove_ids": remove_ids})

    summary = {
        "cutoff": cutoff_iso,
        "include_archived": not args.skip_archived,
        "include_claude_imports": args.include_claude_imports,
        "files_seen": files_seen,
        "skipped_claude_imports": skipped_claude_imports,
        "canonical_sources": len(entries),
        "duplicate_files_skipped": duplicate_files,
        "existing_duplicate_threads": duplicate_existing,
        "skipped_native_threads": skipped_native,
        "new_threads": new_threads,
        "replacements_with_newer_source": replacements,
        "unchanged_existing": unchanged,
        "events_to_write": sum(len(action["entry"]["events"]) for action in actions if action["action"] not in ("unchanged", "skip_native")),
        "search_segments_to_write": sum(len(action["entry"]["segments"]) for action in actions if action["action"] not in ("unchanged", "skip_native")),
        "json_parse_errors": parse_errors,
        "mode": "apply" if args.apply else "dry-run",
    }
    print(json.dumps(summary, indent=2))
    if not args.apply:
        db.close()
        return 0

    now = int(datetime.now().astimezone().timestamp() * 1000)
    try:
        db.execute("BEGIN IMMEDIATE")
        for action in actions:
            entry = action["entry"]
            for duplicate_id in action["remove_ids"]:
                purge_children(db, duplicate_id)
                db.execute("DELETE FROM threads WHERE id = ?", (duplicate_id,))
            if action["action"] in ("unchanged", "skip_native"):
                continue
            insert_entry(db, entry, action["thread_id"], now, action["action"] == "replace")
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
    print(json.dumps({"applied_new": new_threads, "applied_replacements": replacements, "removed_existing_duplicates": duplicate_existing}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
