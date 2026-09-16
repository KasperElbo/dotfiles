#!/usr/bin/env python3
"""Refuse two Neovim plugin fragments that fight over a key lazy.nvim overrides.

lazy.nvim merges `opts`, `dependencies`, `cmd`, `event`, `ft` and `keys` across
every fragment of one plugin spec. Every other key is *overridden* by the
fragment imported last, silently and with no warning. Imported modules are
sorted by module name, so `plugins.colorscheme` loses to `plugins.macos` and
`plugins.wsl`: a shared `init` that a platform overlay also declares simply
never runs on that platform.

That is not a hypothetical. The `FocusGained` colorscheme reload lived on the
shared `"LazyVim/LazyVim"` fragment while both platform overlays declared
`init` on the same spec for their launch settings, so the documented theme
reload was dead on macOS and Fedora WSL (issue #248, RA-36).

This validator parses every plugin fragment the repository ships and fails when
two fragments that are loaded together declare the same non-merged key for the
same plugin. Fragments from two different platforms are never loaded together,
so they are not in conflict: each platform overlay is checked against the shared
set it is stowed alongside, not against its siblings.

Usage:
    scripts/validate-neovim-plugin-specs.py [--root DIR]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

# Keys lazy.nvim merges across fragments; everything else overrides. Kept as the
# positive list so this file states the upstream rule, not a guess at it.
MERGED_KEYS = {"opts", "dependencies", "cmd", "event", "ft", "keys"}

# The overriding keys worth guarding: each one is a behaviour that silently
# disappears when a second fragment declares it.
GUARDED_KEYS = ("init", "config", "build", "priority")

SHARED_PLUGINS = "nvim-lazyvim/.config/nvim/lua/plugins"
PROFILE_PLUGINS = "nvim-lazyvim/.config/nvim/lua/ctf_plugins"
OVERLAY_GLOB = "platforms/*/stow/nvim-*/.config/nvim/lua/plugins/*.lua"

# A plugin is addressed as "owner/repo". Restricting identity to that shape
# keeps list entries that merely start with a string -- `cmd = { "opam", ... }`,
# a `keys` table -- from being mistaken for plugin fragments.
PLUGIN_NAME = re.compile(r"^[\w.-]+/[\w.-]+$")

BLOCK_OPENERS = {"function", "if", "do", "repeat"}
BLOCK_CLOSERS = {"end", "until"}


class Fragment:
    """One `{ "owner/repo", ... }` table, and the keys it declares directly."""

    def __init__(self, path: str, line: int) -> None:
        self.path = path
        self.line = line
        self.plugin: str | None = None
        self.keys: dict[str, int] = {}
        self.positional = 0
        self.expect_item = True


def tokenize(text: str) -> list[tuple[str, str, int]]:
    """Enough of Lua's lexer to tell code from strings, comments and braces."""
    tokens: list[tuple[str, str, int]] = []
    index = 0
    line = 1
    length = len(text)

    def long_bracket(start: int) -> tuple[int, int] | None:
        """Match `[==[` at `start`, returning (content start, level)."""
        if text[start] != "[":
            return None
        cursor = start + 1
        level = 0
        while cursor < length and text[cursor] == "=":
            level += 1
            cursor += 1
        if cursor < length and text[cursor] == "[":
            return cursor + 1, level
        return None

    while index < length:
        character = text[index]

        if character == "\n":
            line += 1
            index += 1
            continue
        if character.isspace():
            index += 1
            continue

        if text.startswith("--", index):
            opened = long_bracket(index + 2)
            if opened:
                start, level = opened
                closing = "]" + "=" * level + "]"
                end = text.find(closing, start)
                end = length if end == -1 else end + len(closing)
                line += text.count("\n", index, end)
                index = end
            else:
                end = text.find("\n", index)
                index = length if end == -1 else end
            continue

        opened = long_bracket(index)
        if opened:
            start, level = opened
            closing = "]" + "=" * level + "]"
            end = text.find(closing, start)
            end = length if end == -1 else end + len(closing)
            tokens.append(("string", text[start : end - len(closing)], line))
            line += text.count("\n", index, end)
            index = end
            continue

        if character in "\"'":
            cursor = index + 1
            while cursor < length:
                if text[cursor] == "\\":
                    cursor += 2
                    continue
                if text[cursor] == character:
                    break
                cursor += 1
            tokens.append(("string", text[index + 1 : cursor], line))
            line += text.count("\n", index, cursor)
            index = cursor + 1
            continue

        if character.isalpha() or character == "_":
            cursor = index
            while cursor < length and (text[cursor].isalnum() or text[cursor] == "_"):
                cursor += 1
            tokens.append(("name", text[index:cursor], line))
            index = cursor
            continue

        if character.isdigit():
            cursor = index
            while cursor < length and (text[cursor].isalnum() or text[cursor] == "."):
                cursor += 1
            tokens.append(("number", text[index:cursor], line))
            index = cursor
            continue

        if text[index : index + 2] in {"==", "~=", "<=", ">=", "::"}:
            tokens.append(("punct", text[index : index + 2], line))
            index += 2
            continue

        tokens.append(("punct", character, line))
        index += 1

    return tokens


