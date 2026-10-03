#!/usr/bin/env bash
# Check that the bb setup actually landed. Exits non-zero if anything failed.
# Usage: ./verify.sh

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$REPO/manifest"
BB_DATA="${BB_DATA_DIR:-$HOME/.bb}"
FILES="$REPO/files"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
note() { printf '        %s\n' "$*"; }
# BSD stat (macOS) and GNU stat (Linux) spell the mode differently.
perm_of() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

echo
echo "bootstrap self-test"
# A non-zero exit from the script is the failure mode that hides everything
# after it, so check the exit status explicitly rather than only reading output.
if bash "$REPO/bootstrap.sh" --dry-run >/tmp/bb-verify-dryrun.log 2>&1; then
  ok "bootstrap.sh --dry-run completes (exit 0)"
else
  rc=$?
  no "bootstrap.sh --dry-run exited $rc"
  tail -5 /tmp/bb-verify-dryrun.log | sed 's/^/        /'
fi
# And it must not have written anything.
if [ -f "$HOME/.claude/CLAUDE.md" ]; then
  before="$(cksum "$HOME/.claude/CLAUDE.md" 2>/dev/null)"
  bash "$REPO/bootstrap.sh" --dry-run >/dev/null 2>&1 || true
  after="$(cksum "$HOME/.claude/CLAUDE.md" 2>/dev/null)"
  [ "$before" = "$after" ] && ok "--dry-run is inert" || no "--dry-run modified a file"
fi

echo
echo "pure helpers (regression)"
# --dry-run skips the paths that do the real work, so the shared helpers are
# exercised directly here against a temporary tree. The no-placeholder case is
# the important one: most skills contain no __HOME__, and a grep that matches
# nothing must not abort the run under `set -o pipefail`.
# shellcheck source=lib/helpers.sh
(
  set -euo pipefail
  . "$REPO/lib/helpers.sh"
  info() { :; }
  warn() { :; }
  die()  { printf 'died: %s\n' "$*" >&2; exit 1; }
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/no-placeholder" "$T/with-placeholder/sub" "$T/src/nested"
  printf -- '---\nname: t\ndescription: t\n---\n\nbody\n' > "$T/no-placeholder/SKILL.md"
  printf '__HOME__/x\n' > "$T/with-placeholder/sub/a.md"
  printf 'kept\n' > "$T/src/nested/b.md"
  mkdir -p "$T/src/node_modules" && printf 'junk\n' > "$T/src/node_modules/j.js"
  mkdir -p "$T/dst" && printf 'stale\n' > "$T/dst/STALE.md"   # must be removed by the mirror
  # the case that previously aborted the whole run
  expand_home "$T/no-placeholder"
  expand_home "$T/with-placeholder"
  copy_tree "$T/src" "$T/dst"
  # Each assertion is an explicit if. A bare "test && exit 1" returns non-zero
  # when the test passes, which aborts under set -e instead of reporting.
  if grep -q __HOME__ "$T/with-placeholder/sub/a.md"; then exit 1; fi
  if [ ! -f "$T/dst/nested/b.md" ]; then exit 1; fi
  if [ -d "$T/dst/node_modules" ]; then exit 1; fi
  if [ -f "$T/dst/STALE.md" ]; then exit 1; fi
)
if [ $? -eq 0 ]; then
  ok "shared helpers behave on empty, nested, and stale trees"
else
  no "a shared helper misbehaved (see lib/helpers.sh)"
fi

echo
echo "bb version"
if command -v bb >/dev/null; then
  v="$(bb --version 2>/dev/null)"
  want="$(grep -E '^bb=' "$MANIFEST/versions.txt" | cut -d= -f2 || true)"
  [ "$v" = "$want" ] && ok "bb $v" || { no "bb $v (pinned $want)"; note "update bb or the pin"; }
else
  no "bb not on PATH"; note "install bb.app, then re-run bootstrap.sh"
fi

echo
echo "bb skills"
missing=0
for d in "$REPO"/files/bb-skills/*/; do
  name="$(basename "$d")"
  [ -f "$BB_DATA/skills/$name/SKILL.md" ] || { no "skill $name"; missing=1; }
done
[ "$missing" = 0 ] && ok "all $(ls -1 "$REPO"/files/bb-skills | wc -l | tr -d ' ') user skills present"
# bb must actually see them, not just find the files on disk
if command -v bb >/dev/null; then
  for d in "$REPO"/files/bb-skills/*/; do
    name="$(basename "$d")"
    bb skill list 2>/dev/null | grep -q "$name" || { no "bb does not list skill $name"; note "a symlinked skill dir is not discovered; copy real files"; }
  done
fi

echo
echo "plugins"
if command -v bb >/dev/null; then
  bb plugin list --json > /tmp/bb-verify-plugins.json 2>/dev/null
  python3 - "$MANIFEST/plugins.json" <<'PY'
