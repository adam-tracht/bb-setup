# Alternative: enroll the new device as a second bb machine

Instead of giving the new device its own bb server, keep this MacBook Pro as the
server and add the new Mac as an enrolled machine. The new device then inherits
everything: settings, plugins, skills, threads, projects, history.

## The tradeoff

| | Own server (the main path) | Second machine |
| --- | --- | --- |
| Setup work | Full bootstrap, an hour or so | About ten minutes |
| Threads and history | Starts empty | Everything, immediately |
| Works when the server machine is off | Yes | No |
| Use both machines at once | Yes, two independent sets | Yes, but they share one server |
| Database size on the new machine | Small, starts fresh | Nothing local; it is all remote |
| Risk of a bad config change | Contained to the new machine | Breaks work on the server machine too |

The real cost of the second-machine route is that the server machine must stay awake and
plugged in. bb itself warns about this: while the server machine is asleep,
running threads may stop.

## When to pick this instead

- Existing threads and history are wanted on the new machine
- Treating the new machine as a thin client is acceptable
- The current server machine is a desktop that stays on

If any of those hold, skip `bootstrap.sh` entirely and follow this route instead.

## Steps

### 1. On the server machine

Settings -> Machines, then copy the installer command. It serves the exact
`bb-app` tarball this server is running, so the new Mac gets a matching build:

```bash
# shown in Settings -> Machines on the server
<the installer command shown in Settings -> Machines>
```

The installer enrolls the machine and installs a launchd service that keeps it
connected. It needs no sudo and no global npm configuration.

### 2. On the new Mac

Run the installer command from step 1, then start bb. It connects to the
server, and the same projects and threads are visible.

### 3. Remote reachability

The server listens on loopback only. Remote machines need one of:

- **bb Connect** (already set up here at `https://adam.getbb.app`). The new
  machine pairs through the same account.
- **A direct URL** that is reachable from the target, such as a private Tailscale
  Serve URL, passed as `--address` when the machine is created.

A configured URL is not proof of reachability. Test it from the new Mac.

### 4. What still does not transfer

Even on this route, the provider CLIs must be installed and logged in on the new
Mac, because threads execute there:

```bash
ocx login codex
claude
devin auth login
prime-agent
ocx service && ocx sync
bb provider list
```

And secrets that live in the new Mac's home directory need recreating: the
opencode key files, and the ocx API keys.

## Verifying

```bash
bb machine list          # new Mac should read connected, not just enrolled
bb provider list
```

If the machine shows enrolled but never connects, the usual cause is the server
being unreachable, not the installer. Check `bb machine show <id>` for the last error.

## Reverting

Removing the machine revokes its access. It does not touch its local files:

```bash
bb machine remove <id-or-name> --yes
```

To promote the new Mac to its own server later, use the main path in the root
README, then `bb server move --check` to see what a real move would involve.
