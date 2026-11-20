from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.check_coverage import (
    check_baseline_transition,
    evaluate,
    markdown_table,
    parse_summary,
    tracked_source_files,
)


def summary(*rows, total=88.0):
    lines = [
        "Summary",
        "",
        "File                              Hits  Missed Coverage",
        "--------------------------------------------------------",
    ]
    for path, hits, missed, coverage in rows:
        lines.append(f"{path:<34} {hits:<5} {missed:<6} {coverage:.2f}%")
    lines.append(f"{'Total':<34} 1000  120    {total:.2f}%")
    return "\n".join(lines) + "\n"


class CoveragePolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = {
            "file_floor": 70.0,
            "platforms": {
                "Linux": {
                    "measured_total": 88.0,
                    "total_floor": 87.5,
                    "allowlist": {
                        "lua/direct/history/reverse.lua": 61.57,
                    },
                },
            },
        }

    def test_unlisted_file_below_floor_fails(self):
        text = summary(("lua/direct/new.lua", 60, 40, 60.0))
        _, errors, _ = evaluate(text, self.policy, "Linux")
        self.assertIn("lua/direct/new.lua: 60.00% is below the 70.00% floor", errors[0])

    def test_never_loaded_source_is_added_as_zero_and_fails_the_floor(self):
        text = summary(("lua/direct/covered.lua", 90, 10, 90.0))
        rows, errors, _ = evaluate(
            text,
            self.policy,
            "Linux",
            source_files=["lua/direct/covered.lua", "lua/direct/new-module.lua"],
        )
        self.assertEqual(rows[0][0], "lua/direct/new-module.lua")
        self.assertEqual(rows[0][1]["coverage"], 0.0)
        self.assertTrue(any("lua/direct/new-module.lua: 0.00%" in error for error in errors))

    def test_source_inventory_includes_only_tracked_lua_under_configured_roots(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "lua/direct").mkdir(parents=True)
            (root / "plugin").mkdir()
            (root / "ftplugin").mkdir()
            (root / "tests/plugin").mkdir(parents=True)
            tracked = [
                "lua/direct/covered.lua",
                "plugin/direct.lua",
                "ftplugin/direct.lua",
                "tests/plugin/not-source.lua",
            ]
            for relative in tracked:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("-- fixture\n", encoding="utf-8")
            (root / "lua/direct/untracked.lua").write_text("-- untracked\n", encoding="utf-8")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "add", "--", *tracked], cwd=root, check=True)

            self.assertEqual(
                tracked_source_files(root, ["lua/direct", "plugin", "ftplugin"]),
                ["ftplugin/direct.lua", "lua/direct/covered.lua", "plugin/direct.lua"],
            )

    def test_improved_allowlisted_file_requires_baseline_update(self):
        text = summary(("lua/direct/history/reverse.lua", 65, 35, 65.0))
        _, errors, _ = evaluate(text, self.policy, "Linux")
        self.assertTrue(any("rose from allowlisted 61.57% to 65.00%" in error for error in errors))

    def test_regressed_allowlisted_file_fails(self):
        text = summary(("lua/direct/history/reverse.lua", 60, 40, 60.0))
        _, errors, _ = evaluate(text, self.policy, "Linux")
        self.assertTrue(any("fell from allowlisted 61.57% to 60.00%" in error for error in errors))

    def test_allowlisted_file_reaching_floor_must_leave_allowlist(self):
        text = summary(("lua/direct/history/reverse.lua", 70, 30, 70.0))
        _, errors, _ = evaluate(text, self.policy, "Linux")
        self.assertTrue(any("remove its stale allowlist entry" in error for error in errors))

    def test_allowlist_entry_for_missing_file_fails(self):
        text = summary(("lua/direct/other.lua", 90, 10, 90.0))
        _, errors, _ = evaluate(text, self.policy, "Linux")
        self.assertTrue(
            any("lua/direct/history/reverse.lua: stale allowlist entry" in error for error in errors)
        )

    def test_total_floor_is_enforced(self):
        text = summary(("lua/direct/ok.lua", 90, 10, 90.0), total=87.4)
        _, errors, _ = evaluate(text, self.policy, "Linux")
        self.assertTrue(any("total coverage 87.40% is below the 87.50%" in error for error in errors))

    def test_total_floor_must_be_below_its_recorded_measurement(self):
        policy = {
            "file_floor": 70.0,
            "platforms": {
                "Linux": {
                    "measured_total": 87.5,
                    "total_floor": 87.5,
                    "allowlist": {},
                },
            },
        }
        text = summary(("lua/direct/ok.lua", 90, 10, 90.0), total=88.0)
        _, errors, _ = evaluate(text, policy, "Linux")
        self.assertTrue(any("must be just below the recorded measurement" in error for error in errors))

    def test_absolute_summary_paths_are_made_repo_relative(self):
        text = summary(("/checkout/lua/direct/ok.lua", 90, 10, 90.0))
        files, _ = parse_summary(text, Path("/checkout"))
        self.assertIn("lua/direct/ok.lua", files)

    def test_windows_summary_paths_are_made_repo_relative_off_windows(self):
        text = summary(
            (r"D:\a\direct.vim\direct.vim\lua\direct\ok.lua", 90, 10, 90.0)
        )
        files, _ = parse_summary(text, r"D:\a\direct.vim\direct.vim")
        self.assertIn("lua/direct/ok.lua", files)

    def test_baseline_transition_allows_raise_and_exception_removal(self):
        previous = {
            "file_floor": 70,
            "source_roots": ["lua/direct", "plugin", "ftplugin"],
            "platforms": {
                "Linux": {
                    "total_floor": 87.5,
                    "allowlist": {
                        "lua/direct/history/reverse.lua": 61.57,
                        "lua/direct/history/crash_test_hook.lua": 33.33,
                    },
                },
            },
        }
        current = {
            "file_floor": 70,
            "source_roots": ["lua/direct", "plugin", "ftplugin"],
            "platforms": {
                "Linux": {
                    "total_floor": 87.6,
                    "allowlist": {
                        "lua/direct/history/reverse.lua": 62.0,
                    },
                },
            },
        }
        self.assertEqual(check_baseline_transition(previous, current), [])

    def test_baseline_transition_rejects_allowlist_growth_and_lowered_figure(self):
        previous = {
            "file_floor": 70,
            "source_roots": ["lua/direct", "plugin"],
            "platforms": {
                "Linux": {
                    "total_floor": 87.5,
                    "allowlist": {"lua/direct/history/reverse.lua": 61.57},
                },
            },
        }
        current = {
            "file_floor": 70,
            "source_roots": ["lua/direct"],
            "platforms": {
                "Linux": {
                    "total_floor": 87.4,
                    "allowlist": {
                        "lua/direct/history/reverse.lua": 60.0,
                        "lua/direct/new.lua": 20.0,
                    },
                },
            },
        }
        errors = check_baseline_transition(previous, current)
        self.assertTrue(any("total floor decreased" in error for error in errors))
        self.assertTrue(any("coverage decreased" in error for error in errors))
        self.assertTrue(any("allowlist grew" in error for error in errors))
        self.assertTrue(any("coverage source root was removed: plugin" in error for error in errors))

    def test_summary_rows_are_sorted_lowest_first(self):
        text = summary(
            ("lua/direct/high.lua", 90, 10, 90.0),
            ("lua/direct/low.lua", 65, 35, 65.0),
        )
        rows, total = parse_summary(text)
        table = markdown_table(
            [(path, row, "at/above floor") for path, row in sorted(
                rows.items(), key=lambda item: (float(item[1]["coverage"]), item[0])
            )],
            "Linux",
            total,
        )
        self.assertLess(table.index("lua/direct/low.lua"), table.index("lua/direct/high.lua"))


if __name__ == "__main__":
    unittest.main()
