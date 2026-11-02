# Margined Markdown skill

Give a coding agent the [authoring skill](margined-markdown/SKILL.md) for portable
Markdown checklists, images, math, diagrams and single-file passage discussions.
It includes compatibility notes, parser workarounds and a [complete example](margined-markdown/assets/review-example.md).
Discussions require Margined 2.0; stable 1.7.1 does not support them. See the skill
for its verified build and format version. Proposed features are not documented
as available.

## Install in Codex

Ask Codex, including in the combined ChatGPT/Codex desktop app:

```text
$skill-installer Install the skill from https://github.com/HighGainDesign/Margined/tree/main/skills/margined-markdown
```

Then invoke `$margined-markdown` when asking for a document. If it does not appear,
start a new chat or restart Codex. The installer may ask you to handle an existing
installation rather than overwriting local edits.

For manual installation, download or clone this repository and copy the entire
`skills/margined-markdown` folder to `~/.agents/skills/margined-markdown/`.
Keep `SKILL.md`, `agents/`, `references/`, `assets/` and `LICENSE` together.

## Other agents and updates

Install the same folder in your harness's supported Agent Skills location, or
ask the agent to read `SKILL.md` and its linked references directly. The skill
contains instructions and examples; it needs no plugin, service or account.

The repository copy is maintained with Margined's formats and usage guidelines.
Refresh installed copies from GitHub for updates, comparing any local changes
first. Codex noticing changed local files does not itself download GitHub updates.
For installations tracked by a recent GitHub CLI, use `gh skill update
margined-markdown --dry-run` to check, then `gh skill update margined-markdown`
to apply updates. Manually copied skills need source tracking before that command
can update them. See [GitHub's update documentation](https://cli.github.com/manual/gh_skill_update).

GitHub CLI can pin a skill to a release tag or commit; pinned skills are skipped
by normal updates. Pin only to a revision that contains this skill. Installation
does not automatically detect your Margined version or select a matching skill.
Keep older-version compatibility notes when using the latest guidance.
See [maintenance guidance](margined-markdown/references/maintenance.md).
The skill is distributed under the [MIT license](margined-markdown/LICENSE).
