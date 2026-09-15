#!/usr/bin/env python3
"""Validate the authoritative capability/provider contract.

`config/capabilities.tsv` and `config/install-options.tsv` describe the same
CLI contract from two directions: the first says what a capability is and how
it defaults, the second says what the parser accepts and what a machine may
remember. They are checked against each other here, so a default can never be
changed in one manifest alone.
"""

from __future__ import annotations

import csv
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = pathlib.Path(os.environ.get("CAPABILITY_MANIFEST", ROOT / "config" / "capabilities.tsv"))
FIELDS = [
    "capability", "platform", "profile", "cli_flag", "default",
    "dependencies", "conflicts", "provider", "packages", "stow",
    "verifier", "state", "docs", "provenance", "status",
]
PLATFORMS = {"fedora", "fedora-wsl", "macos", "parrot-ctf"}
PLATFORM_VERIFIER = re.compile(r"^platforms/[^/]+/scripts/verify\.sh$")
# A platform verifier is the baseline capability from its first line, so
# requiring it to name "base" would only add noise. Every other capability it
# is declared for must be findable in the file.
VERIFIER_MENTION_EXEMPT = {"base"}

OPTION_MANIFEST = pathlib.Path(
    os.environ.get("INSTALL_OPTION_MANIFEST", ROOT / "config" / "install-options.tsv")
)
OPTION_FIELDS = [
    "platform", "option", "kind", "on_flag", "off_flag", "default",
    "values", "capability", "summary",
]

# Capabilities that own a CLI flag but deliberately have no persistent option
# row. `--dev-workflows` runs disposable smoke tests for one invocation; it is
# a transient execution control, so it belongs to no machine's remembered
# configuration and must not gain an install-options.tsv row.
TRANSIENT_CAPABILITIES = {"dev-workflows"}

# How a capability default maps onto the persistent option's default, per
# option kind. A `value` option is "off" by declaring no default at all.
OPTION_DEFAULTS = {
    ("enabled", "boolean"): {"true"},
    ("enabled", "tristate"): {"true"},
    ("disabled", "boolean"): {"false"},
    ("disabled", "tristate"): {"inherit"},
    ("disabled", "value"): {"-"},
    ("auto", "boolean"): {"auto"},
    ("auto", "tristate"): {"auto"},
}

# One package normally has one owner per platform. The exception is a package
# that two independently selectable capabilities each install on their own:
# common/install-ai.sh installs lavish-axi for --firstmate *and* for
# --backpass, so backpass selected alone still brings it. Declaring a single
# owner would leave that install unowned; declaring it twice without this list
# would read as the ownership mistake the check exists to catch.
CO_OWNED_PACKAGES = {"lavish-axi": {"firstmate", "backpass"}}

# Where a capability's native packages are actually requested. The manifest is
# a claim about what gets installed; these files are what does the installing,
# so every package a row declares has to be named in one of them.
CAPABILITY_INSTALLERS = {
    ("base", "fedora"): [
        "platforms/fedora/scripts/install-system.sh",
        "platforms/fedora/scripts/install-terra.sh",
    ],
    ("base", "fedora-wsl"): ["platforms/fedora-wsl/scripts/install-system.sh"],
    ("base", "macos"): ["platforms/macos/Brewfile"],
    ("base", "parrot-ctf"): ["platforms/parrot-ctf/scripts/install-system.sh"],
    ("kde", "fedora"): ["platforms/fedora/scripts/install-kde-theme.sh"],
    ("latex", "fedora"): ["platforms/fedora/scripts/install-latex.sh"],
    ("latex", "fedora-wsl"): ["platforms/fedora/scripts/install-latex.sh"],
    ("ocaml", "fedora"): ["platforms/fedora/scripts/install-ocaml.sh"],
    ("ocaml", "fedora-wsl"): ["platforms/fedora/scripts/install-ocaml.sh"],
    ("ocaml", "macos"): ["platforms/macos/scripts/install-ocaml.sh"],
    ("sway", "fedora"): ["platforms/fedora/scripts/install-sway.sh"],
    ("vm-host", "fedora"): ["platforms/fedora/scripts/install-vm-host.sh"],
    ("vm-guest", "fedora"): ["platforms/fedora/scripts/install-vm-guest.sh"],
    ("vm-guest", "parrot-ctf"): [
        "platforms/parrot-ctf/scripts/install-guest-integration.sh"
    ],
    ("hardware", "fedora"): ["platforms/fedora/scripts/install-asus-hardware.sh"],
    ("hardening", "fedora"): [
        "platforms/fedora/scripts/install-hardening.sh",
        "platforms/fedora/lib/hardening.sh",
    ],
    ("desktop-tools", "fedora"): [
        "platforms/fedora/scripts/install-desktop-tools.sh"
    ],
    ("containers", "fedora"): ["platforms/fedora/scripts/install-containers.sh"],
    # The WSL wrapper delegates to the Fedora installer, which is where the
    # packages are actually named.
    ("containers", "fedora-wsl"): ["platforms/fedora/scripts/install-containers.sh"],
    ("containers", "macos"): ["platforms/macos/scripts/install-containers.sh"],
    ("tailscale", "fedora"): ["platforms/fedora/scripts/install-tailscale.sh"],
    ("tailscale", "macos"): ["platforms/macos/scripts/install-tailscale.sh"],
}

