# Spec: direct.vim improvements, fourth review

**Status:** A33–A37, A41–A43, A45–A47, A49–A50 and A57–A58 are complete.
A48 is partially complete; A38–A40, A44 and A51–A56 remain open.

**Source:** a fourth static review of `origin/master` at `1af1402`
(17 November 2026). Every task from the earlier reviews (S1–S6, R1–R3, F1–F6,
M1–M6 and A1–A32) is complete and has been removed from this doc; the previous
version, with each task's history, is in git at `1af1402`. Numbering carries on
from A32 so IDs stay unique.

This review is **static**. It was done by reading the code, running size and
dependency scans over `lua/direct`, and reading the tests, CI and docs. Neovim
was not available, so the suite was not run and no finding has been reproduced.
Each task's first step is to confirm the problem: write a failing test, take a
measurement, or record that it can't be reproduced and drop the task. The
function-size figures come from a rough scan of top-level functions, so treat
them as a guide to where to look, not as exact counts.

**Last checked:** `origin/master` at `1af1402` (17 November 2026).

**Backlog status checked:** `origin/master` at `6d4073c` (20 November 2026).
The review findings and suggested order below describe the original review
baseline; task statuses reflect the merged work through this commit. A42's
v0.4.0 beta is tagged and published. A48's stability guidance, beta notice and
feedback issue are in place, but the pre-release soak was not performed.

## What this review found

The earlier reviews dealt with data safety, and it shows: the filesystem and
history code is careful, journaled and heavily tested. What is left is mostly
about **how the code is organised**, plus two places where work still happens
on the editor's main thread.

- **Structure.** `lua/direct` is about 20,000 lines in 48 files, and the tests
  are about 22,000 lines. Fourteen modules are "splits" that take a context
  table from their parent and install functions back into it. They are
  separate files, but not separate modules (A37). The same operations are
  written twice, as a synchronous and an asynchronous version (A35).
- **Boundaries.** Several modules do jobs their names and header comments don't
  describe: trash code in `action.lua`, a Git restore feature inside the
  `init.lua` facade, LSP rename notifications and trash bookkeeping inside
  `history.lua` (A36).
- **Size.** By a rough scan, 15 functions are over 100 lines, one of them 341
  (A38).
- **Main thread.** Two paths still wait synchronously: Tab completion for
  `--ref`, and the history lock's retry (A33, A34).
- **Tests.** About 675 test cases in 44 spec files cover the safety-critical
  paths well, including a real second Neovim process for the history lock.
  The gaps are in how they are measured and what they model: one coverage
  floor for the whole tree, crashes that are simulated rather than caused, no
  generated edit sequences, and no fixtures for older on-disk formats
  (A43–A46).
- **Maturity.** The project is young: four tags in eight days, about 87% of
  commits from one author, and no issues or pull requests on GitHub. The code
  is more careful than its track record, so what is missing is a stability
  promise and evidence from other people's use (A47, A48).
- **Guard rails.** Lint covers `lua/direct` only, nothing checks that the
  README and help match the code, and the repository has no contributing,
  security or issue templates (A39–A41).

A second pass on the same commit looked at the plugin from a user's side:
how it behaves in everyday editing, how far it can be configured, and how it
fails on systems it wasn't developed on.

- **Everyday editing.** `:w` starts a background save. That is good for long
  moves, but `:wq`, `:x`, `:wa` and quitting while a save runs look like they
  don't do what a Vim user expects (A49). On a top-level row, the most common
  rename gesture, `cc`, deletes the file and creates an empty one (A50).
  There is no way to preview a save before applying it (A51).
- **When a save is refused.** The refusal messages are written in the code's
  terms ("child materialization baseline is inconsistent") and don't point at
  the line (A52). There is no in-listing key help (A53).
- **Customisation.** Display, keys and Git are well covered. Sorting, hiding
  rules, the icon provider and key actions beyond the built-in list are fixed
  (A54–A56).
- **Other systems.** Safe renames depend on a kernel feature that some
  filesystems and operating systems don't have, and the failure is an
  unexplained "Invalid argument" (A57). Large directories have no performance
  budget; the only measurement is 1.3 s to re-list 20,000 entries (A58).

## Decisions

These were settled with the maintainer on 17 November 2026 and are written
into each task below:

- **A33:** Tab completion may wait up to 200 ms for Git, with a short cache.
- **A37:** several small refactor PRs that change no behaviour are fine: one
  module per PR, with the existing tests unchanged as the safety net.
- **A42:** no upgrade notice or migration handling. The A26–A32 defaults have
  not been released, so no user has them yet; they ship in the next release
  like any other change.
- **A49:** `:write` on a listing waits for its save to finish, showing
  progress, so `:wq`, `:x` and `:wa` behave as in any other buffer.
- **A51:** no confirmation before a save that deletes. `:w` keeps applying the
  plan at once; deletes stay recoverable through the trash and undo. A51 is
  reduced to an on-demand preview, `:DirectPlan`.

## Conventions

- One task per branch and pull request, tests first, run with `make test` and
  `make lint`.
- Keep the existing guarantees: changes never overwrite an existing entry,
  history is journaled, unsaved listing edits are never discarded without an
  explicit `!`, and the repo's own test harness is used.
- Refactor tasks (A35–A38) change no behaviour. The existing tests must pass
  unchanged, and a test that has to change needs a sentence in the PR saying
  why it was coupled to structure.
- Update `README.md`, `doc/direct.txt` and `CHANGELOG.md` (under
  `[Unreleased]`) whenever behaviour, options or mappings change.
- Priorities: **P1** can lose the user's work or data, **P2** is a safety,
  robustness or release gap, **P3** is a maintainability or feature gap,
  **P4** is project maturity.

## Task list

