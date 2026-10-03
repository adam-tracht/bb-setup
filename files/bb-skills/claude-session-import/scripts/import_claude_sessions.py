#!/usr/bin/env python3
"""Synchronize recent Claude Code JSONL transcripts into bb.

The script is dry-run by default. It uses the transcript's canonical provider
identity rather than its path, so duplicate files do not create duplicate bb
threads. When an existing source is newer, its imported content is replaced.

Imported threads are attached to a ready workspace so they can be messaged
right away: personal-project threads use the most recently used ready personal
workspace, and repository threads use an unmanaged environment at the project
checkout (created when missing, mirroring what bb provisions at spawn time).
Threads also receive the claude-code provider default as a sticky model.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import sqlite3
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


CLIENT_REQUEST_ALPHABET = "23456789abcdefghijkmnpqrstuvwxyz"
CLAUDE_CODE_DEFAULT_MODEL = "claude-opus-5[1m]"


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
        value = record.get("sessionId")
        if isinstance(value, str) and value:
            return value
    return path.stem


def is_subagent(path: Path, root: Path) -> bool:
    try:
        parts = path.relative_to(root).parts
    except ValueError:
        parts = path.parts
    return "subagents" in parts


def source_key(path: Path, root: Path, records: Iterable[Dict[str, Any]]) -> str:
    session_id = raw_session_id(path, records)
    return f"{session_id}:{path.stem}" if is_subagent(path, root) else session_id


def entry_parts(entry: Dict[str, Any]) -> List[str]:
    """Ordered, comparable summary of an imported entry's canonical events."""
    parts: List[str] = []
    for event in entry["events"]:
        event_type = event["type"]
        if event_type not in ("item/started", "item/completed"):
            continue
        item = event["data"].get("item", {})
        item_kind = event["item_kind"]
        if item_kind == "userMessage":
            for block in item.get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    parts.append("T:" + block.get("text", ""))
                elif block.get("type") in ("file", "document", "image"):
                    parts.append("F:" + str(block.get("name") or block.get("file_name") or block.get("type")))
        elif item_kind == "agentMessage":
            parts.append("A:" + item.get("text", ""))
        elif item_kind == "toolCall":
            if event_type == "item/started":
                parts.append("S:" + json.dumps(item.get("arguments") or {}, ensure_ascii=False)[:200])
            else:
                parts.append("R:" + json.dumps(item.get("result") or item.get("error") or "", ensure_ascii=False)[:400])
    return parts


def thread_parts(db: sqlite3.Connection, thread_id: str) -> List[str]:
    """Same canonical part stream as entry_parts(), read from an existing thread."""
    rows = db.execute(
        "SELECT type, item_kind, data FROM events WHERE thread_id = ? ORDER BY sequence",
        (thread_id,),
    ).fetchall()
    parts: List[str] = []
    for event_type, item_kind, data in rows:
        if event_type not in ("item/started", "item/completed"):
            continue
        try:
            item = json.loads(data).get("item", {})
        except (TypeError, ValueError):
            continue
        if item_kind == "userMessage":
            for block in item.get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    parts.append("T:" + block.get("text", ""))
                elif block.get("type") in ("file", "document", "image"):
                    parts.append("F:" + str(block.get("name") or block.get("file_name") or block.get("type")))
        elif item_kind == "agentMessage":
            parts.append("A:" + item.get("text", ""))
        elif item_kind == "toolCall":
            if event_type == "item/started":
                parts.append("S:" + json.dumps(item.get("arguments") or {}, ensure_ascii=False)[:200])
            else:
                parts.append("R:" + json.dumps(item.get("result") or item.get("error") or "", ensure_ascii=False)[:400])
    return parts


def contained_in(short: List[str], long: List[str]) -> bool:
    """True when >=95% of short's parts appear, in order, inside long."""
    if not short:
        return False
    iterator = iter(long)
    matched = 0
    for part in short:
        for other in iterator:
            if other == part:
                matched += 1
                break
    return matched >= 0.95 * len(short)


