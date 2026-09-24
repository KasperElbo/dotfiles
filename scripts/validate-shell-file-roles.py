#!/usr/bin/env python3
"""Give every tracked shell file exactly one role, and enforce its file mode.

An executable bit is a contract: it says "this file is an entry point you may
run". A sourced library that carries it invites someone to execute it, which
either does nothing or does something surprising; an entry point that lacks it
fails for whoever types its path. Both had accumulated in this repository.

`config/shell-file-roles.tsv` is the inventory. Every tracked shell file — and
every tracked file under a stowed `bin` directory, which becomes a command on
PATH — must match exactly one pattern there and carry that role's mode.
"Exactly one" is deliberate: an overlapping pattern is an ambiguity in the
inventory, not something to resolve by first-match order.

A role is a claim about the file, so it is checked rather than taken on trust
(#539, V5-10). The roles are a closed set (`ROLES`), and each fixes the mode
and, where the role implies one, where the file may live: a Zsh startup file
recorded as a `sourced-library` at 644 used to pass, because only the mode was
compared and the role was free text. And a glob may not decide the role of a
Zsh startup file. Zsh reads `.zshenv`, `.zprofile`, `.zshrc`, `.zlogin` and
`.zlogout` at five different points, so a tracked `.zlogin` falling into the
`zsh/.config/zsh/*` glob inherited "Sourced by every interactive Zsh", which is
false for it; each of them needs an exact row saying when it is read.

Usage:
    scripts/validate-shell-file-roles.py [--root DIR]
"""

from __future__ import annotations

import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import SHELL_FILE_ROLES_MANIFEST as MANIFEST  # noqa: E402
from manifests import role_pattern_matches as matches  # noqa: E402
from manifests import ManifestSchemaError, has_shell_shebang, read_tsv  # noqa: E402
from manifests import tracked_files  # noqa: E402

FIELDS = ["role", "mode", "pattern", "description"]

# Every role, with the mode it requires and the place a file holding it must
# live, if the role implies one. An executable role is 755, except a
# PowerShell file, which is run through an explicit interpreter and carries no
# executable bit.
EXECUTABLE = "executable"
STOWED = "a stow package"
LIBRARY = "a lib directory"
ROLES: dict[str, tuple[str, str | None]] = {
    "public-entrypoint": (EXECUTABLE, None),
    "internal-executable": (EXECUTABLE, None),
    "platform-entrypoint": (EXECUTABLE, "platforms/**"),
    "platform-command": (EXECUTABLE, "platforms/**"),
    "portable-wrapper": (EXECUTABLE, "scripts/*"),
    "deprecated-wrapper": (EXECUTABLE, "scripts/*"),
    "test-entrypoint": (EXECUTABLE, "tests/**"),
    "stowed-command": (EXECUTABLE, STOWED),
    # Installed by a script that sets the bit; the tracked file is data.
    "installed-system-command": ("644", "platforms/*/assets/*"),
    "sourced-library": ("644", LIBRARY),
    "stowed-config": ("644", STOWED),
    "stowed-data": ("644", STOWED),
}
# Top-level directories that are not stow packages.
NOT_STOWED = {"common", "config", "docs", "LICENSES", "scripts", "tests"}
# The files Zsh itself reads, each at its own point in startup.
ZSH_STARTUP = {".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"}


def governed(root: pathlib.Path, name: str) -> bool:
    """Files whose executable bit this repository is responsible for."""
    if name.endswith((".sh", ".zsh", ".ps1")):
        return True
    if "/.local/bin/" in name or name.startswith("bin/.local/bin/"):
        return True
    if name.startswith("scripts/") and name.endswith(".py"):
        return True
    # A platform asset carrying a shell shebang is a program this repository
    # installs onto the machine -- platforms/fedora/assets/dotfiles-sway is the
    # Wayland session `Exec=`, so it is the command the display manager runs to
    # start the desktop -- and it was governed by nothing, because it has no
    # extension and is not stowed. The shebang is what makes it a program, so
    # the shebang is what decides.
    if matches("platforms/*/assets/**", name) and has_shell_shebang(root / name):
        return True
    return name in {"doctor", "zsh/.zshenv"} or name.startswith("zsh/.config/zsh/")


def is_deprecated_wrapper(path: pathlib.Path) -> bool:
    """A deprecated wrapper is a file that announces itself as one."""
    try:
        body = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    return 'deprecated_wrapper "' in body


def is_exact(pattern: str) -> bool:
    return not any(character in pattern for character in "*?[")


def role_mode(role: str, pattern: str) -> str | None:
    """The mode a role requires for files this pattern names."""
    if role not in ROLES:
        return None
    mode = ROLES[role][0]
    if mode == EXECUTABLE:
        return "644" if pattern.endswith(".ps1") else "755"
    return mode


