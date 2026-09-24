#!/usr/bin/env python3
"""Manual acceptance records must be checkable evidence, not prose.

`docs/testing/manual-acceptance/` holds the checklists a person works through
on real hardware, and `records/` beside them holds what was observed. A record
is only worth committing if a later reader can trust three things about it:
which commit and which day it describes, that every item of its checklist was
given a verdict in the one shared vocabulary, and that it carries nothing
personal about the machine it describes. Each of those is checked here, and
each is the kind of thing that quietly goes wrong in a hand-written file:

1. **The record names what was tested.** A full 40-character commit SHA, an
   ISO date that is a real day, neither in the future nor before the commit,
   and the hardware, operating system, installer command and selected options.
   When the history is present, the commit must be an ancestor of `HEAD`: a
   record naming a typo, or a commit that never reached this branch, describes
   nothing in this tree. A shallow clone cannot answer that, and this says so
   instead of passing silently.
2. **Every item has exactly one verdict.** The record's results table lists
   every item of the checklist it names, once, with one of `pass`, `fail`,
   `not observed` or `not applicable`. A missing row is the silent gap the
   records exist to prevent; a free-form word such as "ok" or "skipped" is a
   verdict nobody can compare. Every outcome other than `pass` carries a note.
   And the verdict agrees with the record's own selection: where an item's
   **Applies when** is decided by installer options -- "`-Handy` is selected",
   "`-SkipNoctty` was not passed" -- an item the record's installer command
   and selected options make inapplicable must say `not applicable`, and one
   they make applicable must not. The README says the outcome "is decided by
   the selection and the hardware, never by what was convenient to test"; a
   record passing WIN-07 while its own command omitted `-Handy` used to pass
   every gate (#539, V5-18).
3. **Nothing personal.** Email addresses, MAC addresses, IP addresses outside
   the documentation ranges, `*.ts.net` tailnet names, UUIDs, serial-number
   fields and home-directory paths are refused. The report names the line and
   the kind of match and never the matched text, so the CI log does not repeat
   what the record should not have contained.

The checklists are held to their own shape too, because the records are
checked against them: every item has an ID and states its boundary, when it
applies, what to do and what counts as a pass, and each checklist's copyable
results table lists exactly its items with every outcome still blank.

A record or checklist this cannot parse is a failure, never a skipped file.

Usage:
    scripts/validate-acceptance-records.py [--root DIR]
"""

from __future__ import annotations

import argparse
import datetime
import ipaddress
import pathlib
import re
import subprocess
import sys

ACCEPTANCE_DIR = pathlib.Path("docs") / "testing" / "manual-acceptance"
RECORDS = "records"
NOT_CHECKLISTS = {"README.md", "template.md"}

OUTCOMES = ("pass", "fail", "not observed", "not applicable")
NOTE_REQUIRED = {"fail", "not observed", "not applicable"}

RECORD_FIELDS = (
    "Checklist",
    "Commit",
    "Date",
    "Hardware",
    "Firmware",
    "Operating system",
    "Installer command",
    "Selected options",
)
RECORD_SECTIONS = ("Record", "Commands", "Results", "Known exclusions")
ITEM_FIELDS = ("Boundary", "Applies when", "Do", "Pass when")

RECORD_NAME = re.compile(
    r"^(?P<date>\d{4}-\d{2}-\d{2})-(?P<checklist>[a-z0-9]+(?:-[a-z0-9]+)*)"
    r"-(?P<sha>[0-9a-f]{7,40})\.md$"
)
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
PLACEHOLDER = re.compile(r"<[^<>]*>")
FENCE = re.compile(r"^\s*```")
SECTION = re.compile(r"^##\s+(?P<title>.+?)\s*$")
SUBSECTION = re.compile(r"^###\s+(?P<title>.+?)\s*$")
ITEM_ID = re.compile(r"^(?P<id>(?P<prefix>[A-Z]{3})-\d{2})\s+\S")
SEPARATOR_CELL = re.compile(r"^:?-+:?$")
# One option clause of an **Applies when** condition. A clause is a necessary
# condition: several joined by "and" must all hold, and a condition with "or"
# in it is not decided here, because either side might be what applied.
OPTION_CLAUSE = re.compile(
    r"`(?P<flag>-{1,2}[A-Za-z][A-Za-z0-9-]*)`\s+"
    r"(?P<verb>is selected|is not selected|was passed|was not passed)"
)
DISJUNCTION = re.compile(r"\bor\b", re.IGNORECASE)
# What is left of a condition that is nothing but option clauses.
ONLY_CLAUSES = re.compile(r"^[\s.,;()]*(?:and[\s.,;()]*)*$", re.IGNORECASE)
# An option as a record states it: a flag on the command line, or a `name:value`
# pair of the reconstructed selection.
FLAG_TOKEN = re.compile(r"(?<![\w-])(-{1,2}[A-Za-z][A-Za-z0-9-]*)")
SELECTION_PAIR = re.compile(r"(?<![\w-])([A-Za-z][A-Za-z0-9_-]*)\s*[:=]\s*([^\s,]+)")
UNSELECTED_VALUES = {"false", "off", "no", "none", "0", "disabled"}

