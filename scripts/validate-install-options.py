#!/usr/bin/env python3
"""Validate each platform installer's argv parser against its option manifest.

`config/install-options.tsv` says which flags a platform installer accepts and
which of them a machine remembers; `platforms/<platform>/install.sh` is what
actually accepts them. The two drift in both directions, and neither direction
is caught anywhere else:

* a flag the parser accepts but the manifest does not declare is never
  recorded, so `./install.sh --rerun` silently forgets it;
* a flag the manifest declares but the parser does not implement is
  documented as real, and `install_selection_serialize` stops every install on
  that platform with "Persistent installer option was never recorded".

So the flags matched by the parser's `while (($#)); do case "$1" in` arms are
compared with the manifest's `on_flag`/`off_flag` values, per platform, and
every difference is reported by name. An arm whose body starts with `die`
rejects its flags rather than accepting them; see REJECTED_FLAGS.

`./scripts/lint.sh` runs this.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import ManifestSchemaError, read_tsv  # noqa: E402
from generated import read_committed  # noqa: E402
from shell import function_spans, outside_functions, strip_noise  # noqa: E402
from installer_argv import (  # noqa: E402
    ARM_ASSIGNMENT,
    ONLY_SHIFTS,
    PARSER,
    REJECTION,
    UnreadableParser,
    parser_flags,
    recorded_variable,
)

ROOT = pathlib.Path(__file__).resolve().parents[1]
OPTION_MANIFEST = pathlib.Path(
    os.environ.get("INSTALL_OPTION_MANIFEST", ROOT / "config" / "install-options.tsv")
)

# Controls that belong to one invocation, not to a machine's configuration, so
# a parser may accept them without a manifest row (install-selection.sh says
# why). The same set scripts/render-installer-options.py documents as TRANSIENT,
# plus the deprecated aliases a parser still forwards during their removal
# window. A parser need not accept any of them; `--platform` belongs to the
# root installer, and a platform parser rejects `--rerun` for the same reason.
TRANSIENT_FLAGS = {
    "--platform",
    "--rerun",
    "--dry-run",
    "--non-interactive",
    "-h",
    "--help",
    "--dev-workflows",
    "--no-dev-workflows",
    # Deprecated aliases of --dev-workflows/--no-dev-workflows.
    "--smoke-test",
    "--workflows",
    "--no-workflows",
}

# Flags a platform deliberately refuses with an explanation, instead of letting
# them fall through to "Unknown option". Each one is a statement that the
# option does not exist on that platform, so it must not have a manifest row
# there, and its arm must really die: listing it here is what keeps a
# deliberate rejection from reading as acceptance.
REJECTED_FLAGS = {
    # Tailscale runs on the Windows host, not inside the WSL distribution.
    "fedora-wsl": {"--tailscale", "--no-tailscale"},
    # TeX is externally managed on macOS; the installer owns no distribution.
    "macos": {"--latex", "--no-latex"},
}

OPTION_FIELDS = [
    "platform", "option", "kind", "on_flag", "off_flag", "default",
    "values", "capability", "summary",
]

# The registry of what reads an option's value, and how. An enumerated `values`
# column is only authoritative if something is held to it: `--theme nonsense`
# was accepted by the installer, recorded, published in the generated
# reference, and refused by `bin/.local/bin/theme` at the end of the install.
CONSUMER_MANIFEST = pathlib.Path(
    os.environ.get("OPTION_CONSUMER_MANIFEST", ROOT / "config" / "option-consumers.tsv")
)
CONSUMER_FIELDS = ["platform", "option", "consumer", "kind", "detail", "summary"]

# One variable set to one literal, as the installers write their defaults:
# several to a line, separated by semicolons.
ASSIGNMENT = re.compile(
    r"(?:^|;)[ \t]*(?P<name>[A-Za-z_]\w*)="
    r"(?P<value>'[^']*'|\"[^\"]*\"|[^\s;#]*)"
)
# A default written as one variable, which is how a shared library states a
# default the installers agree on: `theme="$THEME_DEFAULT_FLAVOUR"`.
REFERENCE = re.compile(r"^\$\{?(?P<name>[A-Za-z_]\w*)\}?$")
# What a manifest default means as a literal the installer assigns. `inherit`
# and `-` are both "the flag was not given", which the installers write as the
# empty string so an omitted sub-flag stays distinguishable from an explicit
# `--no-<component>`.
UNSET_DEFAULTS = {"-", "inherit"}
# The two shapes a `values` column may take. An enumeration of literals,
# `latte|frappe|macchiato|mocha`, is a set of words each consumer has to agree
# with; an integer range, `40..100`, is a bound each consumer has to enforce.
# Nothing else is accepted: `--charge-limit` used to state `[4-9][0-9]|100`, a
# regular expression nothing compared with the installer's own `((x < 40 ||
# x > 100))`, so widening it moved the published range while the installer went
# on refusing it.
RANGE_VALUES = re.compile(r"^(?P<low>\d+)\.\.(?P<high>\d+)$")
LITERAL_VALUES = re.compile(r"^[\w-]+(?:\|[\w-]+)*$")
# One case arm's pattern, at the start of its own line, which is how every
# consumer in the registry writes one.
CASE_ARM = re.compile(r"^[ \t]*(?P<pattern>[^()\n]+?)\)")
# A bare word alternative: an accepted value. `*` and `""` are the arms for
# everything else and for nothing, neither of which names a value.
CASE_VALUE = re.compile(r"^[\w.-]+$")



def fail(message: str) -> None:
    print(f"installer option parser: {message}", file=sys.stderr)


def code_line(line: str) -> str:
    """One line with its comment dropped and everything else left as written.

    `strip_noise` is what finds the comment, because a `#` inside quotes opens
    none, and it keeps every character's position while blanking quoted text.
    That blanking is wrong here -- a value and a case subject are both written
    inside quotes -- so the comment's start is taken from the blanked line and
    the code is read out of the original.
    """
    return line[: len(strip_noise(line))]


def scoped_lines(path: pathlib.Path, detail: str) -> tuple[list[str], str, int] | None:
    """The lines a row's `detail` points at, the name in it, and their offset.

    A `detail` of `flavour` is a name the file reads where it runs; one of
    `kde_global_theme:1` is the same name inside that function, which is how a
    file that reads two different things through `$1` says which of them this
    row is about. None means the function named is not in the file.
    """
    text = path.read_text(encoding="utf-8")
    if ":" not in detail:
        return [code_line(line) for line in text.splitlines()], detail, 0
    function, _, name = detail.partition(":")
    for defined, opened, closed, _ in function_spans(text.splitlines()):
        if defined == function:
            lines = text.splitlines()[opened : closed + 1]
            return [code_line(line) for line in lines], name, opened
    return None


def case_values(path: pathlib.Path, detail: str) -> list[tuple[str, set[str]]] | None:
    """Every `case "$name" in` a row points at, and the values each accepts.

    Read as shell: a name in a comment is not an arm. Only bare word
    alternatives count, so the `*)` and `"")` arms -- everything else, and
    nothing -- are left out rather than read as values. Each `case` is its own
    site, because a file that branches on a flavour twice enforces the set
    twice and a second block that has fallen behind is the drift this check is
    for. None means the row points at a function the file does not define.
    """
    scoped = scoped_lines(path, detail)
    if scoped is None:
        return None
    lines, variable, offset = scoped
    head = re.compile(r"""case\s+"?\$\{?""" + re.escape(variable) + r"""\}?"?\s+in\b""")
    sites: list[tuple[str, set[str]]] = []
    for number, line in enumerate(lines):
        if not head.search(line):
            continue
        found: set[str] = set()
        for arm in lines[number + 1 :]:
            if arm.strip() == "esac":
                break
            match = CASE_ARM.match(arm)
            if match is None:
                continue
            for alternative in match.group("pattern").split("|"):
                alternative = alternative.strip()
                if CASE_VALUE.match(alternative):
                    found.add(alternative)
        sites.append((f'the `case "${variable}"` on line {offset + number + 1}', found))
    return sites


