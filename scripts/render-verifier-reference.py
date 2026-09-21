#!/usr/bin/env python3
"""Render the per-platform verifier inventory from capabilities.tsv.

`config/capabilities.tsv` already names the verifier that proves each
capability on each platform, and `scripts/doctor.sh` reads that column to tell
a machine which verifiers apply to it. This generator turns the same column
into the document a person reads, so no guide has to keep a hand-maintained
list of verifiers that drifts the moment one is added.
"""

from __future__ import annotations

import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import read_tsv, registered_platforms  # noqa: E402

root = pathlib.Path(__file__).resolve().parents[1]
manifest = pathlib.Path(
    os.environ.get("CAPABILITY_MANIFEST", root / "config" / "capabilities.tsv")
)
target = root / "docs" / "reference" / "verifiers.md"

# Section headings are human-authored; which platforms exist is not. A platform
# the manifest models without a heading here fails rather than rendering an
# unlabelled section. Every platform with a row appears, including the Windows
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
    print(f"No section heading for platform(s): {', '.join(missing_headings)}", file=sys.stderr)
    raise SystemExit(1)

rows = read_tsv(manifest)

lines = [
    "# Generated verifier reference",
    "",
    "Generated from `config/capabilities.tsv`; do not edit these tables by hand.",
    "",
    "Each row is one verifier script, the capabilities it proves on that",
    "platform, and the installer flags that select those capabilities — a",
    "PowerShell switch of `platforms/windows/install.ps1` on the Windows host,",
    "whose installer and verifier are both PowerShell. The flags are what an",
    "install asks for — not arguments to the verifier: most verifiers read the",
    "recorded lifecycle state instead of taking options. See",
    "[the verification workflow](../workflows/verification.md) for the few that do",
    "take arguments, and for what a failure versus a warning means.",
    "",
    "A capability with no row here is not verified on that platform, for one of two",
    "reasons: the manifest records it as deliberately absent there, or the manifest",
    "has no row for that pair at all. [The capability matrix](capability-matrix.md)",
    "tells those apart and names who owns each deliberate absence.",
]
for platform in platforms:
    verifiers: dict[str, dict[str, list[str]]] = {}
    for row in rows:
        if row["platform"] != platform or row["status"] != "implemented":
            continue
        if row["verifier"] in ("", "-", "none"):
            continue
        entry = verifiers.setdefault(row["verifier"], {"capabilities": [], "flags": []})
        entry["capabilities"].append(row["capability"])
        if row["cli_flag"] not in ("", "-"):
            entry["flags"].append(row["cli_flag"])
    lines += [
        "",
        f"## {PLATFORM_HEADINGS[platform]}",
        "",
        "| Verifier | Capabilities it proves | Selected by |",
        "|---|---|---|",
    ]
    for verifier in sorted(verifiers):
        entry = verifiers[verifier]
        capabilities = ", ".join(f"`{name}`" for name in sorted(entry["capabilities"]))
        flags = ", ".join(f"`{flag}`" for flag in sorted(entry["flags"])) or "always installed"
        lines.append(f"| `{verifier}` | {capabilities} | {flags} |")
content = "\n".join(lines) + "\n"

if "--check" in sys.argv:
    if not target.exists() or target.read_text(encoding="utf-8") != content:
        print(f"Generated verifier reference is stale: {target}", file=sys.stderr)
        raise SystemExit(1)
else:
    target.write_text(content, encoding="utf-8")