def snapshot_key(entry: Dict[str, Any]) -> Tuple[str, int]:
    """Conversation-root identity: (display title, 5s-bucketed start time).

    Claude's fork/resume flow writes new session files that copy the original
    conversation's start, so same-titled copies share the same start second.
    The 5-second bucket tolerates small timestamp drift between copies;
    whether a sibling is a true snapshot or a diverged fork is decided by
    content containment in filter_snapshots().
    """
    return entry["title"], entry["created_at"] // 5000


def filter_snapshots(entries: List[Dict[str, Any]]) -> Tuple[List[Dict[str, Any]], int]:
    """Drop entries fully contained in a longer sibling of the same conversation
    root (fork/resume snapshots). Diverged forks are kept."""
    grouped: Dict[Tuple[str, int], List[Dict[str, Any]]] = defaultdict(list)
    for entry in entries:
        grouped[snapshot_key(entry)].append(entry)
    kept: List[Dict[str, Any]] = []
    skipped = 0
    for items in grouped.values():
        if len(items) == 1:
            kept.append(items[0])
            continue
        items.sort(key=lambda item: -len(item["events"]))
        keeper = items[0]
        keeper_parts = entry_parts(keeper)
        for item in items[1:]:
            parts = entry_parts(item)
            if len(parts) >= 10 and contained_in(parts, keeper_parts):
                skipped += 1
            else:
                kept.append(item)
        kept.append(keeper)
    kept.sort(key=lambda item: str(item["path"]))
    return kept, skipped


def load_skip_titles(path: Optional[Path]) -> List[str]:
    """Load title prefixes of automated sessions that must never become threads.

    Lines are stripped; empty lines and lines starting with '#' are ignored.
    """
    if path is None or not path.is_file():
        return []
    prefixes: List[str] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            value = line.strip()
            if value and not value.startswith("#"):
                prefixes.append(value)
    return prefixes


def filter_skip_titles(entries: List[Dict[str, Any]], prefixes: List[str]) -> Tuple[List[Dict[str, Any]], int]:
    if not prefixes:
        return entries, 0
    kept: List[Dict[str, Any]] = []
    skipped = 0
    for entry in entries:
        if any(entry["title"].startswith(prefix) for prefix in prefixes):
            skipped += 1
        else:
            kept.append(entry)
    return kept, skipped


def first_cwd(records: Iterable[Dict[str, Any]]) -> Optional[str]:
    for record in records:
        value = record.get("cwd")
        if isinstance(value, str) and value:
            return value
    return None


def custom_title(records: Iterable[Dict[str, Any]]) -> Optional[str]:
    found = None
    for record in records:
        if record.get("type") == "custom-title":
            value = record.get("customTitle")
            if isinstance(value, str) and value.strip():
                found = value.strip()
    return found


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
        if block_type == "text" and isinstance(block.get("text"), str):
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
    if record.get("type") != "user":
        return None
    message = record.get("message") or {}
    blocks, is_turn = prompt_blocks(message.get("content"))
    if not is_turn:
        return None
    text = "\n".join(block["text"] for block in blocks).strip()
    return text or None