def array_values(path: pathlib.Path, detail: str) -> list[tuple[str, set[str]]] | None:
    """The words of the `detail=( ... )` array a row points at.

    The array is read where it is written rather than by running the file, so
    a list held in one place and used in several -- the flavours the Starship
    generator writes a configuration for -- is one site.
    """
    scoped = scoped_lines(path, detail)
    if scoped is None:
        return None
    lines, name, offset = scoped
    text = "\n".join(lines)
    opened = re.compile(r"(?:^|[;\s])" + re.escape(name) + r"=\(", re.M)
    sites: list[tuple[str, set[str]]] = []
    for match in opened.finditer(text):
        closed = text.find(")", match.end())
        if closed == -1:
            return None
        words = {word for word in text[match.end() : closed].split() if CASE_VALUE.match(word)}
        line = offset + text.count("\n", 0, match.start()) + 1
        sites.append((f"the `{name}=(` array on line {line}", words))
    return sites


def loop_values(path: pathlib.Path, detail: str) -> list[tuple[str, set[str]]] | None:
    """The words a `for detail in ...` loop runs over.

    Both bash verifiers check one symlink per flavour that way, so a flavour
    the registry offers and the loop does not name is an asset nothing checks.
    """
    scoped = scoped_lines(path, detail)
    if scoped is None:
        return None
    lines, name, offset = scoped
    loop = re.compile(r"\bfor\s+" + re.escape(name) + r"\s+in\s+(?P<words>[^;\n]*)")
    sites: list[tuple[str, set[str]]] = []
    for number, line in enumerate(lines):
        match = loop.search(line)
        if match is None:
            continue
        words = {word for word in match.group("words").split() if CASE_VALUE.match(word)}
        sites.append((f"the `for {name} in` loop on line {offset + number + 1}", words))
    return sites