| ID | Priority | Status | Task |
|----|----------|--------|------|
| A33 | P2 | Done | Stop `--ref` Tab completion from waiting on Git on the main thread |
| A34 | P2 | Done | Stop the history lock's retry from blocking and re-entering the editor |
| A35 | P3 | Done | Write each filesystem action once, not as sync and async copies |
| A36 | P3 | Done | Move trash, Git-restore and LSP code out of modules that don't own it |
| A37 | P3 | Done | Turn the context-injection "splits" into real modules |
| A38 | P3 | Open | Break up the longest functions and stop new ones appearing |
| A39 | P3 | Open | Split `config.lua` and check the README and help against the defaults |
| A40 | P4 | Open | Lint all Lua, not only `lua/direct`, and clear stale comments |
| A41 | P4 | Done | Add contributing, security and issue/PR templates |
| A42 | P4 | Done | Release the A26–A32 changes |
| A43 | P2 | Done | Test crashes by killing a real process at each journal step |
| A44 | P3 | Open | Enforce coverage per file, not only in total |
| A45 | P3 | Done | Test a save, a restart and an undo across real Neovim processes |
| A46 | P3 | Done | Check undo and sync against a model with generated edit sequences |
| A47 | P2 | Done | Keep golden fixtures for every on-disk format and test them |
| A48 | P4 | Partial | State what is stable before 1.0 and gather real-world use |
| A49 | P2 | Done | Make `:wq`, `:x`, `:wa` and quitting work with background saves |
| A50 | P2 | Done | Treat `cc` on a top-level row as a rename, as child rows already do |
| A51 | P3 | Open | Add `:DirectPlan` to preview a save without applying it |
| A52 | P3 | Open | Rewrite refusal messages in plain language and point at the line |
| A53 | P3 | Open | Add `g?` key help inside a listing |
| A54 | P3 | Open | Let users choose the sort order and what is hidden |
| A55 | P3 | Partial | Ship configurable icon providers; defer optional detail columns pending demand and performance evidence |
| A56 | P3 | Open | Allow custom key actions and expose the entry under the cursor |
| A57 | P2 | Done | Explain and probe filesystems without safe no-replace renames |
| A58 | P3 | Done | Measure large-directory listing and set a performance budget |

## Robustness and performance

### A33 — `--ref` Tab completion waits on Git on the main thread (P2)

**Problem.** `ref_completions` in `lua/direct/git_commands.lua` (around line
150) starts `git for-each-ref` and then calls `process:wait(timeout)` with
`git.timeout_ms`, which defaults to 1000 ms. A completion function runs on the
editor's main thread, so every Tab press on `--ref=` in `:DirectGitDiff`
blocks Neovim until Git answers or a second passes. In a large repository, or
on a slow disk or network mount, that is a visible freeze each time, and the
list is rebuilt from scratch on every press.

`directory_completions` in the same file also scans a directory with
`fs_scandir` on every press. That is cheap for ordinary directories, but it
has no bound either.

**Change.**

- Use a much shorter deadline for completion than for status: 200 ms,
  in a separate constant. On a timeout, return no candidates and do not
  show an error.
- Cache the ref list per repository root for a few seconds, so repeated Tab
  presses and narrowing the prefix don't start a new `git` each time. Throw the
  cache away when the root changes.
- Optionally warm the cache in the background the first time the command line
  is opened for `DirectGitDiff`, so the first Tab is instant.
- Cap the number of candidates returned from a directory scan.

**Tests.** With a stubbed `vim.system` that never finishes, completion returns
an empty list within the deadline. A second call within the cache window
doesn't start `git`. After the window, or after the root changes, it does.
Candidates for a prefix are still filtered and sorted as before.

### A34 — The history lock's retry blocks and re-enters the editor (P2)

**Problem.** A29 made a busy lock retry for up to two seconds.
`acquire_file_lock` in `lua/direct/history/lock.lua` (around line 64) does that
with `vim.wait(RETRY_TIMEOUT_MS, ..., RETRY_INTERVAL_MS)`.

- **The editor is stuck for up to two seconds** while another instance holds
  the lock. Saves, undo and yank callers reach this from key mappings.
- **`vim.wait` runs the event loop.** Timers, autocommands, scheduled
  callbacks and further keypresses can run in the middle of the wait. That
  includes other direct.vim code, such as a refresh scheduled by an earlier
  operation. `acquire` is called before the caller has necessarily claimed
  `pending`, so a second operation could start while the first is still
  waiting for the lock.
- The wait is used even by callers that are already asynchronous
  (`apply_async`, `yank_async`), which could retry from a timer instead.

**Change.**

- In the asynchronous paths, replace the blocking wait with a `vim.uv` timer
  that retries `acquire` every `RETRY_INTERVAL_MS`, and call back when it
  succeeds or the window ends. Give `lock.acquire_async(callback)` the same
  messages and the same two-second window as the blocking version.
- Keep the blocking `acquire` for the genuinely synchronous callers, but take
  the `pending` guard before it waits, so a re-entrant operation is refused
  with the usual message.
- Make sure nothing else in this module touches `depth`, `token` or
  `held_path` while a wait is in progress.

**Tests.** With the lock held by a second process, an asynchronous operation
returns to the event loop immediately, and a timer scheduled during the wait
still fires. A keypress-driven second operation during the wait is refused
because the first is pending. If the other process releases within the window,
the first operation succeeds. After the window it fails with the existing
message.

## Architecture and maintainability

### A35 — Every filesystem action is written twice (P3)

**Progress.** Completed in PR #161, which consolidated synchronous and
asynchronous filesystem action execution.

**Problem.** In `lua/direct/action/action.lua`, each action factory defines
both `_execute` and `_execute_async` by hand:

- `Remove` (around line 297) and `RemoveDirectory` (around line 402) are almost
  line-for-line identical. The only differences are the `warn_cross_device_trash`
  call and the name. The metadata-rollback block (clear the trash metadata,
  warn if that fails) is copied four times in those two functions.
- `Restore` (around line 492) and `RestoreDirectory` (around line 550) differ
  only in whether the reservation marker is a file or a directory.
- `Paste` (around line 660, 187 lines) and `Unpaste` (around line 928, 168
  lines) each carry a synchronous and an asynchronous implementation of the
  same state machine.

Both modes are used in production: saves run `action_mod.execute_async`
(`lua/direct/buffer/sync.lua`, around line 1057) and also `action_mod.execute`
(around line 1084), and `lua/direct/trash.lua` uses the synchronous form. A fix
to one copy can miss the other, and the A26–A32 work had to touch both.

**Change.**

- Extract the shared steps into helpers that both modes call: a
  `trash_target(self)` that resolves and checks the trash destination, and a
  `rollback_trash_metadata(self)` that holds the clear-and-warn block.
- Build `Remove`/`RemoveDirectory` and `Restore`/`RestoreDirectory` from one
  parameterised constructor each (kind, name, directory or file), so the pair
  can't drift apart.
- For `Paste` and `Unpaste`, write the sequence of steps once as a list of
  small functions that each take a callback, and run it either in a
  synchronous driver or an asynchronous one. Keep the existing hooks
  (`_before_copy`, `_after_copy`, `_before_prompt`, `_after_prompt`,
  `_on_copy_conflict`), but document them in one place as the contract between
  actions and history.

**Tests.** The existing action, paste, unpaste and history tests must pass
unchanged. Add a table-driven spec that runs each remove, restore, paste and
unpaste case in both modes and checks identical results, including the
failure path: a failed move leaves no stale trash metadata, and a failed
metadata cleanup warns once.

