#!/usr/bin/env bash
# Apply Adam's bb setup to this Mac. Idempotent: safe to re-run.
# Usage: ./bootstrap.sh [--skip-secrets] [--dry-run]

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$REPO/manifest"
FILES="$REPO/files"
BB_DATA="${BB_DATA_DIR:-$HOME/.bb}"
OC_KEYFILE="$HOME/.config/opencode/opencode-api-key"

SKIP_SECRETS=0
CLAUDE_MODE=merge
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --skip-secrets) SKIP_SECRETS=1 ;;
    --claude=*) CLAUDE_MODE="${arg#--claude=}" ;;
    --replace-claude-config) CLAUDE_MODE=replace ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

case "$CLAUDE_MODE" in
  merge|replace|instructions-only|skip) ;;
  *) echo "--claude must be one of: merge, replace, instructions-only, skip (got '$CLAUDE_MODE')" >&2; exit 2 ;;
esac
SKIP_CLAUDE=0
[ "$CLAUDE_MODE" = "skip" ] && SKIP_CLAUDE=1

# shellcheck source=lib/helpers.sh
. "$REPO/lib/helpers.sh"

step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '    \033[33m! %s\033[0m\n' "$*"; }
die()   { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
# Every filesystem write and state change goes through one of these three, so
# --dry-run genuinely touches nothing.
run()   { if [ "$DRY_RUN" = 1 ]; then info "would run: $*"; else "$@"; fi; }
# Install a file, expanding the __HOME__ placeholder to this machine's home.
# Committed copies carry __HOME__ so the repo is not tied to one account.

# ---------------------------------------------------------------- prereqs ---
step "Checking platform and prerequisites"
# The scripts are POSIX shell plus python3. macOS and Linux provide both
# natively. Windows needs WSL or Git Bash for bash, and python3 on PATH.
case "$(uname -s)" in
  Darwin) info "macOS $(sw_vers -productVersion 2>/dev/null || echo '?')" ;;
  Linux)  info "Linux $(uname -r)" ;;
  MINGW*|MSYS*|CYGWIN*) warn "Windows shell detected. These scripts need WSL or Git Bash, plus python3 on PATH." ;;
  *) warn "unrecognised platform $(uname -s); continuing" ;;
esac
if [ -n "${WSL_DISTRO_NAME:-}" ]; then info "running under WSL ($WSL_DISTRO_NAME)"; fi

# Python is required for file copying, placeholder substitution, and the key
# prompt. It installs as `python` rather than `python3` on Windows, so fall back
# to that name rather than failing the whole run over a symlink.
if ! command -v python3 >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    warn "python3 not found; using 'python' instead"
    python3() { python "$@"; }
  else
    die "python not found. It is required: file copying, substitutions, and the key prompt all use it. Install Python 3 and ensure 'python' or 'python3' is on PATH."
  fi
fi
info "python $(python3 -c 'import sys; print(sys.version.split()[0])' 2>/dev/null || echo '?')"
command -v node  >/dev/null || warn "node not on PATH. Needed for npm-installed CLIs (opencode, ocx); bb itself does not need it."
# rtk is the Claude Code hook that filters shell output. Optional, but the
# Personal CLAUDE.md assumes it. It is a Homebrew formula and needs no ripgrep.
command -v rtk >/dev/null || warn "rtk not found; the Claude Code hook will be a no-op. Install: brew install rtk"
info "node $(node --version 2>/dev/null || echo 'not installed')"
info "rtk $(rtk --version 2>/dev/null | head -1 || echo 'not installed')"
mkdir -p "$BB_DATA"

# The bb CLI. The desktop app does not put it on PATH, and every step below calls
# it, so check for it before doing any work. The app records its own version,
# which pins the npm package to the same build rather than whatever is latest.
if ! command -v bb >/dev/null 2>&1; then
  APP_VER=""
  for f in "$BB_DATA/bb-app-runtime.json"; do
    [ -f "$f" ] && APP_VER="$(python3 -c "import json;print(json.load(open('$f')).get('version',''))" 2>/dev/null || true)"
  done
  [ -n "$APP_VER" ] || APP_VER="latest"
  die "bb is not on PATH, and every step here needs it.
  The desktop app does not add it. Install the CLI matching the app:
    npm install -g --allow-scripts=better-sqlite3,node-pty,@parcel/watcher bb-app@${APP_VER}
  (version ${APP_VER} read from ~/.bb/bb-app-runtime.json). Then re-run this script."