# A Lua long bracket, `[[` or `[==[`, whose level its closer has to repeat.
LUA_LONG_BRACKET = re.compile(r"\[(?P<level>=*)\[")


def blank_lua_comments(text: str) -> str:
    """`text` with every Lua comment blanked, its line breaks and strings kept.

    `--` opens a comment to the end of the line, and `--[[ ... ]]` (or
    `--[==[ ... ]==]`) one that spans lines, except inside a string: quoted
    strings and long-bracket strings are skipped whole. Blanking rather than
    deleting keeps every line at its number, so a reported line still points
    at the line a reader sees.
    """
    out = list(text)
    index = 0
    length = len(text)

    def blank(start: int, end: int) -> None:
        for position in range(start, end):
            if out[position] != "\n":
                out[position] = " "

    def long_close(start: int, level: str) -> int:
        closer = text.find("]" + level + "]", start)
        return length if closer == -1 else closer + len(level) + 2

    while index < length:
        character = text[index]
        if text.startswith("--", index):
            bracket = LUA_LONG_BRACKET.match(text, index + 2)
            if bracket:
                end = long_close(bracket.end(), bracket.group("level"))
            else:
                newline = text.find("\n", index)
                end = length if newline == -1 else newline
            blank(index, end)
            index = end
        elif character in {"'", '"'}:
            index += 1
            while index < length and text[index] not in {character, "\n"}:
                index += 2 if text[index] == "\\" else 1
            index += 1
        elif (bracket := LUA_LONG_BRACKET.match(text, index)) is not None:
            index = long_close(bracket.end(), bracket.group("level"))
        else:
            index += 1
    return "".join(out)


def lua_table_keys(path: pathlib.Path, detail: str) -> list[tuple[str, set[str]]] | None:
    """The keys of the Lua table `detail = { ... }`.

    Neovim's colourscheme picker keeps the flavours it will honour in one such
    table and falls back to a default for anything else, so a flavour missing
    from it is one Neovim silently ignores. The table is a set, so only the
    keys it maps to `true` count: `mocha = false` names the flavour and refuses
    it, which is the same silent fallback with the name still in the file.

    Read as Lua: `-- frappe = true,` is a comment, and a key in one is a
    flavour the table no longer holds. `valid.frappe` is then nil and Neovim
    falls back to the default, which is the failure this row exists to catch.
    """
    text = blank_lua_comments(path.read_text(encoding="utf-8"))
    opened = re.compile(r"(?:^|[\s=,{(])" + re.escape(detail) + r"\s*=\s*\{", re.M)
    sites: list[tuple[str, set[str]]] = []
    for match in opened.finditer(text):
        closed = text.find("}", match.end())
        if closed == -1:
            return None
        body = text[match.end() : closed]
        keys = {
            key
            for key, value in re.findall(r"(?:^|[\s,{])([\w.-]+)\s*=\s*([\w.-]+)", body)
            if value == "true"
        }
        line = text.count("\n", 0, match.start()) + 1
        sites.append((f"the `{detail}` table on line {line}", keys))
    return sites


def validate_set_values(path: pathlib.Path, detail: str) -> list[tuple[str, set[str]]] | None:
    """The literals of the `[ValidateSet(...)]` on the `$detail` parameter.

    PowerShell refuses anything else before the script's first statement runs,
    so this set is exactly what the Windows theme script accepts.
    """
    text = path.read_text(encoding="utf-8")
    parameter = re.compile(
        r"\[ValidateSet\((?P<values>[^)]*)\)\][^$]*\$" + re.escape(detail) + r"\b",
        re.DOTALL,
    )
    sites = []
    for match in parameter.finditer(text):
        values = set(re.findall(r"'([^']*)'|\"([^\"]*)\"", match.group("values")))
        line = text.count("\n", 0, match.start()) + 1
        sites.append((
            f"the ValidateSet on ${detail} on line {line}",
            {single or double for single, double in values},
        ))
    return sites


