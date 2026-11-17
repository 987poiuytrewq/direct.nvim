# Spec: direct.vim improvements, fourth review

**Status:** A33–A42 are open.

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
- **Guard rails.** Lint covers `lua/direct` only, nothing checks that the
  README and help match the code, and the repository has no contributing,
  security or issue templates (A39–A41).

## Decisions

These were settled with the maintainer on 17 November 2026 and are written
into each task below:

- **A33:** Tab completion may wait up to 200 ms for Git, with a short cache.
- **A37:** several small refactor PRs that change no behaviour are fine: one
  module per PR, with the existing tests unchanged as the safety net.
- **A42:** no upgrade notice or migration handling. The A26–A32 defaults have
  not been released, so no user has them yet; they ship in the next release
  like any other change.

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
| A33 | P2 | Open | Stop `--ref` Tab completion from waiting on Git on the main thread |
| A34 | P2 | Open | Stop the history lock's retry from blocking and re-entering the editor |
| A35 | P3 | Open | Write each filesystem action once, not as sync and async copies |
| A36 | P3 | Open | Move trash, Git-restore and LSP code out of modules that don't own it |
| A37 | P3 | Open | Turn the context-injection "splits" into real modules |
| A38 | P3 | Open | Break up the longest functions and stop new ones appearing |
| A39 | P3 | Open | Split `config.lua` and check the README and help against the defaults |
| A40 | P4 | Open | Lint all Lua, not only `lua/direct`, and clear stale comments |
| A41 | P4 | Open | Add contributing, security and issue/PR templates |
| A42 | P4 | Open | Release the A26–A32 changes |

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

## Suggested order

1. A33 and A34 first: both are small, and both stop the editor from waiting.
2. A42 whenever the maintainer wants to cut the release; it has no code.
3. A35 and A36 next, since they remove duplication and mixed ownership that
   the later refactors would otherwise have to carry along.
4. A37 and A38 after that, one module or function per PR, starting with
   `buffer/sync.lua` and `history/recovery.lua`.
5. A39 and A40 together with, or just after, the refactors, since they add the
   checks that keep the result from drifting back.
6. A41 whenever convenient; it touches no code.
