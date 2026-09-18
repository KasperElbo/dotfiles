#!/usr/bin/env python3
"""Validate the authoritative capability/provider contract.

`config/capabilities.tsv` and `config/install-options.tsv` describe the same
CLI contract from two directions: the first says what a capability is and how
it defaults, the second says what the parser accepts and what a machine may
remember. They are checked against each other here, so a default can never be
changed in one manifest alone.

The manifest is also checked against the shell code that implements it: the
packages a row declares against the installers it names, and the Stow packages
it declares against the Stow scripts that deploy them. The installer argv
parsers are compared with `config/install-options.tsv` by
`scripts/validate-install-options.py`.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import (  # noqa: E402
    ManifestSchemaError,
    mise_tool_package,
    mise_tools,
    read_tsv,
    stow_packages,
)

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = pathlib.Path(os.environ.get("CAPABILITY_MANIFEST", ROOT / "config" / "capabilities.tsv"))
FIELDS = [
    "capability", "platform", "profile", "cli_flag", "default",
    "dependencies", "conflicts", "provider", "packages", "stow",
    "verifier", "state", "docs", "provenance", "status", "installers",
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

# A row that declares packages names the files that request them in its
# `installers` column, and check_installer_packages() compares the two. A row
# whose packages are requested somewhere that column cannot point at -- a
# provider with no file in this repository -- has to be listed here with the
# place its packages are checked instead. An implemented row with packages, no
# installers and no entry here fails, so a missing mapping can never read as
# "nothing to check". Empty today: every package-declaring row names its
# installers.
PACKAGES_CHECKED_ELSEWHERE: dict[tuple[str, str], str] = {}

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

COMMON_STOW = pathlib.Path("common") / "stow.sh"
# How a platform Stow script runs the portable one, and which of the portable
# script's own flags switch a `packages+=(…)` branch off.
COMMON_STOW_CALL = re.compile(r'"\$DOTFILES_ROOT/common/stow\.sh"(?P<flags>(?:[ \t]+--[\w-]+)*)')
STOW_FLAG = re.compile(r'^\s*(?P<flag>--[\w-]+)\)\s*(?P<variable>\w+)="true"', re.M)
STOW_GUARDED_APPEND = re.compile(
    r'if \[\[ "\$(?P<variable>\w+)" == "false" \]\]; then\s*'
    r"packages\+=\((?P<names>[^)]*)\)"
)


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
    try:
        options = read_tsv(OPTION_MANIFEST, OPTION_FIELDS)
    except ManifestSchemaError as error:
        for message in error.messages:
            fail_options(message)
        return 1

    implemented = {
        (row["platform"], row["capability"])
        for row in rows
        if row["status"] == "implemented"
    }
    for option in options:
        if option["capability"] in {"", "-"}:
            continue
        if (option["platform"], option["capability"]) not in implemented:
            fail_options(
                f"{option['platform']}/{option['option']}: selects capability "
                f"{option['capability']}, which has no implemented "
                f"{option['platform']} row in the capability manifest"
            )
            errors += 1

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


def requested_packages(path: pathlib.Path) -> set[str]:
    """The package names an installer file can be said to request.

    A mise configuration is parsed, so a package must be a tool it declares. Any
    other file is searched for the name as a whole word. Words are split two
    ways, with and without `@` and `/` as word characters, so a scoped npm
    package such as `@openai/codex` is found as well as a plain name.
    """
    if path.suffix == ".toml":
        return {mise_tool_package(spec) for spec in mise_tools(path)}
    text = path.read_text(encoding="utf-8")
    return set(re.split(r"[^\w.+-]+", text)) | set(re.split(r"[^\w.+@/-]+", text))


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
        where = f"{row['platform']}/{row['capability']}"
        key = (row["capability"], row["platform"])
        installers = split(row["installers"])
        packages = split(row["packages"])
        if row["status"] != "implemented":
            if installers:
                fail(f"{where}: an unsupported row names installers")
                errors += 1
            continue
        if key in PACKAGES_CHECKED_ELSEWHERE and (installers or not packages):
            fail(f"{where}: listed in PACKAGES_CHECKED_ELSEWHERE, but it "
                 f"{'names installers' if installers else 'declares no packages'}; "
                 f"remove the stale entry")
            errors += 1
        if not packages:
            if installers:
                fail(f"{where}: names installers but declares no packages")
                errors += 1
            continue
        if not installers:
            if key not in PACKAGES_CHECKED_ELSEWHERE:
                fail(f"{where}: declares packages ({', '.join(packages)}) but "
                     f"names no installers, so nothing checks they are installed")
                errors += 1
            continue
        requested: set[str] = set()
        for installer in installers:
            path = ROOT / installer
            if not path.is_file():
                fail(f"{where}: declared installer does not exist: {installer}")
                errors += 1
                continue
            requested |= requested_packages(path)
        for package in packages:
            if package not in requested:
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


def scripted_stow_packages(platform: str) -> tuple[set[str], int]:
    """Every Stow package a platform's scripts can deploy, and an error count.

    The platform script's own packages count whether or not they sit behind a
    condition, because the manifest records that condition by putting the
    package on the optional capability's row (`sway: sway,waybar`). The
    portable script's packages count too, less any branch the platform switches
    off when it runs it (`--headless` drops Ghostty).
    """
    script = ROOT / "platforms" / platform / "scripts" / "stow.sh"
    relative = script.relative_to(ROOT).as_posix()
    if not script.is_file():
        fail(f"{platform}: Stow script does not exist: {relative}")
        return set(), 1
    names = set(stow_packages(script))
    call = COMMON_STOW_CALL.search(script.read_text(encoding="utf-8"))
    if call is None:
        return names, 0

    errors = 0
    common_text = (ROOT / COMMON_STOW).read_text(encoding="utf-8")
    variables = {m.group("flag"): m.group("variable") for m in STOW_FLAG.finditer(common_text)}
    switched_off: set[str] = set()
    for flag in call.group("flags").split():
        if flag not in variables:
            fail(f"{relative}: runs {COMMON_STOW.as_posix()} with {flag}, which "
                 f"that script does not accept")
            errors += 1
            continue
        switched_off.add(variables[flag])
    omitted: set[str] = set()
    for match in STOW_GUARDED_APPEND.finditer(common_text):
        if match.group("variable") in switched_off:
            omitted |= set(match.group("names").split())
    return names | (set(stow_packages(ROOT / COMMON_STOW)) - omitted), errors


def check_stow_ownership(rows: list[dict[str, str]]) -> int:
    """Compare each platform's `stow` cells with what its Stow scripts deploy.

    The column drives preflight conflict detection, so a package the scripts
    deploy but no row declares is a dotfile conflict preflight never looks for;
    a package a row declares but no script deploys is a promise nothing keeps.
    """
    errors = 0
    declared: dict[str, set[str]] = {}
    for row in rows:
        if row["platform"] not in PLATFORMS:
            continue
        cell = split(row["stow"]) if row["status"] == "implemented" else []
        declared.setdefault(row["platform"], set()).update(cell)

    for platform in sorted(declared):
        scripted, script_errors = scripted_stow_packages(platform)
        errors += script_errors
        for package in sorted(declared[platform] - scripted):
            fail(f"{platform}: Stow package {package!r} is declared in the stow "
                 f"column but no Stow script deploys it on {platform}")
            errors += 1
        for package in sorted(scripted - declared[platform]):
            fail(f"{platform}: Stow package {package!r} is deployed by the Stow "
                 f"scripts but no {platform} capability declares it in the stow "
                 f"column, so preflight never checks it for conflicts")
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


# ---------------------------------------------------------------------------
# The verify direction
#
# The checks above prove the manifest against the installers and the
# documentation. These prove it against the verifiers: that a declared
# verifier checks what its row installs, reads the registry instead of a copy
# of it, reports through the shared library, and is actually run by CI.
# ---------------------------------------------------------------------------

VERIFY_LIBRARY = ROOT / "common" / "lib" / "verify.sh"
REAL_INSTALL_WORKFLOW = ROOT / ".github" / "workflows" / "real-install.yml"
TEST_RUNNER = ROOT / "scripts" / "test.sh"

# Stow packages whose assets only work once something outside the package is
# in place, and the reference a verifier must contain to show it checks that
# thing: the machine-local theme state that selects the Catppuccin flavour
# files, the tracked Mason inventory LazyVim's tools are installed from, and
# the pinned plugin checkout .tmux.conf runs.
STOW_COMPONENT_EVIDENCE = {
    "starship": ("theme", "dotfiles/theme"),
    "nvim-lazyvim": ("Mason", "mason-packages.txt"),
    "tmux": ("Catppuccin tmux", "check_catppuccin_tmux"),
}

# Verifiers of profiles that no job in real-install.yml installs, and the
# default fast suite that runs each one against a mocked machine instead. That
# suite is their CI evidence, so it has to exist and run the verifier. Every
# other declared verifier must be run by real-install.yml against a real
# installation, directly or through a script the workflow runs.
MOCKED_VERIFIERS = {
    "platforms/fedora/scripts/verify-asus-hardware.sh": "tests/test-asus-verification.sh",
    "platforms/fedora/scripts/verify-containers.sh": "tests/test-containers.sh",
    "platforms/fedora/scripts/verify-desktop-tools.sh": "tests/test-desktop-tools.sh",
    "platforms/fedora/scripts/verify-hardening.sh": "tests/test-hardening.sh",
    "platforms/fedora/scripts/verify-tailscale.sh": "tests/test-tailscale.sh",
    "platforms/fedora/scripts/verify-vm-guest.sh": "tests/test-vm-guest.sh",
    "platforms/fedora/scripts/verify-vm-host.sh": "tests/test-vm-host.sh",
    "platforms/fedora-wsl/scripts/verify-containers.sh": "tests/test-containers-wsl.sh",
}

VERIFIER_REFERENCE = re.compile(
    r"(?<![\w-])((?:common|scripts|platforms/[\w-]+/scripts)/verify[\w-]*\.sh)(?![\w-])"
)
# The CI sequences a real-install step runs. Only these are followed: a
# verifier or installer the workflow runs may name another script behind an
# option the workflow never passes, which is not evidence that it runs.
INTEGRATION_SCRIPT = re.compile(r"(?<![\w-])(tests/integration/[\w.-]+\.sh)(?![\w-])")
SOURCE_LINE = re.compile(r'^\s*(?:source|\.)\s+"(.+)"\s*$')
SOURCE_PREFIXES = ('$(dirname "${BASH_SOURCE[0]}")/', "$DOTFILES_ROOT/")


def code_text(path: pathlib.Path) -> str:
    """A shell or YAML file without its comment lines.

    A path named in a comment is prose, not an invocation; only the lines that
    run something count as evidence that it is run.
    """
    return "\n".join(
        line for line in path.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("#")
    )


def mentions_path(text: str, path: str) -> bool:
    return re.search(rf"(?<![\w-]){re.escape(path)}(?![\w-])", text) is not None


def declared_verifiers(rows: list[dict[str, str]]) -> dict[str, set[str]]:
    """Every distinct verifier path, with the capabilities that declare it."""
    verifiers: dict[str, set[str]] = {}
    for row in rows:
        if row["status"] == "implemented" and row["verifier"] not in {"", "-", "none"}:
            verifiers.setdefault(row["verifier"], set()).add(row["capability"])
    return verifiers


def check_verifier_components(rows: list[dict[str, str]]) -> int:
    """A verifier must check the components its row's Stow packages rely on."""
    errors = 0
    for row in rows:
        if row["status"] != "implemented" or not (ROOT / row["verifier"]).is_file():
            continue
        text = code_text(ROOT / row["verifier"])
        for package in split(row["stow"]):
            if package not in STOW_COMPONENT_EVIDENCE:
                continue
            component, evidence = STOW_COMPONENT_EVIDENCE[package]
            if evidence not in text:
                fail(
                    f"{row['platform']}/{row['capability']}: Stow package {package!r} "
                    f"relies on {component}, but {row['verifier']} never checks it "
                    f"(expected a check referencing {evidence!r})"
                )
                errors += 1
    return errors


