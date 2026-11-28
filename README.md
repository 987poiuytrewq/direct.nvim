# direct.nvim

**Edit your filesystem like a text buffer.**

direct.nvim is a buffer-based file manager for Neovim 0.11.7+. It lists a
directory one line per entry. Rename, create, delete and move files with
ordinary Vim editing, then `:write` to apply the changes. Every saved change
can be undone and redone, even after a restart.

<img src="demo/tour.gif" width="600" alt="direct.nvim demo: renaming, creating and deleting files by editing a listing, undoing on disk, opening files and folders, renaming with :s, copying a folder, and staging with Git">

- **Edit with Vim.** Use `cw`, `dd`, `o`, `:s`, macros or anything else, then `:w`.
- **Browse as a tree.** Expand directories in place with the usual fold keys
  (`zo`, `zc`, `zR`, …). To move an entry, change its indentation.
- **Undo on disk.** `u` and `<C-r>` undo and redo saved renames, creates,
  deletes and pastes. The history survives restarts.
- **Yank and paste files.** `yy` and `p` copy files and whole directory trees in
  the background.
- **Git built in.** Status symbols and colours, a changed-files-only view,
  stage/unstage/restore keys, and `.gitignore` filtering.
- **No dependencies.** Pure Lua. Filetype icons are used when mini.icons or
  nvim-web-devicons is installed.

## How it compares

