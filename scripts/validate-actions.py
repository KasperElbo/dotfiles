#!/usr/bin/env python3
"""Validate the canonical registry of repository-defined user actions.

`config/actions.tsv` is the one authoritative inventory of what this
repository binds, aliases or installs as a user-invocable action. Prose
documentation and the printable cheat sheets are derived from it or checked
against it; neither is a second source of truth.

Four independent things are checked, because each catches a different way the
registry can quietly stop describing reality:

1. **Schema.** Columns, unique IDs, enumerated values taken from
   `config/capabilities.tsv` rather than repeated here, and the rules that
   decide when a sheet omission has to carry a written reason.
2. **Registry to implementation.** Every action this repository defines or
   configures must still match its `source_pattern` in its `source` file, and
   that pattern has to land on something other than a shebang — an interpreter
   line proves a file is a script, not that it still does what the row claims.
   Renaming a binding without updating the registry fails here.
3. **Implementation to registry.** Custom actions are extracted back out of the
   tracked configuration — Sway with its own grammar, AeroSpace through a real
   TOML parser, Waybar through a real JSON parser, tmux and the shell through
   their option and binding syntax, Neovim through its key literals, and the
   commands this repository puts on `PATH` — and each one must be claimed by a
   registry row. Adding a binding without registering it fails here.
4. **Registry to cheat sheets.** A `print=true` action must appear on every
   sheet it names, with a binding *and* a description that agree with the
   registry; a sheet that documents an action in prose has to say so with an
   explicit `% csprose:` marker rather than being matched by accident. Every
   `\\csrow` on a sheet must be claimed by a registry row that lists that sheet,
   which is what stops a shared block from advertising a Fedora-only option on
   macOS.

Usage:
    scripts/validate-actions.py [--root DIR]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import tomllib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import (  # noqa: E402
    ManifestSchemaError,
    capability_names,
    platform_profiles,
    read_tsv,
    supported_platforms,
)

FIELDS = [
    "id", "platform", "profile", "component", "origin", "input", "binding",
    "action", "source", "source_pattern", "discoverability", "print",
    "sheets", "print_reason",
]

# Both enums come from config/capabilities.tsv rather than being repeated here.
# `all` is this registry's sentinel for every platform; a profile name used as
# a platform (today only `workstation`) means every platform whose `base` row
# declares that profile, which is how the 22 workstation-only Neovim actions
# stop claiming to exist on the reduced CTF guest.
PLATFORM_PROFILES = platform_profiles()
PLATFORM_SENTINELS = {"all", *sorted(set(PLATFORM_PROFILES.values()))}
PLATFORMS = {*PLATFORM_SENTINELS, *supported_platforms()}
# A profile is either a capability this repository can install or one of the
# profiles a platform's `base` row declares. `base` is itself a capability.
PROFILES = {*capability_names(), *PLATFORM_PROFILES.values()}
# `kde` and `sway` are the two profiles that own a desktop rather than adding
# to one, so an action carrying either reaches only that desktop's sheet.
DESKTOP_PROFILES = {"kde", "sway"}

ORIGINS = {"repository", "upstream", "upstream-configured"}
# Origins where this repository wrote something that has to keep existing:
# `upstream` means the tool ships the action untouched, and has no source.
SOURCED_ORIGINS = {"repository", "upstream-configured"}
INPUTS = {"key", "mouse", "click", "command", "mode", "session"}
DISCOVERABILITY = {"whichkey", "tool-help", "shell-help", "status-bar", "config-only", "documented"}
# Each sheet is (platform, desktop profile it documents). A sheet with no
# desktop profile documents whatever its platform runs.
SHEETS = {
    "fedora-kde": ("fedora", "kde"),
    "fedora-sway": ("fedora", "sway"),
    "fedora-wsl": ("fedora-wsl", None),
    "macos": ("macos", None),
    "parrot-ctf": ("parrot-ctf", None),
}

CSROW = re.compile(
    r"\\csrow\{(?P<key>(?:[^{}]|\{[^{}]*\})*)\}\{(?P<description>(?:[^{}]|\{[^{}]*\})*)\}"
)
INPUT_DIRECTIVE = re.compile(r"\\input\{(?P<name>[^}]+)\}")
# The explicit prose claim: a sheet that documents an action in a sentence
# rather than a table row names the action id in a LaTeX comment, so the claim
# is deliberate and checkable in both directions.
CSPROSE = re.compile(r"(?m)^\s*%\s*csprose:\s*(?P<id>[A-Za-z0-9.-]+)\s*$")

# Words too common to prove that a sheet's description and the registry's
# describe the same action.
STOPWORDS = {
    "a", "all", "an", "and", "are", "as", "at", "by", "for", "from", "in",
    "into", "is", "it", "its", "of", "on", "one", "or", "the", "this", "to",
    "with",
}


def load(path: pathlib.Path) -> list[dict[str, str]]:
    try:
        return read_tsv(path, FIELDS)
    except ManifestSchemaError as error:
        raise SystemExit(
            "\n".join(f"action registry: {message}" for message in error.messages)
        ) from error


def expand_platform(platform: str) -> set[str]:
    """The concrete platforms a registry `platform` value covers."""
    if platform == "all":
        return set(supported_platforms())
    if platform in PLATFORM_PROFILES.values():
        return {name for name, profile in PLATFORM_PROFILES.items() if profile == platform}
    return {platform}


def reachable_sheets(row: dict[str, str]) -> set[str]:
    """Sheets whose platform and desktop this action actually exists on.

    This is what makes a missing sheet a decision rather than an oversight: a
    `print=true` row that reaches a sheet it does not name has to say why.
    """
    platforms = expand_platform(row["platform"])
    profile = row["profile"]
    reachable = set()
    for sheet, (platform, desktop) in SHEETS.items():
        if platform not in platforms:
            continue
        if profile in DESKTOP_PROFILES and profile != desktop:
            continue
        reachable.add(sheet)
    return reachable


def sheet_claims(row: dict[str, str]) -> list[tuple[str, bool]]:
    """The (sheet, is_prose) pairs a row's `sheets` column names."""
    claims = []
    for entry in row["sheets"].split(","):
        entry = entry.strip()
        if not entry:
            continue
        sheet, _, marker = entry.partition(":")
        claims.append((sheet, marker == "prose"))
    return claims