import json,sys
want={p['id']:p['enabled'] for p in json.load(open(sys.argv[1]))}
try: have={p['id']:p['enabled'] for p in json.load(open('/tmp/bb-verify-plugins.json'))['plugins']}
except Exception as e:
    print('  \033[31mFAIL\033[0m  could not read plugin list: %s'%e); sys.exit(0)
# A row marked unavailable cannot be installed anywhere, so its absence is the
# expected outcome rather than a failure.
unavail={p['id'] for p in json.load(open(sys.argv[1])) if p.get('unavailable')}
want={i:e for i,e in want.items() if i not in unavail}
missing=[i for i in want if i not in have]
wrongstate=[i for i in want if i in have and have[i]!=want[i]]
if unavail:
    print('  \033[33mNOTE\033[0m  %d plugin(s) are unavailable upstream and were skipped: %s'%(len(unavail),', '.join(sorted(unavail))))
if missing:
    print('  \033[31mFAIL\033[0m  %d plugin(s) not installed: %s'%(len(missing),', '.join(missing)))
else:
    print('  \033[32mPASS\033[0m  all %d installable plugins installed'%len(want))
if wrongstate:
    print('  \033[31mFAIL\033[0m  %d plugin(s) wrong enabled state: %s'%(len(wrongstate),', '.join(wrongstate)))
else:
    print('  \033[32mPASS\033[0m  enabled/disabled state matches')
PY
fi

echo
echo "ACP agents"
if command -v bb >/dev/null; then
  agents="$(bb plugin config provider-acp 2>/dev/null | head -1)"
  case "$agents" in *devin*) ok "Devin ACP agent configured" ;; *) no "Devin ACP agent missing"; note "bb plugin config provider-acp set customAgents '<json>'" ;; esac
  case "$agents" in *prime-agent*) ok "Prime Agent ACP agent configured" ;; *) no "Prime Agent ACP agent missing" ;; esac
fi
for f in devin-acp-writefix.mjs pa-acp.sh; do
  [ -x "$BB_DATA/bin/$f" ] && ok "~/.bb/bin/$f executable" || { no "~/.bb/bin/$f missing or not executable"; }
done
# The shim captured a node path from the source Mac. That is only wrong when it
# points at some *other* home directory; on the source Mac it is correct.
foreign_home() { # foreign_home <file> <needle>
  [ -f "$1" ] || return 1
  grep -oE '/Users/[A-Za-z0-9._-]+' "$1" 2>/dev/null | sort -u | grep -vFx "$HOME" | grep -q .
}
foreign_home "$BB_DATA/bin/pa-acp.sh" && { no "pa-acp.sh points at another Mac's home"; note "re-run bootstrap.sh so it rewrites the path"; }
# An unsubstituted placeholder means a file was copied without expansion.
if grep -rq '__HOME__' "$BB_DATA/skills" "$FILES" 2>/dev/null; then
  if grep -rq '__HOME__' "$BB_DATA/skills" 2>/dev/null; then
    no "an installed file still contains the __HOME__ placeholder"
    { grep -rl '__HOME__' "$BB_DATA/skills" 2>/dev/null || true; } | head -3 | sed 's/^/        /'
    note "re-run bootstrap.sh"
  fi
fi

echo
echo "providers"
if command -v bb >/dev/null; then
  prov="$(bb provider list 2>/dev/null | tail -n +3 | awk '{print $1}' | tr '\n' ' ')"
  note "found: $prov"
  # Required: without these there is no thread to run.
  for p in codex claude-code; do
    case " $prov " in *" $p "*) ok "provider $p" ;; *) no "provider $p missing" ;; esac
  done
  # Optional: these ACP agents appear only when their own CLI is installed and
  # signed in. A missing one is a gap in the setup, not a failed install.
  for p in acp-devin acp-prime-agent; do
    case " $prov " in
      *" $p "*) ok "provider $p" ;;
      *) note "provider $p not present; its CLI is not installed or not signed in, so it is skipped rather than failed" ;;
    esac
  done
  case " $prov " in
    *" acp-opencode "*) ok "provider acp-opencode" ;;
    *) note "provider acp-opencode not present; install with: npm install -g opencode-ai" ;;
  esac
fi

echo
echo "bb settings"
if command -v bb >/dev/null; then
  want_theme="$(python3 -c "import json;print(json.load(open('$MANIFEST/bb-settings.json'))['appearance']['themeId'])")"
  got_theme="$(bb theme show --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('themeId',''))" 2>/dev/null)"
  [ "$got_theme" = "$want_theme" ] && ok "theme $got_theme" || no "theme is '$got_theme', expected '$want_theme'"
  instr="$(bb instructions get 2>/dev/null)"
  [ -n "$instr" ] && ok "custom instructions set" || no "custom instructions empty"
fi