def range_bounds(path: pathlib.Path, detail: str) -> list[tuple[str, set[str]]] | None:
    """The bounds each `((detail < LOW || detail > HIGH))` test enforces.

    That arithmetic test is how a script refuses an integer outside its range.
    A bound may be a literal or a name the file sets once to a literal where it
    runs, which is how a script states its range once for its test, its message
    and its usage text. Each test is its own site, read as `LOW..HIGH` so it
    compares with the manifest's range as one value.
    """
    scoped = scoped_lines(path, detail)
    if scoped is None:
        return None
    lines, name, offset = scoped
    constants = load_time_assignments(path.read_text(encoding="utf-8"))
    operand = r"(?:10#)?\$?\{?" + re.escape(name) + r"\}?"
    bound = r"(?P<{}>\w+)"
    test = re.compile(
        operand + r"\s*<\s*" + bound.format("low") + r"\s*\|\|\s*"
        + operand + r"\s*>\s*" + bound.format("high")
    )
    sites: list[tuple[str, set[str]]] = []
    for number, line in enumerate(lines):
        for match in test.finditer(line):
            low, high = (
                constants.get(match.group(side), match.group(side))
                for side in ("low", "high")
            )
            sites.append((f"the range test on line {offset + number + 1}", {f"{low}..{high}"}))
    return sites


def pattern_values(path: pathlib.Path, detail: str) -> list[tuple[str, set[str]]] | None:
    """The values named by `detail`, a line this file writes.

    `{value}` stands for one value, on a line the file writes once per value,
    so `[delta "catppuccin-{value}"]` reads the four Catppuccin sections of a
    git theme file as the four flavours they configure; together those lines
    are one site. `{values}` stands for the whole set written as `a|b|c` on one
    line, which is how a usage string states what a command accepts:
    `Usage: theme {{values}} [--preserve-wallpaper]`. Each such line is a site
    of its own, named by its line number, because a usage string that has
    fallen behind its own `case` is the prose copy nothing else reads.

    A line that opens with `#` or `;` is a comment in every file this kind
    reads (git configuration, shell), so it is left out before matching:
    `# [delta "catppuccin-frappe"]` configures nothing. Worse than nothing,
    in git's case -- the keys under it join the section above, so latte
    silently takes frappe's colours.
    """
    lines = [
        "" if line.lstrip().startswith(("#", ";")) else line
        for line in path.read_text(encoding="utf-8").splitlines()
    ]
    parts = re.split(r"(\{values?\})", detail)
    pattern = re.compile(
        "".join(
            r"(?P<value>[\w.-]+)" if part == "{value}"
            else r"(?P<values>[\w.-]+(?:\|[\w.-]+)*)" if part == "{values}"
            else re.escape(part)
            for part in parts
        )
    )
    if "{values}" in parts:
        return [
            (f"the line matching `{detail}` on line {number}",
             set(match.group("values").split("|")))
            for number, line in enumerate(lines, 1)
            for match in pattern.finditer(line)
        ]
    text = "\n".join(lines)
    return [(f"the lines matching `{detail}`", {m.group("value") for m in pattern.finditer(text)})]


def file_per_value(detail: str) -> list[tuple[str, set[str]]]:
    """The values a directory holds one file for.

    `theme-assets/.local/share/wallpapers/catppuccin-{value}.webp` is a file
    per flavour, and a flavour with no file is one whose install has nothing to
    stow; a file with no flavour is an asset nothing can select.

    A hyphen ends the value, because two patterns share a directory and a
    prefix there: `catppuccin-mocha-lock.webp` is the lock-screen wallpaper for
    `mocha`, not a desktop wallpaper for a flavour called `mocha-lock`.
    """
    prefix, _, suffix = detail.partition("{value}")
    directory = ROOT / pathlib.PurePosixPath(prefix).parent
    stem = pathlib.PurePosixPath(prefix).name
    name_pattern = re.compile(
        re.escape(stem) + r"(?P<value>[A-Za-z0-9_.]+)" + re.escape(suffix) + r"$"
    )
    found: set[str] = set()
    if directory.is_dir():
        for entry in directory.iterdir():
            match = name_pattern.match(entry.name)
            if match is not None:
                found.add(match.group("value"))
    return [(f"the files matching `{detail}`", found)]