# --- Personal-data shapes -------------------------------------------------

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
# The one address a checklist legitimately names: the SSH login GitHub uses.
ALLOWED_EMAILS = {"git@github.com"}
MAC = re.compile(r"(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])")
IPV4 = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
IPV6 = re.compile(r"(?<![0-9A-Fa-f:])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?![0-9A-Fa-f:])")
TAILNET = re.compile(r"\b[\w-]+(?:\.[\w-]+)*\.ts\.net\b", re.IGNORECASE)
UUID = re.compile(
    r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"
    # An Apple device UDID, the other identifier System Information prints.
    r"|\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"
)
SERIAL = re.compile(r"\b(?:serial(?:[ _-]?(?:number|no\.?))?|s/n)\s*[:=|]\s*\S", re.IGNORECASE)
HOME_PATH = re.compile(
    r"(?<![\w.~-])/(?:home|Users)/(?!(?:Shared|linuxbrew)(?:/|\b))[A-Za-z0-9._-]+"
    r"|\b[A-Za-z]:\\Users\\(?!(?:Public|Default)\\)[^\\\s|`]+",
)

# Documentation ranges (RFC 5737, RFC 3849) and addresses that identify no one.
PUBLIC_EXAMPLE_NETWORKS = [
    ipaddress.ip_network(network)
    for network in (
        "192.0.2.0/24",
        "198.51.100.0/24",
        "203.0.113.0/24",
        "127.0.0.0/8",
        "0.0.0.0/32",
        "2001:db8::/32",
        "::1/128",
    )
]


class Problems(list):
    def add(self, path: pathlib.Path, line: int | None, message: str) -> None:
        where = f"{path}:{line}" if line else f"{path}"
        self.append(f"{where}: {message}")


def table_cells(line: str) -> list[str] | None:
    """The cells of one Markdown table row, or None if it is not a row."""
    body = line.strip()
    if not (body.startswith("|") and body.endswith("|") and len(body) > 1):
        return None
    parts = re.split(r"(?<!\\)\|", body[1:-1])
    return [part.strip() for part in parts]


def is_separator(cells: list[str]) -> bool:
    return all(SEPARATOR_CELL.match(cell) for cell in cells)


def unquote(value: str) -> str:
    if len(value) >= 2 and value.startswith("`") and value.endswith("`"):
        return value[1:-1].strip()
    return value


def split_sections(lines: list[str]) -> dict[str, list[tuple[int, str]]]:
    """Level-two sections, keyed by title, with their lines outside fences.

    A fenced block's lines are dropped from the section body: a `|` or a `###`
    inside a code block is text, not a table row or an item.
    """
    sections: dict[str, list[tuple[int, str]]] = {}
    current: list[tuple[int, str]] | None = None
    fence = False
    for number, line in enumerate(lines, 1):
        if FENCE.match(line):
            fence = not fence
            continue
        if fence:
            continue
        match = SECTION.match(line)
        if match:
            current = sections.setdefault(match.group("title"), [])
            continue
        if current is not None:
            current.append((number, line))
    return sections