# Which capability each shell package array belongs to. `None` marks an array
# of packages this repository requests but does not own -- the platform image
# is expected to carry them, and the installer only fills a genuine gap.
# Every `*packages=(` array under platforms/ has to appear here, so a new one
# cannot quietly escape the comparison above.
ARRAY_OWNERS = {
    ("platforms/fedora/scripts/install-system.sh", "packages"): "base",
    ("platforms/fedora/scripts/install-terra.sh", "packages"): "base",
    ("platforms/fedora-wsl/scripts/install-system.sh", "packages"): "base",
    ("platforms/parrot-ctf/scripts/install-system.sh", "packages"): "base",
    ("platforms/fedora/scripts/install-latex.sh", "packages"): "latex",
    ("platforms/fedora/scripts/install-ocaml.sh", "workstation_packages"): "ocaml",
    ("platforms/fedora/scripts/install-ocaml.sh", "wsl_packages"): "ocaml",
    ("platforms/fedora/scripts/install-ocaml.sh", "packages"): None,
    ("platforms/fedora/scripts/install-sway.sh", "packages"): "sway",
    ("platforms/fedora/scripts/install-vm-host.sh", "vm_host_packages"): "vm-host",
    ("platforms/fedora/scripts/install-vm-guest.sh", "vm_guest_packages"): "vm-guest",
    ("platforms/fedora/scripts/install-asus-hardware.sh", "common_packages"): "hardware",
    ("platforms/fedora/scripts/install-asus-hardware.sh", "amd_packages"): "hardware",
    ("platforms/fedora/scripts/install-containers.sh", "container_packages"): "containers",
    # The Fedora KDE spin ships Gwenview, Okular and Ark; the profile reuses
    # them and installs one only when it is genuinely missing, so they belong
    # to the platform image rather than to any capability here.
    ("platforms/fedora/scripts/install-desktop-tools.sh", "baseline_packages"): None,
    ("platforms/fedora/scripts/install-desktop-tools.sh", "added_packages"): "desktop-tools",
}

PACKAGE_ARRAY = re.compile(r"^\s*(\w*packages)=\(([^)]*)\)", re.M)


def split(value: str) -> list[str]:
    return [] if value == "-" else value.split(",")


def fail(message: str) -> None:
    print(f"capability manifest: {message}", file=sys.stderr)


def fail_options(message: str) -> None:
    print(f"installer option manifest: {message}", file=sys.stderr)


def markdown_anchors(path: pathlib.Path) -> set[str]:
    anchors: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*$", line)
        if not match:
            continue
        anchor = match.group(1).strip().lower()
        anchor = re.sub(r"[^\w\- ]", "", anchor)
        anchors.add(anchor.replace(" ", "-"))
    return anchors


def check_option_manifest(rows: list[dict[str, str]]) -> int:
    """Every flagged capability must have an option row that agrees with it."""
    errors = 0
    with OPTION_MANIFEST.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames != OPTION_FIELDS:
            fail_options(f"unexpected columns: {reader.fieldnames}")
            return 1
        options = list(reader)

    by_flag = {(row["platform"], row["on_flag"]): row for row in options}
    for row in rows:
        if row["status"] != "implemented" or row["cli_flag"] in {"", "-"}:
            continue
        where = f"{row['platform']}/{row['capability']}"
        if row["capability"] in TRANSIENT_CAPABILITIES:
            if (row["platform"], row["cli_flag"]) in by_flag:
                fail_options(
                    f"{where}: {row['cli_flag']} is a transient control and must not "
                    "be a persistent option"
                )
                errors += 1
            continue
        option = by_flag.get((row["platform"], row["cli_flag"]))
        if option is None:
            fail_options(
                f"{where}: no persistent option declares {row['cli_flag']} on "
                f"{row['platform']}"
            )
            errors += 1
            continue
        expected = OPTION_DEFAULTS.get((row["default"], option["kind"]))
        if expected is None:
            fail_options(
                f"{row['platform']}/{option['option']}: capability default "
                f"{row['default']!r} has no meaning for a {option['kind']} option"
            )
            errors += 1
        elif option["default"] not in expected:
            fail_options(
                f"{row['platform']}/{option['option']}: option default "
                f"{option['default']!r} disagrees with capability "
                f"{row['capability']} default {row['default']!r} "
                f"(expected {' or '.join(sorted(expected))})"
            )
            errors += 1
    return errors


