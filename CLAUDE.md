# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
make deps          # Clone mini.nvim test dependency into deps/
make test          # Run full test suite headlessly
make test-file FILE=tests/test_watcher.lua   # Run a single test file
make clean         # Remove deps/
```

Test framework: mini.nvim's MiniTest (pure Lua). Tests live in `tests/`, bootstrap via `tests/minimal_init.lua`.

No formal linter config exists. No CI pipeline.

## Architecture

**cc-watcher.nvim** is a real-time file change monitor for Claude Code sessions, integrated into Neovim. It detects changes via two sources, computes diffs, and displays them through multiple UI layers.

### Data Flow

```
Claude Code edits files on disk
  ├─→ fs_event watchers (watcher.lua) → mark_changed() → changed_files{}
  └─→ JSONL session logs (session.lua) → incremental tail-read → merged{}
          ↓
      util.collect_files() merges both sources (deduped)
          ↓
      Old text: git show HEAD:<path> → snapshot fallback → empty string
      Hunks: vim.compute_hunks() via vim.diff()
          ↓
      UI: sidebar, inline diff, pickers (snacks/fzf), trouble, diffview
```

### Core Modules

- **`init.lua`** — Single idempotent `setup(opts)` entry point. Config in `M.config`.
- **`watcher.lua`** — libuv fs_event watchers on open buffers; mtime-based TOCTOU prevention.
- **`session.lua`** — Incremental JSONL parsing (only reads new bytes via `tails{}` state). 30s TTL session cache, 5s JSONL dir cache.
- **`snapshots.lua`** — LRU cache (max 100 files, 10MB each) with generation-counter eviction.
- **`util.lua`** — Shared helpers: `relpath()`, `git_relpath()`, `get_old_text()`, `compute_hunks()`, `collect_files()`.
- **`diff.lua`** — Inline diff via extmarks/signs. Hunk navigation (`]c`/`[c`), single-hunk revert (`cr`).
- **`sidebar.lua`** — Tree-style file list with directory grouping, fold state, debounced rendering (300ms), history navigation.
- **`highlights.lua`** — Semantic highlight groups (`default = true`) linked to built-in groups. Reapplied on `ColorScheme`.

### MCP Bridge (`mcp/`)

Pure-Lua WebSocket server (libuv TCP + RFC 6455). Claude Code discovers it via lock files in `~/.claude/ide/`. Handles JSON-RPC 2.0 with tools like diffAccept/diffReject.

### Integrations (`integrations/`)

11 optional modules (conform, neotest, gitsigns, neo-tree, edgy, fidget, overseer, notifier, flash, mini_diff). All register callbacks via `watcher.on_change()` — never monkey-patch core. Enabled via `config.integrations.<name> = true`.

### Plugin Commands

Defined as lightweight stubs in `plugin/cc-watcher.lua` that call `_ensure_setup()` before dispatching.

## Key Patterns

- **Zero external Lua deps** for core — only vim.uv, vim.diff, vim.json. Optional deps (snacks, fzf-lua, trouble, etc.) loaded via `pcall()`.
- **Debouncing**: Reusable `vim.uv.new_timer()` objects to avoid handle leaks. Three tiers: 500ms (notify), 300ms (JSONL), 150ms (bufenter).
- **Git-first diffing**: `git show HEAD:<relpath>` (respects worktrees) → snapshot fallback → empty string.
- **Cache invalidation**: Git show cache cleared on `FocusGained`. Active session cache has 30s TTL.
- **Extmarks**: Namespaced (`claude_diff`, `claude_sidebar`). Line-to-file mapping rebuilt each render cycle.
- **Augroups**: `ClaudeCodeWatcher`, `ClaudeSidebar`, `ClaudeDiffCleanup`, `CcWatcherMcp`.
