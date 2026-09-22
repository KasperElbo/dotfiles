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
from shell import outside_functions, strip_noise  # noqa: E402

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
# The first assignment in an arm's body is the variable that arm records the
# selection in.
ARM_ASSIGNMENT = re.compile(r"(?P<name>[A-Za-z_]\w*)=")
# A `values` column that enumerates literals, as opposed to one that states a
# pattern: `--charge-limit`'s `[4-9][0-9]|100` is a shape, and there is no set
# of words for a consumer to agree with.
LITERAL_VALUES = re.compile(r"^[\w.-]+(?:\|[\w.-]+)*$")
# One case arm's pattern, at the start of its own line, which is how every
# consumer in the registry writes one.
CASE_ARM = re.compile(r"^[ \t]*(?P<pattern>[^()\n]+?)\)")
# A bare word alternative: an accepted value. `*` and `""` are the arms for
# everything else and for nothing, neither of which names a value.
CASE_VALUE = re.compile(r"^[\w.-]+$")

PARSER = re.compile(
    r'while \(\(\$#\)\); do\s*case "\$1" in\n(?P<arms>.*?)\n\s*esac\s*\n\s*done',
    re.DOTALL,
)
# What ends a case arm. `;&` and `;;&` fall through to the next arm rather than
# leaving the case, and an arm is just as real for ending in one: reading only
# `;;` let the previous arm's body run past a `;&` and swallow the pattern of
# the arm after it, which then accepted a flag nothing in this check had seen.
TERMINATOR = r";;&|;;|;&"
# One alternative of an arm's pattern: `--kde`, or a glob such as `--jobs=*`,
# which is how a parser accepts `--jobs=4` in one word. `=` is not a word
# character, so an arm written that way used to line up with no `)` at all and
# the flag it accepts went unchecked in both directions.
ALTERNATIVE = r"-[\w-]*(?:=\*)?"
# One case arm: a pattern of `-flag | --other` alternatives, then its body up
# to the terminator that ends it. Arms share lines (`--kde) …; shift ;; --no-kde)
# …`), so an arm starts at a line start or right after the previous arm's
# terminator.
ARM = re.compile(
    r"(?:^|" + TERMINATOR + r")[ \t]*"
    r"(?P<pattern>" + ALTERNATIVE + r"(?:[ \t]*\|[ \t]*" + ALTERNATIVE + r")*)"
    r"\)(?P<body>.*?)(?=" + TERMINATOR + r")",
    re.DOTALL | re.MULTILINE,
)
# Every arm, read only far enough to see the pattern it matches on. This is
# what makes an arm shape ARM cannot read an error rather than a silent
# omission: a flag arm the strict pattern skipped is a flag this check never
# compared against the manifest, in either direction.
ANY_ARM = re.compile(r"(?:^|" + TERMINATOR + r")[ \t]*(?P<pattern>[^\n)]*)\)", re.MULTILINE)
# Whether an arm's pattern names a flag at all. `*)` and a bare word arm are
# not this check's business; anything with a `-word` alternative is.
FLAG_ALTERNATIVE = re.compile(r"(?:^|\|)\s*-")
# An arm that refuses its flags rather than accepting them. The word boundary
# matters: `die_if_wsl` is a check the arm runs before accepting the flag, and
# reading it as a refusal reported the flag as rejected on a platform that
# takes it.
REJECTION = re.compile(r"die\b")
# What a persistent option's arm does beyond moving past its own argument. An
# arm that only shifts accepts the flag and records nothing, so the machine
# forgets the selection and `./install.sh --rerun` silently drops it.
ONLY_SHIFTS = re.compile(r"^(?:shift(?:\s+\d+)?\s*;?\s*)+$")


def fail(message: str) -> None:
    print(f"installer option parser: {message}", file=sys.stderr)


class UnreadableParser(Exception):
    """An argv arm this check cannot read, which is never the same as none."""