def check_verifier_package_arrays(verifiers: dict[str, set[str]]) -> int:
    """A verifier reads declared packages from the manifest, never a copy."""
    errors = 0
    for verifier in sorted(verifiers):
        path = ROOT / verifier
        if not path.is_file():
            continue
        for name, entries in package_arrays(path).items():
            if entries:
                fail(
                    f"{verifier}: verifier keeps its own {name}=(...) list "
                    f"({' '.join(entries)}); read the row with capability_packages "
                    f"from common/lib/capabilities.sh instead"
                )
                errors += 1
    return errors


def sources_verify_library(path: pathlib.Path) -> bool:
    for line in code_text(path).splitlines():
        match = SOURCE_LINE.match(line)
        if not match:
            continue
        target = match.group(1)
        for prefix in SOURCE_PREFIXES:
            if target.startswith(prefix):
                base = path.parent if prefix != "$DOTFILES_ROOT/" else ROOT
                if (base / target[len(prefix):]).resolve() == VERIFY_LIBRARY:
                    return True
    return False


def check_verifier_library(verifiers: dict[str, set[str]]) -> int:
    """Declared verifiers, and the verifiers they run, source the library.

    One pass/fail/warning contract is what makes every summary count the same
    things, and it is what gives a verifier the shared ownership checks.
    """
    errors = 0
    pending = sorted(verifiers)
    seen: set[str] = set()
    while pending:
        verifier = pending.pop(0)
        if verifier in seen:
            continue
        seen.add(verifier)
        path = ROOT / verifier
        if not path.is_file():
            continue
        if not sources_verify_library(path):
            fail(
                f"{verifier}: verifier does not source common/lib/verify.sh; "
                f"report through the shared pass/fail/warning contract"
            )
            errors += 1
        for referenced in VERIFIER_REFERENCE.findall(code_text(path)):
            if referenced not in seen and (ROOT / referenced).is_file():
                pending.append(referenced)
    return errors