def check_schema(root: pathlib.Path, rows: list[dict[str, str]], problems: list[str]) -> None:
    seen: set[str] = set()
    for line, row in enumerate(rows, 2):
        where = f"line {line} ({row['id']})"
        if row["id"] in seen:
            problems.append(f"{where}: duplicate action id")
        seen.add(row["id"])
        if not re.fullmatch(r"[a-z0-9]+(?:[.-][a-z0-9]+)*", row["id"]):
            problems.append(f"{where}: id must be lowercase dotted/dashed segments")
        for column, allowed in (
            ("platform", PLATFORMS), ("profile", PROFILES), ("origin", ORIGINS),
            ("input", INPUTS), ("discoverability", DISCOVERABILITY),
        ):
            if row[column] not in allowed:
                problems.append(
                    f"{where}: invalid {column} {row[column]!r}; "
                    f"expected one of {', '.join(sorted(allowed))}"
                )
        if row["print"] not in {"true", "false"}:
            problems.append(f"{where}: print must be true or false")
            continue
        for column in ("binding", "action", "component", "profile"):
            if not row[column] or row[column] == "-":
                problems.append(f"{where}: {column} is required")
        if row["print"] == "true":
            if row["sheets"] == "-" or not row["sheets"]:
                problems.append(f"{where}: print=true must name the sheets it appears on")
                continue
            named = set()
            for sheet, _ in sheet_claims(row):
                if sheet not in SHEETS:
                    problems.append(f"{where}: unknown cheat sheet {sheet!r}")
                named.add(sheet)
            withheld = reachable_sheets(row) - named
            if withheld and row["print_reason"] in {"", "-"}:
                problems.append(
                    f"{where}: the action exists on {', '.join(sorted(withheld))} but is "
                    "not printed there; record why in print_reason"
                )
            if not withheld and row["print_reason"] != "-":
                problems.append(
                    f"{where}: print_reason belongs to rows that omit a sheet they reach"
                )
        else:
            if row["sheets"] != "-":
                problems.append(f"{where}: print=false must not name sheets")
            if row["print_reason"] in {"", "-"}:
                problems.append(f"{where}: print=false requires a rationale")
        if row["origin"] in SOURCED_ORIGINS:
            if row["source"] in {"", "-"}:
                problems.append(f"{where}: a {row['origin']} action must name its source")
            elif not (root / row["source"]).is_file():
                problems.append(f"{where}: source does not exist: {row['source']}")
            if row["source_pattern"] in {"", "-"}:
                problems.append(f"{where}: a {row['origin']} action must name a source pattern")
        else:
            if row["source"] not in {"", "-"} or row["source_pattern"] not in {"", "-"}:
                problems.append(
                    f"{where}: origin=upstream means the tool ships the action untouched; "
                    "use upstream-configured when this repository changes it"
                )