### A36 — Several modules do jobs they don't own (P3)

**Progress.** Completed across PRs #165, #167–#169: trash metadata, Git
worktree restore, history LSP/trash-reference helpers, and register storage
were moved to their owning modules.

**Problem.** The headers describe each module's job, and several don't match
the contents.

- **`lua/direct/action/action.lua`** (about 1,100 lines) opens with filesystem
  actions, but its first 130 lines are trash metadata (`write_trash_metadata`,
  `recover_trash_metadata`, `write_trash_reservation`, `clear_trash_metadata`).
  `lua/direct/trash.lua` requires `action`, and `lua/direct/init.lua` calls
  `action.first_free_trash` and `action.write_trash_metadata` directly, so the
  trash's file format lives in the module that depends on the trash.
- **`lua/direct/init.lua`** says it is "public API facade; dispatch and the
  direct-buffer guard", but it also contains `worktree_backups` (around line
  43, copying changed files into the trash) and `restore_git` (around line
  502, 96 lines with its own confirmation flow). That is a feature, not
  dispatch, and it makes the facade the second-largest user of `fs`, `action`
  and `paths`.
- **`lua/direct/history/history.lua`** (about 1,500 lines) contains
  `rename_files` (around line 28), which builds LSP `willRenameFiles` URIs, and
  about 500 lines of trash-reference bookkeeping (`line_might_reference_trash`,
  `history_mentions_path`, `unreferenced_dropped_trash`, `filter_trash_records`,
  `plan_trash_history`, `apply_trash_history_plan`, around lines 563–1080).
- **`lua/direct/register.lua`** (about 1,000 lines) holds the register's
  storage (manifests, snapshots, pruning), the explicit and deleted-entry
  yanks, and the paste orchestration in one file. `register.paste` (around line
  727) validates the `name` argument near the top and then again before it
  builds `dst_names`; the second check can't fail after the first passes.

**Change.** Move code without changing it, one PR per bullet:

- Trash metadata and the trash path helpers into `lua/direct/trash/` (for
  example `trash/metadata.lua`), with `action.lua` and `init.lua` requiring it.
  `trash.lua` then no longer needs `action` for these.
- `worktree_backups` and `restore_git` into `lua/direct/git_restore.lua`;
  `init.lua` keeps one-line wrappers that apply the guard and call it.
- LSP URI building into `lua/direct/history/lsp.lua` (or into
  `file_operations.lua`, which already owns `will_rename`), and the trash
  bookkeeping into `lua/direct/history/trash_refs.lua`.
- `lua/direct/register/store.lua` (storage and pruning), with `register.lua`
  keeping the yank and paste entry points. Remove the duplicate name check.

**Tests.** None new beyond keeping the suite green. Where a test stubs
`action.write_trash_metadata`, `history.rename_files` or similar through a
module field, move the stub to the new owner; list each one in the PR.

### A37 — The "splits" are separate files, not separate modules (P3)

**Progress.** The fourteen listed splits were converted in separate
module-by-module PRs #171–#185 (excluding unrelated A46 PR #174). PR #186
added cleanup coverage for the action-registry reattachment test.

**Problem.** Fourteen modules are written as `return function(context)` or
`return function(M)`: `buffer/{list,sync,open,navigation,collapse,tree,
row_state,undo_state,sync_plan}.lua`, `action/{moves,registry}.lua`,
`history/{paste,reverse}.lua` and `fs/path_ops.lua`. The parent builds a table
of its local helpers, passes it in, and the child installs methods back onto
the parent. `lua/direct/buffer/sync.lua` starts with about 35 lines of
`local x = context.x`, and `buffer/list.lua` pulls about 34; `buffer.lua`
passes well over a hundred names across the whole directory. The header of
`sync.lua` calls it "a code-only split".

This keeps the file sizes down but nothing else:

- A child can't be loaded, read or tested on its own; it needs the parent to
  construct its context first.
- The dependencies are invisible. A reader can't tell from the top of a file
  what it needs, and a rename of a helper in `buffer.lua` breaks a file that
  doesn't mention it.
- Methods appear on `Buffer` from several files, so finding where
  `Buffer:sync` is defined means searching.
- It encourages the stubbing style the tests use: tests replace fields on the
  parent (`M.fs`, `M.ui`, `M.paths`), and the code exposes those fields
  (over 500 occurrences) so that it can be stubbed.

**Change.** Convert one module per PR, starting with `buffer/sync.lua` and
`buffer/list.lua`:

- Make the module `return` a table of functions, and `require` the leaf
  modules it uses (`fs`, `paths`, `git`, `history`, `ui`) at the top.
- Move the shared state and small helpers the buffer modules all use (the
  `states` and `pending_sync` tables, `is_dir_line`, `indent_size`, and so on)
  into one `lua/direct/buffer/state.lua` that both the parent and the children
  require. Where a real require cycle remains, break it with a lazy `require`
  inside the function and a comment naming the cycle.
- Have `buffer.lua` attach the child's functions to `Buffer` in one visible
  place.
- Stop adding new `M.fs = require(...)` style fields. Where a test needs to
  replace a dependency, give the module a small `_set_dependencies` or accept
  the dependency as an argument at that one call site.

**Tests.** The suite passes unchanged after each conversion. Each converted
module can be `require`d on its own in a new smoke test, without constructing
a `Buffer`.

### A38 — The longest functions are hard to review, and nothing stops new ones (P3)

**Problem.** By a rough scan of top-level functions, there are 518, of which 43
are over 60 lines and 15 over 100. The longest:

| Lines | Function |
|-------|----------|
| 341 | `M.new` in `lua/direct/history/recovery.lua` (a closure holding the whole recovery state machine) |
| 255 | `M.paste` in `lua/direct/register.lua` |
| 194 | `M.parse` in `lua/direct/history/transaction.lua` |
| 187 / 168 | `M.Paste` / `M.Unpaste` in `lua/direct/action/action.lua` |
| 173 | `M.will_rename` in `lua/direct/file_operations.lua` |
| 159 | `M.compare_snapshot` in `lua/direct/git.lua` |
| 143 | `M.yank_async` in `lua/direct/register.lua` |

These are the code paths that run after a crash, on every paste, and on every
rename, so being able to read them in one screen matters. They also hold the
long chains of `if not ok then return ... end` that make a missed early return
easy to write.

**Change.**

- Break the nine worst functions up, one PR each, by naming the phases they
  already have. For example `register.paste`: `validate_target`,
  `load_pasteable_entries`, `build_paste_action`, `run_paste`. For
  `recovery.new`, move each of its inner `local function`s to a module-level
  function that takes `deps` as its first argument, so each can be read and
  tested alone.
