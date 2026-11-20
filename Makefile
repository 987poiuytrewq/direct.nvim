NVIM ?= nvim
PYTHON ?= python3
COVERAGE_PLATFORM ?= local
DEMO_FONT ?= JetBrainsMono Nerd Font
DEMO_GIF ?= demo/tour.gif
DIRECT_LISTING_SAMPLES ?= 3
DIRECT_LISTING_BUDGET_MS ?= 300
DIRECT_LISTING_GITIGNORE_BUDGET_MS ?= 750
LUACHECK ?= luacheck
LUACHECK_MAX_WARNINGS ?= 0
LUALS ?= lua-language-server
LUALS_LOGPATH ?= $(CURDIR)/.cache/luals
COVERAGE_MIN ?= 86

.PHONY: ci test lint coverage coverage-deps coverage-check coverage-summary live-startup e2e demo demo-record demo-gif demo-check listing-benchmark check-nvim

ci:
	$(MAKE) coverage
	$(MAKE) coverage-check
	$(MAKE) coverage-summary
	$(MAKE) live-startup
	$(MAKE) e2e

test: check-nvim
	$(NVIM) --headless -l tests/run.lua

lint:
	@mkdir -p .cache
	@set +e; $(LUACHECK) --no-color lua/direct > .cache/luacheck.log 2>&1; result=$$?; set -e; \
	  cat .cache/luacheck.log; \
	  warnings=$$(sed -n 's/^Total: \([0-9][0-9]*\) warnings.*/\1/p' .cache/luacheck.log); \
	  if [ "$$result" -gt 1 ] || [ -z "$$warnings" ] || [ "$$warnings" -gt '$(LUACHECK_MAX_WARNINGS)' ]; then \
	    echo "luacheck failed (exit $$result, warnings=$${warnings:-unknown}, maximum=$(LUACHECK_MAX_WARNINGS))" >&2; exit 1; \
	  fi
	$(PYTHON) tests/test_function_length.py
	$(PYTHON) scripts/check_function_length.py
	stylua --check lua/direct
	@mkdir -p '$(LUALS_LOGPATH)'
	$(LUALS) --check=lua/direct/init.lua --configpath='$(CURDIR)/.luarc.json' --checklevel=Warning --logpath='$(LUALS_LOGPATH)'
	$(LUALS) --check=lua/direct/config.lua --configpath='$(CURDIR)/.luarc.json' --checklevel=Warning --logpath='$(LUALS_LOGPATH)'
	$(LUALS) --check=lua/direct/folding.lua --configpath='$(CURDIR)/.luarc.json' --checklevel=Warning --logpath='$(LUALS_LOGPATH)'
	$(LUALS) --check=lua/direct/events.lua --configpath='$(CURDIR)/.luarc.json' --checklevel=Warning --logpath='$(LUALS_LOGPATH)'
	$(LUALS) --check=lua/direct --configpath='$(CURDIR)/.luarc.json' --checklevel=Error --logpath='$(LUALS_LOGPATH)'

coverage-deps:
	bash tests/install_coverage_deps.sh

coverage: check-nvim coverage-deps
	@mkdir -p coverage
	@rm -f coverage/luacov.stats.out coverage/index.html coverage/summary.out
	NVIM='$(NVIM)' bash tests/run_coverage.sh

coverage-check:
	@test -s coverage/summary.out || { echo 'Run make coverage before make coverage-check' >&2; exit 1; }
	@total=$$(sed -n 's/^Total .* \([0-9][0-9]*\.[0-9][0-9]*\)%$$/\1/p' coverage/summary.out | tail -1); \
	  if [ -z "$$total" ]; then echo 'could not read total coverage from coverage/summary.out' >&2; exit 1; fi; \
	  awk -v total="$$total" -v minimum='$(COVERAGE_MIN)' 'BEGIN { \
	    if (total + 0 < minimum + 0) { \
	      printf "coverage %.2f%% is below the %.2f%% floor\n", total, minimum > "/dev/stderr"; \
	      exit 1; \
	    } \
	    printf "coverage %.2f%% (floor %.2f%%)\n", total, minimum; \
	  }'

coverage-summary:
	@test -s coverage/luacov.stats.out || { echo 'Run make coverage before make coverage-summary' >&2; exit 1; }
	@{ printf '## Coverage (%s)\n\n```text\n' '$(COVERAGE_PLATFORM)'; cat coverage/summary.out; printf '```\n'; } > coverage/summary.md
	@if test -n "$$GITHUB_STEP_SUMMARY"; then cat coverage/summary.md >> "$$GITHUB_STEP_SUMMARY"; else cat coverage/summary.md; fi

live-startup:
	bash tests/live_startup.sh

e2e: check-nvim
	NVIM='$(NVIM)' $(PYTHON) tests/e2e/run.py
	NVIM='$(NVIM)' $(PYTHON) tests/e2e/run_a49.py

listing-benchmark: check-nvim
	DIRECT_LISTING_SAMPLES='$(DIRECT_LISTING_SAMPLES)' \
	DIRECT_LISTING_BUDGET_MS='$(DIRECT_LISTING_BUDGET_MS)' \
	DIRECT_LISTING_GITIGNORE_BUDGET_MS='$(DIRECT_LISTING_GITIGNORE_BUDGET_MS)' \
	$(NVIM) --headless -l bench/listing.lua

# The README demo: record the tour with asciinema, then convert it to a GIF
# with agg. DEMO_FONT must be a Nerd Font, so the icons render.
demo: demo-record demo-gif

demo-record: check-nvim
	NVIM='$(NVIM)' CAST_DIR='$(abspath demo/casts)' ./demo/demo.sh --force

demo-gif:
	@test -s demo/casts/tour.cast || { echo 'Run make demo-record before make demo-gif' >&2; exit 1; }
	@command -v agg >/dev/null 2>&1 || { echo 'agg is required to convert the recording (install it and ensure it is on PATH)' >&2; exit 1; }
	agg --font-family '$(DEMO_FONT)' demo/casts/tour.cast '$(DEMO_GIF)'

# Play the tour without recording it, and check its result.
demo-check: check-nvim
	NVIM='$(NVIM)' ./demo/demo.sh --check

check-nvim:
	@command -v $(NVIM) >/dev/null 2>&1 || { echo 'Neovim >= 0.11.7 is required (set NVIM=/path/to/nvim if needed)' >&2; exit 1; }
	@$(NVIM) --headless -u NONE -l tests/check_nvim.lua
