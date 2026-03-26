# cc-watcher.nvim

Neovim plugin that monitors [Claude Code](https://claude.ai/claude-code) changes in real time. See what Claude is editing in a sidebar, view inline diffs, and navigate between hunks — all without leaving your editor.

Designed for a **tmux split workflow**: Claude Code on the left, Neovim on the right.

## Features

- **Sidebar** — lists all files Claude has edited, updated live with directory grouping and +N/-M stats
- **Inline diff** — colored highlights showing exactly what changed (no split windows)
- **Sign column indicators** — green/yellow/red bars on changed lines
- **Hunk navigation** — `]c` / `[c` to jump between changes, `cr` to revert a hunk
- **Session awareness** — reads Claude Code's session JSONL to find edited files
- **File watchers** — instant detection via libuv `fs_event` (zero CPU when idle)
- **Snapshot-based diff** — compares against file state *before* Claude edited it, not git HEAD
- **Batched notifications** — debounced to avoid spam when Claude edits many files
- **Lazy loading** — full lazy.nvim support with command/key/event triggers
- **Pure Lua** — no external dependencies
- **Integrations** (opt-in):
  - [Telescope](#telescope) — fuzzy find changed files and hunks with diff preview
  - [fzf-lua](#fzf-lua) — same pickers for fzf users
  - [trouble.nvim](#troublenvim) — diagnostic-like list of all changes
  - [Diffview](#diffview) — side-by-side snapshot diff in a tab

## How it works

```
┌─ Sidebar ──────────┐┌─ Editor ─────────────────────────────┐
│  󰚩 Claude Code     ││                                       │
│  session active    ││   fn process(data: &str) -> Result {  │
│────────────────────││ ~   old line that was here            │  ← dim red
│  src/              ││     let result = parse(data)?;        │  ← yellow (changed)
│    ● api.rs  +3 -1 ││ +   let new_field = validate(&data);  │  ← green (added)
│    ● handlers.rs   ││     Ok(result)                        │
│  ○ models.rs       ││   }                                   │
│────────────────────││                                       │
│  3 files  +8 -3    ││                                       │
│  g? help           ││                                       │
└────────────────────┘└───────────────────────────────────────┘

● = live change (detected by file watcher)
○ = session change (from Claude Code's JSONL log)
```

**Colors:**
- **Green background** (`┃` sign) — lines Claude added
- **Yellow background** (`┃` sign) — lines Claude changed (old version shown above in dim red)
- **Red virtual text** (`▁` sign) — lines Claude deleted

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim) (recommended)

```lua
{
    "elmomk/cc-watcher.nvim",
    event = { "BufReadPost", "BufNewFile" },
    cmd = {
        "ClaudeSidebar", "ClaudeDiff",
        "ClaudeTelescope", "ClaudeFzf", "ClaudeTrouble", "ClaudeDiffview",
    },
    keys = {
        { "<leader>cs", desc = "Claude - toggle sidebar" },
        { "<leader>cd", desc = "Claude - toggle inline diff" },
    },
    opts = {},
}
```

With all integrations:

```lua
{
    "elmomk/cc-watcher.nvim",
    event = { "BufReadPost", "BufNewFile" },
    cmd = {
        "ClaudeSidebar", "ClaudeDiff",
        "ClaudeTelescope", "ClaudeFzf", "ClaudeTrouble", "ClaudeDiffview",
    },
    keys = {
        { "<leader>cs", desc = "Claude - toggle sidebar" },
        { "<leader>cd", desc = "Claude - toggle inline diff" },
    },
    opts = {
        integrations = {
            telescope = true,
            fzf_lua = true,
            trouble = true,
            diffview = true,
        },
    },
}
```

### Minimal

```lua
{
    "elmomk/cc-watcher.nvim",
    opts = {},
}
```

### Local development

```lua
{
    dir = "~/path/to/cc-watcher.nvim",
    name = "cc-watcher.nvim",
    opts = {},
}
```

## Configuration

All options with their defaults:

```lua
require("cc-watcher").setup({
    -- Sidebar width in columns
    sidebar_width = 36,

    -- Keymaps (set to false to disable any binding)
    keys = {
        toggle_sidebar = "<leader>cs",
        toggle_diff = "<leader>cd",
    },

    -- Opt-in integrations (require the corresponding plugin to be installed)
    integrations = {
        telescope = false,   -- :ClaudeTelescope, :Telescope cc_watcher
        fzf_lua = false,     -- :ClaudeFzf
        trouble = false,     -- :ClaudeTrouble
        diffview = false,    -- :ClaudeDiffview
    },
})
```

## Keybindings

### Global

| Key | Action |
|-----|--------|
| `<leader>cs` | Toggle sidebar |
| `<leader>cd` | Toggle inline diff for current file |

### Sidebar

| Key | Action |
|-----|--------|
| `<CR>` / `d` | Open file with inline diff |
| `o` | Open file without diff |
| `r` | Refresh file list |
| `q` | Close sidebar |
| `g?` | Show help popup |

### When diff is active

| Key | Action |
|-----|--------|
| `]c` | Jump to next hunk |
| `[c` | Jump to previous hunk |
| `cr` | Revert hunk under cursor |
| `<leader>cd` | Toggle diff off |

### Diffview (`:ClaudeDiffview`)

| Key | Action |
|-----|--------|
| `]f` | Next file |
| `[f` | Previous file |
| `q` | Close diff tab |

## Commands

| Command | Description |
|---------|-------------|
| `:ClaudeSidebar` | Toggle the changed files sidebar |
| `:ClaudeDiff` | Toggle inline diff for current file |
| `:ClaudeTelescope [changed_files\|hunks]` | Telescope picker for Claude changes |
| `:ClaudeFzf [changed_files\|hunks]` | fzf-lua picker for Claude changes |
| `:ClaudeTrouble` | Open trouble.nvim with Claude changes |
| `:ClaudeDiffview [file]` | Side-by-side diff view |

## Integrations

All integrations are **opt-in** — enable them in your config and install the corresponding plugin.

### Telescope

```lua
opts = { integrations = { telescope = true } }
```

- `:ClaudeTelescope` or `:Telescope cc_watcher` — **changed files picker**
  - Shows indicator (●/○) + file icon + path + diff stats (+N/-M)
  - Preview pane shows unified diff
  - `<CR>` opens file with inline diff, multi-select (Tab) supported
- `:ClaudeTelescope hunks` or `:Telescope cc_watcher hunks` — **hunk picker**
  - Lists every hunk across all changed files
  - `<CR>` jumps to hunk location with inline diff

Requires: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)

### fzf-lua

```lua
opts = { integrations = { fzf_lua = true } }
```

- `:ClaudeFzf` — changed files with diff preview
- `:ClaudeFzf hunks` — hunk picker with context preview

Requires: [fzf-lua](https://github.com/ibhagwan/fzf-lua)

### trouble.nvim

```lua
opts = { integrations = { trouble = true } }
```

- `:ClaudeTrouble` — diagnostic-like list of all Claude changes
- Each hunk appears as: info (additions), warning (modifications), hint (deletions)

Requires: [trouble.nvim](https://github.com/folke/trouble.nvim) v3

### Diffview

```lua
opts = { integrations = { diffview = true } }
```

- `:ClaudeDiffview` — side-by-side diff for all changed files in a new tab
- `:ClaudeDiffview path/to/file` — diff for a single file
- Left pane: snapshot (pre-Claude state, readonly), right pane: current file
- Navigate between files with `]f`/`[f`, close with `q`

Uses vim's built-in diff mode — no additional plugin required.

## Statusline

```lua
-- lualine
sections = {
    lualine_x = {
        {
            require("cc-watcher").statusline,
            cond = function()
                return require("cc-watcher").statusline() ~= ""
            end,
        },
    },
}
```

Returns `""` when no changes, or `"󰚩 N"` where N is the count of changed files.

## How it detects changes

1. **Session JSONL** — reads `~/.claude/projects/*/SESSION_ID.jsonl` to find all `Write`/`Edit` tool calls Claude made. This catches everything, even files you never opened.

2. **File watchers** — for files you've opened, libuv `fs_event` watchers detect changes instantly and auto-reload the buffer.

3. **Snapshots** — when you open a file, its content is stored in memory (LRU cache, max 100 files). Diffs compare against this snapshot, so you see what changed *since you started editing*, not against git.

## Requirements

- Neovim >= 0.10
- [Claude Code](https://claude.ai/claude-code) running in the same directory

**Optional (for integrations):**
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [fzf-lua](https://github.com/ibhagwan/fzf-lua)
- [trouble.nvim](https://github.com/folke/trouble.nvim) v3
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) (file icons in sidebar/telescope)

## Documentation

- `:help cc-watcher` — full vimdoc reference
- [`doc/tutorial.md`](doc/tutorial.md) — in-depth hands-on tutorial

## Highlight groups

All highlights use `default = true` so you can override them in your colorscheme:

| Group | Default | Used for |
|-------|---------|----------|
| `ClaudeDiffAdd` | green bg | Added lines |
| `ClaudeDiffChange` | yellow bg | Changed lines |
| `ClaudeDiffDelete` | red bg, dim text | Deleted lines (virtual text) |
| `ClaudeDiffAddSign` | green | Sign column: added |
| `ClaudeDiffChangeSign` | yellow | Sign column: changed |
| `ClaudeDiffDeleteSign` | red | Sign column: deleted |
| `ClaudeHeader` | mauve, bold | Sidebar title |
| `ClaudeActive` | green | Session active indicator |
| `ClaudeInactive` | grey, italic | No session indicator |
| `ClaudeLive` | yellow | Live-detected file (●) |
| `ClaudeSession` | blue | Session-detected file (○) |
| `ClaudeDir` | grey | Directory group headers |
| `ClaudeFile` | white | Filenames |
| `ClaudeStats` | dark grey | +N/-M stats |
| `ClaudeCount` | blue | File count summary |
| `ClaudeSep` | dark grey | Separator lines |
| `ClaudeHelp` | dark grey | Help text |

## License

MIT