# Comment syntax by source suffix, for `code_text()`. A configuration file
# with no suffix (the Sway config, a PATH command) takes the default.
COMMENT_PREFIXES = {".lua": ("--",), ".jsonc": ("//",), ".json": ("//",)}
DEFAULT_COMMENT_PREFIX = ("#",)
# Block comments, which a line prefix cannot see. Disabling a Lua keymap with
# `--[[ ]]` or a Waybar module with `/* */` is as complete a removal as
# commenting each line out, and Neovim really does stop loading the keys: only
# the line-prefix half of this was checked, so the registry and the printed
# sheets kept advertising bindings the editor no longer had. A Lua long
# comment may carry any number of `=` signs, and its closer has to match its
# opener, which is what `(?P=level)` holds it to.
BLOCK_COMMENTS = {
    ".lua": re.compile(r"--\[(?P<level>=*)\[.*?\](?P=level)\]", re.DOTALL),
    ".jsonc": re.compile(r"/\*.*?\*/", re.DOTALL),
    ".json": re.compile(r"/\*.*?\*/", re.DOTALL),
}


def blank_block_comments(text: str, suffix: str) -> str:
    """`text` with each block comment blanked, its line breaks kept.

    Blanking rather than deleting is what keeps every later line at the number
    it has in the file, so a reported line number still points at the line the
    reader saw.
    """
    expression = BLOCK_COMMENTS.get(suffix)
    if expression is None:
        return text
    return expression.sub(
        lambda match: "".join(
            character if character == "\n" else " " for character in match.group(0)
        ),
        text,
    )


def code_text(path: pathlib.Path) -> str:
    """`path` with every comment blanked out, line numbering intact.

    A source_pattern is evidence that the tool still has the action, so it has
    to match a line the tool actually reads. Commenting a binding out would
    otherwise keep the registry and the printed cheat sheet advertising a key
    that does nothing. `implemented_actions()` already reads the Sway config
    this way; this is the same rule for the opposite direction.

    Comment lines are blanked rather than dropped so a multiline pattern still
    sees the distance between the lines it spans, and the shebang is kept so a
    pattern anchored on it is still reported as anchored on the shebang. Block
    comments are blanked first, for the same reason and by the same rule: what
    the tool reads is what counts, not which comment syntax was used.
    """
    prefixes = COMMENT_PREFIXES.get(path.suffix, DEFAULT_COMMENT_PREFIX)
    lines = blank_block_comments(
        path.read_text(encoding="utf-8"), path.suffix
    ).splitlines()
    kept = []
    for number, line in enumerate(lines, 1):
        if number == 1 and line.startswith("#!"):
            kept.append(line)
        elif line.lstrip().startswith(prefixes):
            kept.append("")
        else:
            kept.append(line)
    return "\n".join(kept)


def check_registry_matches_implementation(
    root: pathlib.Path, rows: list[dict[str, str]], problems: list[str]
) -> None:
    cache: dict[str, str] = {}
    for row in rows:
        if row["origin"] not in SOURCED_ORIGINS:
            continue
        source = row["source"]
        pattern = row["source_pattern"]
        if source in {"", "-"} or pattern in {"", "-"}:
            continue
        path = root / source
        if not path.is_file():
            continue
        if source not in cache:
            cache[source] = code_text(path)
        try:
            expression = re.compile(pattern, re.MULTILINE)
        except re.error as error:
            problems.append(f"{row['id']}: invalid source pattern: {error}")
            continue
        text = cache[source]
        matches = list(expression.finditer(text))
        if not matches:
            problems.append(
                f"{row['id']}: source_pattern no longer matches {source}; "
                "the action was renamed, moved or removed"
            )
            continue
        # An interpreter line is true of every script in the repository, so a
        # pattern that only ever lands on one proves nothing about the action.
        if all(text.startswith("#!", text.rfind("\n", 0, match.start()) + 1)
               for match in matches):
            problems.append(
                f"{row['id']}: source_pattern only matches the shebang of {source}; "
                "anchor it on the action itself"
            )