- Add `scripts/check_function_length.py`, run from `make lint`, that fails if
  a function is longer than 120 lines unless it is on a short, committed
  allowlist. List today's offenders on it. Each refactor PR removes its entry,
  and the allowlist may only shrink.

**Tests.** None new for the refactors beyond a green suite. Give the script
its own test (like `tests/test_changelog_release_gate.py`): a function over
the limit fails it, one on the allowlist passes, and an allowlist entry that
no longer exists also fails, so stale entries get removed.

### A39 — `config.lua` does three jobs, and the docs can drift from it (P3)

**Problem.**

- **Structure.** `lua/direct/config.lua` (about 650 lines) holds the defaults,
  the validation of every option, and the whole key-mapping installation and
  removal logic for global and buffer-local mappings. It requires
  `direct.buffer.buffer` and `direct.folding` lazily from inside functions, and
  repeats `require('direct.ui')` inline in each error path, although `ui` has
  no dependencies and could be required once at the top.
- **Validation style.** Each option has its own hand-written check and its own
  `notify`. A bad `setup()` call reports its errors one at a time, in code
  order, and each new option needs a new branch.
- **Drift.** The README shows the defaults in a code block, `doc/direct.txt`
  documents them again, and `CHANGELOG.md` records changes to them. No test
  compares them with `config.options`. The only test that mentions the README
  is `tests/plugin/highlight_spec.lua`. A26 changed two defaults in all three
  places by hand.

**Change.**

- Split into `lua/direct/config/options.lua` (defaults and validation),
  `lua/direct/config/mappings.lua` (installation and removal) and a small
  `config.lua` that keeps today's public entry points (`setup`, `options`,
  `mapping_lhs`, `install_buffer_mappings`, and so on), so callers don't change.
- Describe the options with a small table (key, type or predicate, default,
  message) and validate from it. Collect every error from one `setup()` call
  before reporting, so a user fixes them all at once. Keep every existing
  message text, since tests and users may match on them.
- Add `tests/plugin/docs_sync_spec.lua`. It extracts the Lua block under
  "These are the defaults" in `README.md`, evaluates it, and checks that each
  key and value equals the same field of the real defaults, and that every
  option name appears in `doc/direct.txt` with a `*direct-<name>*` help tag, the
  form the help already uses (for example `*direct-history_limit*`).

**Tests.** The existing config tests pass unchanged. The new spec passes on
today's docs. Changing a default in `config`, or adding an option without
documenting it, fails it with a message naming the option. Several invalid
options in one `setup()` call produce one report that lists them all.

## Project maturity

### A40 — Lint covers `lua/direct` only, and stale comments remain (P4)

**Problem.**

- `make lint` runs `luacheck` and `stylua --check` on `lua/direct` only
  (`Makefile`, `lint` target). `plugin/direct.lua` (225 lines),
  `ftplugin/direct.lua`, `syntax/direct.vim` and all of `tests/` (about 22,000
  lines, as much as the source) are not linted or format-checked. The tests are
  where a vacuous assertion or an unused variable would hide.
- LuaLS is run at `--checklevel=Warning` on four files and at `Error` on the
  rest, so most of the tree is only checked for errors.
- A few comments still describe the code's history instead of its behaviour:
  `lua/direct/action/action.lua` (around lines 148 and 292) mentions "parity"
  and "the Python `__init__`", and `lua/direct/action/moves.lua` (around line
  11) says "measured on 0.12.5". An earlier review cleaned most of these up;
  a search for "parity", "measured on" and similar finds a handful more.

**Change.**

- Add `plugin` and `ftplugin` to the existing `luacheck` and `stylua` lines.
  Add `tests` with its own `.luacheckrc` section (globals for the harness,
  longer lines allowed), and run `stylua --check tests` once the tests have
  been formatted in a single mechanical PR.
- Raise LuaLS to `--checklevel=Warning` for the next two or three modules each
  PR (start with `fs.lua`, `paths.lua` and `register.lua`), fixing or
  annotating what it reports.
- Reword the remaining history-style comments to say what the code does and
  why, and drop references to the Python version.

**Tests.** None beyond `make lint` itself. Deliberately adding an unused local
to a test file makes it fail.

### A41 — The repository has no contributing, security or issue templates (P4)

**Problem.** `.github/` holds only the workflow. There is no `CONTRIBUTING.md`,
`SECURITY.md`, issue template or pull request template. The contributor
instructions live in the README's Development section, in the middle of a
document aimed at users.

This is a plugin that deletes, moves and overwrites the user's files and runs
shell commands from `:DirectRun` and `:DirectGit`. A data-loss report needs
different handling from a feature request, and A31 showed what happens when a
changelog entry is forgotten.

**Change.**

- Add `SECURITY.md`: how to report a bug that can lose data, or a command that
  runs unintended code, privately, and what response to expect.
- Add `CONTRIBUTING.md` with the content of the README's Development and
  Release checklist sections (leaving a short link behind), and the
  conventions from this doc: tests first, one task per PR, a changelog entry.
- Add `.github/ISSUE_TEMPLATE/bug_report.yml` asking for the Neovim version
  and operating system, the output of `:checkhealth direct`, the plugin
  version, and steps to reproduce on a throwaway directory; add a
  `feature_request.yml`.
- Add `.github/pull_request_template.md` with checkboxes for tests, `make
  lint`, `CHANGELOG.md` under `[Unreleased]`, and README and help updates.

**Tests.** None. A pull request shows the template, and the README's
Development section links to `CONTRIBUTING.md`.

### A42 — Release the A26–A32 changes (P4)

**Problem.** `[Unreleased]` in `CHANGELOG.md` holds six changes, including two
new defaults: undo history is capped at 1000 steps per stack, and trash older
than 90 days is removed by default (`trash_retention = { max_age_days = 90 }`).
Decision A30 deferred these until after `v0.3.0`, which shipped without them,
so no released version has these defaults. Nothing needs migrating; they just
need releasing.

**Change.**

- Tag the next release (`v0.4.0`, since defaults change) using the README's
  release checklist, and publish its GitHub release from the matching
  changelog section.
- Lead the `[0.4.0]` section and the release notes with the two new defaults
  and how to change them (`history_limit`, `trash_retention = false`), so a
  user choosing to install it sees them. Include the lock file location change
  that already appears in the README.

**Tests.** None beyond CI. Check that the `[0.4.0]` section and the release
notes both name `history_limit` and `trash_retention`, and that every merged
pull request since `v0.3.0` has a changelog entry (the A31 checklist line).

## Test coverage and maturity