def parser_flags(
    installer: pathlib.Path,
) -> tuple[set[str], set[str], dict[str, str]] | None:
    """The flags a parser accepts, the flags it rejects, and each arm's body.

    An arm whose pattern this check cannot read raises rather than being
    skipped. Skipping takes the flag out of the comparison in both directions
    at once -- the parser accepts it and the manifest is never asked about it
    -- which is the failure this check exists to prevent.
    """
    match = PARSER.search(installer.read_text(encoding="utf-8"))
    if match is None:
        return None
    arms = match.group("arms")
    accepted: set[str] = set()
    rejected: set[str] = set()
    bodies: dict[str, str] = {}
    read = {arm.start("pattern") for arm in ARM.finditer(arms)}
    for arm in ANY_ARM.finditer(arms):
        pattern = arm.group("pattern").strip()
        if not FLAG_ALTERNATIVE.search(pattern) or arm.start("pattern") in read:
            continue
        raise UnreadableParser(pattern)
    for arm in ARM.finditer(arms):
        flags = {flag.strip() for flag in arm.group("pattern").split("|")}
        body = arm.group("body").strip()
        if REJECTION.match(body):
            rejected |= flags
        else:
            accepted |= flags
            for flag in flags:
                bodies[flag] = body
    return accepted, rejected, bodies


def code_line(line: str) -> str:
    """One line with its comment dropped and everything else left as written.

    `strip_noise` is what finds the comment, because a `#` inside quotes opens
    none, and it keeps every character's position while blanking quoted text.
    That blanking is wrong here -- a value and a case subject are both written
    inside quotes -- so the comment's start is taken from the blanked line and
    the code is read out of the original.
    """
    return line[: len(strip_noise(line))]


def case_values(path: pathlib.Path, variable: str) -> set[str] | None:
    """The values a `case "$variable" in` accepts, or None when there is none.

    Read as shell: a name in a comment is not an arm. Only bare word
    alternatives count, so the `*)` and `"")` arms -- everything else, and
    nothing -- are left out rather than read as values.
    """
    lines = [code_line(line) for line in path.read_text(encoding="utf-8").splitlines()]
    head = re.compile(r"""case\s+"?\$\{?""" + re.escape(variable) + r"""\}?"?\s+in\b""")
    start = next((number for number, line in enumerate(lines) if head.search(line)), None)
    if start is None:
        return None
    found: set[str] = set()
    for line in lines[start + 1 :]:
        if line.strip() == "esac":
            break
        match = CASE_ARM.match(line)
        if match is None:
            continue
        for alternative in match.group("pattern").split("|"):
            alternative = alternative.strip()
            if CASE_VALUE.match(alternative):
                found.add(alternative)
    return found


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

    enumerated = {
        (option["platform"], option["option"]): option
        for option in options
        if option["kind"] == "value" and LITERAL_VALUES.match(option["values"] or "")
    }
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
        path = ROOT / row["consumer"]
        if not path.is_file():
            fail(f"{CONSUMER_MANIFEST.name}: {row['consumer']} does not exist")
            errors += 1
            continue
        if row["kind"] != "shell-case":
            fail(f"{CONSUMER_MANIFEST.name}: {row['consumer']} declares the kind "
                 f"{row['kind']!r}, which this check cannot read")
            errors += 1
            continue
        accepted = case_values(path, row["detail"])
        if accepted is None:
            fail(f"{row['consumer']}: no `case \"${row['detail']}\" in` to read the "
                 f"accepted {row['option']} values from; the registry says this file "
                 f"is what enforces them")
            errors += 1
            continue
        for key in matching:
            covered.add(key)
            declared = {value for value in enumerated[key]["values"].split("|") if value}
            for value in sorted(declared - accepted):
                fail(f"{key[0]}: the manifest offers {row['option']} {value!r}, which "
                     f"{row['consumer']} does not accept; a selection it refuses is "
                     f"one the install fails on after doing its work")
                errors += 1
            for value in sorted(accepted - declared):
                fail(f"{key[0]}: {row['consumer']} accepts {row['option']} {value!r}, "
                     f"which the manifest does not offer, so nothing can select it")
                errors += 1

    for key in sorted(enumerated.keys() - covered):
        fail(f"{key[0]}: the manifest enumerates {key[1]} values, but "
             f"{CONSUMER_MANIFEST.name} names nothing that reads them, so the list "
             f"is documented rather than enforced")
        errors += 1
    return errors


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

        errors += check_declared_defaults(
            platform,
            relative,
            [option for option in options if option["platform"] == platform],
            bodies,
            declared_defaults(installer, platform),
        )

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
