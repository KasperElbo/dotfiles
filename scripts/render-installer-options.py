#!/usr/bin/env python3
"""Render the installer's persistent-option reference from its own manifest.

`config/install-options.tsv` is the one place a persistent option's flag
spelling, kind, default and permitted values live; the installer's parser and
the `--rerun` selection model both read it. This renders the same data as the
documentation table, so a documented option can never be one the installer does
not have — or the other way around.

Transient execution controls are deliberately not in that manifest (they belong
to a single invocation, not to a machine's configuration), so they are listed
here from a fixed list, next to the command that prints the authoritative help.

Usage:
    scripts/render-installer-options.py [--check]
"""

from __future__ import annotations

import csv
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
OPTIONS = ROOT / "config" / "install-options.tsv"
CAPABILITIES = ROOT / "config" / "capabilities.tsv"
TARGET = ROOT / "docs" / "reference" / "installer-options.md"

PLATFORM_TITLES = {
    "fedora": "Fedora workstation (`--platform fedora`, the default)",
    "fedora-wsl": "Fedora on WSL (`--platform fedora-wsl`)",
    "macos": "Apple Silicon macOS (`--platform macos`)",
    "parrot-ctf": "Parrot Security Edition CTF guest (`--platform parrot-ctf`)",
}

PLATFORM_GUIDES = {
    "fedora": "../platforms/fedora.md",
    "fedora-wsl": "../platforms/fedora-wsl.md",
    "macos": "../platforms/macos.md",
    "parrot-ctf": "../platforms/parrot-ctf.md",
}

# Controls that apply to one invocation and are never remembered. They have no
# manifest row by design; `install-selection.sh` documents why.
TRANSIENT = [
    ("`--platform PLATFORM`", "Select the platform installer: `fedora` (default), `fedora-wsl`, `macos`, `parrot-ctf`."),
    ("`--rerun`", "Reapply this machine's last successful configuration. See [rerun.md](../workflows/rerun.md)."),
    ("`--dry-run`", "Resolve and print the plan; change nothing."),
    ("`--non-interactive`", "Use defaults without prompting; requires cached sudo where sudo is needed."),
    ("`--dev-workflows`", "Run the disposable development-workflow smoke tests after installing."),
    ("`-h`, `--help`", "Print the platform installer's own help, which is authoritative for this checkout."),
]


def code(value: str) -> str:
    # A pipe inside a table cell has to be escaped, or the cell splits.
    return "—" if value in {"", "-"} else "`" + value.replace("|", "\\|") + "`"


def render() -> str:
    with OPTIONS.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    with CAPABILITIES.open(newline="", encoding="utf-8") as stream:
        capability_rows = list(csv.DictReader(stream, delimiter="\t"))

    capability_docs = {
        (row["capability"], row["platform"]): row["docs"]
        for row in capability_rows
        if row["status"] == "implemented"
    }

    lines = [
        "# Installer options",
        "",
        "Generated from `config/install-options.tsv`; do not edit these tables by",
        "hand. Run `./scripts/render-installer-options.py` after changing the manifest.",
        "",
        "That manifest is the single source for every option this machine can",
        "*remember*: the installer's parser, the `--rerun` selection record and these",
        "tables all read it. An option missing from a platform's table below is one",
        "that platform's installer rejects rather than silently ignores.",
        "",
        "`Default` is what the option resolves to when it is not given. `auto` means",
        "the installer detects or asks; see the platform guide for which.",
        "",
    ]

    for platform, title in PLATFORM_TITLES.items():
        platform_rows = [row for row in rows if row["platform"] == platform]
        lines.append(f"## {title}")
        lines.append("")
        if not platform_rows:
            lines.append("This platform declares no persistent options.")
            lines.append("")
            continue
        lines.append(f"Platform guide: [{PLATFORM_GUIDES[platform]}]({PLATFORM_GUIDES[platform]})")
        lines.append("")
        lines.append("| Option | Enable | Disable | Default | Values | Summary | Capability | Documented in |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for row in platform_rows:
            capability = row["capability"]
            docs = capability_docs.get((capability, platform), "")
            if docs:
                path, _, anchor = docs.partition("#")
                target = f"../../{path}" if not path.startswith("docs/") else f"../{path[len('docs/'):]}"
                documented = f"[{path}]({target}{'#' + anchor if anchor else ''})"
            else:
                documented = "—"
            lines.append(
                "| "
                + " | ".join(
                    [
                        f"`{row['option']}`",
                        code(row["on_flag"]),
                        code(row["off_flag"]),
                        code(row["default"]),
                        code(row["values"]),
                        row["summary"],
                        code(capability),
                        documented,
                    ]
                )
                + " |"
            )
        lines.append("")

    lines.append("## Execution controls")
    lines.append("")
    lines.append(
        "These control one invocation and are never part of the remembered"
    )
    lines.append(
        "configuration, so they have no manifest row. `./install.sh --help` prints the"
    )
    lines.append("authoritative list for this checkout.")
    lines.append("")
    lines.append("| Control | Meaning |")
    lines.append("|---|---|")
    for control, meaning in TRANSIENT:
        lines.append(f"| {control} | {meaning} |")
    lines.append("")

    rendered = "\n".join(line.rstrip() for line in lines).replace("\n\n\n", "\n\n")
    # Exactly one trailing newline: a blank line at end of file is whitespace
    # damage, and `git diff --check` rejects it.
    return rendered.rstrip("\n") + "\n"


def main() -> int:
    content = render()
    if "--check" in sys.argv:
        if not TARGET.exists() or TARGET.read_text(encoding="utf-8") != content:
            print(f"Generated installer-option reference is stale: {TARGET}", file=sys.stderr)
            print("Run ./scripts/render-installer-options.py", file=sys.stderr)
            return 1
        return 0
    TARGET.write_text(content, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
