# Skills, plugins, and slash commands

Read this when authoring or debugging a skill, plugin, or slash command. Not needed otherwise.

**Source of truth**: `code.claude.com/docs/en/skills`. Check it before making assumptions. This area changed significantly and training knowledge is stale.

## Two distinct systems. Don't conflate them.

### Personal skills (`~/.claude/skills/`)

The right system for personal use. Place a `SKILL.md` inside a named directory and Claude Code picks it up automatically. No JSON registration, no CLI commands.

```
~/.claude/skills/
└── my-skill/
    └── SKILL.md
```

Claude invokes skills automatically when it recognizes a trigger, or you invoke them with `/skill-name`. You don't need a command file to invoke a personal skill via `/name`.

A skill's own `description` field declares its triggers. Don't restate those triggers in CLAUDE.md; that's duplicated instruction that costs context and adds nothing.

### Plugin/marketplace system (`~/.claude/plugins/`)

For distributing skills to others via a marketplace repo. Registered in two places:

1. `~/.claude/plugins/installed_plugins.json`, which tracks what's installed
2. `~/.claude/settings.json` `enabledPlugins`, which gates whether it's active

The UI writes both automatically. Manual installs need both.

The `@local` registration path (`~/.claude/plugins/cache/local/<name>/`) was silently superseded by the `~/.claude/skills/` system. Don't use it for new personal skills.

## Slash commands (`~/.claude/commands/`)

Still work, but skills are preferred. If a skill with the same name exists, the skill takes precedence.

## Writing skills well

Skills should encode opinions, knowledge, or practices particular to me or my work. Keep them lightweight guides rather than exhaustive rulebooks; overconstraining them costs more than it buys, except in genuinely high-stakes areas.

For long skills, split into multiple files and load progressively rather than putting everything in `SKILL.md`.

The `skill-creator` skill handles authoring, editing, and evaluating skills.

Cross-agent skills that every bb provider should see (Claude, Codex, opencode) live in `~/.bb/skills/` (`bb skill list`, scope `bb-user`), not here. Model routing, pickers, proxy, and provider keys: `~/.bb/skills/model-routing/`.

Software factory (nightly unattended repo agents): `~/.claude/reference/factory.md`