What is already good, so these tasks build on it and don't redo it: the suite
has about 675 cases in 44 spec files, a zero-dependency harness with a
per-file isolation check, coverage on three operating systems with a floor,
Neovim 0.11.7, stable and nightly in CI, a live-startup smoke test, and a demo
tour that CI plays. The history lock is tested with a second Neovim process
(`tests/history/history_spec.lua`, around lines 539–600), and crash recovery
has tests for a prepared action and a mid-commit crash (around lines 625 and
899). The tasks below are what is left.

I could not run the suite or measure coverage in this review (see the note at
the top), so the coverage figures A44 asks for have to come from a real run.

### A43 — Crash recovery is tested with simulated crashes, not real ones (P2)

**Problem.** The history journal (`lua/direct/history/transaction.lua`,
`recovery.lua`) exists so that an interrupted save, paste or undo can be
finished or reported after a crash. Its tests build the post-crash state by
hand: they write a journal and then call the recovery code (for example
`tests/history/history_spec.lua`, around lines 625–900). That checks that
recovery handles each state its author thought of. It can't show that the
real code, killed at a real moment, only ever leaves one of those states.
Crash recovery is where a missed case means lost or doubled work, and
`recovery.new` is also the largest function in the tree (A38).

**Change.**

- Add a test hook that makes the process stop (`os.exit` or a signal to
  itself) at a named point: before and after each journal write, between the
  filesystem step and the stack commit, and between the two stack files. Keep
  it inert unless an environment variable names the point, and make sure it
  can't be set by `setup()`.
- A new spec starts a second Neovim process (the pattern at
  `history_spec.lua`, around line 578) that performs a save, a grouped
  swap, a paste, an undo and a redo, once for each stop point. Then a fresh
  process runs recovery and the spec checks the invariants: no file's contents
  are lost, nothing existing is overwritten, undo and redo stacks are
  consistent with the filesystem or the history is reported as needing manual
  recovery, and running recovery twice changes nothing.
- Run the whole matrix on Linux in CI. Run a reduced set on macOS and Windows.

**Tests.** The new spec is the test. Check it by removing one journal write in
a scratch branch, and confirming that some stop point then fails.

### A44 — Coverage is enforced as one total (P3)

**Problem.** `make ci` fails below `COVERAGE_MIN=86` (`Makefile`), measured as
one percentage over all of `lua/direct` (`.luacov` includes the whole
directory, `tests/coverage_report.lua` writes the summary). A new
module with no tests barely moves a total of 20,000 lines, and a well-tested
file can hide a poorly tested one. Also:

- Only line coverage is measured, so an untested branch of a covered line
  isn't visible. That matters for the many early returns on error paths.
- Platform code (`platform/unix.lua`, `platform/windows.lua`) is covered only
  on its own operating system, and each run is measured against the same
  floor, so the floor is a compromise between them.
- `plugin/` and `ftplugin/` aren't included.
- Which files are covered least is only visible by opening the HTML report.

**Change.**

- Print a per-file table in the CI summary, sorted by lowest coverage.
- Add a per-file floor with a committed allowlist, like the function-length
  check in A38: every file must reach a floor (for example 70%) unless it is
  listed with its current figure, and a listed figure may only go up. A new
  file starts under the floor and has to meet it.
- Take the first measurement from a real run, then set the total floor to
  just under it. Record the figures in the PR.
- Add `plugin/` and `ftplugin/` to `.luacov`.
- Look at whether the area where branches matter most (history, recovery,
  fs) can get a branch measure, for example by instrumenting with a custom
  runner. Don't block this task on it.

**Tests.** A test for the check script, as in A38: a file under the floor
fails it, a listed file that rises above its entry fails it until the entry is
raised, and a listed file that no longer exists fails too.

### A45 — Nothing tests a save, a restart and an undo as real processes (P3)

**Problem.** The README's headline claim is "Undo on disk … the history
survives restarts." The live-startup script (`tests/live_startup.sh`) checks
the startup path and mappings, and the demo tour plays one session. Most
specs run inside one Neovim process and reload the plugin between cases. Real
use has more than one process. Neovim is closed after a save, a second
instance starts, and `u` reverses a change the first one made, with the
register and trash left behind.

**Change.** Add `tests/e2e/` with a small runner that starts real
`nvim --headless` processes against a throwaway data and config directory and
drives them with `--cmd`/`-c` scripts or `--listen` plus `nvim_input`:

- Process 1: open a listing, rename a file, delete another, yank and paste a
  folder, save, quit. Process 2: open the same directory, undo three times,
  quit. Process 3: redo. Check the filesystem after each process.
- A listing opened in a directory behind a symlink and one with a name
  containing a space, a Unicode character and a leading dot.
- Two live processes on the same data directory: one saves while the other
  has the same directory open, then the second tries to save and is refused
  with the stale-listing message.

**Tests.** The e2e specs are the tests. Keep them to a handful so they stay
quick, and run them in the existing Linux, macOS and Windows jobs.

### A46 — Undo and sync are checked by examples, not by generated sequences (P3)

**Progress.** PR #162 fixed undo for a grouped rename permutation with a
companion move; PR #166 fixed a larger permutation/move/delete case. PR #170
added generated model tests, and PR #174 extended the pure cases to exercise
the production planner and move grouping.

**Problem.** The tests describe many specific cases, and the earlier reviews
found real bugs by thinking of more. The central promise is general: whatever
edit script the user types, a save applies it, and undo restores the original
tree exactly. The sync planner (`buffer/sync_plan.lua`), move grouping
(`action/moves.lua`) and the history format round trip
(`history/format.lua`) are pure enough to check against a model. Examples
can't cover the number of ways renames, swaps, rotations, nested moves,
deletes and pastes combine.

**Change.**

- Add a small seeded generator that makes a random tree, then a random edit
  script over it (renames, permutations of names, moves between folders,
  deletes, creates, pastes).
- Check, for each generated case: the plan applies without data loss or
  overwrite; the filesystem afterwards equals what a simple in-memory model
  predicts; undo restores the original tree byte for byte, including contents;
  redo restores the result; and serialising then parsing the history record
  gives the same record.
- Print the seed on failure, and pin a few seeds that once failed as ordinary
  regression cases. Run a few hundred cases per CI run, and many more in a
  scheduled job.

**Tests.** The property specs are the tests. Check them by temporarily
breaking `move_groups` and confirming that some seed fails.

### A47 — There are no golden fixtures for the on-disk formats (P2)

**Problem.** direct.vim persists several formats between versions: the history
stacks (a header plus canonical JSONL, currently a versioned format in
`history/format.lua`), the journal (`history/transaction.lua`), the trash
metadata files, the register manifests, and the lock files. The project is
before 1.0 and has already changed some, and users keep this data for months.
The tests build each format with the current code and read it back, which
proves the code agrees with itself. It doesn't prove that a file written by
`v0.3.0` is still read, or refused safely, by a later version. A change to a
field could silently strand or misread a user's trash or history.