def check_value_consumers(options: list[dict[str, str]]) -> int:
    """Each enumerated `values` column against the code that reads it.

    The column is the single authority for what `--theme` accepts: the
    installer validates against it, the resolved value is printed from it, and
    `render-installer-options.py` publishes it as fact. The runtime enum in
    `bin/.local/bin/theme` was a separate hand-written list that nothing
    compared with it, so adding a flavour to the manifest gave an install that
    ran every package, Stow and Mason step and then failed on its
    second-to-last plan step with "Invalid Catppuccin flavour".
    """
    errors = 0
    try:
        rows = read_tsv(CONSUMER_MANIFEST, CONSUMER_FIELDS)
    except ManifestSchemaError as error:
        for message in error.messages:
            fail(message)
        return 1

    enumerated: dict[tuple[str, str], dict[str, str]] = {}
    for option in options:
        if option["kind"] != "value" or option["values"] in {"", "-"}:
            continue
        key = (option["platform"], option["option"])
        values = option["values"]
        bounds = RANGE_VALUES.match(values)
        if bounds and int(bounds.group("low")) > int(bounds.group("high")):
            fail(f"{key[0]}: {key[1]} states the range {values}, whose low bound is "
                 f"above its high bound, so it accepts nothing")
            errors += 1
        elif not bounds and not LITERAL_VALUES.match(values):
            fail(f"{key[0]}: {key[1]} states its values as {values!r}, which is neither "
                 f"an enumeration (a|b|c) nor an integer range (LOW..HIGH); a pattern "
                 f"is published as fact and enforced nowhere this check can read")
            errors += 1
            continue
        enumerated[key] = option
    covered: set[tuple[str, str]] = set()
    for row in rows:
        matching = [
            key for key in enumerated
            if key[1] == row["option"] and row["platform"] in {"-", key[0]}
        ]
        if not matching:
            fail(f"{CONSUMER_MANIFEST.name}: {row['consumer']} is declared as reading "
                 f"{row['option']}, which no {row['platform']} option row enumerates")
            errors += 1
            continue
        # The option is claimed from here on: a row that cannot be read is an
        # error of its own, and reporting the option as unread on top of it
        # would say the registry names nothing when it names this.
        covered.update(matching)
        kind = row["kind"]
        if kind not in CONSUMER_READERS:
            fail(f"{CONSUMER_MANIFEST.name}: {row['consumer']} declares the kind "
                 f"{kind!r}, which this check cannot read")
            errors += 1
            continue
        path = ROOT / row["consumer"]
        if kind != "file-per-value" and not path.is_file():
            fail(f"{CONSUMER_MANIFEST.name}: {row['consumer']} does not exist")
            errors += 1
            continue
        if kind == "file-per-value":
            sites = file_per_value(row["consumer"])
        else:
            sites = CONSUMER_READERS[kind](path, row["detail"])
        if sites is None:
            scope = row["detail"].partition(":")[0]
            fail(f"{row['consumer']}: no function named {scope!r} to read the "
                 f"accepted {row['option']} values from; the registry says this file "
                 f"is what enforces them")
            errors += 1
            continue
        if not sites:
            shape = CONSUMER_SHAPES[kind](row["detail"] if kind != "file-per-value"
                                          else row["consumer"])
            fail(f"{row['consumer']}: no {shape} to read the accepted "
                 f"{row['option']} values from; the registry says this file is what "
                 f"enforces them")
            errors += 1
            continue
        for key in matching:
            values = enumerated[key]["values"]
            if RANGE_VALUES.match(values):
                for where, accepted in sites:
                    if accepted != {values}:
                        fail(f"{key[0]}: the manifest bounds {row['option']} to "
                             f"{values}, but {row['consumer']} enforces "
                             f"{', '.join(sorted(accepted))} in {where}; the published "
                             f"range and the one a run accepts disagree")
                        errors += 1
                continue
            declared = {value for value in values.split("|") if value}
            for where, accepted in sites:
                for value in sorted(declared - accepted):
                    fail(f"{key[0]}: the manifest offers {row['option']} {value!r}, "
                         f"which {row['consumer']} does not cover in {where}; a value "
                         f"a consumer does not know is one the install fails on after "
                         f"doing its work")
                    errors += 1
                for value in sorted(accepted - declared):
                    fail(f"{key[0]}: {row['consumer']} covers {row['option']} "
                         f"{value!r} in {where}, which the manifest does not offer, so "
                         f"nothing can select it")
                    errors += 1

    for key in sorted(enumerated.keys() - covered):
        fail(f"{key[0]}: the manifest enumerates {key[1]} values, but "
             f"{CONSUMER_MANIFEST.name} names nothing that reads them, so the list "
             f"is documented rather than enforced")
        errors += 1
    return errors


