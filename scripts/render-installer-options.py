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

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import supported_platforms  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
OPTIONS = ROOT / "config" / "install-options.tsv"
CAPABILITIES = ROOT / "config" / "capabilities.tsv"
TARGET = ROOT / "docs" / "reference" / "installer-options.md"

# Titles and guide paths are human-authored; which platforms exist is not.
# supported_platforms() decides the set and the order, and a platform missing
# a title or a guide below fails rather than rendering an unlabelled section.
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
# manifest row by design; `install-selection.sh` documents why. Not all of them
# are universal, so each one says which platforms accept it: `--dev-workflows`
# is rejected outright by the CTF guest, whose installer runs no smoke tests.
# `None` means every supported platform.
TRANSIENT = [
    ("`--platform PLATFORM`", None,
     "Select the platform installer: {platforms}. Selects which "
     "`platforms/NAME/install.sh` runs."),
    ("`--rerun`", None,
     "Reapply this machine's last successful configuration. See [rerun.md](../workflows/rerun.md)."),
    ("`--dry-run`", None, "Resolve and print the plan; change nothing."),
    ("`--non-interactive`", None,
     "Use defaults without prompting; requires cached sudo where sudo is needed."),
    ("`--dev-workflows`", ("fedora", "fedora-wsl", "macos"),
     "Run the disposable development-workflow smoke tests after installing."),
    ("`-h`, `--help`", None,
     "Print the platform installer's own help, which is authoritative for this checkout."),
]


def platforms_in_order() -> list[str]:
    platforms = list(supported_platforms())
    missing = [
        platform for platform in platforms
        if platform not in PLATFORM_TITLES or platform not in PLATFORM_GUIDES
    ]
    if missing:
        print(f"No title or platform guide for: {', '.join(missing)}", file=sys.stderr)
        raise SystemExit(1)
    return platforms


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

    supported = platforms_in_order()
    for platform in supported:
        title = PLATFORM_TITLES[platform]
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
    lines.append("| Control | Platforms | Meaning |")
    lines.append("|---|---|---|")
    for control, platforms, meaning in TRANSIENT:
        if platforms is None:
            accepted = "all"
        else:
            missing = [platform for platform in platforms if platform not in supported]
            if missing:
                print(f"{control} names platforms that are not supported: {', '.join(missing)}",
                      file=sys.stderr)
                raise SystemExit(1)
            accepted = ", ".join(f"`{platform}`" for platform in supported if platform in platforms)
        rendered_platforms = ", ".join(
            f"`{platform}`" + (" (default)" if platform == supported[0] else "")
            for platform in supported
        )
        lines.append(
            f"| {control} | {accepted} | {meaning.format(platforms=rendered_platforms)} |"
        )
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
