#!/usr/bin/env python3
"""Render each platform installer's persistent-option text from its manifest.

Adding a capability to an installer means editing nine coupled places in
`platforms/<platform>/install.sh`, and two of them are prose: the `--help`
listing and the dry-run summary. Prose is where drift is invisible --- nothing
fails when a flag the parser accepts is missing from the help text, or when a
help line describes a flag that was renamed. `--tailscale/--no-tailscale` shows
both halves of it: the flag is real, its help line carries no description at
all, and `config/install-options.tsv` has had "Tailscale networking profile"
for that row the whole time.

So both are generated from the manifest the parser already reads, for every
platform that declares options:

* `usage_persistent_options` prints the `--help` listing. Fedora was the only
  platform generated at first; the other three kept a hand-written restatement
  of the `values` and `default` columns that no gate compared with anything, so
  `(default: macchiato)` edited to `(default: mocha)` passed while the installer
  went on defaulting to macchiato.
* `plan_persistent_options` prints the `--dry-run` lines, each option under its
  manifest summary and showing the variable its own argv arm records. The
  hand-written summary was checked only for each variable appearing somewhere,
  so two variables swapped between their labels passed and the plan printed
  `Sway session: false` above a rerun record saying `sway:true`.

The generated functions live in their own file rather than spliced into a
heredoc, because a heredoc has no comments: `# BEGIN GENERATED` inside one
would print. A whole generated file also means the drift gate compares the
whole file, which is the exact comparison the other `render --check` gates
make.

Transient execution controls --- `--dry-run`, `--non-interactive`, `--help` and
the platform's own one-run flags --- are deliberately not in that manifest, so
they stay hand-written in the installer, after the call to the generated
function.

Usage:
    scripts/render-installer-usage.py [--platform NAME] [--check]
"""

from __future__ import annotations

import pathlib
import re
import shlex
import sys
import textwrap

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from generated import check_or_write  # noqa: E402
from installer_argv import UnreadableParser, parser_flags, recorded_variable  # noqa: E402
from manifests import read_tsv  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
OPTIONS = ROOT / "config" / "install-options.tsv"


# `--help` is read in a terminal, so the listing is wrapped rather than left to
# the terminal's own folding, which would break the flag column.
WIDTH = 79
# Where a summary starts, measured from the start of the line. The installers
# have used this column since the first help text; keeping it means the
# generated block sits flush with the hand-written controls below it.
SUMMARY_COLUMN = 21
INDENT = "  "


def target_for(platform: str) -> pathlib.Path:
    return ROOT / "platforms" / platform / "lib" / "usage-options.sh"


# The two shapes a `values` column takes: lower-case words separated by `|`, as
# `latte|frappe|macchiato|mocha` and `ga402xz|ga402rk` are, or an integer range,
# `40..100`. Both are listed from the column itself, so the help text states
# the range the installer and the recorded selection read rather than a copy.
LITERAL_VALUES = re.compile(r"^[a-z0-9][a-z0-9+-]*(?:\|[a-z0-9][a-z0-9+-]*)*$")
RANGE_VALUES = re.compile(r"^(?P<low>\d+)\.\.(?P<high>\d+)$")


# What a `value` option's argument is called in the listing. The manifest says
# an option takes a value and not what to call it, and a generic `VALUE` is
# worse than what the hand-written text had: `--theme FLAVOUR` tells a reader
# which vocabulary to reach for and `--theme VALUE` does not. So the word is
# named here, per option, and an option missing from this table is an error
# rather than a silent `VALUE` --- adding a value option should require the
# choice, not default past it.
VALUE_PLACEHOLDERS = {
    "theme": "FLAVOUR",
    "hardware": "MODEL",
    "charge-limit": "N",
}

# What the `--dry-run` plan prints for an option the run leaves unset. A
# default of `inherit` is its own word; a default of `-` means "not given",
# which reads differently per option -- no hardware profile is `disabled`, no
# charge limit leaves the firmware's `unchanged` -- so it is named here, and an
# option missing from this table is an error for the same reason as above.
UNSET_WORDS = {
    "hardware": "disabled",
    "charge-limit": "unchanged",
}

# Where the `--dry-run` values start: a label that fits is padded to this
# width, the column the Fedora plan has always used, and a longer one is
# followed by a single space.
PLAN_LABEL_WIDTH = 20


class MissingPlaceholder(Exception):
    """A `value` option with no word for its argument, or its absence."""


def flag_spec(platform: str, row: dict[str, str]) -> str:
    """How the option is spelled on the command line."""
    on_flag = row["on_flag"]
    off_flag = row["off_flag"]
    if row["kind"] == "value":
        placeholder = VALUE_PLACEHOLDERS.get(row["option"])
        if placeholder is None:
            raise MissingPlaceholder(
                f"{platform}: {row['option']} takes a value, and no word for it is "
                f"named in VALUE_PLACEHOLDERS in scripts/render-installer-usage.py"
            )
        return f"{on_flag} {placeholder}"
    if off_flag and off_flag != "-":
        return f"{on_flag}/{off_flag}"
    return on_flag


def summary_text(row: dict[str, str]) -> str:
    """The option's one-line description, with its values and its default.

    The default is stated for every option rather than only the interesting
    ones. `false` is as much a fact about the installer as `auto` is, and an
    option whose default changes in the manifest should change here without
    anybody remembering to.
    """
    parts = [row["summary"]]
    values = row["values"]
    bounds = RANGE_VALUES.match(values or "")
    if bounds:
        parts.append(f": {bounds.group('low')}-{bounds.group('high')}")
    elif values and values != "-" and LITERAL_VALUES.match(values):
        parts.append(": " + ", ".join(values.split("|")))
    default = row["default"]
    if default and default != "-":
        parts.append(f" (default: {default})")
    return "".join(parts)


