# RTK (Rust Token Killer)

Token-optimized CLI proxy, 60-90% savings on dev operations. A Claude Code hook rewrites shell commands transparently (`git status` becomes `rtk git status`, 0 tokens overhead), so normal usage needs nothing from you.

Read this only when RTK looks broken or you want savings analytics.

## Meta commands (always call `rtk` directly)

```bash
rtk gain              # Token savings analytics
rtk gain --history    # Command usage history with savings
rtk discover          # Analyze Claude Code history for missed opportunities
rtk proxy <cmd>       # Execute raw command without filtering (debugging)
```

## Installation check

```bash
rtk --version         # Should show: rtk X.Y.Z
rtk gain              # Should work, not "command not found"
which rtk             # Verify correct binary
```

**Name collision**: if `rtk gain` fails, you may have reachingforthejack/rtk (Rust Type Kit) installed instead.

## Git output is filtered, not ground truth

The hook rewrites `git log` / `git diff` / `git status` and shows a **curated subset**, not the literal output. A filtered `git log --oneline` can make a new commit look like it sits directly on an old one, hiding intervening commits, which reads as lost history when nothing was lost.

Never conclude anything about what is actually committed from the filtered display. Bypass it:

```bash
rtk proxy git log ...      # raw, unfiltered
rtk proxy git diff ...
```

For ancestry, trust these over any log display:

```bash
git branch --contains <sha>
git merge-base --is-ancestor <sha> HEAD; echo $?    # 0 = yes
git rev-parse HEAD origin/main
```