def default_test_suites() -> set[str]:
    match = re.search(r"^default_tests=\((.*?)^\)", TEST_RUNNER.read_text(encoding="utf-8"),
                      re.M | re.S)
    return set(match.group(1).split()) if match else set()


def real_install_text() -> str:
    """real-install.yml, plus every integration sequence one of its steps runs."""
    workflow = code_text(REAL_INSTALL_WORKFLOW)
    texts = [workflow]
    for script in sorted(set(INTEGRATION_SCRIPT.findall(workflow))):
        if (ROOT / script).is_file():
            texts.append(code_text(ROOT / script))
    return "\n".join(texts)


def check_verifier_ci(verifiers: dict[str, set[str]]) -> int:
    """Every declared verifier is run by the CI tier that can run it."""
    errors = 0
    real_install = real_install_text()
    suites = default_test_suites()
    for verifier, capabilities in sorted(verifiers.items()):
        names = ", ".join(sorted(capabilities))
        suite = MOCKED_VERIFIERS.get(verifier)
        if suite is None:
            if not mentions_path(real_install, verifier):
                fail(
                    f"{names}: verifier {verifier} is not run by "
                    f".github/workflows/real-install.yml or any script it runs, so "
                    f"no real installation ever proves it"
                )
                errors += 1
        elif suite not in suites:
            fail(f"{names}: {verifier} relies on {suite} for CI evidence, but "
                 f"scripts/test.sh does not run that suite by default")
            errors += 1
        elif not (ROOT / suite).is_file() or not mentions_path(code_text(ROOT / suite), verifier):
            fail(f"{names}: {suite} is recorded as the CI evidence for {verifier} "
                 f"but never runs it")
            errors += 1
    for verifier in sorted(set(MOCKED_VERIFIERS) - set(verifiers)):
        fail(f"MOCKED_VERIFIERS names {verifier}, which no capability declares")
        errors += 1
    return errors


def main() -> int:
    errors = 0
    try:
        rows = read_tsv(MANIFEST, FIELDS)
    except ManifestSchemaError as error:
        for message in error.messages:
            fail(message)
        return 1

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
    errors += check_stow_ownership(rows)
    verifiers = declared_verifiers(rows)
    errors += check_verifier_components(rows)
    errors += check_verifier_package_arrays(verifiers)
    errors += check_verifier_library(verifiers)
    errors += check_verifier_ci(verifiers)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