# How a consumer states the values it knows, by the `kind` column. A kind this
# table does not name is a build error rather than a row this check skips: a
# consumer whose shape cannot be read enforces nothing, and reading that as
# agreement is how the runtime enum drifted from the manifest in the first
# place.
CONSUMER_READERS = {
    "shell-case": case_values,
    "shell-array": array_values,
    "shell-word-list": loop_values,
    "lua-table": lua_table_keys,
    "powershell-validateset": validate_set_values,
    "line-pattern": pattern_values,
    "shell-range": range_bounds,
    "file-per-value": None,
}
# How each kind reads in a message, so a consumer that has stopped carrying the
# shape it is registered for is named in the words of the file it is in.
CONSUMER_SHAPES = {
    "shell-case": lambda detail: f'`case "${detail.rpartition(":")[2]}" in`',
    "shell-array": lambda detail: f"`{detail.rpartition(':')[2]}=(` array",
    "shell-word-list": lambda detail: f"`for {detail.rpartition(':')[2]} in` loop",
    "lua-table": lambda detail: f"`{detail} = {{` table",
    "powershell-validateset": lambda detail: f"`[ValidateSet(...)]` on `${detail}`",
    "line-pattern": lambda detail: f"line matching `{detail}`",
    "shell-range": lambda detail: (
        f"`(({detail.rpartition(':')[2]} < LOW || {detail.rpartition(':')[2]} > HIGH))` test"
    ),
    "file-per-value": lambda detail: f"file matching `{detail}`",
}


def load_time_assignments(text: str) -> dict[str, str]:
    """Each variable this text sets when it is run, as the literal it is set to.

    Function bodies are left out: a default is what the file assigns on its way
    to the argv loop, not what some function would assign if it were called.
    Quotes are dropped, so `ai_codex=''` reads as the empty string it is.
    """
    found: dict[str, str] = {}
    for line in outside_functions(text).splitlines():
        for match in ASSIGNMENT.finditer(code_line(line)):
            value = match.group("value")
            if value[:1] in {"'", '"'} and value[-1:] == value[:1]:
                value = value[1:-1]
            found[match.group("name")] = value
    return found


def declared_defaults(installer: pathlib.Path, platform: str) -> dict[str, str]:
    """The literal each variable holds when the installer starts parsing argv.

    A default stated through one variable is resolved one step, because that is
    how a default shared by every platform is written: `THEME_DEFAULT_FLAVOUR`
    lives in common/lib/theme-selection.sh and each installer assigns it. Its
    literal is as much a second statement of the manifest's default as an
    inline `true` is, so it is compared rather than skipped.
    """
    text = installer.read_text(encoding="utf-8")
    parser = PARSER.search(text)
    preamble = text[: parser.start()] if parser else text
    library: dict[str, str] = {}
    for path in sorted((ROOT / "common" / "lib").glob("*.sh")) + sorted(
        (ROOT / "platforms" / platform / "lib").glob("*.sh")
    ):
        library.update(load_time_assignments(path.read_text(encoding="utf-8")))
    resolved: dict[str, str] = {}
    for name, value in load_time_assignments(preamble).items():
        reference = REFERENCE.match(value)
        if reference and reference.group("name") in library:
            value = library[reference.group("name")]
        resolved[name] = value
    return resolved


# The `--dry-run` branch every platform installer opens the same way, up to the
# `fi` that closes it at the start of a line. Its persistent-option lines come
# from `plan_persistent_options`, which scripts/render-installer-usage.py
# generates from the manifest into lib/usage-options.sh: each under its
# manifest summary, showing the variable its own argv arm records.
DRY_RUN_BRANCH = re.compile(
    r'^if \[\[ "\$dry_run" == true \]\]; then\n(?P<body>.*?)^fi$',
    re.DOTALL | re.MULTILINE,
)
PLAN_CALL = re.compile(r"^[ \t]*plan_persistent_options[ \t]*$", re.MULTILINE)
# Where a selection is recorded for `--rerun`, and where the installer lists the
# capabilities it is about to act on.
SELECTION_SET = re.compile(r"^\s*install_selection_set (?P<option>[\w-]+) ", re.M)

