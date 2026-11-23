# Listing performance budget

## Reproduce

Run the benchmark from a checkout with Neovim 0.11.7 or newer and Git installed:

```sh
make listing-benchmark
```

`bench/listing.lua` creates and removes disposable fixtures under Neovim's
temporary directory. It reports three raw samples and their medians by default.
Set `DIRECT_LISTING_SAMPLES=1` for a quick run, or
`DIRECT_LISTING_PROFILE=1` when invoking the script directly to count and time
filesystem, extmark, and synchronous process calls around list, re-list, and
`zR`.

Each flat fixture has 1,000, 10,000, or 50,000 files at its root, one small
expandable directory, and a rename source. The deep fixture has four directory
levels, branching factor three (120 directories and 324 leaf files), plus a
rename source. Git-ignore-on fixtures are local repositories with an
`ignored-*` rule, which ignores one in ten flat files and one leaf in each deep
directory. Git status, file/folder icons, and single-entry collapsing are
disabled in both modes; only `respect_gitignore` changes. Fixture creation and
`git init` are outside the timed sections.

The four timings are first listing, re-listing the same buffer, full `zR`
expansion, and a synchronous save of one top-level rename. The save is measured
from a fresh, unexpanded listing; listing setup is not included in its save
time. The flat fixture's `zR` expands its one small child directory, while the
deep fixture exercises the complete tree. These are synthetic local-disk
measurements, not guarantees for network or FUSE filesystems.

## Initial measurements and profile

Environment: macOS 26.6.2, Apple M4, internal APFS SSD, Neovim 0.12.6 /
LuaJIT, Apple Git 2.54.0. Results below are medians of three samples in one
process, warm cache. Milliseconds:

| Fixture | Git-ignore | First list | Re-list | `zR` | One-rename save |
|---|---:|---:|---:|---:|---:|
| 1,000 flat entries | off | 21.74 | 60.18 | 14.23 | 137.56 |
| 1,000 flat entries | on | 67.73 | 58.80 | 123.31 | 265.24 |
| 10,000 flat entries | off | 184.89 | 244.64 | 25.31 | 872.89 |
| 10,000 flat entries | on | 412.71 | 400.36 | 197.55 | 1,152.02 |
| 50,000 flat entries | off | 1,153.26 | 1,220.46 | 137.64 | 4,433.93 |
| 50,000 flat entries | on | 1,836.07 | 1,978.81 | 542.13 | 5,600.83 |
| Deep tree | off | 0.64 | 0.46 | 43.22 | 47.00 |
| Deep tree | on | 34.48 | 32.89 | 3,929.45 | 134.00 |

The flat 10,000-entry profile found 10,003 `fs_stat` calls on first list,
10,001 row extmark writes, and two whole-buffer extmark reads. On re-list, the
original path re-statted prior root rows as well as the current rows. Reusing a
prior row identity where a same-spelling current row exists removes those
redundant old-path stats while retaining the existing same-path replacement
behavior; a focused regression assertion now caps refreshes at `2*N+10` stats.
The profile counted 10,003 stats for a 10,000-entry re-list after the change.
An earlier single-sample re-list was 256 ms; the post-change three-sample
median was 245 ms. That wall-time difference is within local run variation, so
the result is reported as a syscall reduction, not a material speedup claim.

Profiling also found the largest expansion cost with Git-ignore enabled: `zR`
on the deep fixture waited for 729 Git processes for 3.61 seconds. Each
directory captures its own list-time Git snapshot so nested repositories and
ignore-rule changes remain guarded. The benchmark makes this cost visible; the
snapshot safety behavior was not weakened to avoid it.

## Budget and CI

The advisory budget is for the median first-list time of the 10,000-entry flat
fixture:

| Mode | Budget | Local M4 baseline |
|---|---:|---:|
| Git-ignore off | 300 ms | 184.89 ms |
| Git-ignore on | 750 ms | 412.71 ms |

The first hosted calibration ran in GitHub Actions run
[44539164138](https://github.com/987poiuytrewq/direct.nvim/actions/runs/44539164138):
Ubuntu 26.04.1 on an AWS `ubuntu-latest` runner (Linux 7.0.0-1016-aws,
x86_64, Intel Xeon 6975P-C), Neovim 0.11.7 / LuaJIT, Git 2.56.1. The 10,000
entry medians were:

| Mode | First list | Re-list | `zR` | One-rename save |
|---|---:|---:|---:|---:|
| Git-ignore off | 191.33 ms | 295.36 ms | 50.42 ms | 855.39 ms |
| Git-ignore on | 527.16 ms | 423.04 ms | 251.27 ms | 1,114.13 ms |

The deep-tree `zR` median on that runner was 65.79 ms with Git-ignore off and
2,990.47 ms with it on. Both 10,000-entry first-list medians fit the advisory
budgets with roughly 36% and 30% headroom respectively. The hosted figures
support retaining 300 ms / 750 ms as the warning thresholds; they are not
hard-fail gates.

The `listing-benchmark` GitHub Actions job runs the same three samples on
`ubuntu-latest`; it is non-blocking and emits a warning on an over-budget result
or if the benchmark cannot complete.

The 50,000-entry results remain above one second, and expanding a deep tree with
Git-ignore enabled is much slower than with the filter disabled. The benchmark
does not justify changing the synchronous user-facing behavior or weakening
snapshot validation; these remain measured limitations rather than silently
accepted performance promises.