def is_stowed(name: str) -> bool:
    """Whether the file is inside a package Stow links into the home directory."""
    parts = name.split("/")
    if len(parts) < 2:
        return False
    if parts[0] == "platforms":
        return len(parts) > 3 and parts[2] == "stow"
    return parts[0] not in NOT_STOWED


def misplaced(role: str, name: str) -> str | None:
    """Why this file cannot hold this role where it lives, or None."""
    place = ROLES[role][1]
    if place is None:
        return None
    if place == STOWED:
        return None if is_stowed(name) else f"is not in {STOWED}"
    if place == LIBRARY:
        return None if "lib" in name.split("/")[:-1] else f"is not in {LIBRARY}"
    return None if matches(place, name) else f"is not under {place}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    try:
        rules = read_tsv(root / MANIFEST, FIELDS)
    except ManifestSchemaError as error:
        for message in error.messages:
            print(f"shell-file roles: {message}", file=sys.stderr)
        return 1

    problems: list[str] = []
    for rule in rules:
        if rule["role"] not in ROLES:
            problems.append(
                f"rule {rule['pattern']!r}: role {rule['role']!r} is not one of "
                f"{', '.join(ROLES)}; a new role belongs in ROLES in "
                f"{pathlib.Path(__file__).name}, with the mode and place it implies"
            )
        elif rule["mode"] != role_mode(rule["role"], rule["pattern"]):
            problems.append(
                f"rule {rule['pattern']!r}: the {rule['role']} role requires mode "
                f"{role_mode(rule['role'], rule['pattern'])}, not {rule['mode']}"
            )
        if rule["mode"] not in {"644", "755"}:
            problems.append(f"rule {rule['pattern']!r}: mode must be 644 or 755")
        if not rule["description"] or rule["description"] == "-":
            problems.append(f"rule {rule['pattern']!r}: every role needs a description")

    used: set[str] = set()
    for name in tracked_files(root):
        if not governed(root, name):
            continue
        applicable = [rule for rule in rules if matches(rule["pattern"], name)]
        if not applicable:
            problems.append(
                f"{name}: no role in {MANIFEST} claims this file; classify it before adding it"
            )
            continue
        # A rule naming one exact file is more specific than any glob over it.
        exact = [rule for rule in applicable if is_exact(rule["pattern"])]
        if len(exact) == 1:
            rule = exact[0]
        elif len(applicable) == 1:
            rule = applicable[0]
        else:
            patterns = ", ".join(item["pattern"] for item in applicable)
            problems.append(f"{name}: matches more than one role pattern ({patterns})")
            continue
        for item in applicable:
            used.add(item["pattern"])
        basename = name.rsplit("/", 1)[-1]
        if basename in ZSH_STARTUP and not is_exact(rule["pattern"]):
            problems.append(
                f"{name}: Zsh reads {basename} at its own point in startup, so a glob "
                f"cannot say when; it matched {rule['pattern']!r} ({rule['description']}). "
                f"Give it its own exact row in {MANIFEST}"
            )
            continue
        if rule["role"] in ROLES:
            where = misplaced(rule["role"], name)
            if where is not None:
                problems.append(
                    f"{name}: classified {rule['role']!r} by {rule['pattern']!r}, but it "
                    f"{where}; that role cannot describe it"
                )
                continue
        # The `scripts/*.sh` catch-all would otherwise classify any new helper
        # as a deprecated wrapper -- a false claim, in the authoritative
        # inventory, that marks the file for deletion. A role that describes
        # what a file *does* has to be checked against what it does.
        if rule["role"] == "deprecated-wrapper" and not is_deprecated_wrapper(root / name):
            roles = ", ".join(sorted({item["role"] for item in rules}))
            problems.append(
                f"{name}: matched the {rule['pattern']!r} catch-all and is therefore "
                f"classified {rule['role']!r}, but it never calls deprecated_wrapper. "
                f"Give it its own exact row in {MANIFEST} with the role it really has "
                f"(available roles: {roles})"
            )
            continue
        actual = oct((root / name).stat().st_mode & 0o777)[2:]
        if actual != rule["mode"]:
            problems.append(
                f"{name}: mode {actual}, but its role {rule['role']!r} requires {rule['mode']} "
                f"({rule['description']})"
            )

    for rule in rules:
        if rule["pattern"] not in used:
            problems.append(
                f"rule {rule['pattern']!r} matches nothing; remove it rather than leaving a "
                "rule that can never fail"
            )

    for problem in problems:
        print(f"shell-file roles: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