**Change.**

- Generate and commit one golden file for each format at `v0.3.0`, under
  `tests/fixtures/formats/v0.3.0/` (stacks with every action kind, a journal
  in each recovery state, trash metadata for a file and a directory, a
  register manifest).
- Add a spec that loads each fixture with the current code and checks it is
  either read to the same result or refused with the documented "preserved and
  blocks operations" behaviour. It must never be reset, reinterpreted or
  partly applied.
- Add a rule to the contributing docs (A41): a change to any persisted format
  bumps its version marker and adds a new fixture directory; old fixtures are
  never edited.

**Tests.** The fixtures spec is the test. Check it by altering a field name in
a scratch branch and confirming that the spec fails.

### A48 — Nothing says what is stable, and there is little outside use (P4)

**Progress.** The stability sections, beta notice and feedback issue were added
for v0.4.0, which is published as a beta. The requested pre-release soak was
not performed; record the soak and its outcome before marking this task done.

**Problem.** There are four tags (`v0.1.0` on 9 November to `v0.3.0` on 16
November 2026), about 445 commits with 389 by one author and 56 by an AI
assistant, no open or closed issues, and no pull requests from anyone else.
The README compares direct.vim with established tools and claims safety
properties. Both are credible from the code, but nobody else has yet put the
plugin through everyday use on real trees, odd filesystems or other platforms,
and neither the README nor the changelog says what may change before 1.0.

**Change.**

- Add a "Stability" section to the README and help: which parts are intended
  to stay (the commands, the `setup()` options, the `User` events, the default
  mappings, and the persisted formats once A47 is in), what is allowed to
  change in a minor release, and how deprecations are announced.
- Say what has been tried. List the platforms and filesystems the suite and
  CI cover (Linux, macOS and Windows on local disks) and the ones it doesn't
  (network and FUSE filesystems, which `:help direct.vim-data` already warns
  about, case-insensitive volumes, very large directories), so users can
  judge the risk.
- Mark the next release as a beta in its notes and ask for reports, using the
  bug template from A41, with a pinned issue for "what worked and what
  didn't".
- Run a pre-release soak: the maintainer uses the release candidate as their
  only file manager for a fixed period, and the result is noted in the
  release.

**Tests.** None. Check that the README section exists and links the pinned
issue.

## Usability

### A49 — `:wq`, `:x`, `:wa` and quitting don't fit background saves (P2)

**Problem.** The listing's `BufWriteCmd` handler (`lua/direct/buffer/buffer.lua`,
around line 443) refuses if any direct operation is pending, and otherwise
runs `:DirectSync`. That starts the save in the background and returns. The
README says the listing "stays modified until the filesystem changes and
history are committed". From reading the code, that means:

- **`:wq` and `:x`.** The write returns while the buffer is still modified, so
  the quit half most likely fails with `E37: No write since last change`.
  The user then reaches for `:q!`, which can stop the save midway.
- **`:wa` and `:wqa`** with more than one modified listing. The first listing
  starts its save, and every other one is refused with "another direct
  operation is pending".
- **Quitting during a save.** There is no `ExitPre` or `VimLeavePre` handler,
  so `:qa!` during a long cross-filesystem move stops it without a word. The
  journal finishes or reports it on the next start, by design, but the user is
  not told at the time.
- **Wiping the buffer.** The `BufWipeout` handler (around line 427) cancels a
  pending save, so `:bw!` during a save also cancels it quietly.

None of `:wq`, `:x` or `:wa` appear in the tests or the docs.

