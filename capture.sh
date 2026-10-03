#!/usr/bin/env bash
# Re-snapshot manifest/ from the live bb on the machine running this script.
# Intended workflow: change the setup on a machine that has it applied, run this
# there, review the diff, commit, then pull and re-run bootstrap.sh elsewhere.
#
# This is how config changes propagate: edit on the source Mac, capture, push,
# then on the other Mac: git pull && ./bootstrap.sh
#
# Usage: ./capture.sh

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$REPO/manifest"
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "plugins"
bb plugin list --json > /tmp/bb-cap-plugins.json
curl -sf "https://getbb.app/marketplace/v2/marketplace.json" -o /tmp/bb-cap-catalog.json || echo '{}' > /tmp/bb-cap-catalog.json
python3 - <<'PYEOF'
import json, os, sqlite3

CATALOG = {}
try:
    for i in json.load(open('/tmp/bb-cap-catalog.json')).get('plugins', []):
        CATALOG[i['id']] = i
except Exception:
    pass

db = sqlite3.connect('file:%s?mode=ro' % os.path.expanduser('~/.bb/bb.db'), uri=True)
db.row_factory = sqlite3.Row
cols = ('source_kind source_git_url source_git_subdirectory source_git_range '
        'source_git_tag_prefix source_npm_package').split()
rows = {r['id']: r for r in db.execute('select id,' + ','.join(cols) + ' from plugins')}

installed = {p['id']: p for p in json.load(open('/tmp/bb-cap-plugins.json'))['plugins']}
old = {}
if os.path.exists('manifest/plugins.json'):
    old = {p['id']: p for p in json.load(open('manifest/plugins.json'))}

out, lost = [], []
for pid, p in installed.items():
    if p['source'].startswith('builtin:'):
        continue
    r = rows.get(pid)
    e = {'id': pid, 'enabled': p['enabled']}
    prev = old.get(pid, {})
    if not prev and not p['enabled']:
        # Disabled here and absent from the manifest means it was deliberately
        # dropped: it could not be reproduced, or it was removed from the setup.
        # Recording it again would resurrect a plugin that no longer belongs.
        continue
    if prev.get('unavailable'):
        # A recorded reason is the only place this exists; bb does not know it.
        e['unavailable'] = prev['unavailable']
        for k in ('source', 'subdirectory', 'tagPrefix'):
            if prev.get(k):
                e[k] = prev[k]
        out.append(e)
        continue
    if pid in CATALOG:
        e['catalog'] = pid
        out.append(e)
        continue
    if r and r['source_kind'] == 'npm' and r['source_npm_package']:
        e['source'] = 'npm:' + r['source_npm_package']
        out.append(e)
        continue
    src = old.get(pid, {}).get('source', '')
    if not src or src.startswith('path:'):
        lost.append(pid)
        continue
    # Prefer the database, but fall back to the manifest: a plugin installed from
    # a local checkout has no git metadata recorded, and the subdirectory it
    # lives in is the only thing that makes it installable elsewhere.
    sub = (r['source_git_subdirectory'] if r else None) or prev.get('subdirectory')
    tp = (r['source_git_tag_prefix'] if r else None) or prev.get('tagPrefix')
    if sub:
        e['subdirectory'] = sub
    if tp:
        e['tagPrefix'] = tp
    e['source'] = src
    out.append(e)

out.sort(key=lambda x: (not x['enabled'], x['id']))
json.dump(out, open('manifest/plugins.json', 'w'), indent=2)
ncat = sum(1 for x in out if 'catalog' in x)
print('  %d plugins recorded (%d via the catalog, %d with an explicit source)'
      % (len(out), ncat, len(out) - ncat))
if lost:
    print('  !! dropped, local path with no recorded source: %s' % ', '.join(sorted(lost)))
PYEOF

step "bb settings"
bb settings show --json > /tmp/bb-cap-settings.json
python3 - <<'PY'
import json
s=json.load(open('/tmp/bb-cap-settings.json'))
g=s['generalSettings']
keep=['defaultProviderId','providerCompletedTurnDisplay','telemetryEnabled','managedBranchPrefix',
      'showKeyboardHints','steerActiveThreadOnEnter','showDiagnosticEvents','streamerMode',
      'machineGitCredentialsEnabled','showUnhandledProviderEvents']
out={'generalSettings':{k:g[k] for k in keep if k in g},
     'experiments':s['experiments'],
     'appearance':{'themeId':s['appearance']['themeId'],'faviconColor':s['appearance']['faviconColor']},
     'voiceTranscriptionEnabled':s['voiceTranscriptionEnabled']}
json.dump(out,open('manifest/bb-settings.json','w'),indent=2)
print('  settings captured')
PY

