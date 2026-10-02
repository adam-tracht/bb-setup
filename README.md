# bb-setup

Reproduces a configured bb (agent IDE) installation on a new machine. Captured on
macOS. bb also publishes Linux and Windows builds, both alpha. Config as code:
clone, run `./bootstrap.sh`, then complete the login steps.

Captured from bb 0.44.0. Exact tool versions are recorded in `manifest/versions.txt`.

## Contents

- 35 non-builtin bb plugins, with enabled and disabled states recorded
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

## Platform support

Tested on macOS, which is the platform this configuration was captured from. The
scripts are POSIX shell plus `python3`. Two commands they used were macOS-specific
and have been replaced with portable equivalents: `rsync` (absent on some systems)
with a python directory copy, and BSD `stat -f` with a helper covering both flavours.

bb publishes desktop builds for macOS, Linux, and Windows. Per bb's own README, the
Linux and Windows builds are **alpha**. macOS is arm64 only; Intel Macs should run
bb through `npx` instead.

| Platform | Scripts | bb desktop app |
| --- | --- | --- |
| macOS (Apple Silicon) | Supported, and what this was tested on | [`bb-<version>-arm64.dmg`](https://getbb.app/download/macos), stable |
| macOS (Intel) | Supported | No desktop build; use `npx bb-app@latest` |
| Linux x64 | Expected to work: needs `bash` and `python3` | [`bb-<version>-x86_64.AppImage`](https://getbb.app/download/linux), alpha |
| Windows x64 | Expected to work under Git Bash with `python3` on PATH | [`bb-<version>-x64.exe`](https://github.com/get-bb/bb/releases/latest), alpha; needs Git for Windows |
| WSL2 | Runs the Linux path | `npx bb-app@latest` from the WSL shell |

Release assets are listed under `desktop-latest` in the [bb releases](https://github.com/get-bb/bb/releases).

**Nothing is skipped based on platform.** Every file in `files/` is installed on
every platform. Several carried pieces are macOS-only in practice and will simply
not function elsewhere: the Aside browser and the `keep-awake` plugin. On a
non-macOS machine, expect those to be inert rather than absent.

## Prerequisites

| Requirement | Notes |
| --- | --- |
| bb | The desktop app (macOS Apple Silicon, Linux x64, Windows x64) or `npx bb-app@latest`. Its Settings installer also provides the provider CLIs |
| `python3` | Required. File copying, path substitution, and the API key prompt all use it |
| Node.js | Only for the optional npm-installed CLIs below |
| rtk | Optional, macOS and Linux. Filters shell output for Claude Code via a hook |

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

1. **Platform and prerequisites.** Reports the platform, requires `python3`, and
   warns about duplicate provider CLIs on `PATH`.
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
   disables it to match. A failure is summarised as a list at the end rather
   than only inline.
8. **Builtin plugins.** Disables the builtins listed in
   `manifest/builtin-plugins.json`. Only exceptions are recorded, so builtins
   added by a later bb release keep their own default.
9. **Plugin settings.** Applies `manifest/plugin-config.json`, expanding
   `${HOME}` in ACP agent paths.
10. **bb settings.** General settings, experiments, theme, and favicon colour.
11. **Interface preferences.** Applies sidebar and thread-list preferences, skipping
    any that embed a project, thread, or environment id from another machine.
12. **Claude Code.** Installs `CLAUDE.md`, hooks, reference docs, scripts, and
    statusline, then merges `settings.json` while preserving existing keys and
    unioning permission lists.
13. **opencode.** Installs the provider config, backing up any existing file, and
    repoints key-file references at the local home directory.
14. **opencodex.** Installs the redacted proxy config when none exists, then
    prompts for API keys with hidden input and writes them mode 600.
15. Prints the remaining manual steps.

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
  plugins.json            35 plugins: source and enabled state
  builtin-plugins.json    builtin plugins switched off (exceptions only)
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
