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
python3 - <<'PY'
import json,os
old={}
if os.path.exists('manifest/plugins.json'):
    old={p['id']:p for p in json.load(open('manifest/plugins.json'))}
rows=[]; lost=[]
for p in json.load(open('/tmp/bb-cap-plugins.json'))['plugins']:
    pid,s=p['id'],p['source']
    if s.startswith('builtin:'):
        continue                      # ships with the app, nothing to record
    prev=old.get(pid,{})
    if s.startswith('path:'):
        remote=prev.get('source') or prev.get('bundled')
        if remote:
            print('  ~ %s still installs from a local path (%s); keeping %s'%(pid,s,remote))
            r={'id':pid,'source':remote,'enabled':p['enabled']}
            if prev.get('subdirectory'): r['subdirectory']=prev['subdirectory']
            rows.append(r); continue
        print('  ! %s installs from a local path with no recorded source: %s'%(pid,s))
        print('    it will NOT be reproducible on another machine. Fix one of:')
        print('      - push it to a git repo and set "source" in manifest/plugins.json')
        print('      - push it to a git repo and set "source" in manifest/plugins.json')
        lost.append(pid); continue
    rows.append({'id':pid,'source':s,'enabled':p['enabled']})
rows.sort(key=lambda r:(not r['enabled'], r['id']))
json.dump(rows,open('manifest/plugins.json','w'),indent=2)
print('  %d plugins recorded'%len(rows))
if lost:
    print('  !! %d plugin(s) need a source before this snapshot is portable: %s'%(len(lost),', '.join(lost)))
PY

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
    # Drop sidebar entries that name plugins which are not in the manifest:
    # a new machine cannot render a panel for a plugin it does not have.
    if val.startswith('['):
        items=json.loads(val)
        known={p['id'] for p in json.load(open('manifest/plugins.json'))}
        builtin_prefixes=('__bb__/',)
        kept=[]
        for i in items:
            pid=i.split('/')[0]
            if pid.startswith(builtin_prefixes) or pid in known:
                kept.append(i); continue
            if any(pid==b for b in ('tasks','github','workflows','automations')):
                kept.append(i); continue
            print('  dropping %r from %s (plugin %r not in the manifest)'%(i,k,pid))
        val=json.dumps(kept,separators=(',',':'))
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
SKIP={'bb-factory'}          # repository registry points at machine-specific checkouts
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

step "review the diff"
git -C "$REPO" --no-pager diff --stat -- manifest/ || true
echo
echo "  Inspect, then: git add manifest/ && git commit -m 'chore: re-snapshot bb config'"