def read_table(
    path: pathlib.Path,
    body: list[tuple[int, str]],
    header: list[str],
    what: str,
    problems: Problems,
) -> list[tuple[int, list[str]]] | None:
    """The data rows of the first table in `body`, which must have `header`.

    Returns None, having reported why, when there is no such table or a row
    does not have the header's width.
    """
    rows = [(number, table_cells(line)) for number, line in body]
    rows = [(number, cells) for number, cells in rows if cells is not None]
    if not rows:
        problems.add(path, None, f"{what}: no table found")
        return None
    first_number, first = rows[0]
    if first != header:
        problems.add(
            path, first_number,
            f"{what}: the table header must be | {' | '.join(header)} |",
        )
        return None
    data = []
    ok = True
    for number, cells in rows[1:]:
        if is_separator(cells):
            continue
        if len(cells) != len(header):
            problems.add(
                path, number,
                f"{what}: row has {len(cells)} cells, expected {len(header)}; "
                "escape a literal pipe as \\|",
            )
            ok = False
            continue
        data.append((number, cells))
    return data if ok else None


# --- Checklists -----------------------------------------------------------


def read_checklist(path: pathlib.Path, problems: Problems) -> tuple[str, list[str]] | None:
    """Validate one checklist; return its ID prefix and item IDs in order."""
    lines = path.read_text(encoding="utf-8").splitlines()
    sections = split_sections(lines)
    items_body = sections.get("Items")
    if items_body is None:
        problems.add(path, None, "checklist has no '## Items' section")
        return None

    ids: list[str] = []
    prefixes: set[str] = set()
    current: str | None = None
    seen_fields: dict[str, set[str]] = {}
    applies: dict[str, str] = {}
    reading: str | None = None
    ok = True

    for number, line in items_body:
        heading = SUBSECTION.match(line)
        if heading:
            match = ITEM_ID.match(heading.group("title"))
            if not match:
                problems.add(
                    path, number,
                    "item heading must start with an ID such as FED-01 and a title",
                )
                ok = False
                current = None
                continue
            current = match.group("id")
            if current in ids:
                problems.add(path, number, f"item ID {current} is used twice")
                ok = False
            ids.append(current)
            prefixes.add(match.group("prefix"))
            seen_fields[current] = set()
            continue
        if current is None:
            continue
        field = re.match(r"^- \*\*(?P<field>[^*]+?):\*\*(?P<text>.*)$", line)
        if field:
            seen_fields[current].add(field.group("field"))
            reading = field.group("field")
            if reading == "Applies when":
                applies[current] = field.group("text").strip()
        elif reading == "Applies when" and line.startswith("  ") and line.strip():
            # A hard-wrapped condition continues on indented lines.
            applies[current] += " " + line.strip()
        else:
            reading = None

    for item in ids:
        missing = [name for name in ITEM_FIELDS if name not in seen_fields.get(item, set())]
        if missing:
            problems.add(
                path, None,
                f"item {item} is missing {', '.join('**' + name + ':**' for name in missing)}",
            )
            ok = False

    if not ids:
        problems.add(path, None, "checklist has no items")
        return None
    if len(prefixes) != 1:
        problems.add(
            path, None,
            f"every item ID in one checklist must share one prefix, found {sorted(prefixes)}",
        )
        return None

    results_body = sections.get("Results table")
    if results_body is None:
        problems.add(path, None, "checklist has no '## Results table' section")
        return None
    rows = read_table(path, results_body, ["ID", "Outcome", "Notes"], "results table", problems)
    if rows is None:
        return None
    listed = [cells[0] for _, cells in rows]
    if listed != ids:
        problems.add(
            path, None,
            "the results table must list exactly the items, in order: "
            f"items {ids}, table {listed}",
        )
        ok = False
    for number, cells in rows:
        if cells[1] or cells[2]:
            problems.add(
                path, number,
                f"the results table is copied into records, so {cells[0]}'s outcome "
                "and notes must stay blank",
            )
            ok = False

    return (prefixes.pop(), ids, applies) if ok else None


# --- Records --------------------------------------------------------------


def git(root: pathlib.Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(root), *arguments],
        capture_output=True,
        text=True,
        check=False,
    )