def strip_jsonc(text: str) -> str:
    """JSONC with its comments taken out, ready for `json.loads`.

    The block comments go through the same blanker `code_text` uses, so the
    two directions of this check cannot disagree about what a comment is: a
    Waybar module disabled with `/* */` has to read as gone to both of them.
    """
    return re.sub(r"(?m)^\s*//.*$", "", blank_block_comments(text, ".jsonc"))


# Zsh options that decide how history is stored rather than what a key or a
# typed word does. Everything else has to be registered or the gate fails.
HISTORY_OPTIONS = re.compile(r"^(HIST_|EXTENDED_HISTORY|SHARE_HISTORY|(INC_)?APPEND_HISTORY)")
# tmux settings that change what the user's keys and mouse do, as opposed to
# colours, limits and timeouts.
TMUX_INTERACTION_OPTIONS = {
    "prefix", "prefix2", "mouse", "base-index", "pane-base-index",
    "mode-keys", "status-keys",
}
# Neovim globals that decide what a user-facing key or command actually does:
# `gx` and Markdown preview go through vim.ui.open and mkdp_browserfunc, the
# unnamed-plus registers through vim.g.clipboard, and VimTeX's view key through
# its viewer. Other vim.g settings are provider and language-server plumbing.
NVIM_BEHAVIOUR_GLOBALS = re.compile(
    r"\bvim\.(ui\.open|g\.(clipboard|mkdp_browserfunc|vimtex_view_general_viewer))\s*="
)
# A Neovim key literal, as opposed to a `<plug>`/`<cmd>` right-hand side.
NVIM_KEY_LITERAL = re.compile(r'"(<(?:leader|localleader|[SCMAD])[^"]*)"')


def shell_files(root: pathlib.Path) -> list[pathlib.Path]:
    """Every tracked Zsh startup file, shared and per-platform."""
    files = [root / "zsh/.zshenv", root / "zsh/.config/zsh/.zshrc"]
    files += sorted((root / "platforms").glob("*/stow/zsh-platform/.config/zsh/*.zsh"))
    return [path for path in files if path.is_file()]


def nvim_files(root: pathlib.Path) -> list[pathlib.Path]:
    """Every tracked Neovim Lua file, shared and per-platform."""
    files = sorted((root / "nvim-lazyvim").rglob("*.lua"))
    files += sorted((root / "platforms").glob("*/stow/nvim-*/**/*.lua"))
    return [path for path in files if path.is_file()]


def path_commands(root: pathlib.Path) -> list[pathlib.Path]:
    """Every command this repository puts on the user's PATH."""
    files = sorted((root / "bin/.local/bin").glob("*"))
    files += sorted((root / "platforms").glob("*/stow/*/.local/bin/*"))
    return [path for path in files if path.is_file()]


