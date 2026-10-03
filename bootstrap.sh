#!/usr/bin/env bash
# Apply Adam's bb setup to this Mac. Idempotent: safe to re-run.
# Usage: ./bootstrap.sh [--skip-secrets] [--dry-run]

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$REPO/manifest"
FILES="$REPO/files"
BB_DATA="${BB_DATA_DIR:-$HOME/.bb}"

SKIP_SECRETS=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --skip-secrets) SKIP_SECRETS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '    \033[33m! %s\033[0m\n' "$*"; }
die()   { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
# Every filesystem write and state change goes through one of these three, so
# --dry-run genuinely touches nothing.
run()   { if [ "$DRY_RUN" = 1 ]; then info "would run: $*"; else "$@"; fi; }
copy()  { # copy <src> <dst>
  if [ "$DRY_RUN" = 1 ]; then info "would back up $1 -> $2"; else cp "$1" "$2"; fi
}
# Recursively expand __HOME__ in a copied tree.
expand_home() {
  grep -rl '__HOME__' "$1" 2>/dev/null | while read -r f; do
    python3 -c "
import os,sys
p=sys.argv[1]
s=open(p).read().replace('__HOME__', os.path.expanduser('~'))
open(p,'w').write(s)" "$f"
  done
}

# Recursive copy that mirrors the source, dropping build and cache artefacts.
# Written in python rather than rsync so it works wherever python3 does, which
# includes Windows under Git Bash or WSL, where rsync is not installed.
copy_tree() { # copy_tree <srcdir> <dstdir>
  python3 -c "
import os,shutil,sys
src,dst=sys.argv[1],sys.argv[2]
SKIP={'node_modules','dist','.git','__pycache__','.DS_Store'}
if os.path.isdir(dst): shutil.rmtree(dst)
for root,dirs,files in os.walk(src):
    dirs[:]=[d for d in dirs if d not in SKIP]
    rel=os.path.relpath(root,src)
    out=dst if rel=='.' else os.path.join(dst,rel)
    os.makedirs(out,exist_ok=True)
    for f in files:
        if f in SKIP: continue
        shutil.copy2(os.path.join(root,f),os.path.join(out,f))
" "$1" "$2"
}
# Install a file, expanding the __HOME__ placeholder to this machine's home.
# Committed copies carry __HOME__ so the repo is not tied to one account.
put()   { # put <src> <dst> <mode>
  if [ "$DRY_RUN" = 1 ]; then info "would install $2"; return; fi
  python3 -c "
import os,sys
s=open(sys.argv[1]).read().replace('__HOME__', os.path.expanduser('~'))
open(sys.argv[2],'w').write(s)" "$1" "$2"
  chmod "$3" "$2"
}

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

# ------------------------------------------------------- provider tooling ---
# bb installs and updates its own provider CLIs (codex, claude-code, pi, cursor).
# Do not npm-install those: a second copy on PATH shadows the one bb manages and
# silently pins an older build. Everything below is for the tools bb does NOT
# manage, and each is optional.
step "Checking provider tooling"
if command -v codex >/dev/null; then
  info "codex $(codex --version 2>/dev/null | head -1) (bb manages this one)"
else
  warn "codex not on PATH. bb's Settings -> Machines installer provides it, or run: bb machine provider-cli install <machine> codex"
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

for opt in opencode ocx; do
  if command -v "$opt" >/dev/null; then
    info "$opt present ($("$opt" --version 2>/dev/null | head -1))"
  else
    warn "$opt missing. Needed for: $([ "$opt" = opencode ] && echo 'the acp-opencode provider' || echo 'the model-routing proxy'). Optional; install with: npm install -g $([ "$opt" = opencode ] && echo opencode-ai || echo @bitkyc08/opencodex)"
  fi
done

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
for p in json.load(open(sys.argv[1])):
    state='SKIP' if p.get('unavailable') else ('1' if p['enabled'] else '0')
    print(state, p['id'], p.get('source',''), p.get('subdirectory',''))
PY

install_count=0
: > /tmp/bb-setup-failures.txt
while read -r enabled id source subdir; do
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
    if [ -n "$subdir" ]; then
      bb plugin install "$source" --subdirectory "$subdir" --yes --json >/dev/null 2>&1 \
        && info "installed $id ($subdir)" || { warn "FAILED $id"; echo "$id" >> /tmp/bb-setup-failures.txt; }
    else
      bb plugin install "$source" --yes --json >/dev/null 2>&1 \
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
if [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/reference" "$HOME/.claude/scripts"
fi
put "$FILES/claude-CLAUDE.md" "$HOME/.claude/CLAUDE.md" 644
for f in "$FILES"/claude-hooks/*.sh;   do [ -f "$f" ] && put "$f" "$HOME/.claude/hooks/$(basename "$f")"   755; done
for f in "$FILES"/claude-reference/*.md; do [ -f "$f" ] && put "$f" "$HOME/.claude/reference/$(basename "$f")" 644; done
for f in "$FILES"/claude-scripts/*.sh; do [ -f "$f" ] && put "$f" "$HOME/.claude/scripts/$(basename "$f")" 755; done
if [ -f "$FILES/claude-statusline-command.sh" ]; then put "$FILES/claude-statusline-command.sh" "$HOME/.claude/statusline-command.sh" 644; fi
if [ -f "$FILES/ccstatusline-settings.json" ]; then put "$FILES/ccstatusline-settings.json" "$HOME/.config/ccstatusline/settings.json" 644; fi

# Merge settings.json rather than overwrite: hooks + permissions + model,
# preserving anything else already there.
if [ "$DRY_RUN" = 0 ]; then
  python3 - "$FILES/claude-settings.json" "$HOME/.claude/settings.json" <<'PY'
import json,os,re,sys
src,dst=sys.argv[1],sys.argv[2]
raw=open(src).read()
raw=re.sub(r'(?m)^(\s*"(?:command|env)"\s*:\s*)"(/Users/adamtracht|/Users/[^/"]+)"',
           lambda m: m.group(1)+'"'+os.path.expanduser('~')+'"', raw)
want=json.loads(raw)
cur=json.load(open(dst)) if os.path.exists(dst) else {}
for k,v in want.items():
    if k=='permissions':
        merged=dict(cur.get('permissions',{}))
        for pk,pv in v.items():
            merged[pk]=sorted(set(merged.get(pk,[]))|set(pv))
        cur[k]=merged
    else:
        cur[k]=v
json.dump(cur,open(dst,'w'),indent=2)
print('    ~/.claude/settings.json merged (%d top-level keys)'%len(cur))
PY
fi

# -------------------------------------------------------------- opencode ---
step "Installing opencode config"
if [ "$DRY_RUN" = 0 ]; then mkdir -p "$HOME/.config/opencode"; fi
if [ -f "$HOME/.config/opencode/opencode.json" ]; then
  copy "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.json.bak-$(date +%Y%m%d-%H%M%S)"
fi
put "$FILES/opencode/opencode.json" "$HOME/.config/opencode/opencode.json" 644
# Repoint the {file:...} key references at this machine's home.
if [ "$DRY_RUN" = 0 ]; then
  python3 - "$HOME/.config/opencode/opencode.json" <<'PY'
import json,os,re,sys
p=sys.argv[1]
raw=open(p).read()
raw=re.sub(r'\{file:/Users/[^/]+/', '{file:'+os.path.expanduser('~')+'/', raw)
open(p,'w').write(raw)
json.load(open(p))  # fail loudly if the rewrite broke the JSON
print('    key file paths repointed to '+os.path.expanduser('~'))
PY
fi
info "opencode needs its key files: ~/.config/opencode/opencode-api-key and meta-api-key (section 6)"

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
  warn "skipping API keys (--skip-secrets); see README section 6"
else
  step "Entering ocx API keys (input is hidden; press Enter to skip)"
  python3 - "$OCX_CFG" <<'PY'
import getpass,json,os,sys
p=sys.argv[1]
cfg=json.load(open(p))
providers=cfg.get('providers',{})
need=[pid for pid,pv in providers.items() if pv.get('apiKey')=='<redacted>']
for pid in need:
    print('\n  API key for provider: %s'%pid)
    val=getpass.getpass('  > ')
    if val:
        providers[pid]['apiKey']=val
        print('    saved')
    else:
        print('    skipped (still <redacted>)')
if need:
    json.dump(cfg,open(p,'w'),indent=1)
    os.chmod(p,0o600)
    print('\n  wrote %s (mode 600)'%p)
PY
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
