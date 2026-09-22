#!/usr/bin/env python3
"""Render the per-platform install flows inside docs/architecture/installation.md.

Each platform installer registers its steps with `plan_add`, and that ordered
list is what `--dry-run` prints and what an apply run executes. The flow
diagrams on the architecture page used to restate that order by hand, which is
exactly the kind of second copy that goes stale: a step added to an installer
does not touch the prose.

This reads the `plan_add` calls straight out of `platforms/*/install.sh`, in
source order, and renders one table per platform. A call that starts its own
line is always planned; one guarded by a conditional — `[[ … ]] || plan_add …`,
or a call indented inside an `if` block — is conditional, and the condition is
what the installer's own options decide.

`./scripts/lint.sh` runs this with `--check`.

Usage:
    scripts/render-install-flows.py [--check]
"""

from __future__ import annotations

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from generated import check_or_write, read_committed  # noqa: E402
from manifests import supported_platforms  # noqa: E402
from provenance import VISIBLE_PROVENANCE  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
TARGET = ROOT / "docs" / "architecture" / "installation.md"

BEGIN = "<!-- BEGIN GENERATED INSTALL FLOWS -->"
END = "<!-- END GENERATED INSTALL FLOWS -->"

PLATFORM_TITLES = {
    "fedora": "Fedora workstation",
    "fedora-wsl": "Fedora on WSL",
    "macos": "Apple Silicon macOS",
    "parrot-ctf": "Parrot Security Edition CTF guest",
}

# A label may interpolate one of the installer's own variables; the rendered
# page shows it as a placeholder rather than a shell expression.
SHELL_VARIABLE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")

# plan_add <id> <label> <phase> …, where the label is a single-quoted or
# double-quoted literal in every call site. Anything before `plan_add` on the
# line is the guard that makes the step conditional.
PLAN_ADD = re.compile(
    r"^(?P<prefix>.*?)plan_add\s+(?P<id>[A-Za-z0-9._-]+)\s+"
    r"(?P<quote>['\"])(?P<label>.*?)(?P=quote)\s+"
    r"(?P<phase>[a-z]+)\b"
)


def placeholder(match: re.Match[str]) -> str:
    return f"`<{match.group(1).replace('_', '-')}>`"


def readable_label(raw: str) -> str:
    return SHELL_VARIABLE.sub(placeholder, raw).replace("|", "\\|")


def steps(installer: pathlib.Path) -> list[tuple[str, str, str, bool]]:
    found: list[tuple[str, str, str, bool]] = []
    for line in installer.read_text(encoding="utf-8").splitlines():
        match = PLAN_ADD.search(line)
        if not match:
            continue
        prefix = match.group("prefix")
        found.append(
            (
                match.group("id"),
                readable_label(match.group("label")),
                match.group("phase"),
                prefix.strip() == "" and not prefix.startswith((" ", "\t")),
            )
        )
    return found


def render() -> str:
    lines = [
        BEGIN,
        "",
        "<!-- Generated from the plan_add calls in platforms/*/install.sh by",
        "     scripts/render-install-flows.py. Do not edit between these markers;",
        "     edit the installer and regenerate. -->",
        "",
        VISIBLE_PROVENANCE.format(
            sources="the `plan_add` calls in `platforms/*/install.sh`",
            renderer="render-install-flows.py",
        ),
        "",
        "## Per-platform install flow",
        "",
        "Every installer builds one ordered execution plan and then runs it. The",
        "tables below are that plan, read out of the installers themselves, so the",
        "order here is the order `--dry-run` prints and an apply run executes:",
        "",
        "```bash",
        "./install.sh --platform <platform> --dry-run",
        "```",
        "",
        "Add the optional flags you intend to use: a **conditional** step is planned",
        "only when its option selects it, and `--dry-run` resolves that for the exact",
        "selection you pass. The `verify` phase runs after every `apply` step it",
        "follows, and component scripts stay individually callable and safe to rerun.",
        "",
    ]

    for platform in supported_platforms():
        installer = ROOT / "platforms" / platform / "install.sh"
        found = steps(installer)
        if not found:
            raise SystemExit(f"No plan_add steps found in {installer}")
        lines.append(f"### {PLATFORM_TITLES[platform]}")
        lines.append("")
        lines.append(f"`{installer.relative_to(ROOT)}`, {len(found)} steps:")
        lines.append("")
        lines.append("| # | Step | Phase | When | What it does |")
        lines.append("|---|---|---|---|---|")
        for index, (identifier, description, phase, always) in enumerate(found, start=1):
            when = "always" if always else "conditional"
            lines.append(
                f"| {index} | `{identifier}` | `{phase}` | {when} | {description} |"
            )
        lines.append("")

    lines.append(END)
    return "\n".join(lines)


def splice(existing: str, generated: str) -> str:
    start = existing.find(BEGIN)
    finish = existing.find(END)
    if start == -1 or finish == -1:
        raise SystemExit(f"{TARGET} has no install-flow markers; add {BEGIN} and {END}")
    return existing[:start] + generated + existing[finish + len(END) :]


def main() -> int:
    updated = splice(read_committed(TARGET), render())
    return check_or_write(
        TARGET,
        updated,
        sys.argv,
        stale="Generated install flows are stale",
        remedy="./scripts/render-install-flows.py",
    )


if __name__ == "__main__":
    raise SystemExit(main())
