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

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
