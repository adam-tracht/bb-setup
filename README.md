# bb-setup

Reproduces a configured bb (agent IDE) installation on a new macOS machine.
Config as code: clone, run `./bootstrap.sh`, then complete the login steps.

Captured from bb 0.44.0. Exact tool versions are recorded in `manifest/versions.txt`.

## Contents

- 39 non-builtin bb plugins, with enabled and disabled states recorded
- 8 bb user skills
- 2 custom ACP agents, with their launch shims
- bb general settings, appearance, experiments, sidebar and thread-list preferences
- Plugin settings for every plugin that has any
- Third-party plugin marketplaces
- A personal `CLAUDE.md`, hooks, reference docs, statusline, and skill sync
- opencode provider config and an opencodex proxy config, with API keys redacted

## Plugins that install unconfigured

Some plugins install and run but have nothing to act on until a machine-specific
value is supplied. This is expected, not a failed install.

- **[bb-factory](https://github.com/adam-tracht/bb-factory)** runs queued coding
  tasks unattended on a `factory` branch. Its repository registry is a list of
  absolute checkout paths and project ids belonging to one machine, so it is not
  carried. The plugin stays disabled until repositories are added through its
  settings. The repository holds the full documentation.

## What is not carried

| Item | Reason |
| --- | --- |
| Provider logins | Codex, Claude Code, and any ACP agent authenticate per machine |
| API keys | Redacted in templates and prompted for at install time |
| bb Connect pairing | One account pairing per bb installation |
| Threads, projects, history | Live in the server database, which is machine-specific |
| Project repositories | Not part of a bb configuration |

## Topology

This setup gives the new machine **its own bb server**: an independent instance
with its own database and threads, usable while other machines are off.

The alternative, enrolling a machine against an existing server, is described in
`docs/second-machine.md`. It requires far less work and inherits threads and
history, at the cost of depending on the server machine staying awake.

## Prerequisites

| Requirement | Notes |
| --- | --- |
| bb | The desktop app. Its Settings installer also provides the provider CLIs |
| Node.js | Only for the optional npm-installed CLIs below |
| rtk | Optional. Filters shell output for Claude Code via a hook |

**Do not npm-install `codex` or `claude-code`.** bb installs and updates those
itself, and a second copy earlier in `PATH` shadows the managed one and pins an
older build. `bootstrap.sh` checks for this and warns.

Two tools are optional and not managed by bb:

```bash
npm install -g opencode-ai          # provides the acp-opencode provider
npm install -g @bitkyc08/opencodex  # the model-routing proxy (optional)
```

## Usage

```bash
git clone https://github.com/adam-tracht/bb-setup.git
cd bb-setup
./bootstrap.sh
```

Flags: `--dry-run` prints every change without touching the filesystem.
`--skip-secrets` leaves API keys for later.

The script is idempotent. Re-run it after any change to `manifest/`.

## What bootstrap.sh does

1. **Prerequisites.** Checks bb, node, and rtk; warns about duplicate provider
   CLIs on `PATH`.
2. **Provider tooling.** Reports which provider CLIs are present and which
   optional tools are missing.
3. **Skills.** Copies `files/bb-skills/*` into `~/.bb/skills/`. These are real
   directories rather than symlinks, because bb does not discover a symlinked
   skill directory.
4. **Instructions.** Installs `~/.bb/AGENTS.md` and the custom-instructions text.
5. **ACP shims.** Installs the agent launch shims into `~/.bb/bin/`, rewriting
   the Prime Agent shim to use whatever `prime-agent` is on `PATH`.
6. **Marketplaces.** Adds every marketplace in `manifest/marketplaces.json`.
7. **Plugins.** Installs each plugin in `manifest/plugins.json`, then enables or
   disables it to match. Monorepo entries install with `--subdirectory`.
8. **Plugin settings.** Applies `manifest/plugin-config.json`, expanding
   `${HOME}` in ACP agent paths.
9. **bb settings.** General settings, experiments, theme, and favicon colour.
10. **Interface preferences.** Applies sidebar and thread-list preferences, skipping
    any that embed a project, thread, or environment id from another machine.
11. **Claude Code.** Installs `CLAUDE.md`, hooks, reference docs, scripts, and
    statusline, then merges `settings.json` while preserving existing keys and
    unioning permission lists.
12. **opencode.** Installs the provider config, backing up any existing file, and
    repoints key-file references at the local home directory.
13. **opencodex.** Installs the redacted proxy config when none exists, then
    prompts for API keys with hidden input and writes them mode 600.
14. Prints the remaining manual steps.

## Manual steps after install

All of these are logins, which cannot be scripted safely.

```bash
codex                                    # sign in
claude                                   # sign in
devin auth login                         # Devin ACP agent, if used
prime-agent                              # Prime Agent ACP agent, if used
npm install -g @bitkyc08/opencodex       # if the proxy is wanted
ocx service && ocx sync                  # start the proxy, pull the catalog
bb provider list                         # confirm the provider list
```

Optional, for phone access:

```bash
bb connect --code <code> --server <server-url>
```

## Verification

```bash
./verify.sh
```

Checks the bb version, skill presence and discovery, plugin install and enabled
state, ACP agent configuration, shim executability, provider availability, theme,
ocx health and key state, opencode key files, Claude Code configuration, and
credential hygiene in the repository itself. Exits non-zero if any check fails.

## Maintenance

Configuration flows one way. Make changes on a machine running this setup, then:

```bash
./capture.sh          # re-snapshot manifest/ from the live bb
git diff -- manifest/ # review before committing
```

On the other machine:

```bash
git pull && ./bootstrap.sh
```

`capture.sh` preserves existing source URLs and warns about any plugin that
installs from a local path with no recorded source, since such a plugin cannot be
reproduced elsewhere.

## Layout

```
bootstrap.sh    applies the configuration, idempotent
verify.sh       checks an installation, non-zero exit on failure
capture.sh      re-snapshots manifest/ from a live bb

manifest/       declarative state, one file per concern
  plugins.json            39 plugins: source, enabled state, optional subdirectory
  plugin-config.json      settings per plugin
  bb-settings.json        general settings, experiments, appearance
  ui-preferences.json     sidebar layout
  thread-list-prefs.json  thread list behaviour
  marketplaces.json       third-party marketplaces
  versions.txt            tool versions at capture time

files/          copies installed onto the target
  bb-skills/              user skills
  bb-bin/                 ACP agent launch shims
  ocx/config.template.json  proxy config, API keys redacted
  opencode/opencode.json    provider config
  bb-AGENTS.md, claude-CLAUDE.md, claude-settings.json,
  claude-hooks/, claude-reference/, claude-scripts/,
  claude-statusline-command.sh, ccstatusline-settings.json

docs/second-machine.md   enrolling a machine against an existing server
```

Committed files use a `__HOME__` placeholder rather than a real home directory,
so the repository is not tied to one account. `bootstrap.sh` expands it during
install and `verify.sh` fails if any installed file still contains it.

## Security

No credential is committed. `files/ocx/config.template.json` carries
`<redacted>` in place of each API key, and `bootstrap.sh` reads keys with hidden
input so they stay out of shell history and transcripts.

Before publishing any change:

```bash
./verify.sh    # includes the credential-hygiene checks
```