def check_installer_wiring(
    platform: str, relative: str, options: list[dict[str, str]],
    bodies: dict[str, str], text: str,
) -> int:
    """The coupled sites a new capability has to be threaded through by hand.

    Adding one to an installer means editing nine places, and the parser arm and
    the default are the only two anything compared with the manifest. The rest
    were prose or plumbing: a capability could be declared, parsed and recorded
    while no step ever ran it, or be recorded under a name `--rerun` cannot
    replay, and every gate stayed green. The `--help` listing is generated from
    the manifest now, so the remaining hand-written sites are held to it here.

    The `--dry-run` summary is generated too. It was checked by asking whether
    each option's variable appeared anywhere in a hand-written heredoc, which
    never tied a variable to the label printed beside it: swapping two
    variables between their labels passed, and the plan a user reads before
    confirming printed `Sway session: false` above a rerun record saying
    `sway:true`. So the branch has to call the generated lines, and may not
    print an option's variable by hand beside them.
    """
    errors = 0
    branch = DRY_RUN_BRANCH.search(text)
    if branch is None:
        fail(f"{relative}: no `if [[ \"$dry_run\" == true ]]; then` branch found, so "
             f"the plan it prints cannot be compared with the manifest")
        return 1
    body = branch.group("body")
    if PLAN_CALL.search(body) is None:
        fail(f"{platform}: the `--dry-run` branch in {relative} never calls "
             f"plan_persistent_options, so the persistent options are resolved and "
             f"installed without the generated plan lines that show them")
        errors += 1

    # A selection is recorded under the option's own name, which is the key
    # `--rerun` replays it by, so the two sets are exactly each other.
    declared_options = {option["option"] for option in options}
    recorded = {match.group("option") for match in SELECTION_SET.finditer(text)}
    for name in sorted(recorded - declared_options):
        fail(f"{platform}: {relative} records a {name} selection, which the manifest "
             f"does not declare as an option of this platform, so ./install.sh "
             f"--rerun cannot replay it")
        errors += 1

    for option in options:
        name = option["option"]
        capability = option["capability"]
        if name not in recorded:
            fail(f"{platform}: {relative} never calls `install_selection_set {name}`, "
                 f"so the machine does not remember the option and ./install.sh "
                 f"--rerun forgets the selection")
            errors += 1
        if capability not in {"", "-"}:
            if f':{capability}"' not in text:
                fail(f"{platform}: {relative} does not list {capability} among the "
                     f"capabilities it reports as selected, so a run can install it "
                     f"without saying so")
                errors += 1
            # A tristate subcomponent is installed by its parent capability's
            # step rather than one of its own, so it owns no plan_add.
            if option["kind"] != "tristate" and not re.search(
                rf"plan_add {re.escape(capability)}\b", text
            ):
                fail(f"{platform}: {relative} has no `plan_add {capability}` step, so "
                     f"selecting {name} records the choice and installs nothing")
                errors += 1

        variable = recorded_variable(platform, option, bodies)
        if variable is None:
            continue
        shown = re.search(r"\$\{?" + re.escape(variable) + r"(?![\w])", body)
        if shown:
            line = text.count("\n", 0, branch.start("body") + shown.start()) + 1
            fail(f"{platform}: {relative}:{line} prints ${variable} in the `--dry-run` "
                 f"plan by hand; plan_persistent_options already shows {name} under its "
                 f"manifest summary, and a hand-written copy is the one that can sit "
                 f"beside the wrong label")
            errors += 1
    return errors


# A line of a hand-written `--help` listing: two spaces, then the flags it
# documents (`--kde/--no-kde`, `--codex/--no-codex, --firstmate`). An argv arm
# starts the same way and is told apart by the `)` or `|` that follows.
HELP_LINE = re.compile(r"^ {2}(?P<flags>--[\w-]+(?:(?:/|,\s*)--[\w-]+)*)(?P<after>.*)$")
USAGE_CALL = re.compile(r"^[ \t]*usage_persistent_options[ \t]*$", re.MULTILINE)


def check_usage_listing(
    platform: str, relative: str, options: list[dict[str, str]], installer: pathlib.Path,
) -> int:
    """The `--help` text lists the persistent options only through the generated call.

    Fedora's listing was generated and the other three platforms kept a
    hand-written copy of the `values` and `default` columns that nothing
    compared with anything: `(default: macchiato)` edited to `(default: mocha)`
    passed every gate while the installer went on defaulting to macchiato. So
    the help text has to call usage_persistent_options, and may not list a
    persistent flag by hand beside it. macOS keeps its help in lib/usage.sh,
    which the Bash 3.2 bootstrap prints too, so that file is read as well.
    """
    errors = 0
    sources = [installer]
    shared = installer.parent / "lib" / "usage.sh"
    if shared.is_file():
        sources.append(shared)
    persistent = {
        option[column]
        for option in options
        for column in ("on_flag", "off_flag")
        if option[column] not in {"", "-"}
    }
    called = False
    for source in sources:
        text = source.read_text(encoding="utf-8")
        called = called or USAGE_CALL.search(text) is not None
        where = source.relative_to(ROOT).as_posix()
        for number, line in enumerate(text.splitlines(), 1):
            match = HELP_LINE.match(line)
            if match is None or re.match(r"\s*[|)]", match.group("after")):
                continue
            for flag in re.findall(r"--[\w-]+", match.group("flags")):
                if flag in persistent:
                    fail(f"{platform}: {where}:{number} lists {flag} in the --help text by "
                         f"hand; usage_persistent_options already lists it from the "
                         f"manifest, and a hand-written copy is the one that drifts")
                    errors += 1
    if not called:
        fail(f"{platform}: {relative} never calls usage_persistent_options, so its "
             f"--help text does not list the persistent options the manifest declares")
        errors += 1
    return errors