echo
echo "opencodex proxy"
if command -v ocx >/dev/null; then
  ocx status >/dev/null 2>&1 && ok "ocx proxy responding" || { no "ocx proxy not running"; note "ocx service && ocx sync"; }
  # The proxy sets ANTHROPIC_BASE_URL for the whole user session, so a stopped
  # proxy breaks every Claude app launched after it stopped.
  env_url="$(launchctl getenv ANTHROPIC_BASE_URL 2>/dev/null || true)"
  if [ -n "$env_url" ]; then
    ok "ANTHROPIC_BASE_URL points at the proxy ($env_url)"
    note "if the proxy is not running, Claude apps cannot reach Anthropic at all"
  else
    note "ANTHROPIC_BASE_URL is not set, so Claude apps are not routed through the proxy"
  fi
  CFG="$HOME/.opencodex/config.json"
  if [ -f "$CFG" ]; then
    perm="$(perm_of "$CFG")"
    [ "$perm" = "600" ] && ok "ocx config mode 600" || { no "ocx config mode $perm, expected 600"; }
    left="$(python3 -c "
import json;c=json.load(open('$CFG'))
print(sum(1 for p in c.get('providers',{}).values() if p.get('apiKey')=='<redacted>'))" 2>/dev/null)"
    [ "$left" = "0" ] && ok "no redacted keys left" || { no "$left API key(s) still '<redacted>'"; note "re-run: ./bootstrap.sh"; }
  else
    no "no ~/.opencodex/config.json"
  fi
else
  no "ocx not on PATH"
fi

echo
echo "model routing stays fresh"
for f in catalog-maintenance.sh model-gap-check.sh; do
  [ -x "$HOME/.opencodex/$f" ] && ok "$f installed and executable" || no "$f missing or not executable in ~/.opencodex"
done
if [ "$(uname -s)" = "Darwin" ]; then
  if launchctl list 2>/dev/null | grep -q 'ai.opencodex.catalog-maintenance'; then
    ok "hourly catalog-maintenance job is loaded"
  else
    no "hourly catalog-maintenance job is not loaded"
    note "launchctl load ~/Library/LaunchAgents/ai.opencodex.catalog-maintenance.plist"
  fi
else
  note "no launchd on this platform; confirm the catalog refresh is scheduled by cron or systemd"
fi
if command -v bb >/dev/null && bb automation list --project proj_personal 2>/dev/null | grep -q 'Sync model catalogs'; then
  ok "bb automation 'Sync model catalogs' present"
else
  no "bb automation 'Sync model catalogs' missing"
  note "see the README for the command; the launchd job covers the same ground"
fi

echo
echo "opencode keys"
for k in opencode-api-key meta-api-key; do
  f="$HOME/.config/opencode/$k"
  [ -s "$f" ] && ok "$k present" || { no "$k missing or empty"; note "write it, chmod 600"; }
done

echo
echo "Claude Code"
[ -f "$HOME/.claude/CLAUDE.md" ] && ok "~/.claude/CLAUDE.md" || no "~/.claude/CLAUDE.md missing"
[ -f "$HOME/.claude/settings.json" ] && ok "~/.claude/settings.json" || no "~/.claude/settings.json missing"
python3 -c "
import json;d=json.load(open('$HOME/.claude/settings.json'))
print('  \033[32mPASS\033[0m  hooks wired: '+', '.join(d.get('hooks',{}))) if d.get('hooks') else print('  \033[31mFAIL\033[0m  no hooks in settings.json')" 2>/dev/null
foreign_home "$HOME/.claude/settings.json" && { no "settings.json points at another Mac's home"; note "re-run bootstrap.sh"; }

echo
echo "secrets hygiene (this repo)"
# A credential is a literal secret value. A "{file:...}" reference is a pointer
# to a key file, and "<redacted>" is the placeholder: neither is a leak.
LEAKS="$(grep -rnoE '"(apiKey|token|secret|password|bearerValue)"[[:space:]]*:[[:space:]]*"[^"]*"' "$REPO" --include='*.json' 2>/dev/null \
  | grep -v '<redacted>' | grep -v '{file:' || true)"
if [ -n "$LEAKS" ]; then
  no "a literal credential is committed in this repo"
  printf '%s\n' "$LEAKS" | head -5
else
  ok "no literal credentials in tracked JSON"
fi
# Belt and braces: anything that looks like a real key shape.
if grep -rqnE '\b(sk-|ghp_|gho_|bbcred_|xoxb-)[A-Za-z0-9_-]{16,}' "$REPO" 2>/dev/null; then
  no "a credential-shaped string is present somewhere in the repo"
  { grep -rnoE '\b(sk-|ghp_|gho_|bbcred_|xoxb-)[A-Za-z0-9_-]{16,}' "$REPO" 2>/dev/null || true; } | head -5 | sed 's/^/        /'
else
  ok "no credential-shaped strings"
fi

echo
if [ "$fail" -gt 0 ]; then
  printf '\033[31m%d passed, %d failed\033[0m\n\n' "$pass" "$fail"
  exit 1
fi
printf '\033[32mall %d checks passed\033[0m\n\n' "$pass"