direct.nvim is **not** a sidebar file tree, and it doesn't preview files. If
that's what you want, use [neo-tree](https://github.com/nvim-neo-tree/neo-tree.nvim)
or [nvim-tree](https://github.com/nvim-tree/nvim-tree.lua).

It's closest to [oil.nvim](https://github.com/stevearc/oil.nvim) and
[mini.files](https://github.com/nvim-mini/mini.nvim/blob/main/readmes/mini-files.md):
all three turn a directory into a buffer you edit and save. The differences:

- **Trees you can edit.** direct.nvim expands folders in place, and one save
  can edit, move and re-indent entries across the whole tree. oil.nvim shows
  one folder per buffer, and mini.files shows folders as columns.
- **Undo after saving.** The others can send deletions to a trash folder, but
  saved changes can't be undone.
- **Git without extensions.** oil.nvim has third-party extensions for Git
  status.
- **No previews or remote files.** oil.nvim and mini.files preview files, and
  oil.nvim can browse SSH and S3. direct.nvim does neither.

|  | direct.nvim | oil.nvim | mini.files | neo-tree, nvim-tree | netrw |
|---|:---:|:---:|:---:|:---:|:---:|
| Change files by editing text | ✓ | ✓ | ✓ | — | — |
| Layout | Buffer, folders expand as a tree | Buffer, one folder | Floating columns | Sidebar tree | Buffer, list or tree |
| Edit across expanded folders | ✓ | — | — | — | — |
| Undo changes after saving | ✓ | — | — | — | — |
| Git status built in | ✓ | Via extensions | — | ✓ | — |
| LSP file operations | ✓ | ✓ | ✓ | Via a plugin | — |
| File preview | — | ✓ | ✓ | ✓ | ✓ |
| Sidebar | — | — | — | ✓ | ✓ |
| Remote filesystems | — | ✓ | — | — | ✓ |

Based on each project's documentation in November 2026; check their docs for
the latest.

## Requirements

- Neovim **0.11.7** or later, on Linux, macOS or Windows. Vim is not supported.
- Git, for status and ignore filtering (optional).
- A [Nerd Font](https://www.nerdfonts.com/) for the default icons (optional;
  icons can be turned off or replaced).
- [mini.icons](https://github.com/nvim-mini/mini.nvim/blob/main/readmes/mini-icons.md)
  or [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) for
  per-filetype icons (optional; without one, files share a generic icon).

Run `:checkhealth direct` to check your setup.

## Stability

**v0.4.0 is a beta** and hasn't yet had a long real-world trial. If you try it,
please share what worked and what didn't in the
[feedback issue](https://github.com/987poiuytrewq/direct.nvim/issues/159).

Commands, `setup()` options, `User` events, default mappings and on-disk data
formats are intended to stay stable through 0.x, but minor releases may still
change behaviour. Breaking changes, deprecations and migrations are described
in [CHANGELOG.md](CHANGELOG.md). On-disk formats are treated as user data: a
format change is versioned and migrated, or refused safely, never silently
rewritten.

CI runs on Linux, macOS and Windows local disks. Network and FUSE filesystems,
case-insensitive volume edge cases and very large directories are not covered;
see `:help direct.nvim-data`.

## Installation

With Neovim's built-in `vim.pack`:

```lua
vim.pack.add({ 'https://github.com/987poiuytrewq/direct.nvim' })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim), load it at startup so it
can take over directories opened from the command line (`nvim .`).
`version = '*'` follows tagged releases:

```lua
{ '987poiuytrewq/direct.nvim', version = '*', lazy = false }
```

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug '987poiuytrewq/direct.nvim'
```

`setup()` is optional. direct.nvim replaces netrw for directory buffers
automatically.

## Quick start

1. Open a directory: run `nvim .`, run `:edit some/dir/`, or press `-` in any
   file to list its directory.
2. Move around: `<CR>` opens the entry under the cursor, and `-` goes up to the
   parent directory.
3. Edit the listing, then `:w`:

   | To…    | Do this                                                     |
   |--------|-------------------------------------------------------------|
   | Rename | Change a name, e.g. `old.txt` → `new.txt`                   |
   | Create | Add a line, e.g. `notes.md` or `reports/2026/summary.md`    |
   | Delete | Delete the line (the entry goes to trash)                   |
   | Move   | Re-indent the line under another expanded directory         |

4. Changed your mind? Press `u` to undo the filesystem change.

### Saving

`:write` applies the changes in the background and waits for them to finish;
cross-filesystem copies show progress. `<C-c>` stops waiting, but the save
carries on. `:wq` and `:x` finish the save before closing, and Neovim waits for
pending saves on exit. If Neovim stops mid-operation, the next start completes
it or reports what was interrupted. See `:help direct.nvim-write`.

While a listing has unsaved edits, `u` and `<C-r>` undo and redo buffer text.
Once it's saved, they undo and redo the filesystem. By default, Direct asks
before undoing changes outside the current listing (see `undo_confirm`).

### Rules for edits

- **Directories end with a separator, files don't.** `archive/` is a directory
  and `archive` is a file. On Windows the separator is `\` (configurable with
  `directory_separator`).
- **Each row keeps a hidden identity.** Editing a name is a rename, a new line
  is a create, and a removed line is a delete, wherever the line ends up. Swaps
  and rotations work, and a save that mixes change types is one undo step.
- **Changes made outside Neovim are kept.** Entries added or removed on disk
  since the listing was drawn are merged in after the save.
- **Unclear edits change nothing.** If Direct can't tell what you meant, an
  edited entry changed on disk, or a destination is taken, the save is refused,
  the filesystem is left alone, and your edits stay in the buffer. The error
  has an `E-DIRECT-*` code and, where possible, points at the row. See
  `:help direct-refusals`.

If text undo leaves a row Direct can't identify, run `:DirectList!` to discard
the listing edits and make them again.

## Key mappings

Mappings are local to Direct listings, except the global `-`.

| Key                            | Action                                              |
|--------------------------------|-----------------------------------------------------|
| `-`                            | List the current file's directory, or go to the parent |
| `z-`                           | Go to the parent and expand the directory you left  |
| `<CR>`                         | Open the file or directory                          |
| `<C-s>` `<C-v>` `<C-t>`        | Open in a horizontal split, vertical split or tab   |
| `g?`                           | Show the active mappings                            |
| `zo` `zc` `za`                 | Expand, collapse or toggle a directory              |
| `zO` `zC` `zA`                 | The same, recursively                               |
| `zR` `zM`                      | Expand or collapse everything                       |
| `]d` `[d`                      | Next or previous directory                          |
| `]f` `[f`                      | Next or previous file                               |
| `u` `<C-r>`                    | Undo or redo the last filesystem change             |
| `yy` `Y`, visual `y`           | Yank entries                                        |
| `p` `P`                        | Paste into the directory under the cursor           |
| `gh`                           | Show or hide dotfiles                               |
| `gi`                           | Toggle `.gitignore` filtering                       |
| `gC`                           | Toggle collapsing of single-child directory chains  |
| `gs`                           | Toggle a view of changed files only                 |
| `gd`                           | Toggle committed changes against the default branch |
| `]c` `[c`                      | Next or previous changed entry                      |
| `ga` `<leader>gu` `<leader>gr` | Stage, unstage, or restore (after confirming) the entry |

Inside a listing these replace your own mappings for the same keys. `gd`,
`<leader>gr` and `<leader>gu` often clash with LSP and gitsigns mappings, so
move them with `mappings` if needed:

```lua
require('direct').setup({ mappings = {
  git_diff = '<leader>gD',
  git_restore = '<leader>gR',
  git_unstage = '<leader>gU',
} })
```

Set an action to `false` to disable it, or `map_default_keys = false` to drop
all default keys. Every action also has a `<Plug>(direct-...)` mapping:

```lua
vim.keymap.set('n', '<leader>e', '<Plug>(direct-expand)', { remap = true })
```

**Mouse.** With `map_mouse_keys = true` and `:set mouse=a`, double-click an
entry to open it, or click a folder icon to expand or collapse it. It's off by
default so tabline click handlers such as bufferline.nvim keep working.

**Custom actions.** A `mappings` key can also be bound to a Lua function. It
receives the entry under the cursor (`path`, `name`, `type`, `root`, `deleted`),
and `g?` lists it as `Custom function`:

```lua
require('direct').setup({
  mappings = {
    ['<leader>y'] = function(entry)
      vim.fn.setreg('+', entry.path)
    end,
    ['<leader>T'] = function(entry)
      if entry.deleted then return end
      local dir = entry.type == 'directory' and entry.path or vim.fs.dirname(entry.path)
      vim.cmd('botright new')
      vim.fn.termopen({ vim.o.shell }, { cwd = dir })
    end,
  },
})
```

For your own code, `require('direct').current_entry()` and
`selected_entries()` return the entry under the cursor and the entries in the
Visual selection.

## Configuration

These are the defaults:

```lua
require('direct').setup({
  map_default_keys = true,           -- install the default keyboard mappings
  map_mouse_keys = false,            -- opt in to mouse-click mappings
  mappings = {},                     -- action = key, action = false, or key = function(entry)
  sort = 'name',                     -- 'name', 'natural' or a comparator function
  sort_directories_first = true,     -- list directories before files
  show_hidden = true,                -- show dotfiles (toggle with `gh`)
  respect_gitignore = true,          -- hide Git-ignored entries (toggle with `gi`)
  collapse_single_entry_directories = true, -- show `a/b/c/` chains as one row (toggle with `gC`)
  indent_size = 2,                   -- spaces per tree level (2 or more)
  undo_confirm = 'elsewhere',        -- true, false, or 'elsewhere': confirm outside this listing
  history_limit = 1000,              -- undo and redo steps per stack
  trash_retention = { max_age_days = 90 }, -- also max_size_bytes, or false to keep everything
  directory_separator = package.config:sub(1, 1), -- native platform separator
  max_recursive_expand_depth = false, -- depth limit for zO/zR; false = unlimited
  buffers = {
    reuse = true,        -- reuse an existing listing for the same directory
    open_in = 'current', -- or 'new' to keep the listing when opening a file
  },
  show_folder_icons = true,
  show_file_icons = true,
  show_filetype_icons = true,
  color_file_icons = true,           -- use the icon provider's colours
  icons = {
    provider = 'auto',               -- mini.icons, then nvim-web-devicons
    file = '\u{f15b}',
    folder = '\u{f07b}',
    folder_open = '\u{f07c}',
    deleted_file = '\u{f016}',
    deleted_folder = '\u{f114}',
    deleted_folder_open = '\u{f115}',
  },
  git = {
    enabled = true,          -- show Git status once the background query finishes
    timeout_ms = 1000,       -- status query deadline
    ignore_timeout_ms = 200, -- ignore query deadline
    show_symbols = true,     -- right-aligned status symbols
    show_deleted = true,     -- show rows for deleted tracked files
    symbols = {              -- one display cell each, or '' to hide
      added = '\u{f067}',
      deleted = '\u{f068}',
      modified = '\u{f01f}',
      renamed = '\u{f061}',
      ignored = '\u{f070}',
      staged = '\u{f00c}',
      conflict = '\u{f00d}',
    },
  },
})
```

`setup()` can be called more than once; each call replaces the previous
options, and unknown or invalid options are reported as errors.

A few options take more than a value:

- `sort` can be a comparator that receives `{ name, type }` records.
- `is_hidden(name, path, type)` customises hidden entries when
  `show_hidden = false`. Return `true` to hide, `false` to show, or `nil` for
  the default dot-name rule.
- `icons.provider` can be `'mini'`, `'devicons'`, `false` for the generic
  glyph, or a function `(name, type) -> glyph, highlight`.
- `buffers` settings can be overridden per call with
  `require('direct').open({ reuse = false, open_in = 'new' })`, and
  `open({ split = 'vertical' })` opens the entry in a split (also
  `'horizontal'` or `'tab'`).

`:help direct.nvim` describes every option in full.

### Highlights

Every highlight group links to a standard group, so it follows your colour
scheme. Override one with `vim.api.nvim_set_hl()`:

| Group                                               | Default link |
|-----------------------------------------------------|--------------|
| `DirectDirectory`                                   | `Directory`  |
| `DirectFileIcon`                                    | `Normal`     |
| `DirectHiddenFolderIcon`, `DirectHiddenFileIcon`    | `Comment`    |
| `DirectGitDeletedFile`, `DirectGitDeletedDirectory` | `ErrorMsg`   |
| `DirectGit*` status groups                          | `Added`, `Changed`, `Removed`, `ErrorMsg`, `Comment` |

`:help direct.nvim` lists every group.

## Git

In a Git repository, each row shows its status on the right and changed names
are coloured to match. Directories show the combined status of their contents,
and deleted tracked files appear as rows you can restore.

- `gs` shows only changed entries, fully expanded.
- `gd` shows entries changed between the default branch's merge base and
  `HEAD`. `:DirectGitDiff --ref {ref}` picks another base, and
  `--include-uncommitted` adds working-tree changes.
- `]c` / `[c` jump between changed entries.
- `ga` stages the entry and `<leader>gu` unstages it.
- `<leader>gr` restores tracked changes under the entry after asking. The
  current versions are copied to `:DirectTrash` first, so the restore can be
  reversed from there.
- `gi` toggles ignore filtering. It uses Git itself, so nested `.gitignore`
  files, `.git/info/exclude` and your global excludes all apply. Tracked files
  are never hidden.

### Run commands on entries

`:DirectRun {cmd}` runs a shell command in the background from the listing's
directory, replacing each `{}` with the escaped path of the entry under the
cursor. `:DirectGit` does the same and then refreshes the Git status:

```vim
:DirectRun wc -l {}
:DirectGit git log --oneline -5 -- {}
```

## LSP integration

Renames, creates and deletes are reported to language servers that support
`workspace/*Files` file operations. Before a rename, servers are asked through
`willRenameFiles`, so they can update imports before the file moves.

## Events

direct.nvim fires `User` autocmds you can hook into:

`DirectListPost`, `DirectSyncPre`, `DirectSyncPost`, `DirectUndoPost`,
`DirectRedoPost`, `DirectPastePost`, `DirectTrashPost`,
`DirectHistoryResetPost` and `DirectGitRestorePost`.

Each callback receives a copy of the event `data`, such as the listing `root`
and the planned `actions`:

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'DirectSyncPost',
  callback = function(event)
    if event.data.success then
      print('Synced', event.data.root, #event.data.actions, 'actions')
    end
  end,
})
```

A `DirectSyncPre` handler can cancel the save with
`require('direct.events').cancel(event.data, 'reason')`. Sync handlers run
while the history lock is held, so keep them fast and don't start another
Direct operation from them. `:help direct.nvim` documents each event's fields.

## Commands

| Command                    | Description                                           |
|----------------------------|-------------------------------------------------------|
| `:DirectList[!] {dir}`     | List a directory                                      |
| `:DirectListBuffer[!]`     | List the current file's directory                     |
| `:DirectListCwd[!]`        | List the working directory                            |
| `:DirectSync`              | Save in the background (`:write` waits for it)        |
| `:DirectUndo` / `:DirectRedo` | Undo or redo filesystem changes (or text while unsaved) |
| `:DirectHistory`           | Show the undo and redo stacks                         |
| `:DirectHistory drop [undo\|redo]` | Drop the top step of one stack                |
| `:DirectHistoryReset`      | Back up and reset the history                         |
| `:DirectTrash`             | List, restore or empty trashed entries                |
| `:DirectYank`              | Yank the entries in a range                           |
| `:DirectPaste [dir]`       | Paste here, or into `{dir}`                           |
| `:DirectPasteAs {name}`    | Paste under a new name                                |
| `:DirectFoldAll` / `:DirectUnfoldAll` | Collapse or expand everything              |
| `:DirectToggleHidden`      | Show or hide dotfiles                                 |
| `:DirectToggleGitIgnore`   | Toggle `.gitignore` filtering                         |
| `:DirectToggleDirectoryCollapse` | Toggle collapsing of single-child directory chains |
| `:DirectToggleGitStatus`   | Toggle the changed-only view                          |
| `:DirectGitStatus [--dir {dir}]` | Show only changed entries                       |
| `:DirectGitDiff [--ref {ref}] [--dir {dir}] [--include-uncommitted]` | Show entries changed on this branch |
| `:DirectNextFile` / `:DirectPreviousFile` | Jump between files, skipping directories |
| `:DirectNextChange` / `:DirectPreviousChange` | Jump between changed entries       |
| `:DirectRun {cmd}` / `:DirectGit {cmd}` | Run a command on the current entry       |

The `!` on the list commands discards that listing's unsaved edits. Without it,
re-listing a modified listing is refused, so edits are never silently lost.

### Trash and history

`:DirectTrash` opens a read-only list of deleted entries. Press `r` or `<CR>`
to restore one, or use `:DirectTrash restore {id}` and `:DirectTrash empty`.
Entries that undo history still needs are protected; the `!` form overrides
that after asking. A restore never overwrites an existing file.

`:DirectHistory` shows both history stacks, newest first. If an undo step can no
longer be applied (for example, its source was removed outside Neovim),
`:DirectHistory drop` discards just that step, and the error message suggests
it.

## How safe is it?

direct.nvim is built so that a mistake can be undone:

- Deleted entries go to a trash directory, and undo restores them from there.
- Files are created, moved and renamed with no-replace operations, so an
  existing file is never silently overwritten. There is no fallback to a
  replacing rename.
- A save is checked against the filesystem before anything changes.
- Undo history is stored under `$XDG_DATA_HOME/direct` (or
  `~/.local/share/direct`) and journaled, so an interrupted operation can be
  finished or reported after a crash.
- Damaged or unknown history is kept, not overwritten, and blocks filesystem
  operations until you deal with it. `:DirectHistoryReset` backs it up first.
- Neovim instances on the same machine share a history lock.

**Limits.** Other programs don't use the lock. No-replace renames are
implemented for Linux, macOS and Windows; on FreeBSD and other BSDs, and on
filesystems without the needed rename flag (often NFS, SMB, sshfs and other
FUSE filesystems, or exFAT on macOS), Direct refuses renames rather than risk
overwriting. `:help direct.nvim-data` explains exactly what is guaranteed.

Don't run a release older than v0.4.0 at the same time as this one:
it uses a different lock file, so the two won't coordinate.

## Documentation

This README is an overview. The full reference is in Neovim:

```vim
:help direct.nvim
```

It covers every command, option, mapping, highlight group and event, the Lua
API, the edit and refusal rules, the data directory layout, and how to upgrade
from the old Python version.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, tests, coverage,
the release checklist and demo recording.

## License

[MIT](LICENSE) © Duncan Williams
