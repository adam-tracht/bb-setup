#!/bin/zsh
# Compares each provider's live model roster with what bb's picker shows.
# On a NEW gap it spawns one bb thread to handle it; unchanged gaps stay quiet.
# Providers covered: codex (ChatGPT roster). Add more as functions below.

set -u
export HOME="${HOME}"
# bb ships its CLI inside the app bundle rather than on the login PATH, so add
# the host-daemon directory when running from a desktop install.
export PATH="$HOME/.volta/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Applications/bb.app/Contents/Resources/app.asar.unpacked/node_modules/bb-app/host-daemon/dist"

readonly STATE="${HOME}/.opencodex/model-gap-state"
# proj_personal is a built-in bb project id, so it resolves on any installation.
readonly BB_PROJECT="${MODEL_GAP_BB_PROJECT:-proj_personal}"

log() { print -r -- "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') gap-check: $*"; }

codex_gaps() {
  # bb serves a cached picker list for 10 min, then refreshes in the background;
  # poke it first so the comparison below sees the refreshed list.
  bb provider models codex --json >/dev/null 2>&1; /bin/sleep 8
  /usr/bin/python3 - <<'PY'
import json, os, subprocess, urllib.request
auth = json.load(open(os.path.expanduser('~/.codex/auth.json')))['tokens']
req = urllib.request.Request(
    'https://chatgpt.com/backend-api/codex/models?client_version=0.159.0',
    headers={'Authorization': 'Bearer ' + auth['access_token'],
             'chatgpt-account-id': auth.get('account_id', ''), 'User-Agent': 'codex'})
live = {m['slug'] for m in json.load(urllib.request.urlopen(req, timeout=20))['models']
        if m.get('visibility') == 'list'}
picker = {m['id'] for m in json.loads(subprocess.check_output(['bb', 'provider', 'models', 'codex', '--json'], timeout=60))}
for slug in sorted(live - picker):
    print('codex:' + slug)
PY
}

gaps="$(codex_gaps 2>&1)" || { log "codex check failed: ${gaps}"; exit 0; }
gaps="$(print -r -- "${gaps}" | /usr/bin/sort -u | /usr/bin/sed '/^$/d')"

previous=""
[[ -f "${STATE}" ]] && previous="$(<"${STATE}")"
print -r -- "${gaps}" >| "${STATE}"

if [[ -z "${gaps}" ]]; then
  [[ -n "${previous}" ]] && log "gaps cleared"
  exit 0
fi

new="$(/usr/bin/comm -13 <(print -r -- "${previous}" | /usr/bin/sort -u) <(print -r -- "${gaps}"))"
if [[ -z "${new}" ]]; then
  log "known gaps unchanged: $(print -r -- "${gaps}" | /usr/bin/tr '\n' ' ')"
  exit 0
fi

log "new gaps: $(print -r -- "${new}" | /usr/bin/tr '\n' ' ')"
prompt_file="$(/usr/bin/mktemp)"
cat >| "${prompt_file}" <<EOF
Automated model-gap alert from ~/.opencodex/model-gap-check.sh.

These models are live at the provider but missing from the bb picker:
${new}

Use the model-routing skill. Find which layer is behind (ocx release, bb cache, bb release) with a measurement, and fix it if a safe command does (ocx update, ocx sync, refresh bb list). Do not restart Codex app-server if any turn is running. Reply in the AGENTS.md shape: answer first, one next action.
EOF
bb thread spawn --project "${BB_PROJECT}" --title "Model gap: $(print -r -- "${new}" | /usr/bin/head -1)" --prompt-file "${prompt_file}" >/dev/null 2>&1 \
  && log "spawned bb thread" || log "ERROR: bb thread spawn failed"
/bin/rm -f "${prompt_file}"
