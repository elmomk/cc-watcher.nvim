# cc-watcher.nvim

Neovim plugin that monitors [Claude Code](https://claude.ai/claude-code) changes in real time. See what Claude is editing in a sidebar, view inline diffs, and navigate between hunks — all without leaving your editor.

Designed for a **tmux split workflow**: Claude Code on the left, Neovim on the right.

## Features

- **Sidebar** — lists all files Claude has edited, updated live
- **Inline diff** — colored highlights showing exactly what changed (no split windows)
- **Sign column indicators** — green/yellow/red bars on changed lines
- **Hunk navigation** — `]c` / `[c` to jump between changes
- **Session awareness** — reads Claude Code's session JSONL to find edited files
- **File watchers** — instant detection via libuv `fs_event` (zero CPU when idle)
- **Snapshot-based diff** — compares against file state *before* Claude edited it, not git HEAD
- **Batched notifications** — debounced to avoid spam when Claude edits many files
- **No python3 dependency** — uses `grep` + Lua JSON parsing

## How it works

```
┌─ Sidebar ──────────┐┌─ Editor ─────────────────────────────┐
│  Claude Code      ││                                       │
│  session active   ││   fn process(data: &str) -> Result {  │
│────────────────────││ ~   old line that was here            │  ← struck-through red
│● src/api.rs       ││     let result = parse(data)?;        │  ← yellow (changed)
│● src/handlers.rs  ││ +   let new_field = validate(&data);  │  ← green (added)
│○ src/models.rs    ││     Ok(result)                        │
│────────────────────││   }                                   │
│  2 live / 1 session││                                       │
│  <CR> diff  o open ││                                       │
└────────────────────┘└───────────────────────────────────────┘

● = live change (detected by file watcher)
○ = session change (from Claude Code's JSONL log)
```

**Colors:**
- **Green background** (`┃` sign) — lines Claude added
- **Yellow background** (`┃` sign) — lines Claude changed (old version shown above as struck-through red)
- **Red struck-through** (`▁` sign) — lines Claude deleted (shown as virtual text)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    "elmomk/cc-watcher.nvim",
    config = function()
        require("cc-watcher").setup()
    end,
}
```

### Local development

```lua
{
    dir = "~/path/to/cc-watcher.nvim",
    name = "cc-watcher.nvim",
    config = function()
        require("cc-watcher").setup()
    end,
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
        toggle_sidebar = "<leader>cs",  -- toggle the changed files sidebar
        toggle_diff = "<leader>cd",     -- toggle inline diff on current file
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

### When diff is active

| Key | Action |
|-----|--------|
| `]c` | Jump to next hunk |
| `[c` | Jump to previous hunk |
| `<leader>cd` | Toggle diff off |

## Commands

| Command | Description |
|---------|-------------|
| `:ClaudeSidebar` | Toggle the changed files sidebar |
| `:ClaudeDiff` | Toggle inline diff for current file |

## How it detects changes

1. **Session JSONL** — reads `~/.claude/projects/*/SESSION_ID.jsonl` to find all `Write`/`Edit` tool calls Claude made. This catches everything, even files you never opened.

2. **File watchers** — for files you've opened, libuv `fs_event` watchers detect changes instantly and auto-reload the buffer.

3. **Snapshots** — when you open a file, its content is stored in memory. Diffs compare against this snapshot, so you see what changed *since you started editing*, not against git.

## Requirements

- Neovim >= 0.10
- `grep` (available on all Unix systems)
- [Claude Code](https://claude.ai/claude-code) running in the same directory

## Highlight groups

All highlights use `default = true` so you can override them in your colorscheme:

| Group | Default | Used for |
|-------|---------|----------|
| `ClaudeDiffAdd` | green bg | Added lines |
| `ClaudeDiffChange` | yellow bg | Changed lines |
| `ClaudeDiffDelete` | red bg, strikethrough | Deleted lines (virtual text) |
| `ClaudeDiffAddSign` | green | Sign column: added |
| `ClaudeDiffChangeSign` | yellow | Sign column: changed |
| `ClaudeDiffDeleteSign` | red | Sign column: deleted |
| `ClaudeHeader` | mauve, bold | Sidebar title |
| `ClaudeActive` | green | Session active indicator |
| `ClaudeInactive` | grey, italic | No session indicator |
| `ClaudeLive` | yellow | Live-detected file icon |
| `ClaudeSession` | blue | Session-detected file icon |

## License

MIT
