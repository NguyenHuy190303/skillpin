<h1 align="center">SkillPin</h1>

<p align="center">A native macOS menu-bar library for AI agent skills.</p>

<p align="center">
  <a href="https://github.com/AndrewNgo-ini/skillpin/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/AndrewNgo-ini/skillpin?label=release&color=171811"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white">
  <a href="https://github.com/AndrewNgo-ini/homebrew-skillpin"><img alt="Homebrew" src="https://img.shields.io/badge/brew-andrewngo--ini%2Fskillpin%2Fskillpin-c8f05a?logoColor=171811"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-6f7168"></a>
  <a href="https://andrewngo-ini.github.io/skillpin/"><img alt="Website" src="https://img.shields.io/badge/site-andrewngo--ini.github.io%2Fskillpin-c8f05a"></a>
</p>

<p align="center">
  <a href="https://andrewngo-ini.github.io/skillpin/"><img src="docs/readme-banner.png" alt="SkillPin: every skill, one place. A native macOS menu-bar library for AI agent skills, reading Globals, Claude, Codex, Cursor and more." width="880"></a>
</p>

<p align="center"><a href="https://andrewngo-ini.github.io/skillpin/"><b>andrewngo-ini.github.io/skillpin</b></a> · <a href="https://github.com/AndrewNgo-ini/skillpin/releases/latest/download/SkillPin.dmg">Download for macOS</a> · <code>brew install --cask andrewngo-ini/skillpin/skillpin</code></p>

Agent skills are folders with a `SKILL.md` file, and every agent reads them from
its own directory. The same skill ends up copied into `~/.agents/skills`,
`~/.claude/skills`, and a `.claude/skills` folder inside two of your
repositories. Nothing shows you the whole set, so you run `ls` in four places
and open files to read the frontmatter.

SkillPin reads user skill directories, registered Claude/Codex plugins and
explicitly selected projects. It shows where each skill comes from, its scope,
instructions, supporting files and estimated context size.

## The pin model

A **pin** is a location where a skill is present. Symlinks to the same physical
skill share a row within the same scope. Independent folders with the same name
stay separate, so a project skill cannot silently replace a personal skill.

```
research                       one skill
├── ~/.agents/skills/          Globals
├── ~/.claude/skills/          Claude
└── ./.agents/skills/          Project: moonfish
```

Pinning to the shared directory, `~/.agents/skills`, is the default. Whether an
agent reads that directory depends on that agent. The per-agent formats
(`.claude`, `.codex`, `.hermes`) are there when you need them and hidden when
you don't. Project pins copy the skill into the repository, so the repository
stays portable and can commit the skills it depends on.

## What it does

- Finds agent skill directories directly under your home folder, including Codex system skills
- Reads registered Claude plugin installations and configured Codex plugin cache entries, with source, version, scope and configured state
- Keeps unrelated same-name skills separate and reports unreadable metadata or excluded symlinks in Diagnostics
- Shows the pins for each skill, marked global or project
- Groups skills in the globals directory by the repository they were installed from, read from `~/.agents/.skill-lock.json`, with anything unrecorded under `Local / untracked`
- Searches names and descriptions, and filters by Globals, Projects, or any single agent you have installed
- Adds a project folder and scans its local skill directories by the same rule
- Pins a skill to Global or a project in any agent's format, always as a copy
- Runs from the menu bar with no dock icon and no window to manage
- Shows full descriptions, metadata, raw instructions, supporting files and context estimates; sorts skills by instruction size
- Turns standalone user skills off by moving them to `~/skills-backup`; restores them without overwriting an existing destination
- Enables or disables known user-scoped plugins through their agent configuration, without moving files out of plugin packages
- Inventories user and explicitly selected project rules and hooks in read-only tabs

## Scope and plugin discovery

Projects are opt-in. SkillPin does not recursively search your home directory for
repositories. A user skill symlink that leaves the selected user skill roots is
reported and excluded, even when its target project has been added separately.
Project identity uses the full path, so two repositories named `app` stay distinct.

Claude plugins come from `~/.claude/plugins/installed_plugins.json`. Project and
local installations appear only for selected projects. Codex plugins come from
canonical `[plugins."name@marketplace"]` entries in `~/.codex/config.toml`, with
files under `~/.codex/plugins/cache`. If more than one cached version exists,
SkillPin shows those versions as **Unknown** and does not choose an active one.
An unregistered cache directory is not treated as an installed plugin.

Configured on/off is not proof of activation in a running session. Managed
policies, session overrides and agent reload behavior may affect the effective
state. System and project skills are read-only for archive operations. Plugin
skills are managed with the whole plugin, not copied out of their package.

The current adapters use the standard `~/.claude` and `~/.codex` locations.
Custom agent homes, remote skills, external marketplace loaders and arbitrary
TOML layouts are not inferred. Unsupported paths or ambiguous state remain
unknown rather than being guessed.

## Context estimates

Expanded skills show three separate estimates:

- **Discovery:** name, description and path before invocation.
- **Full SKILL.md:** the complete instruction file, including frontmatter.
- **Supporting prose:** optional Markdown/text references, excluding executable
  code and binary assets. These are not assumed to load with the skill.

Counts use UTF-8 bytes divided by four, rounded up. They are a model-independent
size heuristic, not a tokenizer, billable usage or measured session context.
The discovery total follows the current filter and includes all listed entries,
including disabled plugins; it is not an active-session total. Agents may omit
or shorten descriptions and load references conditionally.

