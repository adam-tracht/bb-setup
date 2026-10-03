# Shared helpers for bootstrap.sh and verify.sh.
#
# These live in one file on purpose: an earlier copy lived inside bootstrap.sh
# and was duplicated into verify.sh for testing, which let the two drift. Both
# scripts source this instead.
#
# Sourced, never executed. Callers define DRY_RUN, REPO, and the log helpers.

# Expand __HOME__ in a copied file. Committed files carry the placeholder so the
# repository is not tied to one account; install time replaces it.
_put_expand() { # _put_expand <src> <dst>
  python3 -c '
import os, sys
with open(sys.argv[1]) as f:
    s = f.read().replace("__HOME__", os.path.expanduser("~"))
with open(sys.argv[2], "w") as f:
    f.write(s)
' "$1" "$2"
}

# Install a file with a mode, expanding __HOME__. Honours DRY_RUN.
put() { # put <src> <dst> <mode>
  if [ "${DRY_RUN:-0}" = 1 ]; then info "would install $2"; return 0; fi
  _put_expand "$1" "$2"
  chmod "$3" "$2"
}

# Back up a file, honouring DRY_RUN.
copy() { # copy <src> <dst>
  if [ "${DRY_RUN:-0}" = 1 ]; then info "would back up $1 -> $2"; return 0; fi
  cp "$1" "$2"
}

# Recursively expand __HOME__ in a copied tree.
#
# grep exits 1 when it matches nothing, and under `set -o pipefail` that aborts
# the caller. Most skills contain no placeholder, so the empty match is the
# common case and must not be treated as failure.
expand_home() { # expand_home <dir>
  { grep -rl '__HOME__' "$1" 2>/dev/null || true; } | while read -r f; do
    [ -n "$f" ] || continue
    _put_expand "$f" "$f"
  done
}

# Mirror a directory in python, dropping build and cache artefacts.
#
# Python rather than rsync so it works wherever python3 does, which includes
# Windows under Git Bash or WSL where rsync is not installed. Exits 0 when the
# source has no files, which is the common case for a plain directory.
copy_tree() { # copy_tree <srcdir> <dstdir>
  python3 -c '
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
SKIP = {"node_modules", "dist", ".git", "__pycache__", ".DS_Store"}
if os.path.isdir(dst):
    shutil.rmtree(dst)
for root, dirs, files in os.walk(src):
    dirs[:] = [d for d in dirs if d not in SKIP]
    rel = os.path.relpath(root, src)
    out = dst if rel == "." else os.path.join(dst, rel)
    os.makedirs(out, exist_ok=True)
    for f in files:
        if f in SKIP:
            continue
        shutil.copy2(os.path.join(root, f), os.path.join(out, f))
' "$1" "$2"
}
# Merge the captured Claude Code settings into the machine's own.
#
# A machine that already has Claude Code set up keeps its plugins, marketplaces,
# env, and hooks; this only adds what is missing and unions lists. An earlier
# version assigned each captured key wholesale, which silently replaced
# enabledPlugins, env, and extraKnownMarketplaces on any machine that had its own
# configuration. Pass replace=1 on a clean machine to reproduce exactly instead.
merge_claude_settings() { # merge_claude_settings <src> <dst> [replace]
  python3 -c '
import json, os, re, sys

src, dst = sys.argv[1], sys.argv[2]
replace = len(sys.argv) > 3 and sys.argv[3] == "1"

raw = open(src).read()
raw = re.sub(r"(?m)^(\\s*\"(?:command|env)\"\\s*:\\s*)\"(/Users/[^\"/]+)\"",
             lambda m: m.group(1) + "\"" + os.path.expanduser("~") + "\"", raw)
want = json.loads(raw)
have = json.load(open(dst)) if os.path.exists(dst) else {}

def union_any(a, b):
    """b is the machine-side value; it wins on conflict."""
    if isinstance(a, dict) and isinstance(b, dict):
        return union_dict(b, a)
    if isinstance(a, list) and isinstance(b, list):
        return union_list(a, b)
    return b

def union_dict(a, b):
    out = dict(b)
    for k, v in a.items():
        out[k] = union_any(v, b[k]) if k in b else v
    return out

def union_list(a, b):
    out, seen = [], set()
    for item in list(a) + list(b):
        key = json.dumps(item, sort_keys=True)
        if key not in seen:
            seen.add(key)
            out.append(item)
    return out

added, kept = [], []
for k, v in want.items():
    if k not in have:
        have[k] = v
        added.append(k)
    elif replace:
        have[k] = v
        added.append(k + " (replaced)")
    elif isinstance(v, (dict, list)) and isinstance(have[k], type(v)):
        have[k] = union_any(have[k], v)
        added.append(k + " (merged)")
    else:
        kept.append(k)

json.dump(have, open(dst, "w"), indent=2)
print("added/merged: %s" % (", ".join(added) or "nothing"))
if kept:
    print("left as the machine had them: %s" % ", ".join(sorted(kept)))
' "$1" "$2" "$3"
}