class History:
    """What this checkout's Git history can say about a record's commit."""

    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        inside = git(root, "rev-parse", "--is-inside-work-tree")
        self.repository = inside.returncode == 0 and inside.stdout.strip() == "true"
        shallow = git(root, "rev-parse", "--is-shallow-repository") if self.repository else None
        self.shallow = bool(shallow and shallow.stdout.strip() == "true")
        head = git(root, "rev-parse", "--verify", "--quiet", "HEAD") if self.repository else None
        self.has_head = bool(head and head.returncode == 0)

    def has_commit(self, sha: str) -> bool:
        return git(self.root, "cat-file", "-e", f"{sha}^{{commit}}").returncode == 0

    def is_ancestor(self, sha: str) -> bool | None:
        result = git(self.root, "merge-base", "--is-ancestor", sha, "HEAD")
        if result.returncode == 0:
            return True
        if result.returncode == 1:
            return False
        return None

    def commit_date(self, sha: str) -> datetime.date | None:
        result = git(self.root, "show", "-s", "--format=%cs", sha)
        try:
            return datetime.date.fromisoformat(result.stdout.strip())
        except ValueError:
            return None


def check_commit(
    path: pathlib.Path,
    number: int,
    sha: str,
    date: datetime.date | None,
    history: History,
    problems: Problems,
    notes: list[str],
) -> None:
    if not history.repository or not history.has_head:
        notes.append(
            f"{path}: NOT OBSERVED: whether commit {sha} is in this history was not "
            "checked, because this tree has no Git history to ask"
        )
        return
    if not history.has_commit(sha):
        if history.shallow:
            notes.append(
                f"{path}: NOT OBSERVED: commit {sha} is not in this shallow clone, so "
                "its ancestry was not checked; fetch the full history to check it"
            )
        else:
            problems.add(path, number, f"commit {sha} does not exist in this repository's history")
        return
    ancestor = history.is_ancestor(sha)
    if ancestor is None:
        problems.add(path, number, f"could not determine whether commit {sha} is an ancestor of HEAD")
    elif not ancestor:
        problems.add(
            path, number,
            f"commit {sha} is not an ancestor of HEAD; a record must describe a commit "
            "in the history it is added to",
        )
    committed = history.commit_date(sha)
    if committed is None:
        problems.add(path, number, f"could not read the date of commit {sha}")
    elif date is not None and date < committed:
        problems.add(
            path, number,
            f"the record is dated {date.isoformat()}, before its commit was made "
            f"({committed.isoformat()})",
        )


def check_privacy(path: pathlib.Path, lines: list[str], problems: Problems) -> None:
    for number, line in enumerate(lines, 1):
        found: list[str] = []
        if any(match.group(0).lower() not in ALLOWED_EMAILS for match in EMAIL.finditer(line)):
            found.append("an email address")
        if MAC.search(line):
            found.append("a MAC address")
        cells = table_cells(line)
        # A four-part version number, such as a WSL kernel's, has the shape of
        # an IPv4 address. The Record table's version rows are where one lives.
        version_row = bool(cells) and "version" in cells[0].lower()
        if not version_row:
            for match in IPV4.finditer(line):
                try:
                    address = ipaddress.ip_address(match.group(0))
                except ValueError:
                    continue
                if not any(address in network for network in PUBLIC_EXAMPLE_NETWORKS):
                    found.append("an IP address outside the documentation ranges")
                    break
        for match in IPV6.finditer(line):
            token = match.group(0)
            if token.count(":") < 3 or sum(1 for group in token.split(":") if group) < 2:
                continue
            try:
                address = ipaddress.ip_address(token)
            except ValueError:
                continue
            if not any(address in network for network in PUBLIC_EXAMPLE_NETWORKS):
                found.append("an IP address outside the documentation ranges")
                break
        if TAILNET.search(line):
            found.append("a tailnet (*.ts.net) name")
        if UUID.search(line):
            found.append("a UUID or device identifier")
        if SERIAL.search(line):
            found.append("a serial-number field")
        if HOME_PATH.search(line):
            found.append("a home-directory path naming an account; write it from ~")
        for kind in dict.fromkeys(found):
            problems.add(path, number, f"contains {kind}; records must not carry personal data")


def selected_options(fields: dict[str, tuple[int, str]]) -> set[str]:
    """Every option the record's installer command and selection name as chosen.

    Compared without dashes, underscores or case, so `--secure-boot`,
    `secure_boot:true` and PowerShell's case-insensitive `-handy` all name the
    option their checklist spells `--secure-boot` or `-Handy`.
    """
    chosen: set[str] = set()
    for field in ("Installer command", "Selected options"):
        value = fields.get(field, (0, ""))[1]
        for flag in FLAG_TOKEN.findall(value):
            chosen.add(option_key(flag))
        for name, setting in SELECTION_PAIR.findall(value):
            if setting.strip("`").lower() not in UNSELECTED_VALUES:
                chosen.add(option_key(name))
    return chosen


