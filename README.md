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
- **Git HEAD comparison** — compares against git HEAD for accurate diffs, with snapshot fallback for untracked files
- **Batched notifications** — debounced to avoid spam when Claude edits many files
- **Lazy loading** — full lazy.nvim support with command/key/event triggers
- **Pure Lua** — no external dependencies
- **Integrations** (opt-in):
  - [Snacks picker](#snacks-picker) — fuzzy find changed files and hunks with colored diff preview (for [LazyVim](https://www.lazyvim.org/) / snacks.nvim users)
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
        "ClaudeSnacks", "ClaudeTrouble", "ClaudeDiffview",
    },
    keys = {
        { "<leader>cs", desc = "Claude - toggle sidebar" },
        { "<leader>cd", desc = "Claude - toggle inline diff" },
    },
    opts = {},
}
```

With snacks picker + all integrations (for LazyVim users):

```lua
{
    "elmomk/cc-watcher.nvim",
    event = { "BufReadPost", "BufNewFile" },
    cmd = {
        "ClaudeSidebar", "ClaudeDiff",
        "ClaudeSnacks", "ClaudeTrouble", "ClaudeDiffview",
    },
    keys = {
        { "<leader>cs", desc = "Claude - toggle sidebar" },
        { "<leader>cd", desc = "Claude - toggle inline diff" },
        { "<leader>ct", "<cmd>ClaudeSnacks<cr>", desc = "Claude - changed files" },
        { "<leader>ch", "<cmd>ClaudeSnacks hunks<cr>", desc = "Claude - hunks" },
        { "<leader>cx", "<cmd>ClaudeTrouble<cr>", desc = "Claude - trouble" },
        { "<leader>cv", "<cmd>ClaudeDiffview<cr>", desc = "Claude - diffview" },
    },
    opts = {
        integrations = {
            snacks = true,
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
        snacks = false,      -- :ClaudeSnacks (for snacks.nvim / LazyVim users)
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
| `o` | Open file with diff |
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
| `:ClaudeSnacks [changed_files\|hunks]` | Snacks picker for Claude changes |
| `:ClaudeTrouble` | Open trouble.nvim with Claude changes |
| `:ClaudeDiffview [file]` | Side-by-side diff view |

## Integrations

All integrations are **opt-in** — enable them in your config and install the corresponding plugin.

### Snacks picker

```lua
opts = { integrations = { snacks = true } }
```

- `:ClaudeSnacks` — **changed files picker** with colored diff preview (green/red highlights)
- `:ClaudeSnacks hunks` — **hunk picker** with file preview at hunk location
- `<CR>` opens file with inline diff and jumps to first change

Requires: [snacks.nvim](https://github.com/folke/snacks.nvim) (included by default in LazyVim)

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

## LazyVim Dashboard Setup

If you use [LazyVim](https://www.lazyvim.org/) with the snacks.nvim dashboard, you can add a "Claude Changes" entry to your startup page.

Create `~/.config/nvim/lua/plugins/dashboard.lua`:

```lua
return {
  "snacks.nvim",
  opts = {
    dashboard = {
      preset = {
        -- stylua: ignore
        ---@type snacks.dashboard.Item[]
        keys = {
          { icon = " ", key = "f", desc = "Find File", action = ":lua Snacks.dashboard.pick('files')" },
          { icon = " ", key = "n", desc = "New File", action = ":ene | startinsert" },
          { icon = " ", key = "g", desc = "Find Text", action = ":lua Snacks.dashboard.pick('live_grep')" },
          { icon = " ", key = "r", desc = "Recent Files", action = ":lua Snacks.dashboard.pick('oldfiles')" },
          { icon = " ", key = "c", desc = "Config", action = ":lua Snacks.dashboard.pick('files', {cwd = vim.fn.stdpath('config')})" },
          { icon = " ", key = "s", desc = "Restore Session", section = "session" },
          { icon = " ", key = "w", desc = "Claude Changes", action = ":lua vim.cmd('enew'); vim.bo.bufhidden = 'wipe'; vim.cmd('ClaudeSnacks')" },
          { icon = " ", key = "x", desc = "Lazy Extras", action = ":LazyExtras" },
          { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy" },
          { icon = " ", key = "q", desc = "Quit", action = ":qa" },
        },
      },
    },
  },
}
```

Pressing `w` on the startup page opens the snacks changed files picker with diff preview, dismissing the dashboard automatically.

### Lualine (LazyVim)

To add the cc-watcher statusline indicator to LazyVim's lualine, create `~/.config/nvim/lua/plugins/lualine.lua`:

```lua
return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, {
      function()
        return require("cc-watcher").statusline()
      end,
      cond = function()
        local ok, watcher = pcall(require, "cc-watcher.watcher")
        return ok and vim.tbl_count(watcher.get_changed_files()) > 0
      end,
    })
  end,
}
```

This shows `󰚩 N` in the statusline when Claude has changed files.

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

3. **Git HEAD comparison** — diffs compare against `git show HEAD:<file>` for accurate results. For untracked files (not in git), snapshots stored in memory (LRU cache, max 100 files) are used as a fallback.

## Requirements

- Neovim >= 0.10
- [Claude Code](https://claude.ai/claude-code) running in the same directory

**Optional (for integrations):**
- [snacks.nvim](https://github.com/folke/snacks.nvim) (included in LazyVim)
- [trouble.nvim](https://github.com/folke/trouble.nvim) v3
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) (file icons in sidebar/pickers)

## Documentation

- `:help cc-watcher` — full vimdoc reference
- [`doc/tutorial.md`](doc/tutorial.md) — in-depth hands-on tutorial
- [`doc/lua-plugin-guide.md`](doc/lua-plugin-guide.md) — Lua plugin development guide

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
| `ClaudeFileCurrent` | white, bold, bg | Currently open file in sidebar |
| `ClaudeStats` | dark grey | +N/-M stats |
| `ClaudeCount` | blue | File count summary |
| `ClaudeSep` | dark grey | Separator lines |
| `ClaudeHelp` | dark grey | Help text |

## License

MIT