def render_lines(platform: str, rows: list[dict[str, str]]) -> list[str]:
    """One help line per option, wrapped, with the flag column aligned."""
    specs = [(flag_spec(platform, row), summary_text(row)) for row in rows]
    # A flag too long for the shared column gets its summary on the next line
    # rather than pushing every other summary to the right.
    column = SUMMARY_COLUMN
    lines: list[str] = []
    for spec, summary in specs:
        head = f"{INDENT}{spec}"
        wrapped = textwrap.wrap(summary, width=WIDTH - column) or [""]
        if len(head) + 1 <= column:
            lines.append(f"{head.ljust(column)}{wrapped[0]}".rstrip())
            continuation = wrapped[1:]
        else:
            lines.append(head)
            continuation = wrapped
        lines.extend(f"{' ' * column}{piece}" for piece in continuation)
    return lines


def installer_for(platform: str) -> pathlib.Path:
    return ROOT / "platforms" / platform / "install.sh"


class UnplannedOption(Exception):
    """An option the dry-run plan cannot show, because no arm records it."""


def plan_expression(platform: str, row: dict[str, str], variable: str) -> str:
    """The shell word the plan prints for one option's resolved value."""
    default = row["default"]
    if default == "inherit":
        return f'"${{{variable}:-inherit}}"'
    if default == "-":
        word = UNSET_WORDS.get(row["option"])
        if word is None:
            raise MissingPlaceholder(
                f"{platform}: {row['option']} is unset unless given, and what the "
                f"plan prints then is not named in UNSET_WORDS in "
                f"scripts/render-installer-usage.py"
            )
        return f'"${{{variable}:-{word}}}"'
    return f'"${variable}"'


def plan_lines(platform: str, rows: list[dict[str, str]]) -> list[str]:
    """The `printf` arguments the plan prints, one label and value per option.

    The variable is read from the installer's own argv arm for the option's
    flag, so the line labelled with an option's summary shows what that
    option's flag set, by construction rather than by a hand-kept pairing.
    """
    parsed = parser_flags(installer_for(platform))
    if parsed is None:
        raise UnplannedOption(
            f"platforms/{platform}/install.sh: no `while (($#)); do case \"$1\" in` "
            f"argv parser found, so no option can be tied to what it records"
        )
    _, _, bodies = parsed
    lines = []
    for row in rows:
        variable = recorded_variable(platform, row, bodies)
        if variable is None:
            raise UnplannedOption(
                f"platforms/{platform}/install.sh: the {row['on_flag']} arm assigns "
                f"nothing, so the plan has no value to show for {row['option']}"
            )
        label = shlex.quote(f"{row['summary']}:")
        lines.append(f"    {label} {plan_expression(platform, row, variable)}")
    return [
        line + (" \\" if index < len(lines) - 1 else "")
        for index, line in enumerate(lines)
    ]


def render(platform: str, rows: list[dict[str, str]]) -> str:
    listing = render_lines(platform, rows)
    plan = plan_lines(platform, rows)
    body = [
        "#!/usr/bin/env bash",
        "# Generated by scripts/render-installer-usage.py from",
        "# config/install-options.tsv. Do not edit; run that script after changing",
        "# the manifest.",
        "#",
        "# The persistent options this platform's installer accepts -- the ones a",
        "# machine remembers and --rerun replays. The manifest is what the parser",
        "# and the rerun record already read, so a flag listed here that the",
        "# installer does not accept, or accepted and not listed, cannot happen.",
        "#",
        "# Transient execution controls belong to a single invocation rather than to",
        "# a machine's configuration, so they are not in the manifest and stay",
        f"# hand-written in platforms/{platform}/install.sh after this listing.",
        "",
        "usage_persistent_options() {",
        "  cat <<'EOF'",
        *listing,
        "EOF",
        "}",
        "",
        "# The same options as the --dry-run plan shows them: each under its manifest",
        "# summary, with the value of the variable its own argv arm records, so a line",
        "# cannot show one option's value beside another option's label.",
        "plan_persistent_options() {",
        "  # shellcheck disable=SC2154 # The installer that sources this file sets them.",
        f"  printf '%-{PLAN_LABEL_WIDTH}s %s\\n' \\",
        *plan,
        "}",
        "",
    ]
    return "\n".join(body)


def main() -> int:
    argv = sys.argv[1:]
    platform = None
    if "--platform" in argv:
        index = argv.index("--platform")
        if index + 1 >= len(argv):
            print("--platform requires a name", file=sys.stderr)
            return 2
        platform = argv[index + 1]

    rows = read_tsv(OPTIONS)
    # Every platform the manifest declares options for, in manifest order: a
    # platform whose text is hand-written is one whose values and defaults no
    # gate compares with anything.
    declared = list(dict.fromkeys(row["platform"] for row in rows))
    platforms = [platform] if platform else declared

    status = 0
    for name in platforms:
        platform_rows = [row for row in rows if row["platform"] == name]
        if not platform_rows:
            print(
                f"{OPTIONS} declares no options for {name}, so its help text "
                f"cannot be generated",
                file=sys.stderr,
            )
            return 1
        try:
            content = render(name, platform_rows)
        except (MissingPlaceholder, UnplannedOption) as missing:
            print(missing, file=sys.stderr)
            return 1
        except UnreadableParser as unreadable:
            print(f"platforms/{name}/install.sh: an argv arm could not be parsed: "
                  f"{unreadable}", file=sys.stderr)
            return 1
        status |= check_or_write(
            target_for(name),
            content,
            argv,
            stale=f"Generated {name} installer help and plan text is stale",
            remedy=f"./scripts/render-installer-usage.py --platform {name}",
        )
    return status


if __name__ == "__main__":
    raise SystemExit(main())
