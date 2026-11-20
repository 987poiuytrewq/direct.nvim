#!/usr/bin/env python3
"""Check Lua function lengths against the current shrinking offender list."""

from dataclasses import dataclass
from pathlib import Path
import sys


LIMIT = 120

# Current >120-line inventory on the A38 guard branch. Remove an entry when its
# function is refactored; do not add new entries to make a failing function pass.
ALLOWLIST = {
    "lua/direct/buffer/sync.lua:local sync_locked@287": 910,
    "lua/direct/history/reverse.lua:local build@13": 678,
    "lua/direct/buffer/tree.lua:local edited_subtrees@365": 580,
    "lua/direct/history/reverse.lua:M._reverse_async@220": 461,
    "lua/direct/buffer/list.lua:M.list_buffer@255": 321,
    "lua/direct/buffer/sync_plan.lua:local classify_identity@92": 228,
    "lua/direct/history/trash_refs.lua:<anonymous>@4": 267,
    "lua/direct/history/reverse.lua:<anonymous>@450": 223,
    "lua/direct/buffer/tree.lua:local children_integrity@163": 138,
    "lua/direct/buffer/undo_state.lua:local reconcile_undone_materialization@323": 190,
    "lua/direct/buffer/sync_plan.lua:local build_actions@408": 177,
    "lua/direct/buffer/undo_state.lua:local restore_undone_collapse@151": 161,
    "lua/direct/buffer/row_state.lua:M.expand@255": 144,
    "lua/direct/buffer/buffer.lua:local set_options@224": 137,
    "lua/direct/history/history.lua:M.apply_async@1084": 132,
    "lua/direct/file_operations.lua:local resource_expectations@272": 126,
    "lua/direct/buffer/listing.lua:local hidden_descendant@355": 124,
}

BLOCK_KEYWORDS = {"function", "if", "for", "while", "do", "repeat", "until", "end"}


@dataclass(frozen=True)
class Token:
    kind: str
    value: str
    line: int


@dataclass(frozen=True)
class FunctionSpan:
    key: str
    start_line: int
    end_line: int
    line_count: int


def _long_bracket_open(source, index):
    """Return (content_start, closing_delimiter) for Lua's [=[ long forms."""
    if index >= len(source) or source[index] != "[":
        return None
    cursor = index + 1
    while cursor < len(source) and source[cursor] == "=":
        cursor += 1
    if cursor >= len(source) or source[cursor] != "[":
        return None
    return cursor + 1, "]" + "=" * (cursor - index - 1) + "]"


def _skip_long(source, index, content_start, closing):
    end = source.find(closing, content_start)
    if end < 0:
        end = len(source)
    else:
        end += len(closing)
    return end, source[index:end].count("\n")


def tokenize_lua(source):
    """Yield Lua keywords and identifiers, ignoring comments and string bodies."""
    tokens = []
    index, line = 0, 1
    while index < len(source):
        char = source[index]
        if char in " \t\r\f\v":
            index += 1
            continue
        if char == "\n":
            line += 1
            index += 1
            continue
        if source.startswith("--", index):
            long = _long_bracket_open(source, index + 2)
            if long:
                content_start, closing = long
                index, line_breaks = _skip_long(source, index, content_start, closing)
                line += line_breaks
            else:
                end = source.find("\n", index + 2)
                index = len(source) if end < 0 else end
            continue
        if char in {"'", '"'}:
            quote = char
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    if index + 1 < len(source) and source[index + 1] == "\n":
                        line += 1
                    index += 2
                elif source[index] == quote:
                    index += 1
                    break
                else:
                    if source[index] == "\n":
                        line += 1
                    index += 1
            continue
        long = _long_bracket_open(source, index)
        if long:
            content_start, closing = long
            index, line_breaks = _skip_long(source, index, content_start, closing)
            line += line_breaks
            continue
        if char.isalpha() or char == "_":
            start = index
            index += 1
            while index < len(source) and (source[index].isalnum() or source[index] == "_"):
                index += 1
            word = source[start:index]
            kind = "keyword" if word in BLOCK_KEYWORDS else "identifier"
            tokens.append(Token(kind, word, line))
            continue
        tokens.append(Token("symbol", char, line))
        index += 1
    return tokens


def _function_name(tokens, index):
    if index + 1 >= len(tokens) or tokens[index + 1].kind != "identifier":
        return "<anonymous>"
    parts = [tokens[index + 1].value]
    cursor = index + 2
    while (
        cursor + 1 < len(tokens)
        and tokens[cursor].value in {".", ":"}
        and tokens[cursor + 1].kind == "identifier"
    ):
        parts.extend((tokens[cursor].value, tokens[cursor + 1].value))
        cursor += 2
    name = "".join(parts)
    if index > 0 and tokens[index - 1].value == "local":
        name = "local " + name
    return name


def scan_lua_functions(source, relative_path):
    """Return function spans, counting from `function` through its matching `end`."""
    tokens = tokenize_lua(source)
    blocks, functions = [], []
    for index, token in enumerate(tokens):
        if token.kind != "keyword":
            continue
        if token.value == "function":
            blocks.append(
                {
                    "kind": "function",
                    "start": token.line,
                    "name": _function_name(tokens, index),
                }
            )
        elif token.value == "if":
            blocks.append({"kind": "if"})
        elif token.value in {"for", "while"}:
            blocks.append({"kind": "loop", "waiting_for_do": True})
        elif token.value == "do":
            if blocks and blocks[-1]["kind"] == "loop" and blocks[-1]["waiting_for_do"]:
                blocks[-1]["waiting_for_do"] = False
            else:
                blocks.append({"kind": "do"})
        elif token.value == "repeat":
            blocks.append({"kind": "repeat"})
        elif token.value == "until":
            if blocks and blocks[-1]["kind"] == "repeat":
                blocks.pop()
        elif token.value == "end" and blocks:
            block = blocks.pop()
            if block["kind"] == "function":
                line_count = token.line - block["start"] + 1
                key = f"{relative_path}:{block['name']}@{block['start']}"
                functions.append(FunctionSpan(key, block["start"], token.line, line_count))
    return functions


def scan_lua_tree(repo_root):
    source_root = repo_root / "lua" / "direct"
    functions = []
    for path in sorted(source_root.rglob("*.lua")):
        relative_path = path.relative_to(repo_root).as_posix()
        functions.extend(scan_lua_functions(path.read_text(encoding="utf-8"), relative_path))
    return functions


def validate_function_lengths(functions, allowlist, limit=LIMIT):
    """Return diagnostics for new, changed, or stale allowlist entries."""
    by_key = {function.key: function for function in functions}
    errors = []
    for key, expected_length in sorted(allowlist.items()):
        function = by_key.get(key)
        if function is None:
            errors.append(f"stale allowlist entry: {key} no longer exists")
        elif function.line_count <= limit:
            errors.append(f"stale allowlist entry: {key} is now {function.line_count} lines")
        elif function.line_count != expected_length:
            errors.append(
                f"allowlist length changed for {key}: expected {expected_length}, found {function.line_count}"
            )

    for function in sorted(functions, key=lambda item: item.key):
        if function.line_count > limit and function.key not in allowlist:
            errors.append(
                f"function exceeds {limit} lines: {function.key} has {function.line_count}"
            )
    return errors


def main():
    repo_root = Path(__file__).resolve().parents[1]
    functions = scan_lua_tree(repo_root)
    errors = validate_function_lengths(functions, ALLOWLIST)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"function length check passed; {len(ALLOWLIST)} current offenders are allowlisted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