See [OpenAI skill loading](https://learn.chatgpt.com/docs/build-skills) and
[Claude skill loading](https://code.claude.com/docs/en/skills).

## Off, backup and restore

**Turn off & back up** moves one standalone user pin to
`~/skills-backup/<id>/skill` and saves its original path in `record.json`.
The Disabled tab survives app restarts and can restore the exact folder or
symlink. Relative symlink text is preserved. Restore refuses occupied paths,
including broken links. A shared folder cannot be moved while another discovered
pin links to it; turn those links off first.

Off applies to the selected pin, not every copy of a same-name skill. Files that
an agent already loaded may remain in an existing conversation. Reload or start
a new session as needed. Restoring files does not override native agent settings
that separately disabled that skill.

Known user-scoped plugin switches update `enabledPlugins` for Claude or the
existing canonical plugin table for Codex. They affect the whole plugin and ask
for confirmation. Unknown/project plugin states remain read-only. Other settings
are preserved; Codex table comments and formatting are retained.

Rules and hooks are inventoried by source and scope. Hooks are never executed
by SkillPin. Codex `.rules` files are execution policy, not prompt context.

## Directories it reads

SkillPin does not carry a list of supported agents. It looks in your home
folder for any dot-directory containing a `skills` folder, so an agent it has
never heard of shows up without a new release:

```
~/.agents/skills/     →  Globals
~/.claude/skills/     →  Claude
~/.cursor/skills/     →  Cursor
~/.whatever/skills/   →  Whatever
```

The same rule runs inside each project folder you add, and Hermes gets one
extra root per profile in `~/.hermes/profiles/<name>/skills/`.

Thirteen agents are recognised by name and given their own badge icon — Globals,
Claude, Codex, Cursor, Copilot, Gemini, Kimi, Grok, OpenCode, Cline, Goose,
Hermes and Pencil. Anything else is listed under its capitalised directory
name. Adding a recognised agent is one line in `AgentProvider.known`.

## Install

macOS 14 or later. No external dependencies.

Download [SkillPin.dmg](https://github.com/AndrewNgo-ini/skillpin/releases/latest/download/SkillPin.dmg)
and drag SkillPin to Applications, or install it with Homebrew:

```sh
brew install --cask andrewngo-ini/skillpin/skillpin
```

The build is not signed with an Apple Developer ID yet, so macOS asks you to
approve it once under System Settings → Privacy & Security.

To build from source instead:

```sh
git clone https://github.com/AndrewNgo-ini/skillpin.git
cd skillpin
./Scripts/package-app.sh      # builds dist/SkillPin.app
open dist/SkillPin.app
```

To run it straight from the terminal instead:

```sh
swift run SkillPin
```

## What pinning does

Every pin is a copy. The app never creates a symlink.

A skill can be in several places, and in several formats at each place: Global
has `~/.agents/skills`, `~/.claude/skills`, `~/.codex/skills`, …; a project has
the same set under its own root. That is a grid, places × formats, and the
**Pin** menu at the end of an expanded row shows it one place at a time:

```
Pin ▾
  ✓ Global  ·  2        ▸   ✓ Globals (.agents)
    contextbox-harness  ▸   ✓ Claude (.claude)
    api-server          ▸     Codex (.codex)
  ──────────────              Cursor (.cursor)
  Choose project…             Hermes (.hermes)
                              Pencil (.pencil)
```

The top level is the places; each opens its formats. A place row shows a
checkmark and a count when any format there holds the skill.

A tick is presence in that cell. Choosing an unticked row copies the skill's
folder to `<place>/<format>/skills/<name>`; choosing a ticked standalone user
row archives it. One click, one cell. `.agents` leads each submenu because it is the
place skills are kept; the agent rows beside it are what each agent actually
reads. Choose project… adds a repository and copies the skill into its
`.agents`; other formats are one more click in its submenu.

Hermes and Pencil rows are refused when unticked, with the reason: Hermes
nests skills in category folders, so a flat entry would not be read, and
Pencil's directory holds Pencil's own skills. Those sources remain read-only.

**Symlinks you already have.** Installers link agent directories into
`.agents`. SkillPin follows links within the selected scope, marks them with a
link glyph, and archives the link itself when turned off. It does not make new
symlinks. Independent same-name copies remain separate rows and are never
automatically replaced with another source's contents.

## Status

This development version adds plugin discovery, scoped inventory, reversible
skill controls and context estimates. It does not verify activation inside a
running agent or compare installed skills with their upstream repositories.
Releases are ad-hoc signed; a Developer ID signature and notarization come next.

## Development

```sh
swift run SkillPin
swift test
```

`Sources/SkillPin/SkillCatalog.swift` walks the roots and parses frontmatter.
`AgentProvider.swift` is the agent table and the directory discovery rule.
`SkillPinner.swift` plans and performs a copy, and reports what is at a path.
`SkillDrift.swift` hashes folders and replaces a drifted copy.
`AgentInventory.swift` reads plugin registries and inventories rules/hooks.
`SkillBackup.swift` handles reversible standalone skill moves.
`PluginControl.swift` changes supported user plugin settings.
`SkillContext.swift` computes explicit, local size estimates.
`InventoryViews.swift` shows details, plugins, resources, backups and diagnostics.
`SkillPinApp.swift` is the SwiftUI menu-bar interface.

## Contributing

Issues and pull requests are welcome. For a bug report, include your macOS
version and the skill directory that reproduces it.

## License

MIT. See [LICENSE](LICENSE).