def implemented_actions(root: pathlib.Path) -> list[tuple[str, str]]:
    """Every custom action the tracked configuration actually defines.

    Returned as (source, evidence) pairs, where the evidence is the exact text
    a registry row has to claim.
    """
    found: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()

    def record(path: pathlib.Path, evidence: str) -> None:
        entry = (str(path.relative_to(root)), evidence)
        if entry in seen:
            return
        seen.add(entry)
        found.append(entry)

    sway = root / "platforms/fedora/stow/sway/.config/sway/config"
    if sway.is_file():
        for line in sway.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith((
                "bindsym ", "bindgesture ", "floating_modifier ",
                "exec ", "exec_always ",
            )):
                record(sway, stripped)

    aerospace = root / "platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml"
    if aerospace.is_file():
        data = tomllib.loads(aerospace.read_text(encoding="utf-8"))
        for mode, definition in (data.get("mode") or {}).items():
            for key, command in (definition.get("binding") or {}).items():
                rendered = command if isinstance(command, str) else " ".join(command)
                record(aerospace, f"{key} = '{rendered}'")

    waybar = root / "platforms/fedora/stow/waybar/.config/waybar/config.jsonc"
    if waybar.is_file():
        data = json.loads(strip_jsonc(waybar.read_text(encoding="utf-8")))
        for module, definition in data.items():
            if not isinstance(definition, dict):
                continue
            for key, value in definition.items():
                # `disable-*` suppresses an interaction Waybar offers by
                # default, which is as much a decision as adding one.
                if key.startswith(("on-click", "on-scroll", "disable-")) or key == "exec":
                    rendered = json.dumps(value)
                    record(waybar, f'"{key}": {rendered}')

    tmux = root / "tmux/.tmux.conf"
    if tmux.is_file():
        for line in tmux.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith(("bind ", "bind-key ", "unbind ", "unbind-key ")):
                record(tmux, stripped)
                continue
            option = re.match(r"^(?:set|setw|set-option|set-window-option)\b.*?([\w-]+)\s+\S+$",
                              stripped)
            if option and option.group(1) in TMUX_INTERACTION_OPTIONS:
                record(tmux, stripped)

    for path in shell_files(root):
        text = path.read_text(encoding="utf-8")
        for match in re.finditer(r"(?m)^\s*alias\s+([A-Za-z0-9_-]+)=(.*)$", text):
            record(path, f"alias {match.group(1)}={match.group(2).strip()}")
        # Public shell functions only: a leading underscore marks an internal
        # helper, which is not a user action.
        for match in re.finditer(r"(?m)^([a-z][A-Za-z0-9_-]*)\(\)\s*\{", text):
            record(path, f"{match.group(1)}() {{")
        for match in re.finditer(r"(?m)^\s*((?:un)?setopt)\s+([A-Za-z_]+)", text):
            if HISTORY_OPTIONS.match(match.group(2)):
                continue
            record(path, f"{match.group(1)} {match.group(2)}")
        # Literal key bindings, including the repository's own bindkey wrapper;
        # the wrapper's internal `bindkey -- "$sequence"` binds a variable and
        # is not itself an action.
        for match in re.finditer(r"(?m)^\s*(_dotfiles_bindkey|bindkey)\s+([^\s$-][^\s]*)", text):
            record(path, f"{match.group(1)} {match.group(2)}")

    for path in nvim_files(root):
        # The whole line is the evidence: a Lua keymap is a key literal plus
        # the field or table position that gives it meaning, and a registry
        # row has to claim both.
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if NVIM_KEY_LITERAL.search(stripped) or NVIM_BEHAVIOUR_GLOBALS.search(stripped):
                record(path, stripped)

    for path in path_commands(root):
        record(path, f"{path.name} on PATH")

    return found


def check_implementation_is_registered(
    root: pathlib.Path, rows: list[dict[str, str]], problems: list[str]
) -> None:
    patterns: list[tuple[str, re.Pattern[str]]] = []
    sourced: set[str] = set()
    for row in rows:
        if row["origin"] not in SOURCED_ORIGINS or row["source_pattern"] in {"", "-"}:
            continue
        sourced.add(row["source"])
        try:
            patterns.append((row["source"], re.compile(row["source_pattern"])))
        except re.error:
            continue

    for source, evidence in implemented_actions(root):
        if evidence.endswith(" on PATH"):
            # A command on PATH is registered either as an action in its own
            # right — a row naming the script as its source — or as the helper
            # a registered binding spawns.
            name = evidence[: -len(" on PATH")]
            if source in sourced:
                continue
            spawned = re.compile(
                rf"(?:exec|exec_always|exec-and-forget|\"exec\":|/bin/)"
                rf"[^\n]*?(?<![\w-]){re.escape(name)}(?![\w-])"
            )
            if any(spawned.search(pattern.pattern) for _, pattern in patterns):
                continue
        elif any(source == owner and expression.search(evidence)
                 for owner, expression in patterns):
            continue
        problems.append(
            f"{source}: unregistered custom action: {evidence.strip()!r}; "
            "add it to config/actions.tsv"
        )


