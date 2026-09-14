---
name: obsidian-memory
description: Use when someone asks to tidy or audit Claude memory notes, find broken or dangling links, see what links to a note, rename or move a note without breaking links, find where something was decided across notes, or check worklist status in an Obsidian vault.
when_to_use: 'Phrases like "tidy my memory", "broken links", "orphan notes", "what links to X", "rename this note", "move this doc", "where did we decide X", "worklist status". NOT for writing memory content (auto memory does that with Write) or searching code (use Grep).'
---

# Obsidian link-graph work over memory and docs

Plain reads and writes stay on Read/Edit/Write/Grep. This skill covers only what those tools can't do
correctly: link-graph queries and link-safe renames.

## 1. Pick the channel

1. **Obsidian app closed** (output says `The CLI is unable to find Obsidian`): use Grep/Read for the task
   and say graph queries were skipped. **NEVER launch the app.**
2. **PowerShell tool:** `obsidian <command> ...`
3. **Git Bash tool:** `Obsidian.com <command> ...`. Bare `obsidian` there resolves to the GUI `.exe`,
   and colon commands (`search:context`, `base:query`) exit 127 with no output.
4. `vault=<name>` MUST be the first argument. Inside a vault folder the cwd selects it. Vault names in
   use: the repo vault (folder name) and `Claude Memory`, whose `projects/<slug>/memory/` is a junction
   to `~/.claude/projects`.
5. **MCP server `obsidian`** exists only in repos with a committed `.mcp.json`, and only while that
   vault is open. Use it for `vault_get_document_map` (then read one section), `search_query`
   (JsonLogic over frontmatter) and `vault_patch` (heading-targeted append).

## 2. Commands

| Need | Command |
|---|---|
| Dangling links (topics worth writing) | `unresolved verbose format=json` |
| Notes nothing links to / notes linking nowhere | `orphans` / `deadends` (no `format=`) |
| Before renaming or deleting a note | `backlinks path=<p> format=json` |
| Rename or move with links rewritten | `rename path=<p> name=<new>` / `move path=<p> to=<folder-or-path>` |
| Find a decision without reading files | `search:context query="<q>" path=<folder> limit=10 format=json` |
| Map a big doc before reading | `outline path=<p> format=json` |
| Worklist status | `base:query path=<file>.base format=json` |
| Frontmatter | `properties path=<p> format=json`; after `property:set`, verify with `property:read` |

## 3. Rules

- **Exit codes lie.** `move` on a missing file exits 0 and prints `Error: File "x" not found.` Treat
  any output starting `Error:` as failure.
- The first call right after the app starts can print `Command "<x>" not found`. Retry once.
- **NEVER write note content through the CLI** (`create`/`append content=`). `\t` turns LaTeX
  `\times` into a tab, long content throws a JS error, and `create` breaks frontmatter. Use Write/Edit.
- NEVER move a note with a shell or file tool. Only `move`/`rename` rewrite inbound links.
- Link style: repo docs use relative Markdown links, so they render on GitHub. Memory notes keep
  `[[name]]`. Links into dot-folders (`.claude/`) never resolve in Obsidian; write those as code paths.

## 4. Shared, committed memory for a repo (opt-in)

- `.claude/settings.local.json`: `{"autoMemoryDirectory": "<absolute repo path>/memory/"}`
- `.gitattributes`: `memory/MEMORY.md merge=union`
- **NEVER set `autoMemoryDirectory` in user settings.** The path is used as-is, so every project
  would share one memory folder.

## Output

Report what was queried, the findings as a short list or table, and any change made with its
`backlinks` count before and after.
