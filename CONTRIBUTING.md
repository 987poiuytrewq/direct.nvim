# Contributing

Thanks for your interest in direct.vim. Keep each branch and pull request to
one task, and write a failing test before implementing a behavior change. Run
the relevant test first to confirm it fails for the expected reason, then run
the full checks before submitting.

Add every user-visible change to the `Unreleased` section of
[`CHANGELOG.md`](CHANGELOG.md). When behavior, options, or mappings change,
keep [`README.md`](README.md) and the Neovim help (`doc/direct.txt`) in sync.
Before a release, every merged pull request since the last tag needs a changelog
entry.

## Development

On macOS, install the prerequisites with [Homebrew](https://brew.sh/):

```sh
brew install neovim git                    # tests and coverage
brew install asciinema agg expect          # demo recording
brew install --cask font-jetbrains-mono-nerd-font
```

The font is only needed for the demo GIF, which renders the file icons with it.

The tests run in Neovim's embedded Lua and need only Neovim 0.11.7 or later:

```sh
make test
```

The real-process end-to-end check also requires Python 3.9 or later:

```sh
make e2e                 # override Python with PYTHON=python if needed
```

For coverage, `make coverage` fetches
[LuaCov](https://github.com/lunarmodules/luacov) with Git into the ignored
`.rocks/` directory, then runs the suite with it:

```sh
make coverage          # writes coverage/index.html and coverage/summary.out
make coverage-check    # fails below 86% total coverage (override with COVERAGE_MIN)
make coverage-summary  # writes coverage/summary.md
```

On pull requests and pushes to `master`, CI runs the suite with coverage on
Linux, macOS and Windows against Neovim 0.11.7, rejects coverage below the
floor, checks the full Lua tree with Luacheck, StyLua and LuaLS, tests latest
stable Neovim on all three platforms and nightly Neovim on Linux, and checks
the demo tour and real-process end-to-end scenarios.

## Release checklist

1. Add user-visible changes to the `Unreleased` section of
   [`CHANGELOG.md`](CHANGELOG.md) and keep the README and help docs in sync.
   Before release, check that every merged pull request since the last tag has
   a changelog entry.
   Release PRs may edit a released section and should use the `release` label
   to skip the CI check that protects published release notes.
2. Merge the release PR, then create and push an annotated `vX.Y.Z` tag on the
   resulting `master` commit.
3. Publish a GitHub release for that tag using the matching changelog section.

Version tags are the versions installed by lazy.nvim's `version = '*'`.

## Demo recording

`make demo` records a scripted tour of direct.vim with
[asciinema](https://asciinema.org/) and converts it to `demo/tour.gif` with
[agg](https://github.com/asciinema/agg). The tour uses a throwaway Git
repository and data directory. `make demo-check` plays the same tour without
recording it and checks the result. See [`demo/README.md`](demo/README.md) for
details.

## Persisted data formats

Treat files written by direct.vim as user data. When changing a persisted
format, bump its existing version marker and add a new immutable fixture
directory under `tests/fixtures/formats/<version>/`. Do not edit or regenerate
fixtures for an older release; add a new directory for each release baseline.
Tests must show that older data is either read with the same meaning or refused
without changing its bytes or allowing the requested operation to proceed.

Some persisted artifacts are not versioned formats. Do not invent a marker
retroactively in a historical fixture: document the limitation, and introduce
a marker only as part of a deliberate format change. For v0.3.0, the register
golden is its one-line pointer and copied-entry tree rather than a manifest,
and the lock golden is the empty advisory-lock file; neither had a version
marker or manifest at that release.