def package_arrays(path: pathlib.Path) -> dict[str, list[str]]:
    """Every `<name>packages=(...)` literal array in a shell file."""
    found: dict[str, list[str]] = {}
    text = path.read_text(encoding="utf-8")
    for match in PACKAGE_ARRAY.finditer(text):
        entries = [
            word for word in match.group(2).split()
            if not word.startswith("#") and not word.startswith("$")
        ]
        found.setdefault(match.group(1), []).extend(entries)
    return found


def check_installer_packages(rows: list[dict[str, str]]) -> int:
    """Compare each row's package list with the files that install them.

    Two directions, because the manifest can drift either way. A package the
    row claims but no installer names is a promise nothing keeps; a package an
    installer array requests but no row on that platform owns is an install
    nobody is accountable for.
    """
    errors = 0
    owners: dict[str, set[str]] = {}
    for row in rows:
        if row["status"] != "implemented":
            continue
        for package in split(row["packages"]):
            owners.setdefault(row["platform"], set()).add(package)

    for row in rows:
        if row["status"] != "implemented":
            continue
        installers = CAPABILITY_INSTALLERS.get((row["capability"], row["platform"]))
        if installers is None:
            continue
        where = f"{row['platform']}/{row['capability']}"
        words: set[str] = set()
        for installer in installers:
            path = ROOT / installer
            if not path.is_file():
                fail(f"{where}: declared installer does not exist: {installer}")
                errors += 1
                continue
            words |= set(re.split(r"[^\w.+-]+", path.read_text(encoding="utf-8")))
        for package in split(row["packages"]):
            if package not in words:
                fail(f"{where}: package {package!r} is declared but is not "
                     f"requested by {', '.join(installers)}")
                errors += 1

    # Only the installers: a Stow package list and a verifier's expectation
    # list are different columns of the manifest, checked elsewhere.
    for path in sorted(ROOT.glob("platforms/*/scripts/install-*.sh")):
        relative = path.relative_to(ROOT).as_posix()
        platform = path.relative_to(ROOT).parts[1]
        for name, entries in package_arrays(path).items():
            if (relative, name) not in ARRAY_OWNERS:
                fail(f"{relative}: package array {name!r} is not declared in "
                     f"ARRAY_OWNERS, so nothing checks what it installs")
                errors += 1
                continue
            if ARRAY_OWNERS[(relative, name)] is None:
                continue
            for package in entries:
                if package not in owners.get(platform, set()):
                    fail(f"{relative}: {name} installs {package!r}, which no "
                         f"{platform} capability owns")
                    errors += 1
    return errors


def verifier_mentions(path: pathlib.Path, capability: str) -> bool:
    """Does this verifier say anywhere that it checks `capability`?

    A section that names the capability in its code or comments already says
    so; where the name does not appear naturally, the section carries a
    one-line `# verifies: <capability>` marker (see docs/capabilities.md).
    Both spellings are found by the same search: separators are normalized, so
    `dotnet-debug` is found in `check_easy_dotnet_debugger`, and a trailing
    suffix is allowed while a leading one is not, so `latex` is not satisfied
    by an unrelated `foolatex`.
    """
    text = re.sub(r"[^a-z0-9]+", "-", path.read_text(encoding="utf-8").lower())
    return re.search(rf"(?:^|-){re.escape(capability.lower())}", text) is not None


