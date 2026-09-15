#!/usr/bin/env python3
"""Render the complete action reference from config/actions.tsv.

The reference lives inside docs/reference/keybindings.md, between two markers,
so the page keeps its hand-written discovery guidance while the exhaustive
table stays derived from the registry. Every registered action appears here —
including the ones marked `print=false`, which is precisely the difference
between this page and a printable cheat sheet.

Usage:
    scripts/render-action-reference.py [--check]
"""

from __future__ import annotations

import csv
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import supported_platforms  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "config" / "actions.tsv"

# "all" is the registry's own sentinel for an action every platform carries; the
# rest come from config/capabilities.tsv, so a new platform needs no edit here
# beyond its human-authored title below.
SECTION_PLATFORMS = ("all",) + supported_platforms()
TARGET = ROOT / "docs" / "reference" / "keybindings.md"
BEGIN = "<!-- BEGIN GENERATED ACTION REFERENCE -->"
END = "<!-- END GENERATED ACTION REFERENCE -->"

PLATFORM_TITLES = {
    "all": "Every platform",
    "fedora": "Fedora workstation",
    "fedora-wsl": "Fedora on WSL",
    "macos": "Apple Silicon macOS",
    "parrot-ctf": "Parrot Security Edition CTF guest",
}
DISCOVERABILITY_TITLES = {
    "whichkey": "WhichKey",
    "tool-help": "the tool's own help",
    "shell-help": "`shell-integrations` / `--help`",
    "status-bar": "the status bar itself",
    "config-only": "the tracked config",
    "documented": "documentation only",
}


def escape(value: str) -> str:
    return value.replace("|", "\\|")


def render() -> str:
    with REGISTRY.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t", quoting=csv.QUOTE_NONE))

    lines = [
        BEGIN,
        "",
        "<!-- Generated from config/actions.tsv by scripts/render-action-reference.py.",
        "     Do not edit between these markers; edit the registry and regenerate. -->",
        "",
        "## Complete action reference",
        "",
        f"Every action this repository defines or deliberately puts in front of you: "
        f"{len(rows)} entries, grouped by the platform they exist on.",
        "",
        "**Origin** is the distinction that matters when something behaves unexpectedly.",
        "`repository` means this repository binds it, and the `Source` column says where.",
        "`upstream` means the tool ships it and installing that tool is all this",
        "repository did — report those upstream, not here.",
        "",
        "**Print** says whether the action is on a printable cheat sheet. The sheets are",
        "curated to one or two A4 pages per profile, so `no` is a deliberate editorial",
        "choice with a recorded reason, never an omission.",
        "",
    ]

    for platform in SECTION_PLATFORMS:
        platform_rows = [row for row in rows if row["platform"] == platform]
        if not platform_rows:
            continue
        lines.append(f"### {PLATFORM_TITLES[platform]}")
        lines.append("")
        for component in sorted({row["component"] for row in platform_rows}):
            component_rows = [row for row in platform_rows if row["component"] == component]
            lines.append(f"#### {component}")
            lines.append("")
            lines.append("| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |")
            lines.append("|---|---|---|---|---|---|---|---|")
            for row in sorted(component_rows, key=lambda item: item["id"]):
                source = "—" if row["source"] in {"", "-"} else f"`{row['source']}`"
                printed = "yes" if row["print"] == "true" else "no"
                lines.append(
                    "| "
                    + " | ".join(
                        [
                            f"`{escape(row['binding'])}`",
                            escape(row["action"]),
                            row["input"],
                            row["origin"],
                            f"`{row['profile']}`",
                            DISCOVERABILITY_TITLES.get(row["discoverability"], row["discoverability"]),
                            printed,
                            escape(source),
                        ]
                    )
                    + " |"
                )
            lines.append("")

    excluded = [row for row in rows if row["print"] == "false"]
    lines.append("### Why an action is not on a printable sheet")
    lines.append("")
    lines.append(
        f"{len(excluded)} of the {len(rows)} registered actions are deliberately kept off "
        "every sheet:"
    )
    lines.append("")
    lines.append("| Action | Reason |")
    lines.append("|---|---|")
    for row in sorted(excluded, key=lambda item: item["id"]):
        lines.append(f"| `{row['id']}` | {escape(row['print_reason'])} |")
    lines.append("")
    lines.append(END)
    return "\n".join(lines)


def splice(existing: str, generated: str) -> str:
    start = existing.find(BEGIN)
    finish = existing.find(END)
    if start == -1 or finish == -1:
        raise SystemExit(
            f"{TARGET} has no generated-action-reference markers; add {BEGIN} and {END}"
        )
    return existing[:start] + generated + existing[finish + len(END):]


def main() -> int:
    existing = TARGET.read_text(encoding="utf-8")
    updated = splice(existing, render())
    if "--check" in sys.argv:
        if existing != updated:
            print(f"Generated action reference is stale: {TARGET}", file=sys.stderr)
            print("Run ./scripts/render-action-reference.py", file=sys.stderr)
            return 1
        return 0
    TARGET.write_text(updated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