def parse_fragments(path: str, text: str) -> list[Fragment]:
    """Every table whose first positional value is a plugin name."""
    tokens = tokenize(text)
    fragments: list[Fragment] = []
    stack: list[tuple[Fragment, int, int]] = []
    block = 0
    paren = 0

    for position, (kind, value, line) in enumerate(tokens):
        if kind == "name":
            if value in BLOCK_OPENERS:
                block += 1
            elif value in BLOCK_CLOSERS:
                block -= 1
            # `end`/`until` close the block their own token belongs to, so the
            # frame comparison below uses the depth after this adjustment.

        if kind == "punct":
            if value in "([":
                paren += 1
            elif value in ")]":
                paren -= 1
            elif value == "{":
                stack.append((Fragment(path, line), block, paren))
                continue
            elif value == "}":
                if stack:
                    fragment, _, _ = stack.pop()
                    if fragment.plugin:
                        fragments.append(fragment)
                continue

        if not stack:
            continue

        fragment, frame_block, frame_paren = stack[-1]
        # Anything nested inside a function body, a call or an index expression
        # belongs to that construct, not to the table's own key list.
        if block != frame_block or paren != frame_paren:
            continue

        if kind == "punct" and value in ",;":
            fragment.expect_item = True
            continue
        if not fragment.expect_item:
            continue

        following = tokens[position + 1][1] if position + 1 < len(tokens) else ""
        if kind == "name" and following == "=":
            fragment.keys.setdefault(value, line)
            fragment.expect_item = False
        elif kind == "string" and following in {",", ";", "}"}:
            if fragment.positional == 0 and PLUGIN_NAME.match(value):
                fragment.plugin = value
            fragment.positional += 1
            fragment.expect_item = False
        else:
            fragment.expect_item = False

    return fragments


def fragments_in(paths: list[pathlib.Path], root: pathlib.Path) -> list[Fragment]:
    collected: list[Fragment] = []
    for path in sorted(paths):
        relative = path.relative_to(root).as_posix()
        collected.extend(parse_fragments(relative, path.read_text(encoding="utf-8")))
    return collected


def spec_sets(root: pathlib.Path) -> dict[str, list[Fragment]]:
    """The fragment sets that are ever resolved together.

    A platform overlay is stowed into the same `lua/plugins` directory as the
    shared fragments, so lazy.nvim imports both as one module. Two overlays are
    never installed on the same machine, so they never contend with each other.
    """
    shared = fragments_in(sorted((root / SHARED_PLUGINS).glob("*.lua")), root)
    profile = fragments_in(sorted((root / PROFILE_PLUGINS).glob("*.lua")), root)

    sets = {"the shared plugin fragments": shared}
    for overlay in sorted(root.glob(OVERLAY_GLOB)):
        platform = overlay.relative_to(root).parts[1]
        name = f"the shared plugin fragments plus the {platform} overlay"
        sets.setdefault(name, list(shared))
        sets[name].extend(fragments_in([overlay], root))
    if profile:
        sets["the parrot-ctf profile fragments"] = profile
    return sets


def conflicts(sets: dict[str, list[Fragment]]) -> list[str]:
    problems: list[str] = []
    reported: set[tuple[str, str, tuple[str, ...]]] = set()

    for name, fragments in sorted(sets.items()):
        declarations: dict[tuple[str, str], list[Fragment]] = {}
        for fragment in fragments:
            assert fragment.plugin is not None
            for key in GUARDED_KEYS:
                if key in fragment.keys:
                    declarations.setdefault((fragment.plugin, key), []).append(fragment)

        for (plugin, key), owners in sorted(declarations.items()):
            if len(owners) < 2:
                continue
            where = tuple(
                f"{owner.path}:{owner.keys[key]}"
                for owner in sorted(owners, key=lambda item: (item.path, item.line))
            )
            signature = (plugin, key, where)
            if signature in reported:
                continue
            reported.add(signature)
            problems.append(
                f"{plugin!r} declares `{key}` in {len(owners)} fragments loaded together "
                f"({name}): {', '.join(where)}. lazy.nvim merges only "
                f"{', '.join(sorted(MERGED_KEYS))}; every other key is overridden by the "
                "fragment imported last, so all but one of these are dead. Move the "
                "behaviour to a spec no other fragment declares, or merge the fragments."
            )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    sets = spec_sets(root)
    if not sets.get("the shared plugin fragments"):
        print(
            f"neovim plugin specs: parsed no plugin fragments under {SHARED_PLUGINS}; "
            "either the tree moved or this parser is broken",
            file=sys.stderr,
        )
        return 1

    problems = conflicts(sets)
    for problem in problems:
        print(f"neovim plugin specs: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