def main() -> int:
    errors = 0
    with MANIFEST.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames != FIELDS:
            fail(f"unexpected columns: {reader.fieldnames}")
            return 1
        rows = list(reader)

    keys: set[tuple[str, str, str]] = set()
    rows_by_platform: dict[str, list[dict[str, str]]] = {}
    for line, row in enumerate(rows, 2):
        key = (row["capability"], row["platform"], row["profile"])
        if key in keys:
            fail(f"line {line}: duplicate provider ownership for {key}")
            errors += 1
        keys.add(key)
        rows_by_platform.setdefault(row["platform"], []).append(row)
        if row["platform"] not in PLATFORMS:
            fail(f"line {line}: unknown platform {row['platform']!r}")
            errors += 1
        if row["default"] not in {"auto", "enabled", "disabled"}:
            fail(f"line {line}: invalid default {row['default']!r}")
            errors += 1
        if row["status"] not in {"implemented", "unsupported"}:
            fail(f"line {line}: invalid status {row['status']!r}")
            errors += 1
        if row["status"] == "implemented":
            for column in ("provider", "verifier", "docs", "provenance"):
                if row[column] in {"", "-", "none", "unsupported"}:
                    fail(f"line {line}: implemented {key} lacks {column}")
                    errors += 1
            if not (ROOT / row["verifier"]).is_file():
                fail(f"line {line}: verifier does not exist: {row['verifier']}")
                errors += 1
            elif (
                PLATFORM_VERIFIER.match(row["verifier"])
                and row["capability"] not in VERIFIER_MENTION_EXEMPT
                and not verifier_mentions(ROOT / row["verifier"], row["capability"])
            ):
                fail(
                    f"line {line}: verifier {row['verifier']} never mentions "
                    f"{row['capability']}, the capability it is declared for; "
                    f"add the check, or mark the section that performs it with "
                    f"'# verifies: {row['capability']}'"
                )
                errors += 1
            for package in split(row["stow"]):
                portable = ROOT / package
                platform_package = ROOT / "platforms" / row["platform"] / "stow" / package
                if not portable.is_dir() and not platform_package.is_dir():
                    fail(f"line {line}: Stow package does not exist: {package}")
                    errors += 1
            docs_path, _, docs_anchor = row["docs"].partition("#")
            full_docs_path = ROOT / docs_path
            if not full_docs_path.is_file():
                fail(f"line {line}: documentation does not exist: {row['docs']}")
                errors += 1
            elif docs_anchor and docs_anchor not in markdown_anchors(full_docs_path):
                fail(f"line {line}: documentation anchor does not exist: {row['docs']}")
                errors += 1
        elif row["provider"] not in {"unsupported", "windows-host", "user-managed"}:
            fail(f"line {line}: unsupported {key} needs an explicit absence owner")
            errors += 1

    for platform, platform_rows in rows_by_platform.items():
        available = {row["capability"] for row in platform_rows if row["status"] == "implemented"}
        by_capability = {row["capability"]: row for row in platform_rows}
        package_owners: dict[str, str] = {}
        for row in platform_rows:
            if row["status"] != "implemented":
                continue
            for dependency in split(row["dependencies"]):
                if dependency not in available:
                    fail(f"{platform}/{row['capability']}: missing dependency provider {dependency}")
                    errors += 1
            # A conflict is a property of a pair, and common/lib/capabilities.sh
            # reads only the row it is validating. Declared on one side alone it
            # fires or not depending on which capability the selection is
            # checked from, so both rows have to say it. Naming an unsupported
            # capability is allowed -- it can never be selected, so the entry is
            # a statement of intent rather than a rule that fires.
            for conflict in split(row["conflicts"]):
                other = by_capability.get(conflict)
                if other is None:
                    fail(f"{platform}/{row['capability']}: conflicts with {conflict}, "
                         f"which has no row on {platform}")
                    errors += 1
                elif other["status"] == "implemented" and \
                        row["capability"] not in split(other["conflicts"]):
                    fail(f"{platform}: {row['capability']} conflicts with {conflict}, "
                         f"but {conflict} does not conflict with {row['capability']}")
                    errors += 1
            for package in split(row["packages"]):
                previous = package_owners.get(package)
                shared = CO_OWNED_PACKAGES.get(package, set())
                if previous and previous != row["capability"] and not (
                    {previous, row["capability"]} <= shared
                ):
                    fail(f"{platform}: package {package!r} owned by both {previous} and {row['capability']}")
                    errors += 1
                package_owners[package] = row["capability"]

    if PLATFORMS - set(rows_by_platform):
        fail(f"platforms missing from manifest: {', '.join(sorted(PLATFORMS - set(rows_by_platform)))}")
        errors += 1

    errors += check_option_manifest(rows)
    errors += check_installer_packages(rows)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
