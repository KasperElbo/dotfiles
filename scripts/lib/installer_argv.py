"""How a platform installer's argv parser is read, shared by checker and generator.

`scripts/validate-install-options.py` compares the flags each installer's
`while (($#)); do case "$1" in` loop accepts with `config/install-options.tsv`,
and `scripts/render-installer-usage.py` generates the lines `--dry-run` prints
for those options. Both have to agree on which variable an option's arm records
its selection in -- the generator prints it, the checker compares its default
-- so that reading lives here once rather than in two copies that could come to
disagree about it.
"""

from __future__ import annotations

import pathlib
import re

# The first assignment in an arm's body is the variable that arm records the
# selection in.
ARM_ASSIGNMENT = re.compile(r"(?P<name>[A-Za-z_]\w*)=")
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


# A capability a dry-run line shows through a derived display variable rather
# than the one its arm records, with the reason. `--kde` and `--latex` are
# tri-valued (enabled, disabled, auto) and the summary prints the answer the run
# resolved rather than the request, so `$bool_kde` is the honest thing to show.
# Listing it here is what keeps a deliberate indirection from reading as a
# missing line.
DISPLAY_VARIABLES = {
    ("fedora", "kde"): "bool_kde",
    ("fedora", "latex"): "bool_latex",
}


def recorded_variable(
    platform: str, option: dict[str, str], bodies: dict[str, str]
) -> str | None:
    """The variable a `--dry-run` plan shows for `option`, or None.

    That is the first variable the option's own argv arm assigns -- the one the
    installer goes on to act on -- unless DISPLAY_VARIABLES names the resolved
    form it is shown through instead. None means the option has no arm that
    assigns anything, which the manifest checks report on their own.
    """
    flag = option["on_flag"]
    if flag in {"", "-"} or flag not in bodies:
        return None
    assignment = ARM_ASSIGNMENT.search(bodies[flag])
    if assignment is None:
        return None
    return DISPLAY_VARIABLES.get((platform, option["option"])) or assignment.group("name")