def item_id(source: str, record: Dict[str, Any], index: int, block_index: int) -> str:
    raw = str(record.get("uuid") or index)
    return f"cc_{short_hash(source)}_{safe_id(raw)}_{block_index}"


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
) -> Dict[str, Any]:
    source = source_key(path, root, records)
    source_mtime = int(path.stat().st_mtime_ns // 1_000_000)
    fallback_time = source_mtime
    raw_times = [iso_ms(record.get("timestamp"), fallback_time) for record in records]
    created_at = min(raw_times) if raw_times else fallback_time
    updated_at = max(max(raw_times) if raw_times else fallback_time, source_mtime)
    cwd = first_cwd(records)
    title = custom_title(records)
    first_prompt = next(
        (prompt for record in records if (prompt := user_text_for_title(record))),
        None,
    )
    display_title = compact_text(title or first_prompt or "Untitled session")
    title_fallback = compact_text(
        f"Claude Code session {source} · {cwd or 'unknown cwd'}", 500
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
            completed["error"] = "Claude session ended before the tool result was recorded."
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

        if record_type == "assistant":
            ensure_thread(timestamp)
            message = record.get("message") or {}
            content = message.get("content")
            if not isinstance(content, list):
                continue
            if active_turn is None:
                start_turn(timestamp)
            for block_index, block in enumerate(content):
                if not isinstance(block, dict):
                    continue
                block_type = block.get("type")
                if block_type == "text" and isinstance(block.get("text"), str) and block["text"]:
                    item = {
                        "type": "agentMessage",
                        "id": item_id(source, record, index, block_index),
                        "text": block["text"],
                    }
                    add_event(events, "item/completed", "turn", active_turn["turn_id"], source, {"item": item}, timestamp, item)
                elif block_type == "thinking" and isinstance(block.get("thinking"), str) and block["thinking"]:
                    item = {
                        "type": "reasoning",
                        "id": item_id(source, record, index, block_index),
                        "summary": [],
                        "content": [block["thinking"]],
                    }
                    add_event(events, "item/completed", "turn", active_turn["turn_id"], source, {"item": item}, timestamp, item)
                elif block_type in {"tool_use", "server_tool_use"}:
                    tool_key = str(block.get("id") or item_id(source, record, index, block_index))
                    item = {
                        "type": "toolCall",
                        "id": item_id(source, record, index, block_index),
                        "tool": str(block.get("name") or block_type),
                        "status": "pending",
                    }
                    if isinstance(block.get("input"), dict):
                        item["arguments"] = block["input"]
                    pending_tools[tool_key] = {"turn_id": active_turn["turn_id"], "item": item}
                    add_event(events, "item/started", "turn", active_turn["turn_id"], source, {"item": item}, timestamp, item)
                elif block_type == "web_search_tool_result":
                    item = {
                        "type": "toolCall",
                        "id": item_id(source, record, index, block_index),
                        "tool": "web_search",
                        "status": "completed",
                        "result": block.get("content"),
                    }
                    add_event(events, "item/completed", "turn", active_turn["turn_id"], source, {"item": item}, timestamp, item)
            continue

        if record_type != "user":
            continue

        message = record.get("message") or {}
        content = message.get("content")
        content_list = content if isinstance(content, list) else []
        tool_results = [
            block for block in content_list
            if isinstance(block, dict) and block.get("type") == "tool_result"
        ]
        blocks, is_turn = prompt_blocks(content)
        if is_turn:
            ensure_thread(timestamp)
            close_turn(timestamp)
            turn = start_turn(timestamp)
            add_event(events, "turn/input/accepted", "turn", turn["turn_id"], source, {"clientRequestId": turn["request_id"]}, timestamp)
            item = {
                "type": "userMessage",
                "id": item_id(source, record, index, 0),
                "content": blocks,
                "clientRequestId": turn["request_id"],
            }
            add_event(events, "item/completed", "turn", turn["turn_id"], source, {"item": item}, timestamp, item)

        for block_index, block in enumerate(tool_results):
            tool_key = str(block.get("tool_use_id") or item_id(source, record, index, block_index))
            pending = pending_tools.pop(tool_key, None)
            if pending is None:
                continue
            tool_item = dict(pending["item"])
            failed = bool(block.get("is_error"))
            tool_item["status"] = "failed" if failed else "completed"
            if failed:
                tool_item["error"] = result_text(block.get("content"))
            else:
                tool_item["result"] = block.get("content")
            add_event(events, "item/completed", "turn", pending["turn_id"], source, {"item": tool_item}, timestamp, tool_item)

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


def discover(root: Path, cutoff: float, include_subagents: bool) -> Tuple[List[Tuple[Path, List[Dict[str, Any]], int]], int, int]:
    groups: Dict[str, List[Tuple[Path, List[Dict[str, Any]], int]]] = defaultdict(list)
    files_seen = 0
    for path in sorted(root.rglob("*.jsonl")):
        if not path.is_file() or path.stat().st_mtime < cutoff:
            continue
        if not include_subagents and is_subagent(path, root):
            continue
        records, parse_errors = load_records(path)
        groups[source_key(path, root, records)].append((path, records, parse_errors))
        files_seen += 1

    selected: List[Tuple[Path, List[Dict[str, Any]], int]] = []
    duplicate_files = 0
    for candidates in groups.values():
        candidates.sort(key=lambda item: (item[0].stat().st_mtime_ns, item[0].stat().st_size, str(item[0])))
        selected.append(candidates[-1])
        duplicate_files += len(candidates) - 1
    selected.sort(key=lambda item: str(item[0]))
    return selected, files_seen, duplicate_files


def project_roots(db: sqlite3.Connection) -> List[Tuple[str, str]]:
    return [(str(row[0]), str(row[1])) for row in db.execute("SELECT path, project_id FROM project_sources WHERE path IS NOT NULL")]


def project_for_cwd(cwd: Optional[str], roots: List[Tuple[str, str]]) -> str:
    if cwd:
        matches = [(root, project_id) for root, project_id in roots if cwd == root or cwd.startswith(root + os.sep)]
        if matches:
            return max(matches, key=lambda value: len(value[0]))[1]
    return "proj_personal"


def local_host_id(db: sqlite3.Connection) -> Optional[str]:
    row = db.execute("SELECT id FROM hosts ORDER BY last_seen_at DESC LIMIT 1").fetchone()
    if row:
        return str(row[0])
    row = db.execute("SELECT host_id FROM environments WHERE host_id IS NOT NULL LIMIT 1").fetchone()
    return str(row[0]) if row else None


def project_source_path(db: sqlite3.Connection, project_id: str) -> Optional[str]:
    row = db.execute(
        "SELECT path FROM project_sources WHERE project_id = ? AND path IS NOT NULL ORDER BY path LIMIT 1",
        (project_id,),
    ).fetchone()
    return str(row[0]) if row else None


def git_branch(path: Optional[str]) -> Optional[str]:
    if not path:
        return None
    try:
        result = subprocess.run(
            ["git", "-C", path, "symbolic-ref", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    value = result.stdout.strip() if result.returncode == 0 else ""
    return value or None


def new_environment_id() -> str:
    return "env_" + secrets.token_hex(5)


def environment_columns(db: sqlite3.Connection) -> set:
    """Column names of the environments table in this database."""
    return {str(row[1]) for row in db.execute("PRAGMA table_info(environments)")}


def resolve_environment(db: sqlite3.Connection, project_id: str, now: int) -> Tuple[Optional[str], bool]:
    """Return (environment_id, created) for a ready workspace hosting the project.

    Personal threads attach to the most recently used ready personal workspace.
    Repository threads attach to an unmanaged environment at the project
    checkout, creating one when the project has none (the same shape bb
    provisions when a thread is spawned there). Returns (None, False) when no
    workspace can be resolved; the thread is then imported unattached and the
    caller should surface a warning.
    """
    # bb has changed this table twice: workspace_provision_type and managed were
    # both removed, and the personal/unmanaged distinction now lives in the
    # environment provider columns. Read the columns this database actually has
    # rather than assuming a version, so the script keeps working across upgrades.
    cols = environment_columns(db)
    legacy = "workspace_provision_type" in cols

    if project_id == "proj_personal":
        if legacy:
            kind = "workspace_provision_type = 'personal'"
        elif "environment_provider_id" in cols:
            kind = "environment_provider_id = 'personal-workspace'"
        else:
            kind = None
        if kind:
            row = db.execute(
                "SELECT id FROM environments WHERE project_id = ? AND %s AND status = 'ready' "
                "ORDER BY updated_at DESC LIMIT 1" % kind,
                (project_id,),
            ).fetchone()
            if row:
                return str(row[0]), False
        row = db.execute(
            "SELECT id FROM environments WHERE project_id = ? AND status = 'ready' ORDER BY updated_at DESC LIMIT 1",
            (project_id,),
        ).fetchone()
        if row:
            return str(row[0]), False
        return None, False

    # Match by path, not by provision type. bb now provisions a
    # project-checkout environment for repository projects, so insisting on an
    # "unmanaged" row finds nothing and the insert then collides with the
    # existing (project_id, host_id, path) row. Any ready environment at the
    # project checkout is the right one to attach to.
    source_path = project_source_path(db, project_id)
    if source_path:
        row = db.execute(
            "SELECT id FROM environments WHERE project_id = ? AND path = ? AND status = 'ready' LIMIT 1",
            (project_id, source_path),
        ).fetchone()
        if row:
            return str(row[0]), False
    rows = db.execute(
        "SELECT id, path FROM environments WHERE project_id = ? AND status = 'ready' ORDER BY path",
        (project_id,),
    ).fetchall()
    if rows:
        return str(rows[0][0]), False

    host_id = local_host_id(db)
    if not host_id or not source_path:
        return None, False
    env_id = new_environment_id()
    is_git = bool(source_path and os.path.isdir(os.path.join(source_path, ".git")))
    # Both managed and workspace_provision_type were removed from environments, so
    # name only the columns this database still has. Leaving provider columns null
    # is what marks the row as an unmanaged checkout.
    wanted = ["id", "project_id", "host_id", "path", "is_git_repo", "branch_name",
              "status", "created_at", "updated_at"]
    present = [c for c in wanted if c in cols]
    values = {
        "id": env_id,
        "project_id": project_id,
        "host_id": host_id,
        "path": source_path,
        "is_git_repo": int(is_git),
        "branch_name": git_branch(source_path),
        "status": "ready",
        "created_at": now,
        "updated_at": now,
    }
    db.execute(
        "INSERT INTO environments (%s) VALUES (%s)"
        % (", ".join(present), ", ".join("?" for _ in present)),
        [values[c] for c in present],
    )
    return env_id, True


def existing_threads(db: sqlite3.Connection) -> Tuple[Dict[str, List[Dict[str, Any]]], set]:
    """Return (import-owned threads by provider session id, provider session ids already
    owned by a native, non-imported bb thread).

    A native bb thread (any id not created by this script) can back the exact same
    Claude Code session file this script would otherwise import, e.g. when bb itself
    spawns the `claude` CLI for a thread and that session's transcript lands under
    --claude-projects. Importing it anyway would create a permanently-broken duplicate
    thread with no environment, so those session ids must be skipped entirely rather
    than matched for new/replace.
    """
    rows = db.execute(
        """
        SELECT t.id, t.project_id, t.title, t.title_fallback, t.created_at, t.updated_at,
               COALESCE((SELECT MAX(e.created_at) FROM events e
                         WHERE e.thread_id = t.id AND e.type != 'thread/name/updated'), t.created_at)
        FROM threads t
        WHERE t.id LIKE 'thr_claude_%'
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
        elif not thread_id.startswith("thr_claude_"):
            native_provider_ids.add(str(provider_id))
    return grouped, native_provider_ids


def canonical_thread_id(source: str) -> str:
    return "thr_claude_" + safe_id(source).replace("-", "")


def schema_check(db: sqlite3.Connection) -> None:
    required = {"threads", "events", "thread_search_segments", "project_sources"}
    found = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    missing = sorted(required - found)
    if missing:
        raise RuntimeError("bb database is missing required tables: " + ", ".join(missing))


def purge_children(db: sqlite3.Connection, thread_id: str) -> None:
    db.execute("DELETE FROM thread_search_segments WHERE thread_id = ?", (thread_id,))
    db.execute("DELETE FROM events WHERE thread_id = ?", (thread_id,))


def insert_entry(
    db: sqlite3.Connection,
    entry: Dict[str, Any],
    thread_id: str,
    now: int,
    replace: bool,
    environment_id: Optional[str],
    model_override: Optional[str],
) -> int:
    if replace:
        purge_children(db, thread_id)
        db.execute(
            """
            UPDATE threads SET project_id = ?, provider_id = 'claude-code', title = ?,
              title_fallback = ?, status = 'idle', visibility = 'visible',
              archived_at = NULL,
              latest_attention_at = ?, created_at = ?, updated_at = ?,
              environment_id = COALESCE(environment_id, ?),
              model_override = COALESCE(model_override, ?)
            WHERE id = ?
            """,
            (entry["project_id"], entry["title"], entry["title_fallback"], entry["updated_at"], entry["created_at"], entry["updated_at"], environment_id, model_override, thread_id),
        )
    else:
        db.execute(
            """
            INSERT INTO threads
              (id, project_id, environment_id, model_override, provider_id, title, title_fallback,
               status, visibility, last_read_at, latest_attention_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'claude-code', ?, ?, 'idle', 'visible', ?, ?, ?, ?)
            """,
            (thread_id, entry["project_id"], environment_id, model_override, entry["title"], entry["title_fallback"], now, entry["updated_at"], entry["created_at"], entry["updated_at"]),
        )

    row = db.execute("SELECT environment_id FROM threads WHERE id = ?", (thread_id,)).fetchone()
    event_environment_id = str(row[0]) if row and row[0] is not None else None
    event_prefix = "evt_claude_" + short_hash(thread_id)
    for sequence, event in enumerate(entry["events"], start=1):
        db.execute(
            """
            INSERT INTO events
              (id, thread_id, environment_id, scope_kind, turn_id,
               provider_thread_id, sequence, type, item_id, item_kind, data, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                f"{event_prefix}_{sequence}", thread_id, event_environment_id, event["scope"], event["turn_id"],
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
    parser.add_argument("--include-subagents", action="store_true")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--db", type=Path, default=Path.home() / ".bb" / "bb.db")
    parser.add_argument("--claude-projects", type=Path, default=Path.home() / ".claude" / "projects")
    parser.add_argument("--skip-titles-file", type=Path, default=None, help="file with title prefixes of automated sessions to never import (default: skip-titles.txt next to this script when present)")
    args = parser.parse_args()
    if args.days < 0:
        parser.error("--days must be non-negative")
    if args.since and args.days != 30:
        parser.error("use either --since or --days, not both")

    cutoff, cutoff_iso = local_cutoff(args)
    if not args.db.exists():
        raise RuntimeError(f"bb database not found: {args.db}")
    if not args.claude_projects.exists():
        raise RuntimeError(f"Claude projects directory not found: {args.claude_projects}")

    db = sqlite3.connect(str(args.db), timeout=60)
    db.execute("PRAGMA foreign_keys = ON")
    schema_check(db)
    roots = project_roots(db)
    candidates, files_seen, duplicate_files = discover(args.claude_projects, cutoff, args.include_subagents)
    all_entries = [
        build_entry(path, args.claude_projects, records, parse_errors, project_for_cwd(first_cwd(records), roots))
        for path, records, parse_errors in candidates
    ]
    entries, snapshot_skipped = filter_snapshots(all_entries)
    skip_titles_path = args.skip_titles_file or (Path(__file__).resolve().parent / "skip-titles.txt")
    entries, title_skipped = filter_skip_titles(entries, load_skip_titles(skip_titles_path))
    existing, native_provider_ids = existing_threads(db)
    existing_session_ids = {
        str(row[0])
        for row in db.execute("SELECT provider_thread_id FROM events WHERE type = 'thread/identity' AND provider_thread_id IS NOT NULL")
    }
    existing_thread_parts: Dict[Tuple[str, int], List[Tuple[str, List[str]]]] = defaultdict(list)
    for thread_id, title, created in db.execute(
        "SELECT id, COALESCE(title, ''), created_at FROM threads WHERE provider_id = 'claude-code' AND id LIKE 'thr_claude_%'"
    ):
        parts = thread_parts(db, thread_id)
        if parts:
            existing_thread_parts[(title, created // 5000)].append((thread_id, parts))
    filtered_entries: List[Dict[str, Any]] = []
    for entry in entries:
        source = entry["source_key"]
        if source in existing_session_ids:
            filtered_entries.append(entry)
            continue
        entry_key = (entry["title"], entry["created_at"] // 5000)
        entry_stream = entry_parts(entry)
        # Only treat sizable entries as candidate snapshots; tiny entries (e.g.
        # freshly-started sessions or failed runs) are always imported.
        if len(entry_stream) >= 10 and any(contained_in(entry_stream, thread_parts) for _, thread_parts in existing_thread_parts.get(entry_key, [])):
            snapshot_skipped += 1
        else:
            filtered_entries.append(entry)
    entries = filtered_entries
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
        "include_subagents": args.include_subagents,
        "files_seen": files_seen,
        "canonical_sources": len(entries),
        "duplicate_files_skipped": duplicate_files,
        "snapshot_duplicates_skipped": snapshot_skipped,
        "title_skipped": title_skipped,
        "existing_duplicate_threads": duplicate_existing,
        "skipped_native_threads": skipped_native,
        "new_threads": new_threads,
        "replacements_with_newer_source": replacements,
        "unchanged_existing": unchanged,
        "events_to_write": sum(len(action["entry"]["events"]) for action in actions if action["action"] not in ("unchanged", "skip_native")),
        "search_segments_to_write": sum(len(action["entry"]["segments"]) for action in actions if action["action"] not in ("unchanged", "skip_native")),
        "json_parse_errors": parse_errors,
        "threads_needing_attach": db.execute(
            "SELECT COUNT(*) FROM threads WHERE provider_id = 'claude-code' AND id LIKE 'thr_claude_%' AND (environment_id IS NULL OR model_override IS NULL)"
        ).fetchone()[0],
        "mode": "apply" if args.apply else "dry-run",
    }
    print(json.dumps(summary, indent=2))
    if not args.apply:
        db.close()
        return 0

    now = int(datetime.now().astimezone().timestamp() * 1000)
    environments_created = 0
    try:
        db.execute("BEGIN IMMEDIATE")
        for action in actions:
            entry = action["entry"]
            for duplicate_id in action["remove_ids"]:
                purge_children(db, duplicate_id)
                db.execute("DELETE FROM threads WHERE id = ?", (duplicate_id,))
            if action["action"] in ("unchanged", "skip_native"):
                continue
            environment_id, created = resolve_environment(db, entry["project_id"], now)
            if environment_id is None:
                print(f"warning: no ready workspace for project {entry['project_id']}; importing thread unattached", file=sys.stderr)
            if created:
                environments_created += 1
            insert_entry(db, entry, action["thread_id"], now, action["action"] == "replace", environment_id, CLAUDE_CODE_DEFAULT_MODEL)

        healed_environment = 0
        for thread_id, in db.execute(
            "SELECT id FROM threads WHERE provider_id = 'claude-code' AND id LIKE 'thr_claude_%' AND environment_id IS NULL"
        ):
            row = db.execute("SELECT project_id FROM threads WHERE id = ?", (thread_id,)).fetchone()
            if not row:
                continue
            environment_id, created = resolve_environment(db, str(row[0]), now)
            if environment_id is None:
                continue
            if created:
                environments_created += 1
            db.execute("UPDATE threads SET environment_id = ? WHERE id = ?", (environment_id, thread_id))
            healed_environment += 1
        db.execute(
            "UPDATE threads SET model_override = ? WHERE provider_id = 'claude-code' AND id LIKE 'thr_claude_%' AND model_override IS NULL",
            (CLAUDE_CODE_DEFAULT_MODEL,),
        )
        healed_model = db.execute("SELECT changes()").fetchone()[0]
        db.execute(
            """
            UPDATE events SET environment_id = (SELECT t.environment_id FROM threads t WHERE t.id = events.thread_id)
            WHERE environment_id IS NULL AND thread_id IN (
                SELECT id FROM threads WHERE provider_id = 'claude-code' AND id LIKE 'thr_claude_%'
            )
            """
        )
        backfilled_events = db.execute("SELECT changes()").fetchone()[0]
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
    print(
        json.dumps(
            {
                "applied_new": new_threads,
                "applied_replacements": replacements,
                "removed_existing_duplicates": duplicate_existing,
                "environments_created": environments_created,
                "healed_environment": healed_environment,
                "healed_model": healed_model,
                "backfilled_events": backfilled_events,
            }
        )
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