def expanded_sheet(root: pathlib.Path, sheet: str) -> str:
    directory = root / "docs" / "cheatsheets"
    path = directory / f"{sheet}.tex"
    if not path.is_file():
        return ""
    text = path.read_text(encoding="utf-8")
    for match in INPUT_DIRECTIVE.finditer(text):
        included = directory / f"{match.group('name')}.tex"
        if included.is_file():
            text += "\n" + included.read_text(encoding="utf-8")
    return text


def normalize(value: str) -> str:
    """Compare bindings without LaTeX escaping or spacing noise."""
    value = re.sub(r"\\texttt\{([^{}]*)\}", r"\1", value)
    value = re.sub(r"\\textbar\s*", "|", value)
    value = re.sub(r"\\textasciitilde\s*", "~", value)
    value = re.sub(r"\\[a-zA-Z]+", "", value)
    value = value.replace("\\", "")
    value = re.sub(r"[{}$]", "", value)
    return re.sub(r"\s+", "", value).lower()


def words(value: str) -> set[str]:
    """Content words of a description, for comparing two wordings of it."""
    value = re.sub(r"\\texttt\{([^{}]*)\}", r"\1", value)
    value = re.sub(r"\\[a-zA-Z]+", " ", value)
    tokens = re.split(r"[^A-Za-z0-9]+", value.lower())
    return {token for token in tokens if len(token) > 2 and token not in STOPWORDS}


def check_cheat_sheets(root: pathlib.Path, rows: list[dict[str, str]], problems: list[str]) -> None:
    sheets = {sheet: expanded_sheet(root, sheet) for sheet in sorted(SHEETS)}
    for sheet, text in sheets.items():
        if not text:
            problems.append(f"cheat sheet source is missing: docs/cheatsheets/{sheet}.tex")

    printed = {
        sheet: {
            normalize(match.group("key")): match.group("description")
            for match in CSROW.finditer(text)
        }
        for sheet, text in sheets.items()
    }
    prose = {
        sheet: {match.group("id") for match in CSPROSE.finditer(text)}
        for sheet, text in sheets.items()
    }
    claimed: dict[str, set[str]] = {sheet: set() for sheet in sheets}
    claimed_prose: dict[str, set[str]] = {sheet: set() for sheet in sheets}

    for row in rows:
        if row["print"] != "true":
            continue
        binding = normalize(row["binding"])
        for sheet, is_prose in sheet_claims(row):
            if sheet not in sheets:
                continue
            if is_prose:
                # A prose claim is deliberate: the sheet names the action id in
                # a `% csprose:` comment beside the sentence that documents it.
                if row["id"] in prose[sheet]:
                    claimed_prose[sheet].add(row["id"])
                else:
                    problems.append(
                        f"{row['id']}: sheets names {sheet}:prose, but "
                        f"docs/cheatsheets/{sheet}.tex carries no "
                        f"'% csprose: {row['id']}' marker"
                    )
                continue
            if binding not in printed[sheet]:
                problems.append(
                    f"{row['id']}: print=true names {sheet}, but the sheet does not "
                    f"document {row['binding']!r}"
                )
                continue
            claimed[sheet].add(binding)
            # The binding matching is not enough: a row can keep its key and
            # describe something the implementation no longer does.
            if not words(printed[sheet][binding]) & words(row["action"]):
                problems.append(
                    f"{row['id']}: docs/cheatsheets/{sheet}.tex describes "
                    f"{row['binding']!r} as {printed[sheet][binding]!r}, which shares "
                    f"no word with the registry's {row['action']!r}"
                )

    for sheet, sheet_rows in printed.items():
        for key in sorted(set(sheet_rows) - claimed[sheet]):
            problems.append(
                f"docs/cheatsheets/{sheet}.tex: printed action {key!r} is not in "
                "config/actions.tsv for this sheet"
            )
    for sheet, markers in prose.items():
        for identifier in sorted(markers - claimed_prose[sheet]):
            problems.append(
                f"docs/cheatsheets/{sheet}.tex: '% csprose: {identifier}' claims an "
                f"action that does not name {sheet}:prose in config/actions.tsv"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    rows = load(root / "config" / "actions.tsv")
    problems: list[str] = []
    check_schema(root, rows, problems)
    check_registry_matches_implementation(root, rows, problems)
    check_implementation_is_registered(root, rows, problems)
    check_cheat_sheets(root, rows, problems)

    for problem in problems:
        print(f"action registry: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