fi
info "bb $(bb --version 2>/dev/null || echo '?') at $(command -v bb)"

# ------------------------------------------------------- provider tooling ---
# bb installs and updates its own provider CLIs (codex, claude-code, pi, cursor).
# Do not npm-install those: a second copy on PATH shadows the one bb manages and
# silently pins an older build. Everything below is for the tools bb does NOT
# manage, and each is optional.
step "Checking provider tooling"
# codex is the default provider, and a plugin reads rate-limit credits through
# `codex app-server`, so a machine without it is not a working setup.
#
# Ask bb to install it first, because bb places it in ~/.local/bin alongside
# claude-code and updates it itself. Falling back to npm would put a second copy
# on PATH that shadows the managed one.
if command -v codex >/dev/null 2>&1; then
  info "codex $(codex --version 2>/dev/null | head -1) (bb manages this one)"
else
  info "codex is not installed; asking bb to install it"
  MACHINE_ID="$(bb machine list --json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    ms=d if isinstance(d,list) else d.get('machines') or d.get('hosts') or []
    print(ms[0].get('id','') if ms else '')
except Exception:
    print('')" 2>/dev/null)"
  installed=0
  if [ -n "$MACHINE_ID" ]; then
    bb machine provider-cli install "$MACHINE_ID" codex --json >/dev/null 2>&1 && installed=1
  fi
  if [ "$installed" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    warn "bb could not install it; falling back to npm"
    npm install -g @openai/codex >/dev/null 2>&1 && installed=1
  fi
  if [ "$installed" = 1 ] && command -v codex >/dev/null 2>&1; then
    info "installed codex $(codex --version 2>/dev/null | head -1)"
  elif [ "$DRY_RUN" = 1 ]; then
    info "would install the codex CLI via bb, then npm as a fallback"
  else
    die "the codex CLI could not be installed. It is the default bb provider and a plugin reads rate-limit credits through it.
  Install it with: bb machine provider-cli install $(bb machine list 2>/dev/null | awk 'NR==2{print $3}') codex
  or: npm install -g @openai/codex
  Then re-run this script."
  fi
fi
if command -v claude >/dev/null; then
  info "claude $(claude --version 2>/dev/null | head -1) (bb manages this one)"
else
  warn "claude not on PATH. bb's Settings -> Machines installer provides it."
fi

# A duplicate provider CLI earlier in PATH than bb's copy is a real hazard:
# check for it and say so, rather than installing one.
# A second, different provider CLI on PATH is a real hazard: whichever comes
# first wins, and bb will then drive a build it does not manage. Compare unique
# resolved paths, so a PATH that merely repeats the same entry is not flagged.
for cli in codex claude; do
  command -v "$cli" >/dev/null || continue
  winner="$(command -v "$cli")"
  others="$(which -a "$cli" 2>/dev/null | tail -n +2 | sort -u | grep -vxF "$winner" || true)"
  if [ -n "$others" ]; then
    warn "$cli resolves to $winner but these can shadow it: $(echo "$others" | tr '\n' ' ')"
  fi
done

# opencodex is not optional here. It is the proxy every routed model goes
# through, and it is what points ANTHROPIC_BASE_URL at the local port. Treat a
# missing ocx as a reason to install it rather than a warning to ignore.
if command -v ocx >/dev/null; then
  info "ocx present ($(ocx --version 2>/dev/null | head -1))"
elif [ "$DRY_RUN" = 1 ]; then
  info "would install @bitkyc08/opencodex (required for model routing)"
else
  info "installing @bitkyc08/opencodex"
  npm install -g @bitkyc08/opencodex >/dev/null 2>&1 \
    && info "installed ocx $(ocx --version 2>/dev/null | head -1)" \
    || die "could not install @bitkyc08/opencodex. It is required: it proxies every routed model and sets ANTHROPIC_BASE_URL. Install it with: npm install -g @bitkyc08/opencodex"
fi

# opencode has to actually run, not merely exist. A binary copied from another
# machine keeps its old code signature and is killed on launch, which leaves the
# usage plugin logging query failures with no obvious cause. So execute it.
opencode_runs() { command -v opencode >/dev/null 2>&1 && opencode --version >/dev/null 2>&1; }

if opencode_runs; then
  info "opencode present and running ($(opencode --version 2>/dev/null | head -1))"
elif command -v opencode >/dev/null 2>&1; then
  # On PATH but will not start. Installing over it replaces the broken binary.
  warn "opencode is on PATH but does not run. A binary copied from another machine keeps its old code signature and is killed on launch."
  if [ "$DRY_RUN" = 1 ]; then
    info "would reinstall opencode-ai over the broken binary"
  else
    npm install -g opencode-ai >/dev/null 2>&1
    if opencode_runs; then
      info "reinstalled opencode ($(opencode --version 2>/dev/null | head -1))"
    else
      warn "still does not run. Install it with: curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path"
    fi
  fi
elif [ "$DRY_RUN" = 1 ]; then
  info "would install opencode-ai (the acp-opencode provider)"
else
  info "installing opencode-ai"
  npm install -g opencode-ai >/dev/null 2>&1
  if opencode_runs; then
    info "installed opencode ($(opencode --version 2>/dev/null | head -1))"
  else
    warn "could not install opencode, so the acp-opencode provider is unavailable. Run: curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path"
  fi
fi

# ------------------------------------------------------------- bb skills ---
step "Installing bb user skills"
# Real directories, not symlinks: verified bb does not discover a symlinked skill dir.
for d in "$FILES"/bb-skills/*/; do
  [ -f "$d/SKILL.md" ] || continue
  name="$(basename "$d")"
  if [ "$DRY_RUN" = 1 ]; then
    info "would install skill $name"
  else
    copy_tree "$d" "$BB_DATA/skills/$name"
    expand_home "$BB_DATA/skills/$name"
    info "skill $name"
  fi
done

# ------------------------------------------------------- bb instructions ---
step "Installing bb user instructions"
put "$FILES/bb-AGENTS.md" "$BB_DATA/AGENTS.md" 644
if [ "$DRY_RUN" = 0 ] && command -v bb >/dev/null; then
  instructions=$(python3 -c "import json;print(json.load(open('$MANIFEST/plugin-config.json'))['custom-instructions']['instructions'])")
  bb instructions set "$instructions" >/dev/null && info "custom instructions set"
fi

# ------------------------------------------------------------- ACP shims ---
step "Installing ACP agent shims"
mkdir -p "$BB_DATA/bin"
for f in devin-acp-writefix.mjs pa-acp.sh; do
  [ -f "$FILES/bb-bin/$f" ] || continue
  put "$FILES/bb-bin/$f" "$BB_DATA/bin/$f" 755
done
# The prime-agent shim ships with a placeholder node path. Point it at whatever
# prime-agent is on PATH on this machine.
if [ "$DRY_RUN" = 0 ]; then
  shim="$BB_DATA/bin/pa-acp.sh"
  real="$(command -v prime-agent || true)"
  if [ -n "$real" ]; then
    info "pointing pa-acp.sh at $real"
    python3 - "$shim" "$real" <<'PY'
import re,sys
p,real=sys.argv[1],sys.argv[2]
s=open(p).read()
s=re.sub(r'(?m)^export PATH=.*$','export PATH="%s:$PATH"'%('/'.join(real.split('/')[:-2])),s)
s=re.sub(r'(?m)^PRIME_AGENT_BIN=.*$','PRIME_AGENT_BIN="%s"'%real,s)
open(p,'w').write(s)
PY
  else
    warn "prime-agent not on PATH; pa-acp.sh keeps its placeholder. Install prime-agent, then re-run."
  fi
fi

# ---------------------------------------------------------- marketplaces ---
step "Adding plugin marketplaces"
python3 - "$MANIFEST/marketplaces.json" <<'PY' > /tmp/bb-setup-mkts.txt
import json,sys
for m in json.load(open(sys.argv[1])):
    print(m['name'], m['source'])
PY
while read -r name source; do
  [ -n "$name" ] || continue
  if [ "$DRY_RUN" = 1 ]; then info "would add marketplace $name"; continue; fi
  if bb marketplace list --json 2>/dev/null | python3 -c "import json,sys;print('$name' in [m['name'] for m in json.load(sys.stdin)])" | grep -q True; then
    info "marketplace $name already present"
  else
    bb marketplace add "$source" --json >/dev/null 2>&1 && info "added marketplace $name" || warn "could not add $name"
  fi
done < /tmp/bb-setup-mkts.txt

# --------------------------------------------------------------- plugins ---
PLUGIN_COUNT=$(python3 -c "import json;print(len(json.load(open('$MANIFEST/plugins.json'))))")
step "Installing plugins (this is the slow part; $PLUGIN_COUNT plugins)"
python3 - "$MANIFEST/plugins.json" > /tmp/bb-setup-plugins.txt <<'PY'
import json,sys
# Field order: state, id, install target, subdirectory, tagPrefix.
# The catalog form is a bare id@marketplace; the git form carries flags.
for p in json.load(open(sys.argv[1])):
    state='SKIP' if p.get('unavailable') else ('1' if p['enabled'] else '0')
    target=p['catalog']+'@bb-community' if p.get('catalog') else p.get('source','')
    print(state, p['id'], target, p.get('subdirectory',''), p.get('tagPrefix',''))
PY

install_count=0
: > /tmp/bb-setup-failures.txt
while read -r enabled id target subdir tagprefix; do
  [ -n "$id" ] || continue
  if [ "$enabled" = "SKIP" ]; then
    warn "skipping $id: $(python3 -c "
import json;print(next(r.get('unavailable','') for r in json.load(open('$MANIFEST/plugins.json')) if r['id']=='$id'))")"
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then info "would install $id"; install_count=$((install_count+1)); continue; fi

  if bb plugin list --json 2>/dev/null | python3 -c "import json,sys;print(any(p['id']=='$id' for p in json.load(sys.stdin)['plugins']))" | grep -q True; then
    info "present  $id"
  else
    # A monorepo needs its subdirectory, and often a tag prefix, or bb cannot
    # tell which plugin inside the repository is meant.
    if [ -n "$subdir" ] || [ -n "$tagprefix" ]; then
      flags=""
      [ -n "$subdir" ] && flags="--subdirectory $subdir"
      [ -n "$tagprefix" ] && flags="$flags --tag-prefix $tagprefix"
      bb plugin install "$target" $flags --yes --json >/dev/null 2>&1 \
        && info "installed $id ($subdir)" || { warn "FAILED $id"; echo "$id" >> /tmp/bb-setup-failures.txt; }
    else
      bb plugin install "$target" --yes --json >/dev/null 2>&1 \
        && info "installed $id" || { warn "FAILED $id"; echo "$id" >> /tmp/bb-setup-failures.txt; }
    fi
    install_count=$((install_count+1))
  fi

  if [ "$enabled" = "1" ]; then
    bb plugin enable "$id" >/dev/null 2>&1 || { warn "could not enable $id"; echo "$id (enable)" >> /tmp/bb-setup-failures.txt; }
  else
    bb plugin disable "$id" >/dev/null 2>&1 || { warn "could not disable $id"; echo "$id (disable)" >> /tmp/bb-setup-failures.txt; }
  fi
done < /tmp/bb-setup-plugins.txt
info "processed $install_count new installs"

if [ -s /tmp/bb-setup-failures.txt ] && [ "$DRY_RUN" = 0 ]; then
  step "Plugins that did not complete"
  sort -u /tmp/bb-setup-failures.txt | while read -r f; do info "$f"; done
  info "re-run after fixing the cause; the script is safe to re-run"
fi

# Builtin plugins ship with bb and are not installed, only toggled. Only the
# ones switched off are listed, so builtins added by a later bb release keep
# their own default.
while read -r bid; do
  [ -n "$bid" ] || continue
  if [ "$DRY_RUN" = 1 ]; then info "would disable builtin $bid"; continue; fi
  if bb plugin list --json 2>/dev/null | python3 -c "import json,sys;print(any(p['id']=='$bid' for p in json.load(sys.stdin)['plugins']))" | grep -q True; then
    bb plugin disable "$bid" >/dev/null 2>&1 && info "disabled builtin $bid" || warn "could not disable builtin $bid"
  fi
done < <(python3 -c "
import json
for b in json.load(open('$MANIFEST/builtin-plugins.json'))['disabled']: print(b)")

# ------------------------------------------------------- plugin settings ---
step "Applying plugin settings"
if [ "$DRY_RUN" = 0 ]; then
  python3 - "$MANIFEST/plugin-config.json" > /tmp/bb-setup-pcfg.tsv <<'PY'
import json,os,sys
cfg=json.load(open(sys.argv[1]))
home=os.path.expanduser('~')
for pid,keys in cfg.items():
    if pid=='custom-instructions':      # applied earlier via `bb instructions set`
        continue
    for k,v in keys.items():
        if isinstance(v,bool):   v='true' if v else 'false'
        elif isinstance(v,(int,float)): v=str(v)
        v=v.replace('${HOME}',home)
        print(pid,k,v,sep='\t')
PY
  while IFS=$'\t' read -r pid key val; do
    [ -n "$pid" ] || continue
    bb plugin config "$pid" set "$key" "$val" >/dev/null 2>&1 \
      && info "$pid.$key" || warn "could not set $pid.$key"
  done < /tmp/bb-setup-pcfg.tsv
fi

# ----------------------------------------------------------- bb settings ---
step "Applying bb settings"
if [ "$DRY_RUN" = 0 ]; then
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] || continue
    bb settings general "$key" "$val" >/dev/null 2>&1 && info "general.$key=$val" || warn "general.$key"
  done < <(python3 -c "
import json;d=json.load(open('$MANIFEST/bb-settings.json'))['generalSettings']
[print(k,json.dumps(v),sep='\t') for k,v in d.items()]")

  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] || continue
    bb settings experiment "$key" "$val" >/dev/null 2>&1 && info "experiment.$key=$val" || warn "experiment.$key"
  done < <(python3 -c "
import json;d=json.load(open('$MANIFEST/bb-settings.json'))['experiments']
[print(k,json.dumps(v),sep='\t') for k,v in d.items()]")

  theme=$(python3 -c "import json;print(json.load(open('$MANIFEST/bb-settings.json'))['appearance']['themeId'])")
  fav=$(python3 -c "import json;print(json.load(open('$MANIFEST/bb-settings.json'))['appearance']['faviconColor'])")
  bb theme set "$theme" >/dev/null 2>&1 && info "theme=$theme" || warn "theme $theme"
  bb theme favicon set "$fav" >/dev/null 2>&1 && info "favicon=$fav" || warn "favicon $fav"
fi

# ------------------------------------------------- ui + thread-list prefs ---
step "Applying sidebar and thread-list preferences"
if [ "$DRY_RUN" = 0 ]; then
  # Skip any preference whose value embeds a project/thread/environment id from
  # the source Mac: those ids do not exist on this machine.
  python3 - "$MANIFEST/ui-preferences.json" > /tmp/bb-setup-ui.tsv <<'PY'
import json,re,sys
ID=re.compile(r'\b(proj|thr|env|host)_[0-9a-z]{6,}')
for k,v in json.load(open(sys.argv[1])).items():
    raw=v if isinstance(v,str) else json.dumps(v)
    if ID.search(raw):
        print('SKIP\t'+k, file=sys.stderr); continue
    # scalars go through bare, lists and null as JSON. bb parses either.
    print(k, raw, sep='\t')
PY
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] || continue
    bb settings ui set "$key" "$val" >/dev/null 2>&1 && info "ui.$key" || warn "ui.$key"
  done < /tmp/bb-setup-ui.tsv
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] || continue
    bb thread-list prefs set "$key" "$val" >/dev/null 2>&1 && info "thread-list.$key" || warn "thread-list.$key"
  done < <(python3 -c "
import json;d=json.load(open('$MANIFEST/thread-list-prefs.json'))
[print(k,json.dumps(v),sep='\t') for k,v in d.items()]")
fi

# ---------------------------------------------------------- claude code ---
step "Installing Claude Code config (CLAUDE.md, hooks, reference docs)"
if [ "$DRY_RUN" = 0 ] && [ "$SKIP_CLAUDE" = 0 ]; then
  mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/reference" "$HOME/.claude/scripts"
fi
if [ -f "$HOME/.claude/CLAUDE.md" ] && ! cmp -s "$FILES/claude-CLAUDE.md" "$HOME/.claude/CLAUDE.md"; then
  # Never overwrite someone's instructions without a copy to fall back on.
  _bak="$HOME/.claude/CLAUDE.md.bak-$(date +%Y%m%d-%H%M%S)"
  copy "$HOME/.claude/CLAUDE.md" "$_bak" && [ "$DRY_RUN" = 0 ] && info "backed up the existing CLAUDE.md to $_bak"
fi
put "$FILES/claude-CLAUDE.md" "$HOME/.claude/CLAUDE.md" 644
for f in "$FILES"/claude-hooks/*.sh;   do [ -f "$f" ] && put "$f" "$HOME/.claude/hooks/$(basename "$f")"   755; done
for f in "$FILES"/claude-reference/*.md; do [ -f "$f" ] && put "$f" "$HOME/.claude/reference/$(basename "$f")" 644; done
for f in "$FILES"/claude-scripts/*.sh; do [ -f "$f" ] && put "$f" "$HOME/.claude/scripts/$(basename "$f")" 755; done
if [ -f "$FILES/claude-statusline-command.sh" ]; then put "$FILES/claude-statusline-command.sh" "$HOME/.claude/statusline-command.sh" 644; fi
if [ -f "$FILES/ccstatusline-settings.json" ]; then put "$FILES/ccstatusline-settings.json" "$HOME/.config/ccstatusline/settings.json" 644; fi

# Claude Code settings are merged, not overwritten, so a machine that already has
# Claude Code set up keeps its own plugins, marketplaces, env, and hooks. Use
# --replace-claude-config on a clean machine to reproduce exactly, or --skip-claude
# to leave the file alone entirely.
if [ "$SKIP_CLAUDE" = 1 ]; then
  step "Skipping Claude Code configuration"
  info "omit --claude=skip to install it"
elif [ "$DRY_RUN" = 1 ]; then
  step "Claude Code configuration (--claude=$CLAUDE_MODE)"
  case "$CLAUDE_MODE" in
    instructions-only) info "would install CLAUDE.md and reference docs only; settings.json, hooks and plugins untouched" ;;
    skip) info "would do nothing" ;;
    *) info "would merge ~/.claude/settings.json (existing plugins, env and hooks are kept)" ;;
  esac
else
  step "Claude Code configuration (--claude=$CLAUDE_MODE)"
  if [ "$CLAUDE_MODE" != "instructions-only" ] && [ -f "$HOME/.claude/settings.json" ]; then
    info "merging into the existing ~/.claude/settings.json"
  elif [ "$CLAUDE_MODE" != "instructions-only" ]; then
    info "creating ~/.claude/settings.json"
  fi
  if [ "$CLAUDE_MODE" != "instructions-only" ]; then
    mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/reference" "$HOME/.claude/scripts"
    merge_claude_settings "$FILES/claude-settings.json" "$HOME/.claude/settings.json" "$([ "$CLAUDE_MODE" = replace ] && echo 1 || echo 0)" | while read -r line; do info "$line"; done
  else
    info "instructions-only: CLAUDE.md and reference docs, leaving settings.json, hooks and plugins alone"
  fi
fi

# ------------------------------------------------------------------- ocx ---
step "Installing opencodex (ocx) proxy config"
if [ "$DRY_RUN" = 0 ]; then mkdir -p "$HOME/.opencodex"; fi
OCX_CFG="$HOME/.opencodex/config.json"
if [ -f "$OCX_CFG" ] && [ ! -f "$OCX_CFG.bak-setup" ]; then
  copy "$OCX_CFG" "$OCX_CFG.bak-setup"
fi
if [ ! -f "$OCX_CFG" ]; then
  put "$FILES/ocx/config.template.json" "$OCX_CFG" 600
  info "installed redacted template at ~/.opencodex/config.json"
else
  info "existing ~/.opencodex/config.json left in place (delete it first to re-template)"
fi

if [ "$SKIP_SECRETS" = 1 ] || [ "$DRY_RUN" = 1 ]; then
  warn "skipping API keys (--skip-secrets); see the README for the commands"
else
  step "Entering provider API keys"
  # One prompt per provider. A provider whose key is skipped is marked disabled
  # rather than left holding a "<redacted>" placeholder: an unkeyed provider still
  # advertises every one of its models, which fills the pickers with rows that
  # cannot answer. See the README for the flag and the restart it needs.
  python3 - "$OCX_CFG" "$OC_KEYFILE" <<'KEYS'
import getpass, json, os, stat, sys

cfg_path, oc_keyfile = sys.argv[1], sys.argv[2]
cfg = json.load(open(cfg_path))
providers = cfg.get('providers', {})

# The opencode-go provider and the opencode CLI share one key.
shared_note = '  (also written to ~/.config/opencode/opencode-api-key; both use the same key)'

changed = False
for pid, pv in providers.items():
    if not isinstance(pv, dict):
        continue
    if pv.get('apiKey') != '<redacted>' and not pv.get('disabled'):
        continue
    if pv.get('apiKey') == '<redacted>':
        print('\n  API key for provider: %s%s' % (pid, shared_note if pid == 'opencode-go' else ''))
        val = getpass.getpass('  > ')
        if val:
            pv['apiKey'] = val
            pv['disabled'] = False
            changed = True
            if pid == 'opencode-go':
                try:
                    parent = os.path.dirname(oc_keyfile)
                    if parent:
                        os.makedirs(parent, exist_ok=True)
                    with open(oc_keyfile, 'w') as f:
                        f.write(val)
                    os.chmod(oc_keyfile, stat.S_IRUSR | stat.S_IWUSR)
                    print('    saved to both the proxy config and the opencode key file')
                except OSError as e:
                    print('    WARNING: could not write %s: %s' % (oc_keyfile, e))
            else:
                print('    saved')
        else:
            pv['disabled'] = True
            print('    skipped, so this provider is disabled and its models are not listed')
    elif pv.get('disabled'):
        print('\n  provider %s is disabled; press Enter to leave it disabled' % pid)
        val = getpass.getpass('  > ')
        if val:
            pv['apiKey'] = val
            pv['disabled'] = False
            changed = True
            print('    enabled')

if changed:
    json.dump(cfg, open(cfg_path, 'w'), indent=1)
    os.chmod(cfg_path, stat.S_IRUSR | stat.S_IWUSR)
    print('\n  wrote %s (mode 600)' % cfg_path)
    print('  Restart the proxy for the change to take effect: ocx service restart')
KEYS
fi

# The proxy must be running, not merely installed. ocx registers a launchd job
# and sets ANTHROPIC_BASE_URL at the user level, so every Claude app started after
# this points at 127.0.0.1:10100. If the proxy is not running, those apps cannot
# reach Anthropic at all.
step "Starting the model-routing proxy"
if [ "$DRY_RUN" = 1 ]; then
  info "would run: ocx service   (installs the com.opencodex.proxy launchd job)"
elif command -v ocx >/dev/null 2>&1; then
  ocx service >/dev/null 2>&1 && info "proxy service installed and started" \
    || warn "could not start the proxy with 'ocx service'. Run it by hand, then 'ocx ready' to confirm."
  sleep 2
  if ocx ready --json >/dev/null 2>&1; then
    info "proxy is ready"
  else
    warn "the proxy did not report ready. ANTHROPIC_BASE_URL points at it, so Claude apps will fail to reach Anthropic until it is up. Check: ocx status"
  fi
else
  warn "ocx is not installed, so the proxy cannot be started"
fi

# ------------------------------------------------- ocx scheduled maintenance ---
# Without this the model catalogs go stale and bb's picker silently drops new
# models. Installs the two scripts and the hourly launchd job, and creates the
# bb automation that keeps the proxy and the opencode list warm.
step "Installing ocx scheduled maintenance"
for f in catalog-maintenance.sh model-gap-check.sh; do
  [ -f "$FILES/ocx/$f" ] || continue
  put "$FILES/ocx/$f" "$HOME/.opencodex/$f" 700
done

if [ "$(uname -s)" = "Darwin" ]; then
  PLIST_SRC="$FILES/ocx/ai.opencodex.catalog-maintenance.plist"
  if [ -f "$PLIST_SRC" ]; then
    if [ "$DRY_RUN" = 0 ]; then mkdir -p "$HOME/Library/LaunchAgents"; fi
    put "$PLIST_SRC" "$HOME/Library/LaunchAgents/ai.opencodex.catalog-maintenance.plist" 644
    if [ "$DRY_RUN" = 1 ]; then
      info "would load the hourly catalog-maintenance job"
    elif launchctl unload "$HOME/Library/LaunchAgents/ai.opencodex.catalog-maintenance.plist" 2>/dev/null; then
      : # not previously loaded
    fi
    if [ "$DRY_RUN" = 0 ]; then
      if launchctl load "$HOME/Library/LaunchAgents/ai.opencodex.catalog-maintenance.plist" 2>/dev/null; then
        info "loaded hourly catalog-maintenance job"
      else
        warn "could not load the catalog-maintenance job; run: launchctl load ~/Library/LaunchAgents/ai.opencodex.catalog-maintenance.plist"
      fi
    fi
  fi
else
  warn "no launchd on this platform: schedule $HOME/.opencodex/catalog-maintenance.sh hourly with cron or a systemd timer"
fi

if [ "$DRY_RUN" = 1 ]; then
  info "would create the bb automation 'Sync model catalogs'"
elif command -v bb >/dev/null && bb automation list --project proj_personal 2>/dev/null | grep -q 'Sync model catalogs'; then
  info "bb automation 'Sync model catalogs' already present"
elif command -v bb >/dev/null; then
  # The exact flag names have moved between bb versions, so a failure here is a
  # note, not a fatal error: the launchd job covers the same ground hourly.
  bb automation create --project proj_personal --name "Sync model catalogs" \
     --cron "0 * * * *" --timezone "$(/usr/bin/date +%Z 2>/dev/null || echo UTC)" \
     --script 'ocx ensure >/dev/null 2>&1; opencode models >/dev/null 2>&1; exit 0' \
     >/dev/null 2>&1 \
     && info "created bb automation 'Sync model catalogs'" \
     || warn "could not create the bb automation; see README for the command"
fi

# -------------------------------------------------------------- opencode ---
step "Installing opencode config"
if [ "$DRY_RUN" = 0 ]; then mkdir -p "$HOME/.config/opencode"; fi
if [ -f "$HOME/.config/opencode/opencode.json" ]; then
  copy "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.json.bak-$(date +%Y%m%d-%H%M%S)"
fi
# Only the provider blocks whose key file actually exists are written. opencode
# validates the whole config at once, so one {file:...} reference to a missing
# file fails everything and `opencode models` lists nothing, which leaves bb's
# acp-opencode provider showing zero models.
write_opencode_config "$FILES/opencode/opencode.json" "$HOME/.config/opencode/opencode.json" | while read -r line; do info "$line"; done
if [ "$DRY_RUN" = 0 ] && command -v opencode >/dev/null 2>&1; then
  # The local models.dev cache ships nearly empty, so without a refresh the
  # provider lists a fraction of the real roster until something else warms it.
  if opencode models --refresh >/dev/null 2>&1; then
    n="$(opencode models 2>/dev/null | grep -c . || true)"
    info "opencode catalog refreshed (${n:-?} models listed)"
  else
    warn "could not refresh the opencode catalog; the picker may list few models until 'opencode models --refresh' succeeds"
  fi
fi

# --------------------------------------------------------------- wrap up ---
step "Done. Run ./verify.sh, then work through README section 6."
cat <<'EOF'

  Manual steps that remain:

    bb connect --code <code> --server https://adam.getbb.app   # phone access, optional
    ocx login codex          # ChatGPT account for the proxy
    claude                   # sign in, once
    devin auth login         # Devin ACP agent
    prime-agent              # sign in, once
    ocx service && ocx sync  # start the proxy and pull the model catalog
    bb provider list         # expect 7 providers

EOF
