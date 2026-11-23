# direct.nvim

**Edit your filesystem like a text buffer.**

direct.nvim lists a directory in a Neovim buffer, one line per entry. Rename,
create, delete and move files with ordinary Vim editing, then `:write` to apply
the changes. Every filesystem change can be undone and redone.

Saving runs the filesystem and history commit asynchronously. `:write` waits for
the commit to finish, and cross-filesystem copies show progress. `<C-c>` stops
waiting but does not cancel the save; direct.nvim reports that it is continuing
in the background. `:wq` and `:x` finish the save before closing, and `:wa`
queues modified Direct listings one at a time. On exit, Neovim waits for pending
saves; `<C-c>` lets you quit anyway. `:bw!` warns that the listing buffer is
wiped while its save continues. If Neovim exits during an operation, journal
recovery completes it or reports the interruption on the next start.

<img src="demo/tour.gif" width="600" alt="direct.nvim demo: renaming, creating and deleting files by editing a listing, undoing on disk, opening files and folders, renaming with :s, copying a folder, and staging with Git">

- **Edit with Vim.** Use `cw`, `dd`, `o`, `:s`, macros or anything else, then `:w`.
- **Browse as a tree.** Expand directories in place with the usual fold keys
  (`zo`, `zc`, `zR`, …). To move an entry, change its indentation.
- **Undo filesystem changes.** `u` and `<C-r>` undo and redo saved renames,
  creates, deletes and pastes. With unsaved listing edits, they undo or redo
  buffer text instead. The filesystem history survives restarts.
- **Yank and paste files.** `yy` copies files and whole directory trees in the
  background; after a delete, the register uses the trash entry instead of a
  second copy. Paste is refused while listing edits are unsaved.
- **Git integration.** Status symbols and colours, a changed-files-only view,
  stage/reset/restore keys, and `.gitignore` filtering.
- **No dependencies.** Pure Lua and no Python. Icons work without an icon
  plugin, and use filetype icons when nvim-web-devicons is installed.

## How it compares

direct.nvim is **not** a sidebar file tree, and it doesn't preview files. If
that's what you want, use [neo-tree](https://github.com/nvim-neo-tree/neo-tree.nvim)
or [nvim-tree](https://github.com/nvim-tree/nvim-tree.lua).

It's closest to [oil.nvim](https://github.com/stevearc/oil.nvim) and
[mini.files](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-files.md):
all three turn a directory into a buffer you edit and save. The differences:

- **Trees you can edit.** direct.nvim expands folders in place, and you can
  edit, move and re-indent entries across the whole tree in one save. oil.nvim
  shows one folder per buffer, and mini.files shows folders as columns.
- **Undo on disk.** `u` and `Ctrl-r` undo and redo renames, creates, deletes
  and pastes after they're saved, and the history survives restarts. The
  others can send deletions to a trash folder, but saved changes can't be
  undone.
- **Git built in.** Status symbols and colours, a changed-files-only view and
  staging keys, with no extra plugins. oil.nvim has third-party extensions for
  Git status.
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

- Neovim **0.11.7** or later, on Linux, macOS or Windows
- Git, for status and ignore filtering (optional)
- A [Nerd Font](https://www.nerdfonts.com/), for the default icons (optional;
  you can turn icons off or replace them)
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons), for icons
  that match each file's type (optional; without it, files use one generic
  icon)

Run `:checkhealth direct` to check Neovim, Git, data-directory write access and
safe no-replace renames there, history recovery state, trash size and icon
configuration.

Register and trash paths use NUL-delimited SHA-256 keys. Neovim 0.11 rejects
NUL-containing strings in `vim.fn.sha256()` (`E976`), so direct uses a byte-safe
SHA-256 fallback on 0.11 to keep those keys identical across versions.

## Stability

