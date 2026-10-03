#!/bin/zsh

set -u

export HOME="${HOME}"
export PATH="$HOME/.volta/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Resolve tools at run time rather than pinning the path they were installed to.
readonly OCX="$(command -v opencodex || true)"
readonly VOLTA="$(command -v volta || true)"
readonly JQ="$(command -v jq || true)"

if [[ -z "${OCX}" ]]; then
  print -r -- "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ERROR: opencodex not on PATH"
  exit 1
fi
readonly STATE_DIR="${HOME}/.opencodex"
readonly RUNTIME_VERSION_FILE="${STATE_DIR}/catalog-maintenance-runtime-version"

# Whatever path this run takes, finish by checking provider rosters against the
# bb picker (spawns a bb thread on a new gap).
trap '/bin/zsh "${STATE_DIR}/model-gap-check.sh"' EXIT

log() {
  print -r -- "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

active_turns() {
  local status_json
  status_json="$(${OCX} system status --json 2>/dev/null)" || return 1
  print -r -- "${status_json}" | ${JQ} -r '.memory.activeTurnCount // 0'
}

ensure_proxy() {
  if ${OCX} ready --json >/dev/null 2>&1; then
    return 0
  fi

  log "proxy was not ready; restarting the background service"
  ${OCX} stop >/dev/null 2>&1
  ${OCX} service restart >/dev/null || return 1
  ${OCX} ready --wait --timeout 30 --json >/dev/null
}

refresh_catalogs() {
  ${OCX} sync >/dev/null || return 1
  # sync-cache exits 1 when the Codex cache already matches the catalog; its
  # message then reads "did not complete (completed)". Treat that no-op as success.
  local cache_out
  cache_out="$(${OCX} sync-cache 2>&1 >/dev/null)" && return 0
  print -r -- "${cache_out}" >&2
  [[ "${cache_out}" == *"did not complete (completed)"* ]]
}

ensure_proxy || {
  log "ERROR: OpenCodex proxy could not be made ready"
  exit 1
}

# Live provider discovery is a single merged operation. It updates OpenAI,
# OpenCode Go, OpenRouter, and any provider added later.
if refresh_catalogs; then
  log "provider catalogs refreshed"
else
  log "ERROR: provider catalog refresh failed"
  exit 1
fi

update_json="$(${OCX} system update check --channel latest --json 2>/dev/null)" || {
  log "ERROR: OpenCodex release check failed"
  exit 1
}

current_version="$(print -r -- "${update_json}" | ${JQ} -r '.currentVersion // empty')"
latest_version="$(print -r -- "${update_json}" | ${JQ} -r '.latestVersion // empty')"
installed_runtime_version=""
[[ -f "${RUNTIME_VERSION_FILE}" ]] && installed_runtime_version="$(<"${RUNTIME_VERSION_FILE}")"

if [[ -z "${current_version}" || -z "${latest_version}" ]]; then
  log "ERROR: release check returned no version"
  exit 1
fi

needs_package_update=0
[[ "${current_version}" != "${latest_version}" ]] && needs_package_update=1

needs_runtime_restart=0
[[ -n "${installed_runtime_version}" && "${installed_runtime_version}" != "${current_version}" ]] && needs_runtime_restart=1

if (( needs_package_update == 0 && needs_runtime_restart == 0 )); then
  log "OpenCodex ${current_version} is current"
  exit 0
fi

turn_count="$(active_turns)" || {
  log "ERROR: could not determine active request count; deferring update"
  exit 1
}

if (( turn_count > 0 )); then
  log "update deferred: ${turn_count} active OpenCodex request(s)"
  exit 0
fi

if (( needs_package_update == 1 )); then
  log "updating OpenCodex ${current_version} -> ${latest_version}"
  if [[ -n "${VOLTA}" ]]; then
    ${VOLTA} install "@bitkyc08/opencodex@${latest_version}" >/dev/null || {
      log "ERROR: Volta package update failed"
      exit 1
    }
  else
    npm install -g "@bitkyc08/opencodex@${latest_version}" >/dev/null || {
      log "ERROR: npm package update failed"
      exit 1
    }
  fi
  current_version="${latest_version}"
fi

# No post-install turn recheck: once volta swaps the package, the running
# proxy detects its files changed and refuses all requests (healthz 503),
# so `system status` cannot run and no real turn can still be in flight.
# The pre-install check above is the only window where deferral helps.
${OCX} stop >/dev/null 2>&1
${OCX} service restart >/dev/null || {
  log "ERROR: proxy service restart failed"
  exit 1
}
${OCX} ready --wait --timeout 30 --json >/dev/null || {
  log "ERROR: updated proxy did not become ready"
  exit 1
}
refresh_catalogs || {
  log "ERROR: post-update catalog refresh failed"
  exit 1
}

print -r -- "${current_version}" >| "${RUNTIME_VERSION_FILE}"
log "OpenCodex ${current_version} activated and catalogs refreshed"
