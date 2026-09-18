#!/usr/bin/env python3
"""Validate each platform installer's argv parser against its option manifest.

`config/install-options.tsv` says which flags a platform installer accepts and
which of them a machine remembers; `platforms/<platform>/install.sh` is what
actually accepts them. The two drift in both directions, and neither direction
is caught anywhere else:

* a flag the parser accepts but the manifest does not declare is never
  recorded, so `./install.sh --rerun` silently forgets it;
* a flag the manifest declares but the parser does not implement is
  documented as real, and `install_selection_serialize` stops every install on
  that platform with "Persistent installer option was never recorded".

So the flags matched by the parser's `while (($#)); do case "$1" in` arms are
compared with the manifest's `on_flag`/`off_flag` values, per platform, and
every difference is reported by name. An arm whose body starts with `die`
rejects its flags rather than accepting them; see REJECTED_FLAGS.

`./scripts/lint.sh` runs this.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import ManifestSchemaError, read_tsv  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
OPTION_MANIFEST = pathlib.Path(
    os.environ.get("INSTALL_OPTION_MANIFEST", ROOT / "config" / "install-options.tsv")
)

# Controls that belong to one invocation, not to a machine's configuration, so
# a parser may accept them without a manifest row (install-selection.sh says
# why). The same set scripts/render-installer-options.py documents as TRANSIENT,
# plus the deprecated aliases a parser still forwards during their removal
# window. A parser need not accept any of them; `--platform` belongs to the
# root installer, and a platform parser rejects `--rerun` for the same reason.
TRANSIENT_FLAGS = {
    "--platform",
    "--rerun",
    "--dry-run",
    "--non-interactive",
    "-h",
    "--help",
    "--dev-workflows",
    "--no-dev-workflows",
    # Deprecated aliases of --dev-workflows/--no-dev-workflows.
    "--smoke-test",
    "--workflows",
    "--no-workflows",
}

# Flags a platform deliberately refuses with an explanation, instead of letting
# them fall through to "Unknown option". Each one is a statement that the
# option does not exist on that platform, so it must not have a manifest row
# there, and its arm must really die: listing it here is what keeps a
# deliberate rejection from reading as acceptance.
REJECTED_FLAGS = {
    # Tailscale runs on the Windows host, not inside the WSL distribution.
    "fedora-wsl": {"--tailscale", "--no-tailscale"},
    # TeX is externally managed on macOS; the installer owns no distribution.
    "macos": {"--latex", "--no-latex"},
}

OPTION_FIELDS = [
    "platform", "option", "kind", "on_flag", "off_flag", "default",
    "values", "capability", "summary",
]

PARSER = re.compile(
    r'while \(\(\$#\)\); do\s*case "\$1" in\n(?P<arms>.*?)\n\s*esac\s*\n\s*done',
    re.DOTALL,
)
# One case arm: a pattern of `-flag | --other` alternatives, then its body up
# to the `;;` that ends it. Arms share lines (`--kde) …; shift ;; --no-kde) …`),
# so an arm starts at a line start or right after the previous arm's `;;`.
ARM = re.compile(
    r"(?:^|;;)[ \t]*(?P<pattern>-[\w-]*(?:[ \t]*\|[ \t]*-[\w-]*)*)\)(?P<body>.*?)(?=;;)",
    re.DOTALL | re.MULTILINE,
)


def fail(message: str) -> None:
    print(f"installer option parser: {message}", file=sys.stderr)


def parser_flags(installer: pathlib.Path) -> tuple[set[str], set[str]] | None:
    """The flags a parser accepts and the flags it rejects, or None."""
    match = PARSER.search(installer.read_text(encoding="utf-8"))
    if match is None:
        return None
    accepted: set[str] = set()
    rejected: set[str] = set()
    for arm in ARM.finditer(match.group("arms")):
        flags = {flag.strip() for flag in arm.group("pattern").split("|")}
        if arm.group("body").lstrip().startswith("die"):
            rejected |= flags
        else:
            accepted |= flags
    return accepted, rejected


def main() -> int:
    errors = 0
    try:
        options = read_tsv(OPTION_MANIFEST, OPTION_FIELDS)
    except ManifestSchemaError as error:
        for message in error.messages:
            fail(message)
        return 1

    declared: dict[str, set[str]] = {}
    for option in options:
        flags = declared.setdefault(option["platform"], set())
        for column in ("on_flag", "off_flag"):
            if option[column] not in {"", "-"}:
                flags.add(option[column])

    installers = {
        path.parent.name: path for path in sorted(ROOT.glob("platforms/*/install.sh"))
    }
    for platform in sorted(set(declared) - set(installers)):
        fail(f"{platform}: the manifest declares options, but "
             f"platforms/{platform}/install.sh does not exist")
        errors += 1

    for platform, installer in installers.items():
        relative = installer.relative_to(ROOT).as_posix()
        flags = parser_flags(installer)
        if flags is None:
            fail(f"{relative}: no `while (($#)); do case \"$1\" in` argv parser found")
            errors += 1
            continue
        accepted, rejected = flags
        manifest = declared.get(platform, set())
        deliberate = REJECTED_FLAGS.get(platform, set())

        for flag in sorted(manifest):
            if flag in TRANSIENT_FLAGS:
                fail(f"{platform}: {flag} is a transient control and must not be a "
                     f"persistent option")
                errors += 1
            elif flag in rejected:
                fail(f"{platform}: the manifest declares {flag}, but {relative} "
                     f"rejects it")
                errors += 1
            elif flag not in accepted:
                fail(f"{platform}: the manifest declares {flag}, but {relative} "
                     f"has no case arm for it")
                errors += 1

        for flag in sorted(accepted - manifest - TRANSIENT_FLAGS):
            fail(f"{platform}: {relative} accepts {flag}, which the manifest does "
                 f"not declare, so ./install.sh --rerun can never remember it")
            errors += 1
        for flag in sorted(accepted & deliberate):
            fail(f"{platform}: {flag} is listed in REJECTED_FLAGS, but {relative} "
                 f"accepts it")
            errors += 1

        for flag in sorted(rejected - manifest - TRANSIENT_FLAGS - deliberate):
            fail(f"{platform}: {relative} rejects {flag}; list it in REJECTED_FLAGS "
                 f"with the reason")
            errors += 1
        for flag in sorted(deliberate - rejected - accepted):
            fail(f"{platform}: {flag} is listed in REJECTED_FLAGS, but {relative} "
                 f"has no case arm that rejects it")
            errors += 1

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