**Change.** Confirm each case first with real processes (A45's runner), then:

- Make `:write` on a listing wait for its save to finish, showing the
  existing progress notification, and return only once the filesystem and
  history are committed and the listing is clean. This applies to long
  cross-filesystem moves too. `:wq` and `:x` then work, because the buffer is
  no longer modified when the quit runs. `<C-c>` stops waiting and leaves
  the save running in the background, with a message saying so. The work
  itself stays asynchronous, so progress keeps updating while `:write` waits.
- Queue saves instead of refusing them when the pending operation is another
  listing's save, so `:wa` saves every listing in turn.
- Add an `ExitPre` handler. If a save is pending, say what it is doing and
  wait for it, with `<C-c>` to stop waiting and quit anyway.
- When `:bw!` cancels a save, say so, and say what the journal will do with it.
- Document all of this in the help under `direct.vim-write`.

**Tests.** In a real process: `:w` returns with the listing clean and the
change on disk. `:wq` after a rename applies the rename and exits with status
0, including for a slow (stubbed) cross-filesystem move. `<C-c>` during the
wait returns, and the save still completes. `:wa` with two modified listings saves both. `:qa` during
a slow (stubbed) save waits and then exits, and the filesystem and history
are complete. `:bw!` during a save reports the cancellation.

### A50 — `cc` on a top-level row deletes the file instead of renaming it (P2)

**Problem.** Rows know which entry they are from an extmark. A whole-line
change such as `cc` or `S` invalidates that mark. For rows inside an expanded
directory, `lua/direct/buffer/tree.lua` (around lines 399–411) re-attaches a
lost identity when old and new rows pair one-for-one in the same slot, so
`cc` there is a rename. That is tested in `tests/sync/sync_tree_edit_spec.lua`
(around line 291).

Top-level rows don't get that treatment. `tests/sync/sync_plan_spec.lua`
(around line 76) asserts that replacing `old.txt` with `new.txt` deletes
`old.txt` to the trash and creates a new **empty** `new.txt`. The README
documents this ("the old entry is yanked and the new one is empty"). It can be
undone, but `cc newname<Esc>:w` is one of the most common ways to rename in
Vim. The result looks like the file's contents were lost, and it happens only
at the top level, so a user can't predict it.

It isn't confirmed which other gestures invalidate the mark the same way
(`ciw` across the whole name, `:s/.*/new/`, `:normal`, pasting a line over
another).

**Change.**

- List the gestures that lose the mark on top-level rows, with a test for each.
- Apply the child-row pairing rule to top-level rows. Inside a run of rows
  bounded by rows that kept their marks, if the removed and added rows pair
  one-for-one with the same type (file or directory), treat each pair as a
  rename. If the counts differ, keep today's refusal or delete-plus-create.
- Update the README's "Rules for edits", which today describes the empty-file
  outcome.

**Tests.** `cc`, `S` and the other listed gestures on a top-level file and
directory rename them with their contents. Two rows replaced by three still
behave as today. The existing child-row tests still pass.

### A51 — There is no way to preview a save (P3)

**Problem.** `:w` applies the plan at once. A save can delete a large tree,
move a directory across filesystems, or mix dozens of renames, creates and
deletes in one step. All of it can be undone, and by decision A51 a save
won't ask before applying it. But there is also no way to look at the plan
first, when a user wants to check a large edit.

The plan already exists as data before anything runs (`build_actions` in
`lua/direct/buffer/sync_plan.lua`, then `action.summarize`), so showing it is
cheap.

**Change.**

- Add `:DirectPlan`, which builds the plan for the current listing and shows
  it in a floating window, one line per action (`rename a → b`,
  `delete build/ (12,340 entries)`, `move x/ to another filesystem`). It
  changes nothing. If the save would be refused, it shows the refusal instead
  (with A52's message).
- Map it to nothing by default, and add a `plan` action to `mappings` so a
  user can bind it.
- Don't add a confirmation option or a prompt to `:w`.

**Tests.** `:DirectPlan` on a listing with a rename, a delete and a create
lists all three and leaves the filesystem, history and listing unchanged. On
a listing whose save would be refused, it shows the refusal. `:w` still
applies without asking.

### A52 — Refusal messages use the code's terms and don't point at the line (P3)

**Problem.** When a save is refused, the filesystem is left alone, which is
right. But the message is often written for the developer. Among about forty
distinct refusals in `lua/direct/buffer/sync_plan.lua`, `tree.lua` and
`sync.lua`:

- "child materialization baseline is inconsistent"
- "child identity marks were lost outside an undo to their materialization
  baseline"
- "child rows cannot be uniquely associated with their root identity"
- "root row identity is unavailable after text undo or redo; Direct cannot
  safely identify this edit; restore the marked listing state or use
  :DirectList! to discard it and redo the change"

Most don't say which line caused the refusal, and the cursor is only moved on
a successful save (`sync.lua`, around line 979). A user with a large edited
listing can't tell what to fix, and the README's "row identity" and "marked
listing state" are not ideas a user has.

Some refusals are really limitations, such as "edit a moved directory and its
new children in separate syncs". Those deserve to be listed so that users
know about them before they hit them.

**Change.**

- Give every refusal a short code (for example `E-DIRECT-ROW-AMBIGUOUS`) and a
  plain message that says what happened, on which line, and what to do. For
  example: "Line 12 was replaced as a whole, and direct.vim can't tell whether
  `old.txt` was renamed or replaced. Undo that change and rename with `ciw`,
  or use `:DirectList!` to discard the edits."
- Move the cursor to the first offending line and mark it with a diagnostic
  (`vim.diagnostic.set` in a direct namespace) so it shows in the sign column.
  Clear it on the next change.
- Add `:help direct-refusals`, listing every code with its cause and its fix,
  and the limitations among them.

**Tests.** A spec that triggers each refusal code checks the message names the
line and the cursor is on it. A test fails if a refusal is added without a
code or without a help entry.

### A53 — There is no key help inside a listing (P3)

**Problem.** A listing has about thirty buffer-local mappings, and some of
them shadow common keys (the README warns about `gd`, `<leader>gr` and
`<leader>gu`). Users can override them through `mappings`. But the only way to
see what is active in a listing is to read the README or `:nmap <buffer>`.
oil.nvim and most tree plugins have `g?`.

**Change.** Add a `show_help` action, mapped to `g?` by default, that opens a
floating window listing the active mappings from the same catalogue
`config.lua` uses to install them (so it reflects overrides and disabled
keys), with each action's description. Add it to the README table and the
help.

**Tests.** `g?` opens the window. An overridden mapping shows its new key. A
disabled mapping is absent. Setting `show_help = false` in `mappings` removes
`g?`.

## Customisation

### A54 — The sort order and the hiding rules are fixed (P3)

**Problem.**

- **Sort.** Listings show directories first, then files, each group sorted
  byte-wise (`dirs_then_name` in `lua/direct/buffer/buffer.lua`, and the sorts
  in `buffer/listing.lua`). So `B.txt` comes before `a.txt`, and `file10`
  before `file2`. Neither can be changed.
- **Hiding.** Entries are hidden for two reasons only, dotfiles
  (`show_hidden`) and Git-ignore (`respect_gitignore`). There is no way to
  hide `__pycache__/` or `*.o` outside Git, or to always show `.env` while
  hiding other dotfiles.

**Change.**

- Add `sort`, accepting `'name'` (today's byte order, the default),
  `'natural'` (case-insensitive, with numbers compared as numbers) or a
  function `(a, b) -> boolean` over entry records (`name`, `type`). Add
  `sort_directories_first` (default `true`).
- Add `is_hidden`, a function `(name, path, type) -> boolean|nil`. Returning
  `nil` falls back to today's rules, so users can add exceptions both ways.
  The `gh` toggle shows everything this hides, as it does for dotfiles.
- Confirm first that sync pairs rows by identity and never by position
  (the README says it does), so a different display order can't change what a
  save does. Add a test that saves a rename under each sort order.

**Tests.** `'natural'` lists `file2` before `file10` and `a.txt` before
`B.txt`. A custom sort function is used and errors in it are reported, not
raised. `is_hidden` hides and un-hides as described, and `gh` shows hidden
rows. Renames under each order give the same result on disk.

### A55 — Only one icon provider, and no detail columns (P3)

**Progress.** Configurable file icon providers were shipped in PR #207 (merge
`75c8506`). The separate detail-columns follow-up is deferred below.

**Problem.** Filetype icons come only from nvim-web-devicons
(`lua/direct/buffer/rows.lua`, around line 98). mini.icons, which many
configurations now use instead, isn't supported, and neither is a user
function. A row also can't show anything besides its name, icon and Git
status, such as size, modification time or permissions, which oil.nvim offers
as columns.

**Change.**

- Add `icons.provider`: `'auto'` (default: mini.icons if loaded, else
  nvim-web-devicons, else the generic glyphs), `'mini'`, `'devicons'`,
  `false`, or a function `(name, type) -> glyph, highlight`.
- Optional follow-up: a `columns` option for size and modification time shown as
  virtual text to the right, like the Git symbols. Plumb through the list-time
  stat used to build row identity where possible, and keep columns outside the
  editable listing text.

**Columns decision (2026-11-21): Deferred.** No repository issue requests size,
modification-time, or other metadata columns, and the open beta-feedback issue
has no comments asking for them. The `fs_scandir` path supplies name/type only
(`lua/direct/buffer/listing.lua`, around line 220); the later row-identity step
stats each visible path but retains only path/inode, not size/mtime. A columns
implementation may be able to reuse the existing identity stat work; no extra
stat per entry is assumed here. What is unmeasured is the incremental row-state,
formatting, and virtual-text rendering cost. The A58 benchmark profile already
records about 10,003 `fs_stat` calls and 10,001 row extmark writes for 10,000
entries, with listing/re-list medians of 184.89/244.64 ms locally and
191.33/295.36 ms on CI (columns disabled). The CI re-list baseline is about
295 ms, close to the 300 ms first-list advisory budget; there is no demonstrated
headroom for additional display work in this synchronous path. With no
demonstrated user demand and no measurement of incremental rendering cost, the
optional parity feature is not justified yet. Reopen this follow-up when
concrete user requests and a benchmark support it. If implemented, keep columns
as read-only virtual text and test that edits and saves cannot consume or alter
them.

**Tests (shipped icon-provider part).** With a stubbed mini.icons, `'auto'`
uses it. A provider function's glyph and highlight are used. An error in the
function falls back to the generic glyph and is reported once. If columns are
reopened, test that their virtual text is not part of listing text and cannot
affect an edit or save.

### A56 — Custom keys can only call built-in actions (P3)

**Problem.** `mappings` maps one of the built-in action names to a key
(`config.lua`, `resolve_mappings`, around line 392), and `<Plug>` mappings
exist for each action. A user who wants "open this entry in a terminal" or
"copy its path" has to write a `FileType direct` autocommand and work out the
path from the line, because `require('direct')` has no public function for
the entry under the cursor. `:DirectRun` covers shell commands, but not Lua.

**Change.**

- Let `mappings` take a function as well as a key name:
  `mappings = { ['<leader>y'] = function(entry) ... end }`. The function
  receives `{ path, name, type, root, deleted }` for the row under the cursor.
- Add `require('direct').current_entry()` returning the same table (or `nil`
  outside a listing), and `require('direct').selected_entries()` for a visual
  range.
- Add two short recipes to the README: copy the path, and open a terminal in
  the directory.

**Tests.** A function mapping is installed buffer-local and receives the
right entry for a file, a directory, a collapsed chain and a deleted row.
`current_entry()` returns `nil` outside a listing. Errors in a user function
are reported, not raised.

## Reliability

### A57 — Filesystems without no-replace renames fail with "Invalid argument" (P2)

**Problem.** Every rename goes through `rename_noreplace` in
`lua/direct/platform/unix.lua` (around line 48). It calls `renameat2` with
`RENAME_NOREPLACE` on Linux and `renamex_np` with `RENAME_EXCL` on macOS,
through LuaJIT FFI, and fails closed. Failing closed is right, since a plain
rename could overwrite. But only `EEXIST` and `EXDEV` are given meaning. Every
other error is passed on as the system's text. That includes:

- `EINVAL` or `ENOTSUP` from filesystems that don't support the flag: NFS,
  SMB/CIFS, many FUSE filesystems (sshfs among them), exFAT on macOS, and
  older ZFS on Linux;
- `ENOSYS` or `EPERM` where a container's seccomp profile blocks
  `renameat2`;
- on FreeBSD and other BSDs, which are neither `Linux` nor `Darwin`, every
  rename fails with "atomic no-replace rename is unavailable on FreeBSD".

So on those systems, every save fails with a message such as "Invalid
argument" and no explanation. The README says network filesystems are "not
guaranteed to work", but nothing tells the user that this is what happened.

**Change.**

- Map `EINVAL`, `ENOTSUP`/`EOPNOTSUPP`, `ENOSYS` and `EPERM` from these calls to
  one message: this filesystem (name the mount point if it can be found)
  doesn't support safe no-replace renames, so direct.vim won't rename here;
  see `:help direct.vim-data`.
- Remember the result per device (`st_dev`) for the session, so the message
  is given once and later saves on that device are refused up front, before
  anything is changed.
- In `:checkhealth direct`, probe the data directory (inside it, never in a
  user directory) and report whether safe renames work there.
- List the supported operating systems and the known unsupported filesystems
  in the README and help.
- Consider, as a separate opt-in later, a fallback for regular files only:
  `link()` then `unlink()`, where `link` fails with `EEXIST` atomically. Never
  for directories.

**Tests.** With the FFI call stubbed to return each errno, a save fails before
changing anything, with the new message, once per device. A BSD `sysname`
gives the same message. `:checkhealth` reports the probe result.

### A58 — Large directories have no performance budget (P3)

**Progress.** `bench/listing.lua` now measures listing, re-listing, full
expansion and a one-rename save on flat and deep fixtures, with Git-ignore on
and off. Initial measurements, a focused optimization and the advisory CI
budgets are recorded in `docs/performance/listing-benchmark.md`.

**Problem.** Listing is synchronous: `lua/direct/buffer/listing.lua` scans the
directory with `fs_scandir` (around line 158), stats entries, sets an extmark
and highlights for each row, and may wait up to `git.ignore_timeout_ms` for
Git. The only measurement is historical: re-listing a 20,000-entry flat
directory took about 1.3 s with Git status and icons off
(`docs/performance/gitignore-benchmark.md`, 4 November 2026, before the
current ignore snapshot). Expanding `node_modules/` or a build tree with
`zR` can multiply that. There is no current figure, no budget and no
benchmark in CI, so a slowdown can land unnoticed.

**Change.**

- Add `bench/listing.lua`, run with `nvim --headless -l`, that times a first
  list, a re-list, a full `zR` expansion and a save of one rename, for flat
  directories of 1,000, 10,000 and 50,000 entries and a deep tree, with Git
  on and off.
- Profile the 10,000-entry case and fix the largest costs found (for example
  stat calls that the scan's type already answers, or one extmark call per
  row where a batched form would do).
- Set a budget (for example, listing 10,000 entries in under 300 ms on the CI
  Linux runner) and run the benchmark in a non-blocking CI job that warns when
  it is exceeded.
- If 50,000 entries stay slow, consider listing the first screens at once and
  the rest in the background, and say so in the help.

**Tests.** The benchmark is the test. Record its figures in the PR and in
`docs/performance/`.

## Suggested order

1. Complete the A48 pre-release soak and record its result. The stability
   guidance and v0.4.0 beta feedback path are already in place; the soak can
   proceed independently of the remaining engineering work.
2. Continue A38 as separate one-function PRs, and do A39 as its own config
   split. These can proceed independently; A39 should land before A53 and A56,
   which depend on the established configuration and mapping shape.
3. Do A40 before A44 because the lint, coverage and CI changes overlap.
4. Do A52 and A53 before A51, which depends on the refusal and help work.
5. Do A54 after A51. A58's performance baseline is complete; keep A55-icons
   and the optional A55-columns work in separate PRs, then do A56 after A55 is
   resolved.
