#!/usr/bin/env python3
"""Render the Stow and machine-local state inventories in file-ownership.md.

Two lists on that page were hand-copied and drifted: the Stow packages (only
the portable set and Fedora's were listed, though every platform deploys its
own) and the machine-local state files (the lifecycle state directory and the
per-capability component state files were missing entirely).

Both are derivable. The Stow package lists are the `packages=(…)` arrays the
stow scripts themselves iterate, and the component state files are named by
the `state` column of `config/capabilities.tsv`. The theme-derived files and
the lifecycle files under `$XDG_STATE_HOME` are a fixed set, recorded below
with the code that writes each one.

`./scripts/lint.sh` runs this with `--check`.

Usage:
    scripts/render-file-ownership.py [--check]
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from generated import check_or_write, read_committed  # noqa: E402
from manifests import read_tsv, stow_packages, supported_platforms  # noqa: E402
from provenance import VISIBLE_PROVENANCE  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
CAPABILITIES = ROOT / "config" / "capabilities.tsv"
TARGET = ROOT / "docs" / "architecture" / "file-ownership.md"

BEGIN_STOW = "<!-- BEGIN GENERATED STOW PACKAGES -->"
END_STOW = "<!-- END GENERATED STOW PACKAGES -->"
BEGIN_STATE = "<!-- BEGIN GENERATED MACHINE-LOCAL STATE -->"
END_STATE = "<!-- END GENERATED MACHINE-LOCAL STATE -->"

PLATFORM_TITLES = {
    "fedora": "Fedora workstation",
    "fedora-wsl": "Fedora on WSL",
    "macos": "Apple Silicon macOS",
    "parrot-ctf": "Parrot Security Edition CTF guest",
}

# Files written outside a capability's own component state. Each entry names
# the code that writes it, so the claim stays checkable by reading one file.
THEME_STATE = [
    ("theme", "the selected Catppuccin flavour", "common/lib/theme-shared-state.sh"),
    ("ghostty.conf", "Ghostty/Noctty theme include", "common/lib/theme-shared-state.sh"),
    ("git-theme", "the delta feature Git loads", "common/lib/theme-shared-state.sh"),
    ("tmux-theme.conf", "the tmux Catppuccin flavour", "common/lib/theme-shared-state.sh"),
    ("sway-theme.conf", "Sway colours", "platforms/fedora/lib/theme-desktop.sh"),
    ("waybar-theme.css", "Waybar colours", "platforms/fedora/lib/theme-desktop.sh"),
    ("fuzzel.ini", "Fuzzel colours", "platforms/fedora/lib/theme-desktop.sh"),
    ("mako.conf", "Mako colours", "platforms/fedora/lib/theme-desktop.sh"),
    ("swaylock.conf", "swaylock colours", "platforms/fedora/lib/theme-desktop.sh"),
]

LIFECYCLE_STATE = [
    ("install.conf", "the install lifecycle state `--rerun` reapplies", "common/lib/install-lifecycle.sh"),
    ("install.log", "the timestamped execution-plan log", "common/lib/install-lifecycle.sh"),
    ("theme-actions.log", "what each theme hook did, and whether it failed", "common/lib/theme-hooks.sh"),
    ("mise-context/", "the empty directory every mise invocation runs from", "common/lib/common.sh"),
    ("git-identity/", "backups taken before a Git identity migration", "common/lib/git-identity.sh"),
]

UNTRACKED_FILES = [
    ("~/.config/git/local", "machine-local Git identity and signing configuration"),
    ("~/.config/git/drdk", "a per-directory Git identity include"),
    ("~/.config/sway/local.conf", "output names, positions, modes, and scaling"),
    ("~/.config/mise/conf.d/ai.toml", "the untracked AI toolchain mise fragment"),
]


def render_stow() -> str:
    lines = [
        BEGIN_STOW,
        "",
        "<!-- Generated from the packages=( … ) arrays in common/stow.sh and",
        "     platforms/*/scripts/stow.sh by scripts/render-file-ownership.py.",
        "     Do not edit between these markers; edit the script and regenerate. -->",
        "",
        VISIBLE_PROVENANCE.format(
            sources="the `packages=( … )` arrays in `common/stow.sh` and "
            "`platforms/*/scripts/stow.sh`",
            renderer="render-file-ownership.py",
        ),
        "",
        "Every installation deploys the portable packages at the repository root",
        "and then its own platform tree. `common/stow.sh` is the authoritative",
        "manifest for the first; each platform's `stow.sh` is for the second.",
        "",
        "| Tree | Packages |",
        "|---|---|",
    ]

    portable = stow_packages(ROOT / "common" / "stow.sh")
    names = " ".join(f"`{name}`" for name in sorted(portable))
    lines.append(f"| Portable (`common/stow.sh`) | {names} |")

    # A package a platform names may still live at the top of the checkout,
    # because its contents are not that platform's: theme-assets is one set of
    # images every platform that wants them links. Resolving the root here is
    # the same rule capability_stow_package_root applies at install time, so
    # this table cannot claim a package sits somewhere it does not.
    shared: dict[str, list[str]] = {}
    for platform in supported_platforms():
        script = ROOT / "platforms" / platform / "scripts" / "stow.sh"
        owned = []
        for name in sorted(stow_packages(script)):
            if name in portable or not (ROOT / name).is_dir():
                owned.append(name)
                continue
            shared.setdefault(name, []).append(platform)
        names = " ".join(f"`{name}`" for name in owned)
        lines.append(
            f"| {PLATFORM_TITLES[platform]} (`platforms/{platform}/stow/`) | {names} |"
        )

    for name in sorted(shared):
        deployed = ", ".join(PLATFORM_TITLES[platform] for platform in shared[name])
        lines.append(f"| Shared (repository root, deployed by {deployed}) | `{name}` |")

    lines.extend(
        [
            "",
            "A shared row is a package at the repository root that `common/stow.sh`",
            "does not deploy: the platforms named there link it, and there is one",
            "copy of its contents rather than one per platform.",
            "",
            "Not every package in a row is deployed on every run: `common/stow.sh",
            "--headless` omits the GUI terminal package for the WSL composition,",
            "`--without-mise` omits the general-workstation mise manifest for the",
            "Parrot guest, and Fedora's `sway` and `waybar` packages are stowed only",
            "with `--sway`.",
            "",
            END_STOW,
        ]
    )
    return "\n".join(lines)


def component_state() -> list[tuple[str, str]]:
    rows = read_tsv(CAPABILITIES)

    owners: dict[str, set[str]] = {}
    for row in rows:
        name = row["state"]
        if name in {"", "-", "install"} or row["status"] != "implemented":
            continue
        owners.setdefault(name, set()).add(row["capability"])
    return [(name, ", ".join(f"`{c}`" for c in sorted(owners[name]))) for name in sorted(owners)]


def render_state() -> str:
    lines = [
        BEGIN_STATE,
        "",
        "<!-- Component state files are generated from the `state` column of",
        "     config/capabilities.tsv by scripts/render-file-ownership.py.",
        "     Do not edit between these markers; edit the manifest and regenerate. -->",
        "",
        VISIBLE_PROVENANCE.format(
            sources="the `state` column of `config/capabilities.tsv`",
            renderer="render-file-ownership.py",
        ),
        "",
        "### Component state — `~/.config/dotfiles/<component>.conf`",
        "",
        "One file per installed component, recording what was requested and what was",
        "observed. A profile's verifier and `--rerun` read these rather than asking",
        "for a flag again. The manifest's `state` column is what names them:",
        "",
        "| File | Written for |",
        "|---|---|",
    ]
    for name, capabilities in component_state():
        lines.append(f"| `~/.config/dotfiles/{name}.conf` | {capabilities} |")

    lines.extend(
        [
            "",
            "`hardware.conf` is created only after an optional hardware profile has",
            "been installed; it records the selected model and verification",
            "requirements.",
            "",
            "### Theme state — `~/.config/dotfiles/`",
            "",
            "Derived from the selected flavour every time `theme` runs:",
            "",
            "| File | What it carries | Written by |",
            "|---|---|---|",
        ]
    )
    for name, purpose, writer in THEME_STATE:
        lines.append(f"| `~/.config/dotfiles/{name}` | {purpose} | `{writer}` |")

    lines.extend(
        [
            "",
            "The first four are portable. The rest are the Fedora desktop half and",
            "exist only where that theme hook is installed.",
            "",
            "### Lifecycle state — `$XDG_STATE_HOME/dotfiles/`",
            "",
            "`$XDG_STATE_HOME` defaults to `~/.local/state`. This directory is state",
            "the installer itself keeps, not configuration:",
            "",
            "| Path | What it carries | Written by |",
            "|---|---|---|",
        ]
    )
    for name, purpose, writer in LIFECYCLE_STATE:
        lines.append(
            f"| `$XDG_STATE_HOME/dotfiles/{name}` | {purpose} | `{writer}` |"
        )

    lines.extend(
        [
            "",
            "### Other machine-local files",
            "",
            "| Path | What it carries |",
            "|---|---|",
        ]
    )
    for path, purpose in UNTRACKED_FILES:
        lines.append(f"| `{path}` | {purpose} |")

    lines.append("")
    lines.append(END_STATE)
    return "\n".join(lines)


def splice(existing: str, begin: str, end: str, generated: str) -> str:
    start = existing.find(begin)
    finish = existing.find(end)
    if start == -1 or finish == -1:
        raise SystemExit(f"{TARGET} has no {begin}/{end} markers; add them")
    return existing[:start] + generated + existing[finish + len(end) :]


def main() -> int:
    updated = splice(read_committed(TARGET), BEGIN_STOW, END_STOW, render_stow())
    updated = splice(updated, BEGIN_STATE, END_STATE, render_state())
    return check_or_write(
        TARGET,
        updated,
        sys.argv,
        stale="Generated file ownership is stale",
        remedy="./scripts/render-file-ownership.py",
    )


if __name__ == "__main__":
    raise SystemExit(main())
