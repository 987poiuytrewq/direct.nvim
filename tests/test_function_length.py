from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.check_function_length import scan_lua_functions, validate_function_lengths


def function_source(name, body_lines):
    body = ''.join(f'  local value_{line} = {line}\n' for line in range(body_lines))
    return f'function {name}()\n{body}end\n'


class FunctionLengthTests(unittest.TestCase):
    def test_unallowlisted_over_limit_function_fails(self):
        functions = scan_lua_functions(function_source('new_function', 120), 'sample.lua')

        self.assertEqual(len(functions), 1)
        self.assertEqual(functions[0].line_count, 122)
        self.assertTrue(
            any('function exceeds 120 lines' in error for error in validate_function_lengths(functions, {}))
        )

    def test_allowlisted_over_limit_function_passes(self):
        function = scan_lua_functions(function_source('old_function', 120), 'sample.lua')[0]

        self.assertEqual(
            validate_function_lengths([function], {function.key: function.line_count}),
            [],
        )

    def test_missing_and_shrunk_allowlist_entries_fail(self):
        errors = validate_function_lengths([], {'sample.lua:removed@1': 150})
        self.assertTrue(any('stale allowlist entry' in error for error in errors))

        function = scan_lua_functions(function_source('shortened', 118), 'sample.lua')[0]
        errors = validate_function_lengths([function], {function.key: 121})
        self.assertTrue(any('is now 120 lines' in error for error in errors))

    def test_scanner_ignores_comments_and_strings_and_counts_nested_blocks(self):
        source = '''-- function comment_fake() end
local text = "function string_fake() end"
--[=[ function long_comment_fake() end ]=]
function outer()
  if true then
    for index = 1, 1 do
      local function inner()
        return index
      end
    end
  end
end
'''
        functions = scan_lua_functions(source, 'sample.lua')

        self.assertEqual(
            [(function.key, function.line_count) for function in functions],
            [('sample.lua:local inner@7', 3), ('sample.lua:outer@4', 9)],
        )


if __name__ == '__main__':
    unittest.main()