step "ui preferences"
bb settings ui list > /tmp/bb-cap-ui.txt
python3 - <<'PY'
import json,re
ID=re.compile(r'\b(proj|thr|env|host)_[0-9a-z]{6,}')
keys=['sidebar.organizationMode','sidebar.threadGrouping.environment','sidebar.chronologicalSort',
 'sidebar.sortDirection','sidebar.manualSectionOrder','sidebar.machineSectionOrder',
 'sidebar.hiddenGroups','sidebar.collapsedSections','sidebar.collapsedThreads',
 'sidebar.footerOrder','sidebar.hiddenFooterItems','sidebar.pluginPanelOrder',
 'sidebar.visiblePluginPanels','sidebar.navigationProvider','sidebar.headerProvider','sidebar.threadListProvider']
pref={}
for line in open('/tmp/bb-cap-ui.txt'):
    if not line.startswith(('sidebar.','notes.','composer.','terminal.')): continue
    k=line.split()[0]
    if k not in keys: continue
    val=line.split(None,1)[1].rsplit('  (revision',1)[0].strip()
    if ID.search(val):
        print('  skipping %s (embeds a machine-specific id)'%k); continue
    # No filtering of list values. Verified: bb accepts a panel id naming a
    # plugin that is not installed and ignores it, so an entry left behind by a
    # removed plugin is harmless. Filtering here previously deleted built-in
    # section names such as 'pinned' and 'threads' because they are not plugin
    # ids, which corrupted the sidebar configuration.
    pref[k]=val
json.dump(pref,open('manifest/ui-preferences.json','w'),indent=2)
print('  %d ui preferences captured'%len(pref))
PY

step "thread-list preferences"
bb thread-list prefs list > /tmp/bb-cap-tl.txt
python3 - <<'PY'
import json
keep=['showProviderIcons','threadLifecycles','organizationMode','environmentGrouping',
      'chronologicalSort','sortDirection','manualSectionOrder','machineSectionOrder',
      'hiddenGroups','collapsedSections','collapsedThreads','collapsedMachines']
d={}
for line in open('/tmp/bb-cap-tl.txt'):
    p=line.rstrip('\n').split('\t')
    if len(p)>=2 and p[0] in keep:
        try: d[p[0]]=json.loads(p[1])
        except Exception: pass
json.dump(d,open('manifest/thread-list-prefs.json','w'),indent=2)
print('  %d thread-list prefs captured'%len(d))
PY

step "plugin settings"
python3 - <<'PY'
import json,os,sqlite3,glob
data=glob.glob(os.path.expanduser('~/.bb/bb.db'))
if not data:
    print('  no bb.db found; skipping'); raise SystemExit
c=sqlite3.connect('file:%s?mode=ro'%data[0],uri=True)
rows=c.execute("select plugin_id,key,value from plugin_settings").fetchall()
# Skipped because the value is a list of absolute checkout paths and project
# ids from one machine, so it cannot apply anywhere else.
SKIP={'bb-factory'}
out={}
for pid,k,v in rows:
    if pid in SKIP: continue
    if any(s in k.lower() for s in ('key','token','secret','password')): continue
    out.setdefault(pid,{})[k]=v
# custom instructions live in a plugin setting but are applied by `bb instructions set`
out.setdefault('custom-instructions',{})
json.dump(out,open('manifest/plugin-config.json','w'),indent=2)
print('  captured settings for %d plugins (skipped: %s)'%(len(out),', '.join(sorted(SKIP))))
PY

step "marketplaces"
bb marketplace list --json > /tmp/bb-cap-mkts.json
python3 - <<'PY'
import json
ms=json.load(open('/tmp/bb-cap-mkts.json'))
keep=[{'name':m['name'],'source':m['source']} for m in ms
      if m['name'] not in ('bb-official','bb-community')]
json.dump(keep,open('manifest/marketplaces.json','w'),indent=2)
print('  %d third-party marketplace(s)'%len(keep))
PY

step "versions"
{
echo "# Tool versions captured from this machine on $(date +%Y-%m-%d)"
echo "bb=$(bb --version 2>/dev/null)"
echo "node=$(node --version 2>/dev/null)"
echo "codex-cli=$(codex --version 2>/dev/null | head -1)"
echo "claude-code=$(claude --version 2>/dev/null | head -1)"
echo "devin=$(devin --version 2>/dev/null | head -1)"
echo "prime-agent=$(prime-agent --version 2>/dev/null | head -1)"
echo "opencode=$(opencode --version 2>/dev/null | head -1)"
echo "# optional tools bb does not manage:"
for t in opencode ocx; do
  command -v "$t" >/dev/null && echo "$t=$("$t" --version 2>/dev/null | head -1)"
done
} > manifest/versions.txt
echo "  versions captured"

# json.dump writes no trailing newline, which shows as diff noise on every
# capture. Normalise once here rather than at each write site.
for f in manifest/*.json; do
  [ -s "$f" ] || continue
  [ -n "$(tail -c1 "$f")" ] && printf '\n' >> "$f"
done

step "review the diff"
git -C "$REPO" --no-pager diff --stat -- manifest/ || true
echo
echo "  Inspect, then: git add manifest/ && git commit -m 'chore: re-snapshot bb config'"