def option_key(option: str) -> str:
    return re.sub(r"[-_]", "", option).lower()


def applicability(condition: str, chosen: set[str]) -> tuple[bool, bool] | None:
    """Whether the selection makes the item applicable, and whether that is all.

    None when the condition names no option or is a disjunction. Otherwise
    (applies, decided): `applies` is False when any option clause fails, and
    `decided` says the condition is nothing but option clauses, so their
    holding makes the item applicable rather than merely not excluded.
    """
    if DISJUNCTION.search(condition):
        return None
    clauses = list(OPTION_CLAUSE.finditer(condition))
    if not clauses:
        return None
    applies = True
    for clause in clauses:
        present = option_key(clause.group("flag")) in chosen
        wanted = clause.group("verb") in ("is selected", "was passed")
        if present != wanted:
            applies = False
    decided = ONLY_CLAUSES.match(OPTION_CLAUSE.sub("", condition)) is not None
    return applies, decided


def check_record(
    path: pathlib.Path,
    checklists: dict[str, list[str] | None],
    conditions: dict[str, dict[str, str]],
    history: History,
    today: datetime.date,
    problems: Problems,
    notes: list[str],
) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    check_privacy(path, lines, problems)

    name = RECORD_NAME.match(path.name)
    if not name:
        problems.add(
            path, None,
            "record file name must be YYYY-MM-DD-<checklist>-<short-sha>.md",
        )

    sections = split_sections(lines)
    for title in RECORD_SECTIONS:
        if title not in sections:
            problems.add(path, None, f"record has no '## {title}' section")

    fields: dict[str, tuple[int, str]] = {}
    record_body = sections.get("Record")
    if record_body is not None:
        rows = read_table(path, record_body, ["Field", "Value"], "Record table", problems)
        for number, (field, value) in rows or []:
            if field in fields:
                problems.add(path, number, f"Record field '{field}' appears twice")
            fields[field] = (number, value)
    for field in RECORD_FIELDS:
        if record_body is None:
            break
        if field not in fields:
            problems.add(path, None, f"Record table has no '{field}' field")
            continue
        number, value = fields[field]
        if not unquote(value):
            problems.add(path, number, f"Record field '{field}' is empty")
        elif PLACEHOLDER.search(value):
            problems.add(path, number, f"Record field '{field}' still holds a template placeholder")

    # Commit and date.
    sha = None
    date = None
    if "Commit" in fields:
        number, value = fields["Commit"]
        value = unquote(value)
        if FULL_SHA.match(value):
            sha = value
        elif value and not PLACEHOLDER.search(fields["Commit"][1]):
            problems.add(
                path, number,
                "Commit must be the full 40-character lowercase SHA that git rev-parse HEAD prints",
            )
    if "Date" in fields:
        number, value = fields["Date"]
        value = unquote(value)
        if ISO_DATE.match(value):
            try:
                date = datetime.date.fromisoformat(value)
            except ValueError:
                problems.add(path, number, f"Date {value} is not a real calendar date")
        elif value and not PLACEHOLDER.search(fields["Date"][1]):
            problems.add(path, number, "Date must be an ISO date, YYYY-MM-DD")
        # One day of grace for a record written in a time zone ahead of the
        # machine checking it; anything later has not happened yet.
        if date is not None and date > today + datetime.timedelta(days=1):
            problems.add(path, number, f"Date {date.isoformat()} is in the future")
    if sha is not None:
        check_commit(path, fields["Commit"][0], sha, date, history, problems, notes)

    # The checklist it follows.
    checklist_ids: list[str] | None = None
    checklist_conditions: dict[str, str] = {}
    checklist_stem = None
    if "Checklist" in fields:
        number, value = fields["Checklist"]
        value = unquote(value)
        if value and not PLACEHOLDER.search(fields["Checklist"][1]):
            if value not in checklists:
                known = ", ".join(sorted(checklists)) or "none"
                problems.add(path, number, f"Checklist {value} is not a checklist here (known: {known})")
            else:
                checklist_ids = checklists[value]
                checklist_conditions = conditions.get(value, {})
                checklist_stem = value.removesuffix(".md")

    # The file name agrees with the record.
    if name:
        if date is not None and name.group("date") != date.isoformat():
            problems.add(path, None, f"file name date {name.group('date')} does not match Date {date.isoformat()}")
        if checklist_stem is not None and name.group("checklist") != checklist_stem:
            problems.add(
                path, None,
                f"file name names checklist {name.group('checklist')}, but the record follows {checklist_stem}",
            )
        if sha is not None and not sha.startswith(name.group("sha")):
            problems.add(path, None, f"file name commit {name.group('sha')} is not a prefix of Commit {sha}")

    # One verdict per item.
    results_body = sections.get("Results")
    if results_body is None:
        return
    rows = read_table(path, results_body, ["ID", "Outcome", "Notes"], "Results table", problems)
    if rows is None:
        return
    seen: dict[str, int] = {}
    chosen = selected_options(fields)
    for number, (item, outcome, note) in rows:
        if item in seen:
            problems.add(path, number, f"{item} has more than one result (first on line {seen[item]})")
            continue
        seen[item] = number
        if checklist_ids is not None and item not in checklist_ids:
            problems.add(path, number, f"{item} is not an item of the checklist this record follows")
        outcome = unquote(outcome)
        if outcome not in OUTCOMES:
            problems.add(
                path, number,
                f"{item}: outcome must be one of {', '.join(OUTCOMES)}"
                + (" (it is empty)" if not outcome else ""),
            )
        elif outcome in NOTE_REQUIRED and not note:
            problems.add(path, number, f"{item}: a '{outcome}' outcome needs a note saying why")
        if outcome in OUTCOMES and item in checklist_conditions:
            decision = applicability(checklist_conditions[item], chosen)
            if decision is None:
                continue
            applies, decided = decision
            condition = checklist_conditions[item]
            if not applies and outcome != "not applicable":
                problems.add(
                    path, number,
                    f"{item} applies when {condition!r}, which this record's installer "
                    f"command and selected options do not meet, so its outcome is "
                    f"'not applicable', not '{outcome}'",
                )
            elif applies and decided and outcome == "not applicable":
                problems.add(
                    path, number,
                    f"{item} applies when {condition!r}, which this record's installer "
                    f"command and selected options meet, so it cannot be 'not applicable'",
                )
    if checklist_ids is not None:
        missing = [item for item in checklist_ids if item not in seen]
        if missing:
            problems.add(path, None, f"no result for {', '.join(missing)}; every item needs an outcome")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    directory = root / ACCEPTANCE_DIR
    problems = Problems()
    notes: list[str] = []

    if not directory.is_dir():
        problems.add(ACCEPTANCE_DIR, None, "the manual acceptance directory is missing")
    else:
        checklists: dict[str, list[str] | None] = {}
        conditions: dict[str, dict[str, str]] = {}
        prefixes: dict[str, str] = {}
        for path in sorted(directory.glob("*.md")):
            if path.name in NOT_CHECKLISTS:
                continue
            result = read_checklist(path, problems)
            if result is None:
                # Known, so a record naming it is not also told it does not exist.
                checklists[path.name] = None
                continue
            prefix, ids, applies = result
            conditions[path.name] = applies
            if prefix in prefixes:
                problems.add(path, None, f"item prefix {prefix} is also used by {prefixes[prefix]}")
            prefixes[prefix] = path.name
            checklists[path.name] = ids
        if not checklists:
            problems.add(ACCEPTANCE_DIR, None, "no checklist found")

        records = directory / RECORDS
        if records.exists():
            history = History(root)
            today = datetime.date.today()
            for path in sorted(records.iterdir()):
                if not path.is_file() or path.suffix != ".md":
                    problems.add(path, None, "records/ may hold only record .md files")
                    continue
                check_record(path, checklists, conditions, history, today, problems, notes)

    for note in notes:
        print(f"Acceptance records: {_relative(note, root)}", file=sys.stderr)
    for problem in problems:
        print(f"Acceptance records: {_relative(problem, root)}", file=sys.stderr)
    return 1 if problems else 0


def _relative(message: str, root: pathlib.Path) -> str:
    prefix = f"{root}/"
    return message[len(prefix):] if message.startswith(prefix) else message


if __name__ == "__main__":
    raise SystemExit(main())
