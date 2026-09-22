#!/usr/bin/env python3
"""Render the human-facing support/ownership table from capabilities.tsv."""

from __future__ import annotations

import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from generated import check_or_write  # noqa: E402
from manifests import read_tsv, registered_platforms  # noqa: E402

root = pathlib.Path(__file__).resolve().parents[1]
manifest = pathlib.Path(
    os.environ.get("CAPABILITY_MANIFEST", root / "config" / "capabilities.tsv")
)
target = root / "docs" / "reference" / "capability-matrix.md"

# Column headings are human-authored; which columns exist is not. A platform
# the manifest models without a heading here fails rather than rendering an
# unlabelled column. Every platform with a row gets one, including the Windows
# host, which this repository installs and verifies without `./install.sh`
# being able to run it.
PLATFORM_HEADINGS = {
    "fedora": "Fedora",
    "fedora-wsl": "Fedora WSL",
    "macos": "macOS",
    "parrot-ctf": "Parrot CTF",
    "windows": "Windows",
}

platforms = list(registered_platforms(manifest))
missing_headings = [platform for platform in platforms if platform not in PLATFORM_HEADINGS]
if missing_headings:
    print(f"No column heading for platform(s): {', '.join(missing_headings)}", file=sys.stderr)
    raise SystemExit(1)

rows = read_tsv(manifest)

capabilities = sorted({row["capability"] for row in rows})
lookup = {(row["capability"], row["platform"]): row for row in rows}
headings = " | ".join(PLATFORM_HEADINGS[platform] for platform in platforms)
lines = [
    "# Generated capability support matrix",
    "",
    "Generated from `config/capabilities.tsv`; do not edit this table by hand.",
    "",
    "A column is a platform this repository installs, which is not the same as a",
    "platform `./install.sh --platform` accepts: the Windows host is installed by",
    "`platforms/windows/install.ps1` and verified by `platforms/windows/verify.ps1`,",
    "and is answerable to this registry on the same terms as the rest.",
    "",
    "A cell reads one of three ways, and the difference matters:",
    "",
    "- `✓ <provider>` — supported on that platform, installed and owned by that provider.",
    "- `— <owner>` — deliberately absent, with the named owner of that absence:",
    "  `unsupported` (this repository does not provide it there), `windows-host`",
    "  (the Windows side of a WSL install owns it) or `user-managed` (a person",
    "  installs it themselves).",
    "- `—` alone — not modelled: the manifest has no row for that pair, so this",
    "  repository has taken no position on it either way.",
    "",
    f"| Capability | {headings} |",
    "|---|" + "---|" * len(platforms),
]
for capability in capabilities:
    cells = []
    for platform in platforms:
        row = lookup.get((capability, platform))
        if row is None:
            cells.append("—")
        elif row["status"] == "implemented":
            cells.append(f"✓ `{row['provider']}`")
        else:
            cells.append(f"— {row['provider']}")
    lines.append(f"| `{capability}` | " + " | ".join(cells) + " |")
content = "\n".join(lines) + "\n"

raise SystemExit(
    check_or_write(
        target,
        content,
        sys.argv,
        stale="Generated capability matrix is stale",
        remedy="./scripts/render-capability-matrix.py",
    )
)