def check_declared_defaults(
    platform: str, relative: str, options: list[dict[str, str]],
    bodies: dict[str, str], defaults: dict[str, str],
) -> int:
    """Each declared default against the value the installer starts with.

    The manifest and the generated reference both publish that column as fact,
    and nothing compared it with the `name=value` the installer actually starts
    from. Flipping `macos defaults` to false in the manifest and regenerating
    the documentation passed every validator, every render gate and every
    suite, while the installer went on defaulting it to true.
    """
    errors = 0
    for option in options:
        flag = option["on_flag"]
        if flag in {"", "-"} or flag not in bodies:
            continue
        assignment = ARM_ASSIGNMENT.search(bodies[flag])
        if assignment is None:
            continue
        variable = assignment.group("name")
        if variable not in defaults:
            fail(f"{platform}: {relative} records {flag} in ${variable}, which it "
                 f"never sets before parsing argv, so the option has no default "
                 f"to record")
            errors += 1
            continue
        declared = option["default"]
        expected = "" if declared in UNSET_DEFAULTS else declared
        found = defaults[variable]
        if found == expected:
            continue
        name = option["option"]
        fail(f"{platform}: the manifest gives {name} the default {declared!r}, "
             f"but {relative} starts with {variable}={found!r}; the generated "
             f"reference publishes the manifest's answer")
        errors += 1
    return errors


def main() -> int:
    errors = 0
    try:
        options = read_tsv(OPTION_MANIFEST, OPTION_FIELDS)
    except ManifestSchemaError as error:
        for message in error.messages:
            fail(message)
        return 1

    declared: dict[str, set[str]] = {}
    for option in options:
        flags = declared.setdefault(option["platform"], set())
        for column in ("on_flag", "off_flag"):
            if option[column] not in {"", "-"}:
                flags.add(option[column])

    errors += check_value_consumers(options)

    installers = {
        path.parent.name: path for path in sorted(ROOT.glob("platforms/*/install.sh"))
    }
    for platform in sorted(set(declared) - set(installers)):
        fail(f"{platform}: the manifest declares options, but "
             f"platforms/{platform}/install.sh does not exist")
        errors += 1

    for platform, installer in installers.items():
        relative = installer.relative_to(ROOT).as_posix()
        try:
            flags = parser_flags(installer)
        except UnreadableParser as unreadable:
            fail(f"{relative}: an argv arm could not be parsed: {unreadable}. Until it "
                 f"is read, which flags that arm accepts is unknown, which is not the "
                 f"same as none")
            errors += 1
            continue
        if flags is None:
            fail(f"{relative}: no `while (($#)); do case \"$1\" in` argv parser found")
            errors += 1
            continue
        accepted, rejected, bodies = flags
        manifest = declared.get(platform, set())
        deliberate = REJECTED_FLAGS.get(platform, set())

        for flag in sorted(manifest):
            if flag in TRANSIENT_FLAGS:
                fail(f"{platform}: {flag} is a transient control and must not be a "
                     f"persistent option")
                errors += 1
            elif flag in rejected:
                fail(f"{platform}: the manifest declares {flag}, but {relative} "
                     f"rejects it")
                errors += 1
            elif flag not in accepted:
                fail(f"{platform}: the manifest declares {flag}, but {relative} "
                     f"has no case arm for it")
                errors += 1

        for flag in sorted(accepted - manifest - TRANSIENT_FLAGS):
            fail(f"{platform}: {relative} accepts {flag}, which the manifest does "
                 f"not declare, so ./install.sh --rerun can never remember it")
            errors += 1
        for flag in sorted(manifest & accepted):
            if ONLY_SHIFTS.match(bodies[flag]):
                fail(f"{platform}: {relative} accepts {flag} and only shifts past it, "
                     f"so nothing records the selection and ./install.sh --rerun "
                     f"forgets it")
                errors += 1
        for flag in sorted(accepted & deliberate):
            fail(f"{platform}: {flag} is listed in REJECTED_FLAGS, but {relative} "
                 f"accepts it")
            errors += 1

        for flag in sorted(rejected - manifest - TRANSIENT_FLAGS - deliberate):
            fail(f"{platform}: {relative} rejects {flag}; list it in REJECTED_FLAGS "
                 f"with the reason")
            errors += 1
        for flag in sorted(deliberate - rejected - accepted):
            fail(f"{platform}: {flag} is listed in REJECTED_FLAGS, but {relative} "
                 f"has no case arm that rejects it")
            errors += 1

        platform_options = [
            option for option in options if option["platform"] == platform
        ]
        errors += check_declared_defaults(
            platform,
            relative,
            platform_options,
            bodies,
            declared_defaults(installer, platform),
        )
        errors += check_usage_listing(platform, relative, platform_options, installer)
        errors += check_installer_wiring(
            platform,
            relative,
            platform_options,
            bodies,
            read_committed(installer),
        )

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