**v0.4.0 is a beta.** The maintainer pre-release soak was not performed. If you
try the beta, please share what worked and what did not in the
[feedback issue](https://github.com/987poiuytrewq/direct.nvim/issues/159).

The commands, `setup()` options, `User` events, default mappings, and persisted
data formats are intended to remain stable during the 0.x series. This is a
pre-1.0 project: minor releases may still change behavior or public interfaces.
Breaking changes and migrations will be described in the changelog and release
notes. Deprecations will be called out there and in the help; when practical,
an interface will be marked deprecated before it is removed. Persisted formats
are treated as user data: format changes require explicit versioning and
migration or a safe refusal, not a silent rewrite.

CI runs the suite on Linux, macOS, and Windows using the runners' local disks.
It does not establish compatibility with network or FUSE filesystems, test
case-insensitive-volume edge cases as a separate configuration, or cover very
large directories. See `:help direct.nvim-data` for filesystem limitations.

## Installation

With Neovim's built-in `vim.pack`:

```lua
vim.pack.add({ 'https://github.com/987poiuytrewq/direct.nvim' })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim), load it at startup so it
can take over directories opened from the command line (`nvim .`):

```lua
{ '987poiuytrewq/direct.nvim', version = '*', lazy = false }
```

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug '987poiuytrewq/direct.nvim'
```

`setup()` is optional, and direct.nvim replaces netrw for directory buffers
automatically.

Releases are tagged with a `v` prefix; see [CHANGELOG.md](CHANGELOG.md) for
release notes. lazy.nvim users can select tagged releases with `version = '*'`.

## Quick start

1. Open a directory: run `nvim .`, run `:edit some/dir/`, or press `-` in any
   file to list its directory.
2. Move around: `<Enter>` or a double-click opens the entry under the cursor,
   and `-` goes up to the parent directory.
3. Edit the listing, then `:w`:

| To…    | Do this                                                     |
|--------|-------------------------------------------------------------|
| Rename | Change a name, e.g. `old.txt` → `new.txt`                   |
| Create | Add a line, e.g. `notes.md` or `reports/2026/summary.md`    |
| Delete | Delete the line (the entry goes to trash, so `p` can put it back) |
| Move   | Re-indent the line under another expanded directory         |

4. Changed your mind? Press `u` to undo the filesystem change.

See `:help direct.nvim-write` for save, quit, and interrupted-operation behavior.

### Rules for edits

- **Directories end with a separator, files don't.** `archive/` is a directory
  and `archive` is a file. On Windows the separator is `\`; you can change it
  with the `directory_separator` option.
- **Deleting a collapsed directory chain removes the whole visible chain.**
  Direct removes the deepest directory with its contents, then removes each
  parent only if it is empty. A parent with hidden, Git-ignored, or other
  unlisted entries is kept. The whole chain is one undo step.
- **A save can mix root renames, creates and deletes.** Direct pairs edited
  rows by their row identities, not by line position. The whole save is one
  undoable history entry when it mixes change types; deleted entries are
  kept in trash and referenced by the register.
- **A grouped rename permutation stays with the rest of its sync.** When a
  save includes a rename permutation such as a swap or rotation, Direct batches
  it with the sync's other recorded actions, so one undo reverses the
  permutation and its companion operations together. Standalone independent
  moves can remain separate undo steps when there is no grouped permutation.
- **A row's identity decides whether an edit is a rename.** Editing its name
  while the row mark survives is a rename. An unmarked row is a create, and a
  marked row that disappears is a delete. If a whole-line edit such as `cc` or
  `S` loses a top-level row's mark, Direct can still recognize a rename when
  the rows between surviving identity marks pair one-for-one and each pair is
  the same type (file or directory). The same rule applies to rows inside an
  expanded directory. Different counts or file/directory types keep the
  delete-plus-create behavior; an unclear identity after text undo/redo is
  refused because Direct cannot safely identify the edit. Restore the marked
  listing state, or use `:DirectList!` to discard the edits and redo the change;
  re-listing alone will not preserve ambiguous edits.
- **Unrelated disk changes are reconciled on save, including in expanded
  folders.** Entries added, removed or replaced outside edited rows and
  destinations are kept and shown after the successful save. A changed or
  missing edit source is refused, as is an external entry that occupies a
  requested destination.
- **Unclear edits change nothing.** If direct.nvim can't tell what you meant, or
  an edited source changed on disk or a destination is occupied, the save is
  refused, the filesystem is left alone, and your edits stay in the buffer.
  Refusals use stable `E-DIRECT-*` codes; when a row is known, the cursor and a
  diagnostic point to it and clear on the next text change. Global checks don't
  invent a row. Partial action failures are reported separately because some
  actions may already have succeeded. See `:help direct-refusals` for every
  code, its fix, and documented save limitations. If text undo/redo lost a row
  identity, use `:DirectList!` to deliberately discard those edits, then redo
  them; a normal re-list cannot preserve ambiguous edits.

When a listing has unsaved edits, `u` / `<C-r>` (and `:DirectUndo` /
`:DirectRedo`) undo or redo buffer text only. Once the listing is clean, they
operate on the filesystem history, except that a local text undo's paired redo
stays text-only until the listing is refreshed. The default asks before
changing files outside the current listing; configure `undo_confirm` to change
that behavior.

## Key mappings

Mappings are buffer-local to direct listings, except the global `-`.

| Key              | Action                                              |
|------------------|-----------------------------------------------------|
| `-`              | List the current file's directory, or go to the parent |
| `z-`             | Go to the parent and expand the directory you left  |
| `<CR>`, double-click | Open the file or directory                      |
| `<C-s>` `<C-v>` `<C-t>` | Open in a horizontal split, vertical split, or tab |
| `g?`             | Show the active mappings for this listing           |
| `zo` `zc` `za`   | Expand, collapse or toggle one directory            |
| `zO` `zC` `zA`   | The same, recursively                               |
| `zR` `zM`        | Expand or collapse everything                       |
| `]d` `[d`        | Next or previous directory row                      |
| `]f` `[f`        | Next or previous file row                           |
| `u` `<C-r>`      | Undo or redo the last filesystem change             |
| `yy` `Y`, visual `y` | Yank entries                                    |
| `p` `P`          | Paste into the directory under the cursor           |
| `gh`             | Show or hide dotfiles                               |
| `gi`             | Toggle `.gitignore` filtering                       |
| `gC`             | Toggle collapsing of single-child directory chains  |
| `gs`             | Toggle a view of changed files only                 |
| `gd`             | Toggle committed changes against the default branch |
| `]c` `[c`        | Next or previous changed entry                      |
| `ga` `<leader>gu` `<leader>gr` | Stage, unstage, or confirm restore of the entry |

These defaults are buffer-local, but inside a Direct listing they replace any
existing mappings for the same keys. In particular, `gd` is commonly used for
LSP go-to-definition, `<leader>gr` for references, and `<leader>gu` for a
gitsigns reset. Move only the conflicting actions with `mappings`:

```lua
require('direct').setup({ mappings = {
  git_diff = '<leader>gD',
  git_restore = '<leader>gR',
  git_unstage = '<leader>gU',
} })
```

Set `map_default_keys = false` to disable all defaults while keeping explicit
`mappings` and `<Plug>` mappings active.

`mappings` can also bind a custom Normal-mode key to a Lua function. The
function receives a detached entry record with `path`, `name`, `type`, `root`,
and `deleted`; errors are reported as warnings instead of escaping the mapping.
The `g?` help view labels these keys `Custom function`:

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

`require('direct').current_entry()` returns the unchanged row under the cursor,
or `nil` outside a Direct listing or on an edited/unidentified row.
`require('direct').selected_entries()` returns the ordered entries in the
active Visual line range, or `nil` when there is no active Direct selection.

With mouse support on (`:set mouse=a`), double-click an entry to open it, and
click a folder icon to expand or collapse that folder.

## Configuration

These are the defaults:

```lua
require('direct').setup({
  map_default_keys = true,           -- install the mappings above
  mappings = {},                      -- per-action override, false to disable, or lhs -> function(entry)
  sort = 'name',                     -- 'natural' or a comparator function
  sort_directories_first = true,     -- keep directories in a leading group
  show_hidden = true,                -- show dotfiles (toggle with `gh`)
  respect_gitignore = true,          -- hide Git-ignored entries (toggle with `gi`)
  collapse_single_entry_directories = true, -- show `a/b/c/` chains as one row (toggle with `gC`)
  indent_size = 2,                   -- spaces per tree level (integer > 1)
  undo_confirm = 'elsewhere',        -- true, false, or confirm only outside this listing
  history_limit = 1000,              -- undo and redo steps per stack
  trash_retention = { max_age_days = 90 }, -- or false, or add max_size_bytes
  directory_separator = package.config:sub(1, 1), -- native platform separator
  max_recursive_expand_depth = false, -- limit for zO/zR; false = unlimited
  buffers = {
    reuse = true,        -- reuse an existing Direct listing for the same directory
    open_in = 'current', -- or 'new' to keep the source buffer when opening files
  },
  show_folder_icons = true,
  show_file_icons = true,
  show_filetype_icons = true,
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
    enabled = true,       -- show Git status when its background query completes
    timeout_ms = 1000,    -- background Git status-query deadline
    ignore_timeout_ms = 200, -- Git-ignore snapshot deadline
    show_symbols = true,  -- right-aligned status symbols
    show_deleted = true,  -- show rows for deleted tracked files
    symbols = {           -- one display cell each, or '' to hide
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

`sort` accepts `'name'` (byte-wise name order), `'natural'` (case-insensitive
numeric name order), or a comparator receiving `{ name, type }` records. Set
`sort_directories_first = false` to sort directories and files together. If a
custom comparator errors, Direct warns once for that listing and falls back to
name order for the complete listing.

`is_hidden(name, path, type)` optionally customizes hidden-entry filtering when
`show_hidden = false`. Return `true` to hide an entry, `false` to show it (even
if its name starts with a dot), or `nil` to use the default dot-name rule.
`gh` reveals dot- and custom-hidden entries; Git-ignore and `wildignore` remain
independent filters.

Git status is read in the background so it doesn't delay the initial listing.
When the query completes, Direct adds the status decorations and deleted rows.
`git.timeout_ms` sets the status-query deadline. A timed-out status query
leaves the listing usable without status; a timed-out Git-ignore query leaves
ignored entries visible for that listing, with an in-buffer warning. Saving
retries the ignore query: it proceeds if the changed paths are still visible,
and refuses if the query still times out or a changed path would be hidden. In
that case, `gi` can turn the filter off without discarding the unsaved edits.
`git.ignore_timeout_ms` sets the independent Git-ignore deadline (default `200` ms).

You can call `setup()` more than once. Each call replaces the previous options,
and unknown or invalid options are reported as errors instead of being silently
ignored.

`buffers.reuse` applies to Direct directory listings. Set it to `false` to
create a separate listing buffer each time; its name shows the directory path
with a unique suffix. With `buffers.open_in = 'current'`, clean listings are
removed as you navigate away, while modified listings remain hidden. If you
open a directory that already has a modified listing, Direct offers to switch
to it or create another listing. Regular file buffers keep Neovim's normal
path-based reuse. `buffers.open_in = 'new'` keeps the source listing (including
unsaved edits) when opening a file, without creating a split. It defaults to
`'current'`, which opens in the current window and removes the clean source
buffer after a successful file open. For directory navigation, clean source
listings are also removed when `reuse = false`. A source buffer is only removed
when no other window displays it. These settings can be overridden per call:

```lua
require('direct').open({ reuse = false, open_in = 'new' })
```

Explicit split options continue to preserve the source.

`mappings` accepts action names such as `open`, `undo`, `redo`, `yank`,
`paste`, `toggle_hidden`, `toggle_gitignore`, `git_add`, `git_diff`, `next_change`,
`open_horizontal`, `open_vertical`, `open_tab`, `expand`, `collapse`, `toggle`,
`show_help`, and their recursive variants. A non-empty key string overrides
that action's default; `false` disables its physical default. `g?` displays the
currently active buffer-local mappings; disabled mappings are omitted.
Every action also has a `<Plug>(direct-...)` mapping for composing your own
bindings. For example:

```lua
vim.keymap.set('n', '<leader>e', '<Plug>(direct-expand)', { remap = true })
```

The folder actions are also public Lua functions: `require('direct').expand()`,
`collapse()`, `toggle()`, `expand_recursive()`, `collapse_recursive()`, and
`toggle_recursive()`.

Pass a `split` option to open the selected entry in a new layout, leaving the
current listing in place: `require('direct').open({ split = 'horizontal' })`,
`require('direct').open({ split = 'vertical' })`, or
`require('direct').open({ split = 'tab' })`. The default bindings are `<C-s>`,
`<C-v>`, and `<C-t>`.

`undo_confirm` controls prompts before filesystem undo/redo: `true` always
prompts, `false` never prompts, and `'elsewhere'` (the default) prompts only if
the affected paths are outside the current listing's directory.

`history_limit` bounds each undo/redo stack. When a commit exceeds the limit,
the oldest steps are dropped and direct.nvim warns once per Neovim session.
`trash_retention` defaults to `{ max_age_days = 90 }`; set `max_age_days`,
`max_size_bytes`, or both to change pruning, or use `false` to disable it.
History-referenced trash is kept unless explicitly forced through
`:DirectTrash! empty`. Forced restore or empty asks first when it would discard
undo/redo steps that depend on the trash payload, and reports the number of
affected steps. Automatic retention runs at most once per Neovim session and
data directory during saves. When history trimming releases trash paths,
age-based retention checks those paths directly; size limits trigger at most
one additional full scan per session. Opening `:DirectTrash` forces a fresh
pass before showing the entries.

`:checkhealth direct` reports undo/redo step counts and register size, and warns
when register storage exceeds 1 GiB. Register snapshots that are neither the
current yank nor referenced by undo/redo paste records are cleaned after
register or history updates.

When an older trash entry has no metadata sidecar, `:DirectTrash` looks for its
delete action in history and reconstructs the original path and entry type,
with an estimated deletion time marked in the view. Restore-ID completion only
lists trash names; it does not size entries or write metadata. If no matching
history remains, the entry stays marked unknown and needs an explicit restore
path.

With `show_filetype_icons` enabled, `icons.provider` selects the source for
regular-file icons. The default `'auto'` uses configured `mini.icons` first,
then `nvim-web-devicons`, and falls back to `icons.file` if neither can provide
an icon. Set it to `'mini'` or `'devicons'` to choose one provider, `false` to
always use the generic glyph, or a function `(name, type) -> glyph, highlight`
to supply an icon. A custom function's errors fall back safely and are reported
once. Folders and deleted tracked files keep their configured Direct icons.

### Highlights

Every highlight links to a standard group by default, so it follows your
colour scheme. To change one, use `vim.api.nvim_set_hl()`:

| Group                                       | Default link            |
|---------------------------------------------|-------------------------|
| `DirectDirectory`                           | `Directory`             |
| `DirectFileIcon`                             | `Normal`                |
| `DirectHiddenFolderIcon`, `DirectHiddenFileIcon` | `Comment`           |
| `DirectGitDeletedFile`, `DirectGitDeletedDirectory` | `ErrorMsg`      |
| `DirectGit*` status groups                  | `Added`, `Changed`, `Removed`, `ErrorMsg`, `Comment` |

Visible file icons use `DirectFileIcon`; hidden file icons retain
`DirectHiddenFileIcon`. nvim-web-devicons supplies file glyphs, but its
highlight groups do not override Direct's groups. Git status still colours the
file names and folder icons.

`:help direct.nvim` lists every group.

## Git

In a Git repository, each row shows its status on the right, and the names of
changed entries are coloured to match. Directories show the combined status of
their contents, and deleted tracked files appear as protected rows so you can
restore them.

- `gs` shows only changed entries, with directories fully expanded.
- `:DirectGitStatus [--dir {dir}]` shows changed entries in the target listing.
  In a Direct listing, it applies there by default; elsewhere it opens or reuses
  a listing for the working directory. Relative `--dir` paths are based on the
  current listing when run there, and on the working directory otherwise.
- `gd` toggles committed changes from a branch's merge base to `HEAD` in the
  current listing. In a Direct listing, `:DirectGitDiff` applies there by
  default. Elsewhere it opens or reuses a listing for the working directory.
  Both commands accept a relative `--dir` from the current listing or working
  directory, depending on where invoked. `:DirectGitDiff` accepts `--ref {ref}`
  and `--include-uncommitted`. Options, refs and directories have completion.
  Without `--ref`, Direct uses `origin/HEAD`, then local `main`, then local
  `master`. Staged, unstaged,
  and non-ignored untracked paths are included only with
  `--include-uncommitted`; they are unioned with committed changes. Directories
  are expanded to show changed descendants, and deleted paths remain visible.
  Repeating the command with the same options toggles the filter off. Commands
  refuse while the target listing has unsaved edits.
- `]c` / `[c` jump between changed entries.
- `ga` stages the entry; `<leader>gu` unstages it.
- `<leader>gr` asks before discarding tracked worktree changes under the entry.
  The prompt names the path and counts changed files. It leaves untracked and
  staged-only changes alone. Before restoring, it copies existing changed
  entries to `:DirectTrash` and reports their IDs and original paths. In the
  trash view, `r` or `<CR>` on a Git-restore backup asks before moving the current
  file into trash and putting the backup back. That put-back is one undoable
  history step; the Git restore itself is not.
- `gi` toggles ignore filtering. Filtering uses Git itself, so nested
  `.gitignore` files, `.git/info/exclude` and your global excludes file all
  apply. Tracked files are never hidden. Ignore queries use `git.ignore_timeout_ms`;
  a timeout leaves entries visible with an in-buffer warning. Saving retries the
  query and refuses only if it still times out or a changed entry would be
  hidden; `gi` can disable the filter without losing unsaved edits. Unreadable
  subfolders are skipped with a warning during nested-repository discovery.

### Run commands on entries

`:DirectRun {cmd}` runs a shell command asynchronously from the listing's
directory. Each `{}` in the command is replaced with the escaped path of the
entry under the cursor:

```vim
:DirectRun wc -l {}
:DirectGit git log --oneline -5 -- {}
```

`:DirectGit` works the same way and also refreshes the Git status in the listing
when the command finishes.

## LSP integration

Renames, creates and deletes are reported to language servers that support
`workspace/*Files` file operations. For a rename, servers are asked first
through `willRenameFiles`, so they can update imports before the file moves.

## Events for plugins

direct.nvim emits Neovim `User` autocmds after a listing, before and after a
filesystem sync, after filesystem undo, redo and paste, after trash restore or
empty, after history reset, and after Git worktree restore. Event callbacks
receive copied `data`. Sync data includes the absolute `root` and planned
`actions`. For example:

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

Supported patterns are `DirectListPost`, `DirectSyncPre`, `DirectSyncPost`,
`DirectUndoPost`, `DirectRedoPost`, `DirectPastePost`, `DirectTrashPost`,
`DirectHistoryResetPost`, and `DirectGitRestorePost`. `DirectListPost` has an
empty `actions` array. Sync post data also includes `applied`, `failed`, `yanks`,
`success`, and `error`; paste post includes `changed`, `entry`, `success`, and
`error`; undo/redo post actions describe the reversal. `DirectTrashPost` includes
`operation` (`restore` or `empty`), `success`, and `error`, plus the applicable
ID, destination, force, removed, or protected fields. `DirectHistoryResetPost`
includes `success`, `backups`, and `error`. `DirectGitRestorePost` includes
`root`, `target`, changed paths, trash backups, `success`, and `error`. Action
records use the same `name`, `src`, `dst`, and nested `actions` fields as the
Direct history model.

Event data is copied before dispatch, so editing it does not mutate Direct's
operation. A `DirectSyncPre` handler can cancel by calling
`require('direct.events').cancel(event.data, 'reason')`. The sync is refused
before yanks or filesystem effects, remains modified, and emits a failed
`DirectSyncPost`. Both sync events run synchronously while the history lock is
held; handlers should be fast and must not start another Direct filesystem or
history operation. If a handler edits the listing instead, the sync is also
refused and the listing remains modified for review.

## Commands

direct.nvim notifications are prefixed with `direct:` so they can be
distinguished from messages from Neovim and other plugins.

| Command                    | Description                                           |
|----------------------------|-------------------------------------------------------|
| `:DirectList[!] {dir}`     | List a directory; `!` discards its unsaved listing edits |
| `:DirectListBuffer[!]`     | List the current file's directory; `!` discards its unsaved listing edits |
| `:DirectListCwd[!]`        | List the working directory; `!` discards its unsaved listing edits |
| `:DirectSync`              | Start an asynchronous save; `:write` waits for completion |
| `:DirectUndo` / `:DirectRedo` | Undo/redo filesystem changes, or text while modified |
| `:DirectHistory`           | Show the undo and redo stacks in a read-only view     |
| `:DirectHistory drop [undo|redo]` | Drop only the top step of one history stack     |
| `:DirectHistoryReset`      | Back up and reset both history stacks                 |
| `:DirectTrash`             | List, restore, or empty trashed entries               |
| `:DirectYank`              | Yank the entries in a range                           |
| `:DirectPaste [dir]`       | Paste here, or into `{dir}`                           |
| `:DirectPasteAs {name}`    | Paste under a new name                                |
| `:DirectFoldAll` / `:DirectUnfoldAll` | Collapse or expand everything              |
| `:DirectToggleHidden`      | Show or hide dotfiles                                 |
| `:DirectToggleGitIgnore`   | Toggle `.gitignore` filtering                         |
| `:DirectToggleDirectoryCollapse` | Toggle collapsing of single-child directory chains |
| `:DirectToggleGitStatus` / `:DirectGitStatus` | Toggle, or enter, the changed-only view |
| `:DirectGitStatus [--dir {dir}]` | Filter the current listing, or target a directory |
| `:DirectGitDiff [--ref {ref}] [--dir {dir}] [--include-uncommitted]` | Filter the current listing, or target a directory |
| `:DirectNextFile` / `:DirectPreviousFile` | Jump between files, skipping directories |
| `:DirectNextChange` / `:DirectPreviousChange` | Jump between changed entries       |
| `:DirectRun {cmd}` / `:DirectGit {cmd}` | Run a command on the current entry       |

`:DirectTrash` opens a read-only list. Use `:DirectTrash restore {id}` to
restore an entry (or add a destination for old entries with no matching
history), and `:DirectTrash empty` to remove unreferenced entries. Command
completion offers `restore`, `empty`, and trash IDs. In the view, `r` or `<CR>`
restores the selected entry after confirmation; `q` closes it. Prefix a command
with `!` only to override history protection; an existing restore destination
is never overwritten.

If a forced restore or empty would invalidate undo/redo steps that refer to the
trash payload, Direct asks before proceeding and removes those records plus
earlier history steps that overlap the affected paths, so surviving entries do
not depend on a missing operation. This includes paste/unpaste steps for entries
that were later moved to trash. Use `:DirectHistory drop undo` or
`:DirectHistory drop redo` to discard just one irrecoverable top step while
preserving the rest of that stack. The command defaults to `undo` when the
direction is omitted. If undo/redo fails because its source is missing, the
error suggests the matching `:DirectHistory drop` command.

`:DirectHistory` shows both filesystem history stacks newest first, with each
action's summary and affected paths. It is a read-only snapshot: it does not
recover an unfinished transaction, initialize missing logs, or rewrite damaged
history. The current buffer remains loaded when the view replaces it.

Relisting a directory with unsaved edits is refused so the listing is not
silently overwritten. Opening a file from a modified listing is also refused;
opening a directory keeps the original listing available. Sync the edits, or
use the command's `!` form to deliberately discard edits in the listing being
refreshed.

## How safe is it?

direct.nvim is built so that a mistake can be undone:

- Deleted entries go to a trash directory, and undo restores them from there.
- Files are created, moved and renamed with no-replace operations, so an
  existing file is never silently overwritten.
- A save is checked against the filesystem before anything is changed. If the
  directory has changed since it was listed, the save is refused.
- Undo history is stored on disk under `$XDG_DATA_HOME/direct` (or
  `~/.local/share/direct`) and journaled, so an interrupted operation can be
  finished or reported after a crash.
- Damaged or unknown history is preserved and blocks filesystem operations.
  `:DirectHistoryReset` first backs up readable history files before resetting.
- Neovim instances on the same machine share a history lock. Busy locks are
  retried for up to two seconds, and the error identifies the holder when
  possible. The lock is released while a paste clash prompt is open or an
  explicit yank copies in the background; on resume, the register, history and
  destination are checked again.

The lock file is stored at `<data>/direct/.direct-history.lock`; a companion
`.owner` file records the holder PID for diagnostics. Do not run an older
direct.nvim version at the same time as this version: older versions use
`<data>/.direct-history.lock`, so the two versions would not coordinate with
each other. The old lock file is left untouched and is harmless once no older
version is running.

Other programs don't use the lock, and network filesystems are not guaranteed
to work. `:help direct.nvim-data` explains exactly what is guaranteed.

Direct's atomic no-replace rename is implemented for Linux, macOS and Windows.
FreeBSD and other BSD systems currently fail closed because Direct has no native
no-replace implementation for them. Even on supported operating systems, a
filesystem may not support the required rename flag; this can happen on NFS,
SMB/CIFS, FUSE filesystems such as sshfs, exFAT on macOS, or older ZFS on Linux.
Direct never falls back to a replacing rename. `:checkhealth direct` tests this
capability only inside Direct's own data directory. When a rename on another
filesystem reports that the operation is unsupported, Direct remembers that
device for the current session and refuses later renames there before changing
anything. See `:help direct.nvim-data`.

## Documentation

This README is an overview. The full reference is in Neovim:

```vim
:help direct.nvim
```

It covers every command, option, mapping and highlight group, the Lua API, the
sync and ambiguity rules, the data directory layout, and how to upgrade from the old
Python version.

## Development

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for development setup, test and coverage
commands, the release checklist, and demo recording instructions.

## License

[MIT](LICENSE) © Duncan Williams
