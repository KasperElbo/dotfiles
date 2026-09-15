# Documentation, reference, cheat-sheet and maintainability audit

Repository: `KasperElbo/dotfiles`, audited at `32ad606` (`main`, 2026-09-15).
Read-only audit. No tracked file was modified, no generator output was
committed, and the working tree was byte-identical before and after
(`git status --short --ignored` empty after cleanup of the untracked PDF build
output the audit produced). Every finding cites the file and line it was
verified against; nothing below is inferred from a file name or a comment.

Validation actually run in this audit (Ubuntu 24.04 container, tools
installed for the purpose):

| Check | Result |
|---|---|
| `./scripts/lint.sh` | ShellCheck step exits 1 under ShellCheck 0.9.0: 194 *info*-level notes (SC2015, SC2119), 0 warnings, 0 errors. Environment-dependent; see DOC-066. Every later lint stage was run individually and passes (below). |
| `render-capability-matrix.py --check`, `render-installer-options.py --check`, `render-action-reference.py --check`, `render-supply-chain.py --check`, `update-starship-themes.sh --check` | all pass |
| `validate-actions.py`, `validate-docs.py`, `validate-capabilities.py`, `validate-fedora-dependency-closure.py`, `validate-network-sources.py`, `validate-repository-hygiene.py`, `validate-shell-file-roles.py` | all pass |
| Write-mode regeneration of all five generators, then `git status --short` | clean: regeneration is deterministic and produces no unrelated change |
| `./scripts/test.sh` | 67 passed, 2 failed, both environmental (`test-csharpier-ownership.sh`: Ubuntu Neovim 0.9.5 lacks `vim.uv`; `test-idempotency.sh`: no `ssh`/`scp`/`sftp` client in the container). See DOC-066. |
| `git diff --check` | clean |
| `docs/cheatsheets/generate.sh` + `docs/cheatsheets/verify.sh` | all five sheets compile, are A4, have no overfull box > 1 pt, no undefined reference, and are byte-reproducible across two builds |
| Rendered pages inspected visually (`pdftoppm`) | see §4 |
| Installer `--help` for all four platforms compared mechanically with `config/install-options.tsv` | every flag in every help text is in the manifest and vice versa |

---

# 1. Executive summary

This is a well-engineered documentation system with an unusually strong core:
a set of tab-separated manifests under `config/` are the declared source of
truth, four reference documents and the Starship configurations are generated
from them, `lint.sh` fails when any generated artifact is stale, an action
registry drives both the exhaustive keybinding reference and the printable
cheat sheets in both directions, and CI compiles and verifies the sheets. The
generated material is correct and current. The workflow guides for rerun,
theming precedence, shell PATH policy, Git identity and the WSL/Parrot
platform guides are accurate line for line.

The problems are concentrated in four places:

1. **The two structured manifests disagree with each other and with the
   installer on defaults.** `config/capabilities.tsv` says KDE and LaTeX
   default to `auto` on Fedora; `config/install-options.tsv` says `false`;
   the installer auto-detects KDE and prompts for LaTeX. The generated
   reference therefore publishes a wrong default for the default platform's
   most visible option, and nothing cross-validates the two files. Package
   lists in `capabilities.tsv` also diverge from what five installer scripts
   actually install, and one capability names a verifier that verifies nothing.
2. **Prose documents that transcribe manifest or code data by hand have
   drifted.** `package-ownership.md` (36% transcribed data, four errors),
   `installation.md` (flow trees missing four optional profiles and the whole
   macOS flow), `file-ownership.md` (omits the lifecycle state directory and
   three platform Stow trees), `defaults.md`, `verification.md` (omits seven
   of the verifier's sections), and the hand-written half of `keybindings.md`
   (52 rows restating the registry).
3. **The two failures a new machine is most likely to hit are undocumented:**
   a Stow conflict with a pre-existing `~/.zshrc`, and a prompt full of missing
   glyphs because no Nerd Font is installed on Fedora, WSL or macOS.
   `./doctor` is absent from the troubleshooting guide, and the confirmation
   prompt is both undocumented and mis-implemented (Enter cancels).
4. **The action registry has platform-attribution and coverage gaps.** 22
   Neovim actions are tagged `platform=all` but do not exist on the Parrot
   guest; the Parrot sheet omits shared actions that do exist there; the
   WSL sheet prints a Ghostty command the WSL runtime does not have; and the
   registry gate never compares a binding or a description to its source.

| Dimension | Grade | Why |
|---|---|---|
| Correctness | **B** | Generated references, rerun, theming, shell, Git and the four platform guides are accurate. Against that: a wrong published default (DOC-001), a manifest verifier that checks nothing (DOC-004), a truncated paragraph and dangling cross-references (DOC-015/016), a wrong state-file path (DOC-017), and installer messages pointing at README sections that no longer exist (DOC-039). |
| Completeness | **B-** | Verification covers one of four platforms (DOC-041); troubleshooting has no installer, Stow, font, lifecycle or Mason entries (DOC-043/044/045); editor provisioning and the profile mechanism are undocumented (DOC-023); the Parrot sheet withholds actions with no recorded reason (DOC-050). |
| Maintainability | **B** | The manifest/generator/gate design is the right one and should be kept. But `cli_flag`/`default` are duplicated across two manifests with different vocabularies (DOC-002), package lists are copied into a manifest nobody checks against the installers (DOC-003), and ~250 lines of prose restate manifests or `plan_add` lists by hand (DOC-005..008, DOC-062). Adding a platform touches at least twelve hard-coded lists (DOC-011), and the conventions page and the roles manifest disagree on what is public (DOC-068). |
| Discoverability | **B-** | The README and index are good entry points. `./doctor`, the per-platform verifiers, the confirmation prompt and the Stow-conflict remedy are not reachable from where a user would look (DOC-038, DOC-041, DOC-035, DOC-043). |
| Cheat sheets | **B** | Curated, budget-enforced, reproducible, and every printed binding exists. But the WSL PDF's second page is an orphan footer on a blank page (DOC-052), the Sway/macOS sheets leave half of page 1 empty (DOC-053), the WSL sheet tells its reader to run `ghostty` (DOC-051), and the Parrot sheet is 35% of one page while omitting things Parrot has (DOC-050). |
| Drift protection | **B** | Five generators with `--check` in lint, link/anchor/orphan/stale-claim validation, and a two-way action gate are real protection. The gaps: no manifest-to-manifest check, no manifest-to-installer package check, no check of any prose table, and the action gate's substring fallback lets a single-letter binding "match" any sheet (DOC-063). |

Highest-value improvements, in order: fix the manifest defaults and add the
cross-manifest and package-parity checks (WS-A); document the prompt, `doctor`,
Stow conflicts and the font requirement (WS-D/E); retag the Neovim actions and
give the Parrot sheet the shared block (WS-F); replace the hand-copied prose
tables with generated or linked material (WS-B).

**Could a documented claim cause the wrong thing to be installed or configured
on a supported platform?** Yes, in five places:

- DOC-001: a `--rerun` record written before the `kde`/`latex` option existed
  is reconstructed with `--no-kde`/`--no-latex` (`install-selection.sh:170-175`
  reads the manifest default `false`), overriding the auto-detect/prompt
  behaviour the installer otherwise has.
- DOC-036: a failed Fedora WSL or Parrot install prints a "Safe rerun" command
  with none of the user's options, so following it reinstalls fewer profiles.
- DOC-046: the troubleshooting remedy for a missing AI tool regenerates
  `ai.toml` without `--gnhf`/`--backpass`, after which `verify-ai.sh` fails.
- DOC-018: on macOS `install-containers.sh` has no argument parser, so a user
  following the containers guide's `--api-socket` instruction gets it silently
  ignored rather than rejected.
- DOC-051: the WSL cheat sheet instructs the reader to run
  `ghostty +list-keybinds --default`, a binary the WSL runtime never installs.

---

# 2. Documentation architecture

## Current structure

`docs/README.md` defines seven roles with an explicit precedence order:
structured contract (`config/*.tsv`) > generated reference > platform/profile
guides > workflow guides > full action reference > printable cheat sheets >
rationale/history. This is the right shape, it is written down, and
`tests/test-documentation.sh` asserts the roles section exists and that the
README stays an entry point (< 400 lines). The root README is a real overview
(220 lines) that links out rather than restating.

Roles are clear on paper. In practice three things blur them:

1. **Role 1 has two overlapping members.** `capabilities.tsv` carries
   `cli_flag` and `default` columns; `install-options.tsv` carries `on_flag`,
   `off_flag` and `default` for the same options with a different vocabulary
   (`auto|enabled|disabled` vs `true|false|inherit`). `docs/capabilities.md`
   describes the first and never mentions the second. Nothing validates them
   against each other (DOC-002).
2. **Role 2 is under-declared.** The index lists three generated documents.
   Five artifacts are generated and lint-gated: those three, the generated
   block of `keybindings.md`, and the four Starship files (DOC-009).
3. **Roles 3/4/7 contain role-1 data transcribed by hand.**
   `package-ownership.md`, `installation.md`, `file-ownership.md`,
   `defaults.md`, `verification.md` and the top half of `keybindings.md`
   all restate manifest rows or `plan_add` sequences (DOC-005..008, 041, 062).

Duplication and competing sources of truth, with the source that should win:

| Duplicated claim | Copies | Should be authoritative |
|---|---|---|
| Option flags and defaults | `capabilities.tsv`, `install-options.tsv`, each platform `usage()`, `installer-options.md` (generated), `install.md` prose | `install-options.tsv` for flag/default/kind; `capabilities.tsv` should not carry `cli_flag`/`default` at all, or must be validated against it |
| Package lists per capability | `capabilities.tsv`, `platforms/*/scripts/install-*.sh` arrays, `package-ownership.md`, profile guides | the installer arrays are what runs; `capabilities.tsv` must be validated against them, and prose should link, not list |
| Install step order | `plan_add` calls, `installation.md` trees | `plan_add`; the trees should be generated or replaced by "run `--dry-run`" |
| Machine-local state files | `profile-state.sh`, `theme-shared-state.sh`, `file-ownership.md`, `rerun.md`, `theming.md` | `capabilities.tsv` `state` column plus one generated or checked list |
| Verifier per platform/capability | `capabilities.tsv` `verifier` column, `verification.md`, platform guides | the manifest column; `verification.md` should render it |
| Actions | `config/actions.tsv`, generated block, hand tables in `keybindings.md`, sheets | the registry; the hand tables should shrink to discovery guidance |
| Platform list | 12 code sites, 6 doc sites | `capabilities.tsv` `base` rows (already used by `install-main.sh`) |

Documents in the wrong place or mixing roles:

- `docs/workflows/verification.md`: half of it is test-architecture prose that
  belongs to `docs/testing.md` (DOC-042).
- `docs/workflows/first-run.md` §6 "SFTP client" is not a choice the user makes
  and is Fedora/KDE-specific; it belongs in the Fedora guide or the shell
  workflow (DOC-033).
- `docs/workflows/install.md` quick start: Fedora-desktop reboot/Plasma/Ghostty
  rationale sits in the platform-neutral section (DOC-024).
- `docs/platforms/macos.md` (623 lines) restates ten sections that profile and
  workflow guides own (DOC-028).
- `docs/reference/keybindings.md`: hand-written tables above the generated
  block duplicate 52 of its rows (DOC-062).

Issue references: all 30-odd `#NNN` references are in test headers, code
comments and `docs/testing.md`/`parrot-ctf-shell-audit.md` rationale, and
`validate-docs.py` blocks the "waiting for #N" pattern in guides. No stale
normative issue dependency was found. No TODO/FIXME exists outside `mktemp`
templates and the validator's own regex.

## Proposed target structure

No restructuring of directories is needed. Three targeted changes:

1. Make `docs/README.md` role 2 list all five generated artifacts, and add a
   `docs/reference/generated.md` (or a section in
   `repository-conventions.md`) that is the single "do not edit these" list.
2. Turn the three most drift-prone prose tables into generated or validated
   blocks with the same BEGIN/END-marker pattern `keybindings.md` already
   uses: `package-ownership.md` package blocks, `installation.md` flow trees
   (or delete them), `verification.md` verifier table, `file-ownership.md`
   state-file list.
3. Shrink `macos.md`, `verification.md` and the hand tables in
   `keybindings.md` to what only they can say, linking to the owner.

---

# 3. Implementation/documentation parity matrix

Legend: **Impl** = accepted by parser and installed; **Verif** = a verifier
actually checks it; **Docs** = documented where the manifest says; **Sheet** =
on the platform's printable sheet or in the generated reference.

## Fedora workstation

| Capability | Impl | Verif | Docs | Sheet/ref | Mismatch |
|---|---|---|---|---|---|
| base | `install-system.sh` + `install-terra.sh`; packages match manifest exactly | `verify.sh` | fedora.md, README | kde/sway sheets | — |
| kde (`--kde`) | auto-detects `plasmashell` (`install.sh:124`) | `verify.sh:107` | theming.md#kde | kde sheet | published default `false` (DOC-001); `verification.md` omits the KDE section (DOC-041) |
| latex (`--latex`) | prompts, default no (`install.sh:125-130`) | **none** (`verify.sh` has zero LaTeX checks) | latex.md | ref only | DOC-001, DOC-004 |
| sway (`--sway`) | `install-sway.sh`; bindings verified line by line | `verify.sh:309` | fedora.md#optional-sway-session | sway sheet | `verification.md` omits it (DOC-041) |
| hardware (`--hardware`, `--secure-boot`, `--charge-limit`) | `install-asus-hardware.sh` | `verify-asus-hardware.sh` | fedora.md#asus-laptop-hardware | — | doc never shows `--hardware` (DOC-013); manifest packages `asusctl,akmods` vs 5-13 actually installed (DOC-003); installer message points at deprecated `scripts/verify.sh` (DOC-039) |
| vm-host / vm-guest | conflicts enforced (`install.sh:114-115`) | own verifiers | profiles/vm-*.md | — | manifest lists 5 of 13 vm-host packages, omits vm-guest `xclip` (DOC-003); vm-host.md has no commands or conflict note (DOC-021) |
| hardening | `install-hardening.sh` | `verify-hardening.sh` | profiles/hardening.md | — | manifest names `policycoreutils-python-utils` (never installed) and `dnf-automatic` (actual: `dnf5-plugin-automatic`) (DOC-003) |
| desktop-tools | `install-desktop-tools.sh` | `verify-desktop-tools.sh` | profiles/desktop-tools.md | — | script installs `xdg-utils`, owned by `base` in the manifest; two docs repeat the wrong owner (DOC-003) |
| containers, tailscale | own scripts | own verifiers | profile guides | — | `verification.md` omits both (DOC-041); help text points at README sections that do not exist (DOC-039) |
| ai + codex/firstmate/gnhf/backpass | `common/install-ai.sh` | `common/verify-ai.sh` | profiles/ai.md | — | `defaults.md` names only Codex/FirstMate (DOC-006); "rejects exactly that sub-flag" is macOS-only (DOC-019); `lavish-axi` owned by `firstmate` alone in manifest but installed by `--backpass` too (DOC-003) |
| dotnet-debug, dev-workflows | mise config / `test-dev-workflows.sh` | self | development.md | ref | dev-workflows is a capability with a flag but no option row and is listed as a transient control (DOC-002, DOC-025) |

## Fedora on WSL

| Capability | Impl | Verif | Docs | Sheet/ref | Mismatch |
|---|---|---|---|---|---|
| base (headless, no Ghostty) | `install-system.sh`; `common/stow.sh --headless` | `verify.sh` (asserts no Ghostty config) | fedora-wsl.md | wsl sheet | shared sheet block prints `ghostty +list-keybinds` and Linux/macOS copy keys (DOC-051) |
| terminal (Windows-owned Noctty) | `platforms/windows/install.ps1` via Scoop | `verify.ps1` | fedora-wsl.md:59-126 | wsl sheet | doc omits that Scoop itself is fetched and installed (DOC-027) |
| latex | forwarded to Fedora script; verifier takes `--latex` | `verify.sh --latex` | latex.md | — | the only platform whose verifier checks LaTeX |
| containers (+api-socket) | WSL wrapper → Fedora script | `verify-containers.sh` | fedora-wsl.md#podman-containers-under-wsl | — | — |
| ai + subcomponents | shared | shared | fedora-wsl.md:566 | — | doc names only `--codex --firstmate` and points "below" at a section that is in another file (DOC-014); dry-run prints raw gnhf/backpass values (DOC-040) |
| tailscale | explicitly rejected with message | — | tailscale.md#fedora-wsl-policy | — | fedora-wsl.md references the section by name without a link (DOC-014) |
| Recovery | — | — | — | — | "Safe rerun" is the fixed string `./install.sh --platform fedora-wsl --non-interactive` (DOC-036) |

## Apple Silicon macOS

| Capability | Impl | Verif | Docs | Sheet/ref | Mismatch |
|---|---|---|---|---|---|
| base | `brew bundle` — Brewfile matches manifest exactly, casks included | `verify.sh` | macos.md | macos sheet | 623-line guide duplicates ten sections (DOC-028); "reads only `--platform`" stale (DOC-026) |
| defaults (`--defaults`) | `apply-defaults.sh`, 13 keys | `verify.sh --defaults` | macos.md#7 | — | `--defaults` flag on the verifier documented; `--containers`/`--tailscale` verifier flags documented nowhere (DOC-041) |
| containers | `install-containers.sh` has **no argument parser** | `verify.sh --containers` | containers.md | — | guide presents Linux-only `--api-socket`, subuid, SELinux, `--skip-smoke-test` as generic (DOC-018) |
| tailscale | cask `tailscale-app` | `verify.sh --tailscale` (warns, does not fail, on undetermined state) | tailscale.md#macos | — | tailscale.md names the Fedora state file for macOS and says undetermined state "fails" (DOC-017) |
| latex | rejected with actionable message | — | macos.md#latex-is-externally-managed-on-macos | ref | correct |
| ai | shared; per-flag capability gate | shared | macos.md#ai-assisted-development-toolchain | — | manifest points macOS AI docs at the annex, not the profile guide (DOC-020) |
| `--non-interactive` | `preflight_sudo` only when Homebrew missing; `chsh` later needs sudo | — | bootstrap-help.txt | — | can still block on a sudo prompt (DOC-034) |

## Parrot Security Edition CTF guest

| Capability | Impl | Verif | Docs | Sheet/ref | Mismatch |
|---|---|---|---|---|---|
| base (APT) | `install-system.sh` | `verify.sh` | parrot-ctf.md (most accurate guide of the four) | parrot sheet | installer also installs `fontconfig`, `konsole`, `xz-utils`; manifest stow column lists `mise`, which `--without-mise` never deploys (DOC-003) |
| vm-guest (always on) | `install-guest-integration.sh` | `verify.sh` | parrot-ctf.md | — | — |
| terminal (Konsole profile + Hack Nerd Font) | `install-terminal.sh` | `verify.sh:259-299` | parrot-ctf.md:96-102 | — | not modeled as a `terminal` capability row; `installation.md` tree omits the step (DOC-007, DOC-067) |
| neovim reduced profile | `install-neovim-tools.sh --profile parrot-ctf` | `verify.sh` | parrot-ctf.md | sheet prose | registry tags VimTeX/table-nvim/EasyDotnet actions `platform=all` although `lua/plugins` is not imported on this profile (DOC-048) |
| shared shell (`theme`, `tar`, `untar`, `shell-integrations`, line editing, tmux, fzf) | stowed via `common/stow.sh` and installed | — | — | **not on the Parrot sheet**, no recorded reason (DOC-050) |
| `--dev-workflows`, all optional profiles | rejected | — | parrot-ctf.md | — | `installer-options.md` lists `--dev-workflows` as a universal control (DOC-025) |
| Recovery | — | — | — | — | fixed "Safe rerun" string (DOC-036) |

## Windows side

`platforms/windows/install.ps1` installs Noctty through Scoop, manages a
`shared.conf` include and a theme script, and `verify.ps1` validates it.
`docs/platforms/fedora-wsl.md:59-126` matches the manifest (`manifest.psd1`)
parameter for parameter. No document calls the WSL terminal Ghostty; the
only inaccuracy is the shared cheat-sheet block (DOC-051) and the missing
sentence about Scoop itself (DOC-027). `verify.ps1` and
`platforms/windows/set-noctty-theme.ps1` are named only in the WSL guide.

---

# 4. Cheat-sheet and action-reference audit

## Printable artifacts

| Sheet | Pages | Budget | Font | Rendering findings |
|---|---|---|---|---|
| `fedora-kde.pdf` | 1 | 1 | 10 pt | Good. Two columns, ~15% white at the bottom of column 2. Proves the shared block plus a platform block fits one page. `theme <f>` printed twice with different descriptions (DOC-057). |
| `fedora-sway.pdf` | 2 | 2 | 9 pt | Page 1 uses ~55% of the page; forced `\clearpage`; page 2 (shared block) uses ~60%. Grid note says "Ctrl+Left" for a `Super+Ctrl+H` binding (DOC-061). |
| `fedora-wsl.pdf` | 2 | 2 | 10 pt | **Page 2 is blank except the footer line.** The `\csfoot` `\vfill` spills after `multicols`. The budget of 2 hides a layout regression (DOC-052). Shared block prints `ghostty +list-keybinds` (DOC-051). |
| `macos.pdf` | 2 | 2 | 9 pt | Page 1 uses ~45%; page 2 ~60%. Same forced break as Sway (DOC-053). |
| `parrot-ctf.pdf` | 1 | 1 | 10 pt | Uses ~35% of the page. Accurate, but withholds shared actions the guest has (DOC-050). |

All five: A4, no overfull boxes, no undefined references, byte-reproducible.
Typography is consistent within a sheet; the 9 pt/10 pt split between sheets
is deliberate for the denser desktop sheets and is not a defect.

## Registry coverage (independent inventory vs `config/actions.tsv`)

Complete and correct: all 49 Sway `bindsym` lines, all 46 AeroSpace bindings,
every Waybar `on-click`/`exec`, every alias and public function in the three
Zsh files the validator reads, the WSL interop commands, the Parrot helpers,
the theme command. Git has no aliases, Lazygit no custom keybindings, Ghostty
no `keybind`, `keymaps.lua` no keymaps: the registry's "upstream" rows for
those are correct.

Missing repository-defined actions (DOC-055):

| Action | Source | Why it matters |
|---|---|---|
| `setopt AUTO_CD` | `zsh/.config/zsh/.zshrc:27` | changes how every bare directory name is interpreted, on all platforms |
| `set -g mouse on`, 1-based indexes | `tmux/.tmux.conf:2-4,17` | sheet heading says "unmodified"; the registry has an `input=mouse` value with zero rows |
| `floating_modifier $mod normal` | `sway/config:17` | Super+drag move/resize; appears nowhere else in the repo |
| `"disable-scroll": true` | `waybar/config.jsonc:9` | deliberately removes a Waybar default |
| `bat`/`fd` command shims | `platforms/parrot-ctf/stow/command-shims/` | `alias cat=bat` on the Parrot sheet only works because of them |
| `gx`→`wsl-open`, `"+y`/`"+p`→Windows clipboard | `platforms/fedora-wsl/stow/nvim-wsl/.../wsl.lua:8-43` | user-visible rerouting, mentioned only in a sheet note |

Wrong attribution (DOC-048, DOC-049, DOC-054, DOC-056):

- 22 rows (`nvim.latex.*`, `nvim.markdown.*`, `nvim.dotnet.*`) are
  `platform=all`; `profile.lua:23/38` imports `lua/plugins` only for the
  workstation profile, so none exist on Parrot. The registry vocabulary has no
  "every workstation" value.
- `sway.session.start` says the desktop entry launches it and that it handles
  "Waybar, wallpaper"; in fact `sway/config:117` `exec`s it and Waybar and the
  wallpaper are set by `config:125` and `config:35`.
- `theme.preserve-wallpaper` is `sheets=fedora-sway` but is also printed in
  prose on the KDE sheet, and the Fedora hook applies it to KDE too.
- `fzf.history` and `lazyvim.format` are `origin=upstream` although
  `.zshrc:135-143` sets `FZF_CTRL_R_OPTS` and `formatting.lua:12-21` rewires
  `<leader>cf`; the shared sheet heads the block "fzf (upstream defaults)".

Stale or inaccurate prose around the registry (DOC-060, DOC-061, DOC-062):
`keybindings.md:222` points at `lazyvim.json` for extras that are declared in
`profile.lua`; `:267-269` says the VimTeX fallback viewer is macOS `open`
when `latex.lua:16-23` falls back to `xdg-open`; `:592-601` lists four sheets
(no Parrot); `cheatsheets/README.md:40` says "build all four", `:33-35` says
the sheets and the reference have "separate sources" (both derive from the
registry), `:111-112` tells contributors to hand-edit a table inside the
generated block, and `:99-107` misdescribes what `test-cheatsheet-bindings.sh`
greps; `cheatsheet.sty:5-6` names four sheets.

Print inclusion/exclusion judgement (labelled as judgement):

- Parrot should carry the shared Zsh/line-editing/tmux/fzf rows it actually
  has; page 1 has room for all of them (DOC-050).
- VimTeX (`\ll`, `\lv`, `\le`), EasyDotnet (`<leader>tr/tt/td`) and the
  table-nvim mappings are repository-defined and not discoverable outside
  WhichKey; keeping them `print=false` is defensible because WhichKey lists
  them, and their `print_reason` says so. No change recommended.
- `x-copy` on a Fedora VM guest is `print=false` with a reasonable reason.
- The upstream LazyVim block on every workstation sheet is a deliberate,
  documented choice and should stay.

## Gate strength (`validate-actions.py`, `test-action-registry.sh`, `test-cheatsheet-bindings.sh`)

What is proven: schema; each `repository` row's `source_pattern` matches
somewhere in its source; every Sway/AeroSpace/Waybar/three-Zsh-file action is
claimed by a row; every `print=true` row appears on its sheets and every
`\csrow` is claimed. Negative tests exist for each.

What is not proven (DOC-063), each demonstrated on a scratch copy:

- the `binding` column is never compared to the source (changing
  `nvim.dotnet.run-nearest` to `<leader>zz` passes);
- a sheet's description is never checked (`\csrow{Super+F}{Lock the session}`
  passes);
- the prose fallback (`normalize()` substring over the whole sheet) makes short
  bindings unfalsifiable: `K`, `Tab`, `Space` all "match" `parrot-ctf.tex`
  today via `WhichKey`/`\begin{tabular}` (reproduced during this audit);
- extraction never reads `bindkey`, `setopt`, `floating_modifier`, tmux, any
  Lua, the macOS/WSL `zsh-platform` files, `command-shims`, or `.local/bin`;
- `test-cheatsheet-bindings.sh` re-types 13 Sway, 9 AeroSpace and 24 sheet
  literals by hand, and `test-action-registry.sh:236-247`'s forbidden-string
  list for the WSL sheet lacks `ghostty`, which is why DOC-051 passes;
- the `profile` column has no enum (`markdown` is not a capability).

---

# 5. Normative-source/drift audit

| Claim family | Source(s) | Category | CI prevents drift? |
|---|---|---|---|
| Installer options: flag spelling, kind, permitted values | `install-options.tsv` → `installer-options.md`; platform `usage()` | A (generated) + parser hand-written | Generated doc: yes. Parser vs manifest: `test-installer-options.sh`/`test-install-rerun.sh` exercise it; this audit confirmed help ↔ manifest parity mechanically. |
| Installer option **defaults** | `install-options.tsv` (`false`), `capabilities.tsv` (`auto`), `install.sh:19,124-130`, help text | **C, and currently wrong** | No. DOC-001/002. |
| Capability availability and provider | `capabilities.tsv` → `capability-matrix.md` | A | Yes (`--check` in lint; negative test in `test-documentation.sh`). |
| Capability packages | `capabilities.tsv` vs installer arrays | **C** | No. Only intra-manifest owner uniqueness. DOC-003. |
| Capability verifier | `capabilities.tsv` `verifier` | B (existence only) | Existence yes; that it verifies the capability, no. DOC-004. |
| Platform support list | `capabilities.tsv` `base` rows; 12 code sites; 6 doc sites | C | Partially (`validate-capabilities.py` fails if its own set is missing from the manifest). DOC-011. |
| Network sources / provenance | `network-sources.tsv` → `supply-chain-sources.md` | A | Yes. |
| Actions | `actions.tsv` → `keybindings.md` block; sheets checked | A + B | Yes for the block; sheets B with the weaknesses above. |
| Hand tables in `keybindings.md` | duplicates of the registry | C | No. DOC-062. |
| Starship configs | `config/starship/*` → `starship/.config/starship/*.toml` | A | Yes (`--check` in lint; negative test in `test-starship-themes.sh`). |
| Package ownership prose | `package-ownership.md` | C | No. DOC-005. |
| Install flow order | `plan_add` vs `installation.md` | C | No. DOC-007. |
| Machine-local state files | `profile-state.sh` etc. vs `file-ownership.md` | C | No. DOC-008. |
| What the verifier checks | `verify.sh` sections vs `verification.md` | C | No. DOC-041. |
| Defaults summary | `defaults.md` | C | No. DOC-006. |
| Install command examples in docs | `validate-docs.py` checks `--platform X` commands against the manifest | B | Yes for platform-qualified commands only; a bare `./install.sh --hardware …` is not checked, and `--smoke-test` is treated as universally transient. DOC-025. |
| Cross-document references | Markdown links: B; plain-text "see X above/below": C | Links yes; plain-text no. DOC-014/016. |
| README section names quoted in shell scripts | 7 sites | C | No. DOC-039. |
| Shell file roles and modes | `shell-file-roles.tsv` | B | Yes. |
| Repository hygiene | `validate-repository-hygiene.py` | B | Misses tracked bytecode. DOC-065. |

Can changing a capability, provider or option leave documentation silently
stale while CI is green? Yes, in these ways: changing a package array in an
installer (manifest and `package-ownership.md` stay wrong); changing a
default in an installer (both manifests stay wrong); adding a `plan_add` step
(`installation.md` stays wrong); adding a verifier section (`verification.md`
stays wrong); adding a state file (`file-ownership.md` stays wrong); adding a
Neovim keymap, tmux binding or `setopt` (registry stays incomplete); renaming a
README heading (seven scripts keep quoting the old one).

---

# 6. New-user journey

**Bootstrap.** The README answers "what is this, which platforms, what is
optional, who owns what" in the first 120 lines and links the generated
option and capability tables. Good. Gaps: the README says "Six manifests"
(there are seven, DOC-010); nothing says a Nerd Font is required for the
prompt on three of four platforms (DOC-044); the Parrot guide is the only
place the guest's terminal is described.

**Install.** `./install.sh --dry-run` then `./install.sh` is discoverable and
correct. What the user is not told: a `Continue with installation? [y/N]`
prompt appears and Enter cancels (DOC-035); `--non-interactive` means
something different on macOS and can still block on sudo (DOC-034); KDE is
auto-detected and LaTeX is prompted, while the reference says both default to
`false` (DOC-001); a pre-existing `~/.zshrc` stops the run with a Stow
conflict whose remedy exists only in the error string (DOC-043); the Fedora
reboot/Plasma advice reads as universal (DOC-024).

**Verify.** `verification.md` gives one command, for Fedora, and a bullet list
that omits seven sections; a macOS or WSL user has to find their verifier in
the platform guide or `installation.md`'s trees (DOC-041). `./doctor` is in
the README but not in the verification or troubleshooting pages (DOC-038).

**Normal use.** `keybindings.md` and the sheets are good; the theme, shell and
Git guides are accurate. A Parrot user's sheet under-reports what they have
(DOC-050); a WSL user's sheet names a binary they do not have (DOC-051).
Editor provisioning (profiles, extras, Mason bootstrap, lock files) is
undocumented (DOC-023).

**Rerun/update.** `rerun.md` and the README are accurate end to end. The one
trap is a stale record predating an option being reconstructed with the wrong
default (DOC-001), and a failed WSL/Parrot run printing a recovery command
without the user's options (DOC-036).

**Troubleshooting.** Thirteen accurate entries, all about the running
environment. None about the installer, lifecycle state, `doctor` output, Stow,
fonts, Mason or the Neovim first launch (DOC-043/044/045). The AI remedy omits
two sub-flags (DOC-046).

Answers a new user can and cannot find:

| Question | Findable? |
|---|---|
| What does this install? Which platforms? What profiles? What is optional? | Yes: README + generated matrix |
| What is safe to run? | Yes: README safety model; `--dry-run` is prominent |
| Which manager owns each tool class? | Yes in principle (README principles, matrix); `package-ownership.md` is partly wrong (DOC-005) |
| Fresh install / rerun | Yes |
| Verify it | Fedora yes; other platforms only via their guide (DOC-041) |
| What if verification fails | Partially: no `doctor` or installer entries in troubleshooting (DOC-038/045) |
| Where are keybindings | Yes |
| Platform-specific instructions | Yes |
| Which files do I edit manually | Yes for Git identity, theme, Sway `local.conf` (`first-run.md`, `file-ownership.md`); the lifecycle state directory and component state files are not listed (DOC-008) |
| Which files are generated and must not be edited | Only by reading each file's banner; no single list (DOC-009) |

---

# 7. Maintainer journey

**Add or change a capability.** `docs/capabilities.md` says where to declare
it and to run `validate-capabilities.py` and `render-capability-matrix.py`.
It does not say to add an `install-options.tsv` row (the file is never
mentioned), nor to run `render-installer-options.py`, so a maintainer who
follows it fails lint (DOC-012). It does not say the `default` and `cli_flag`
columns must agree with the other manifest, because nothing checks it
(DOC-002). Package lists must be kept in sync by hand with the installer
array, `package-ownership.md`, and the profile guide (DOC-003/005). Verdict:
requires tribal knowledge; the update surface is five files, three of them
unchecked.

**Add a platform.** Twelve hard-coded platform lists in code and six in docs
(DOC-011), plus a sheet, a page budget in `verify.sh`, a `SHEETS` entry, an
`installation.md` tree, and a `defaults.md` sentence. Nothing documents this
list. Tribal knowledge.

**Add an installer flag.** Add a row to `install-options.tsv`, a `case` arm in
the platform installer, a `usage()` line, and re-render. The tests catch a row
without a parser arm. Reasonably obvious; the only trap is the transient-flag
list living in three places (`render-installer-options.py`,
`validate-docs.py`, `install-selection.sh` comments) and being wrong for
Parrot (DOC-025).

**Add a keybinding.** For Sway/AeroSpace/Waybar/Zsh aliases the gate fails
until a registry row exists, and `cheatsheets/README.md` explains the sheets.
For Neovim, tmux, `bindkey` or `setopt` nothing fails and no document says the
registry is expected to carry them (DOC-055/063). The README's instruction to
hand-edit a table inside the generated block is wrong (DOC-061).

**Regenerate a generated artifact.** Each generator has a `--check` and lint
runs all of them; `testing.md` describes the gates accurately. The list of
generators is not in one place (DOC-009).

**Detect stale docs.** Links, anchors, orphans, stale-issue phrasing and
platform-qualified install commands are checked. Prose tables, plain-text
cross-references and README-heading quotations in shell scripts are not
(DOC-014/016/039).

**Represent a platform-specific exception.** `capabilities.tsv` does this
well (`unsupported`, `windows-host`, `user-managed`). The action registry
cannot express "every workstation but not the guest" (DOC-048), and
`lavish-axi` cannot be co-owned (DOC-003).

**Normative vs explanatory.** Stated clearly in `docs/README.md`. The
exceptions are the documents that mix the two (§2).

---

# 8. Findings

Severity scale: Critical = a supported machine is installed or configured
wrongly or unsafely by following the docs; High = a documented claim is false
in a way a user will act on, or a likely first-run failure is undocumented;
Medium = wrong or missing information with a clear remedy path elsewhere, or
a drift mechanism with no gate; Low = local inaccuracy or maintainability
debt.

Totals: Critical 0, High 12, Medium 32, Low 29 (73 findings).

## Normative data and drift

### DOC-001 — Fedora `--kde`/`--latex` defaults are `auto` in the installer and one manifest, `false` in the other manifest and the generated reference
- Severity: **High**
- Category: normative drift / correctness
- Platforms: fedora (also affects `--rerun` on fedora)
- Evidence: `platforms/fedora/install.sh:19` (`install_kde=auto; install_latex=auto`), `:124` (auto-detects `plasmashell`), `:125-130` (prompts, default no); help `:40-41`; `config/capabilities.tsv:10,14` (`auto`); `config/install-options.tsv:3-4` (`false`); `docs/reference/installer-options.md:21-22` (`false`), `:12` ("`auto` means the installer detects or asks; see the platform guide", but no row says `auto` and no platform guide documents the detection or prompt); `common/lib/install-selection.sh:170-175` (an option missing from a rerun record falls back to the manifest default and emits the `off_flag`).
- Current: two manifests contradict each other; the published default is wrong; a rerun record predating the option is reconstructed as `--no-kde`/`--no-latex`.
- Expected: one declared default that matches the installer, rendered as `auto`, with the detection/prompt behaviour documented in the Fedora guide.
- Why it matters: this is the default platform's most visible option, and the wrong value is load-bearing on rerun.
- Fix: add `auto` to the `boolean` vocabulary in `install-selection.sh:60-63` (or an `auto` kind), set `default=auto` on `install-options.tsv:3-4`, re-render, add a "Defaults that resolve themselves" subsection to `docs/platforms/fedora.md`.
- Files: `config/install-options.tsv`, `common/lib/install-selection.sh`, `docs/reference/installer-options.md`, `docs/platforms/fedora.md`.
- Regression test: a manifest cross-check (DOC-002) plus a `test-install-rerun.sh` case where a record lacks `latex` and the reconstructed argv contains neither `--latex` nor `--no-latex`.
- Overlaps: DOC-002.

### DOC-002 — `capabilities.tsv` and `install-options.tsv` duplicate flag and default with different vocabularies and no cross-validation
- Severity: **Medium**
- Category: drift architecture
- Platforms: all
- Evidence: `capabilities.tsv` columns `cli_flag`,`default` (`auto|enabled|disabled`); `install-options.tsv` columns `on_flag`,`off_flag`,`default` (`true|false|inherit|-`); `scripts/validate-capabilities.py` never opens `install-options.tsv`; mechanical comparison in this audit: 2 default mismatches that matter (DOC-001), 12 vocabulary mismatches (`disabled` vs `inherit`), 1 (`hardware`: `disabled` vs `-`), and `dev-workflows` has `cli_flag=--dev-workflows` on three platforms with no option row (`capabilities.tsv:67-69`); `validate-capabilities.py` also has no code path for the `conflicts` column.
- Current: two structured "role 1" sources for the same fact.
- Expected: one owner per fact, or a validator that fails when they disagree.
- Fix: either drop `cli_flag`/`default` from `capabilities.tsv` and have `install-options.tsv` reference the capability (it already does via `capability`), or add a cross-check to `validate-capabilities.py` that maps `enabled/disabled/auto` onto `true/false/auto/inherit` and fails on mismatch; validate `conflicts` symmetry while there.
- Files: `config/*.tsv`, `scripts/validate-capabilities.py`, `docs/capabilities.md`.
- Regression test: negative case in `tests/test-capabilities.sh` that edits one default and expects failure.
- Overlaps: DOC-001, DOC-012, DOC-025.

### DOC-003 — `capabilities.tsv` package and Stow lists diverge from what the installers install
- Severity: **Medium**
- Category: normative drift
- Platforms: fedora, parrot-ctf
- Evidence: Parrot base: `platforms/parrot-ctf/scripts/install-system.sh:17-49` installs `fontconfig`, `konsole`, `xz-utils` not in `capabilities.tsv:5`; the row's stow column lists `mise` but `platforms/parrot-ctf/scripts/stow.sh:12` passes `--without-mise` and `common/stow.sh:40-42` then never stows it. Hardware: `capabilities.tsv:30` `asusctl,akmods` vs `install-asus-hardware.sh:222-228,263,323,336-344` (`asusctl asusctl-rog-gui fwupd mokutil pciutils` plus model-specific sets). Hardening: `capabilities.tsv:34` names `policycoreutils-python-utils` (installed nowhere; only occurrence in the repo) and `dnf-automatic` (script installs `dnf5-plugin-automatic`, `lib/hardening.sh:280-282`). vm-host: manifest 5 packages vs `install-vm-host.sh:20-36` 13 (`libvirt` is never requested; `swtpm`, `virt-viewer` promised by `vm-host.md:11-12` are absent from the manifest). vm-guest: `xclip` installed (`install-vm-guest.sh:20-23`) and documented (`vm-guest.md:47`) but not in the manifest. desktop-tools: `install-desktop-tools.sh:29` installs `xdg-utils`, which the manifest assigns to `base`; `desktop-tools.md:56` and `package-ownership.md:70-71` repeat the wrong owner. AI: `lavish-axi` is owned by `firstmate` only, but `install-ai.sh:225-227` installs it for `--backpass` too. `validate-capabilities.py:104-110` checks only intra-manifest uniqueness.
- Current: the normative package inventory under-declares nine packages and mis-declares three.
- Expected: manifest equals installer arrays; a validator diffs them.
- Fix: correct the rows; extend `validate-capabilities.py` to parse each platform's package arrays (they are plain `packages=(…)` blocks) and fail on asymmetric difference; give `lavish-axi` its own row or allow co-ownership explicitly.
- Files: `config/capabilities.tsv`, `scripts/validate-capabilities.py`, `docs/profiles/desktop-tools.md`, `docs/architecture/package-ownership.md`, `platforms/fedora/scripts/install-desktop-tools.sh`.
- Regression test: negative case adding a package to an installer array without the manifest.
- Overlaps: DOC-005.

### DOC-004 — The Fedora `latex` capability names a verifier that performs no LaTeX check
- Severity: **High**
- Category: correctness / support claim
- Platforms: fedora
- Evidence: `config/capabilities.tsv:14` verifier `platforms/fedora/scripts/verify.sh`; that file contains zero occurrences of `latex`, `texlive`, `latexmk`, `biber` or `pdflatex` (checked with `grep -c`) and accepts no arguments; contrast `platforms/fedora-wsl/scripts/verify.sh:198-206` which checks seven TeX commands behind `--latex`; `README.md:90-92` promises "What is not verified is said to be not verified".
- Current: a selected Fedora LaTeX profile passes verification unconditionally.
- Expected: a LaTeX section gated on the selected capability, or an honest `none` in the manifest.
- Fix: port the WSL block into the Fedora verifier gated on `install_lifecycle_capability_selected latex`; make `validate-capabilities.py` require the verifier file to mention the capability name.
- Files: `platforms/fedora/scripts/verify.sh`, `config/capabilities.tsv`.
- Regression test: `tests/test-latex-profile.sh` case where a selected latex profile with `latexmk` absent fails verification.

### DOC-005 — `docs/architecture/package-ownership.md` transcribes ~121 lines of manifest data by hand and has drifted
- Severity: **Medium**
- Category: duplicated source of truth
- Platforms: fedora, all
- Evidence: `:33` `fd` (package is `fd-find`, as the doc's own Parrot section notes); base list omits `firewalld`, `gnupg2`, `jq`, `shadow-utils`, `xdg-utils` present in `capabilities.tsv:2`; `:70-71` attributes `xdg-utils` to desktop-tools; `:233-254` "complete expected inventory" has 16 rows while `mason-packages.txt` has 17 (`tree-sitter-cli` missing); no test or script references the file (`grep -rn package-ownership tests/ scripts/` empty). Blocks 29-52, 54-83, 89-93, 147-167, 190-205, 218-224, 237-254 are all transcriptions.
- Fix: replace the transcribed blocks with generated blocks (BEGIN/END markers, `render-package-ownership.py --check` wired into `lint.sh`) or with links to the manifests, keeping only the rationale prose.
- Regression test: `--check` in lint.
- Overlaps: DOC-003.

### DOC-006 — `docs/reference/defaults.md` is a hand-maintained, Fedora-shaped, partial copy of the manifests
- Severity: **Medium**
- Category: duplicated source of truth / platform accuracy
- Platforms: all
- Evidence: `:17` "Claude Code + Herdr, Codex/FirstMate optional" omits `gnhf`/`backpass` (`capabilities.tsv:61,64`); "Terminal: Ghostty" is false on WSL (Noctty) and Parrot (Konsole); "Distribution: Fedora / Desktop: KDE" unqualified; four of 21 Fedora options named; `docs/README.md:68` presents it as "what a default install ends up with" for any platform. `Accent: Mauve` and `KDE decoration: Classic` were verified correct (`install-kde-theme.sh:60-72`).
- Fix: retitle "Fedora workstation defaults", drop the flag lines in favour of links to the generated tables, or generate the file.
- Overlaps: DOC-001.

### DOC-007 — `docs/architecture/installation.md` flow trees are stale
- Severity: **Medium**
- Category: duplicated source of truth
- Platforms: all
- Evidence: Fedora tree (`:34-58`) omits `desktop-tools`, `containers`, `tailscale`, `ai` steps (`platforms/fedora/install.sh` plan order captured in this audit) and places vm-host/vm-guest/hardening after LaTeX when they run before `local`/`stow`; WSL tree omits `interop`, `latex`, `containers`, `ai`, `theme`; Parrot tree omits `terminal` (Nerd Font, bat themes, Konsole profile) and `theme`; macOS has no tree; the top line shows `install.sh` → `platforms/fedora/install.sh` without `scripts/install-main.sh`.
- Fix: delete the trees in favour of "run `./install.sh --platform X --dry-run`; the plan printed is authoritative", or generate them from `plan_add` lines.

### DOC-008 — `docs/architecture/file-ownership.md` omits the lifecycle state directory, component state files and three platform Stow trees
- Severity: **Medium**
- Category: completeness
- Platforms: all
- Evidence: Stow block `:7-26` lists root packages and `platforms/fedora/stow/` only; `platforms/fedora-wsl/scripts/stow.sh:13`, `platforms/macos/scripts/stow.sh:12`, `platforms/parrot-ctf/scripts/stow.sh:15` deploy eleven further packages. State block `:48-67` omits `${XDG_STATE_HOME}/dotfiles/{install.conf,install.log,theme-actions.log,mise-context/,git-identity/}` (`install-lifecycle.sh:8-10,85`, `theme-hooks.sh:29`, `common.sh:99-101`, `git-identity.sh:43-46`) and the per-capability `~/.config/dotfiles/<capability>.conf` files (`profile-state.sh:26-36`); `:77-79` attributes the Git migration to `platforms/fedora/scripts/setup-local.sh` when it lives in `common/setup-local.sh:30-82`.
- Fix: derive the state list from `capabilities.tsv` column `state` plus a fixed list; list all four platform trees; correct the migration script.

### DOC-009 — No single list of generated artifacts; `docs/README.md` names three of five
- Severity: **Low**
- Category: discoverability / maintainability
- Evidence: `docs/README.md:14` lists capability-matrix, installer-options, supply-chain-sources; `starship/.config/starship/*.toml` (`update-starship-themes.sh`, lint `:35`) and the `keybindings.md` block (`render-action-reference.py`, lint `:44`) are equally generated and gated but documented only on their own pages.
- Fix: one list, in the index role table or `repository-conventions.md`.

### DOC-010 — README says "Six manifests"; there are seven
- Severity: **Low**
- Evidence: `README.md:104-114` omits `config/terra-keys.tsv`, read as a manifest by `platforms/fedora/lib/fedora.sh:25` and cited by `supply-chain.md:141,155`.
- Fix: add the row.

### DOC-011 — Hard-coded platform lists duplicate `capabilities.tsv` in 12 code sites and 6 doc sites
- Severity: **Low**
- Category: maintainability
- Evidence: `install.sh:63`; `scripts/install-main.sh:174-176` (help, in the file that derives the real list at `:138-139`); `render-capability-matrix.py:13,25`; `render-installer-options.py:29-41,46`; `render-action-reference.py:26,73`; `validate-actions.py:47,51`; `validate-capabilities.py:19`; docs: `README.md:7-12`, `docs/platforms/README.md:3-11`, `docs/profiles/ai.md:26,33`, `docs/workflows/latex.md:3`, plus the generated pages.
- Fix: a shared helper for the Python scripts reading `base` rows; reuse the awk expression for the help text; leave titles/guides mapping human-authored.

### DOC-012 — `docs/capabilities.md` omits the second manifest, the column vocabularies and two required generators
- Severity: **Medium**
- Category: maintainer guidance
- Evidence: the doc never mentions `install-options.tsv`; its column list omits `default` and `profile`; none of the enforced vocabularies (`validate-capabilities.py:19,64,67,94`) appear; step 4 names `render-capability-matrix.py` only, while `lint.sh:43-44` also requires `render-installer-options.py` and `render-action-reference.py`.
- Fix: add a column/vocabulary table, an `install-options.tsv` section, and replace step 4 with "run `./scripts/lint.sh` and `./scripts/test.sh`".
- Overlaps: DOC-002.

## Platform and profile guides

### DOC-013 — The `--hardware` option's documentation link lands on a page that never mentions `--hardware`
- Severity: **Medium**
- Platforms: fedora
- Evidence: `installer-options.md:38` and `capabilities.tsv:30` link `docs/platforms/fedora.md#asus-laptop-hardware`; that section (`:20-32`) shows only the component-script spelling `install-asus-hardware.sh --model …`; the installer form `./install.sh --hardware ga402xz --secure-boot --charge-limit 80` exists only in `install.md:90-95`. `validate-docs.py:201-203` skips commands without `--platform`, so the omission is invisible.
- Fix: add the installer form to the Fedora section.

### DOC-014 — `docs/platforms/fedora-wsl.md` points "below" at a section it does not contain and omits two AI sub-flags
- Severity: **Medium**
- Platforms: fedora-wsl
- Evidence: `:566-570` names `--ai`, `--codex`, `--firstmate` and "AI-assisted development toolchain below"; the file has no such heading (it is `macos.md:272` / `ai.md:1`); `platforms/fedora-wsl/install.sh:69-70` also accepts `--gnhf`/`--backpass`. `:53-57` references "Fedora WSL policy" in `tailscale.md` by name without a link.
- Fix: list all four sub-flags; convert both references to relative links (which `validate-docs.py` then checks).

### DOC-015 — `docs/profiles/ai.md` ends with a truncated, orphaned paragraph
- Severity: **High**
- Platforms: all with AI; parrot-ctf statement
- Evidence: `ai.md:503-505` begins mid-sentence: `  Edition CTF VM" above): install or invoke AI tooling there only as a conscious per-lab decision…`, inside a section about `ai.toml`; the lead-in naming the Parrot guest is gone.
- Current: the profile's only statement about AI tooling on the CTF guest is unreadable.
- Fix: restore the sentence (Parrot is `unsupported` per `capabilities.tsv:54`) or delete lines 502-505.

### DOC-016 — Dangling plain-text "above/below" cross-references survived the documentation split
- Severity: **Medium**
- Evidence: `hardening.md:5-6` ("see Parrot Security Edition CTF VM above"), `containers.md:250-252` ("Podman containers under WSL … above"), `package-ownership.md:185` ("AI-assisted development toolchain above"), `ai.md:130` ("Worktree isolation for agent/crewmate work below" — no such heading anywhere: `grep -rn` returns only that line), `ai.md:21-24` (a colon introducing a block that now sits after `### Platform scope`). `validate-docs.py` checks Markdown links only.
- Fix: convert each to a relative link; add a lint rule rejecting `"…" (above|below)` in docs.

### DOC-017 — Tailscale guide names the Fedora state file for macOS and overstates the macOS verifier
- Severity: **Medium**
- Platforms: macos
- Evidence: `tailscale.md:177-181` `~/.config/dotfiles/tailscale.conf` vs `platforms/macos/scripts/install-tailscale.sh:18` `macos-tailscale.conf` (`capabilities.tsv:49`, `macos.md:366` correct); `tailscale.md:21-31` "could not be determined, which fails" vs `platforms/macos/scripts/verify.sh:432,435` (warnings).
- Fix: correct the path; scope the failure contract to Fedora and state macOS's weaker one.

### DOC-018 — `containers.md` presents Fedora-only behaviour as the whole profile; the macOS installer silently ignores flags
- Severity: **Medium**
- Platforms: macos
- Evidence: `containers.md:8,24,63,125,151-155,236,239` (Fedora path, `--api-socket`, subuid/subgid, SELinux `:Z`, `--skip-smoke-test`) unqualified; macOS is mentioned only at `:243-257`; `platforms/macos/scripts/install-containers.sh` (38 lines) has no argument parser, so `--api-socket` is ignored rather than rejected; `install-options.tsv` has no macOS `containers-api-socket` row; `platforms/macos/scripts/verify.sh:18-20` has no `--skip-smoke-test`.
- Fix: retitle the opening block "Fedora and Fedora WSL", move platform scope up; add an unknown-flag-rejecting parser to the macOS script for consistency with every other installer.

### DOC-019 — "That platform's installer rejects exactly that sub-flag" is true only on macOS
- Severity: **Medium**
- Platforms: fedora, fedora-wsl
- Evidence: `ai.md:35-38`; macOS implements it (`platforms/macos/install.sh:86-102`); Fedora and WSL route sub-capabilities through `capability_validate_selection` (`platforms/fedora/install.sh:215-218`, `platforms/fedora-wsl/install.sh:117-120`), which fails the whole preflight with the generic message (`common/lib/capabilities.sh:38-40`).
- Fix: lift the per-flag check into `common/lib/capabilities.sh`, or scope the sentence to macOS.

### DOC-020 — Manifest points macOS AI readers at the platform annex instead of the authoritative guide
- Severity: **Low**
- Evidence: `capabilities.tsv:53,57,60,63,66` docs column `docs/platforms/macos.md#ai-assisted-development-toolchain`; the annex (`macos.md:280,290-291`) itself defers to `ai.md`.
- Fix: point the five rows at `docs/profiles/ai.md`; keep the annex link from `ai.md:31`.

### DOC-021 — `vm-host.md` never shows how to install or verify the profile, nor its conflict with `--vm-guest`
- Severity: **Low**
- Evidence: `capabilities.tsv:26` `conflicts=vm-guest`, enforced at `platforms/fedora/install.sh:114`; `vm-host.md` contains no `./install.sh --vm-host`, no `install-vm-host.sh`/`verify-vm-host.sh`, and no conflict sentence; every other profile guide leads with its commands. The mutual exclusion is documented nowhere (only `--vm-guest`+`--hardware` is, `install.md:128-129`).
- Fix: add the standard lead-in block and one conflict sentence, mirrored in `vm-guest.md`.

### DOC-022 — OCaml prerequisites differ per platform and the workflow guide never says so
- Severity: **Low**
- Evidence: `development.md:256-262` shows only `./install.sh --ocaml`; three native sets exist (`platforms/fedora/scripts/install-ocaml.sh:26-37`, `:24` with `--wsl`, `platforms/macos/scripts/install-ocaml.sh:94`), and `common/verify-ocaml.sh:126-152` fails when `opam` is outside the platform prefix.
- Fix: a three-row table after `:262`.

### DOC-023 — `docs/workflows/editor.md` misattributes the Neovim provider and omits the profile/bootstrap mechanism
- Severity: **Medium**
- Platforms: macos, parrot-ctf
- Evidence: `editor.md:3` "Neovim is installed through DNF" (macOS: `Brewfile:15`; Parrot: `stow/mise-ctf/.config/mise/config.toml:2,5` pinned 0.12.5). Not documented anywhere: the profile mechanism (`lua/config/profile.lua:3-59`, marker `~/.config/dotfiles/neovim-profile`, `DOTFILES_NVIM_PROFILE`), extras declared in `profile.lua:7-22,33-37` not `lazyvim.json` (`"extras": []`), per-profile lock files (`profile.lua:6,32`, `lazy.lua:26`), the three-phase Mason bootstrap and its 20-minute timeout (`common/install-neovim-tools.sh:89-91,144-207`).
- Fix: add a "how the editor is provisioned" section.

### DOC-024 — `install.md` quick start and checklist mix Fedora-desktop advice into the platform-neutral path
- Severity: **Medium**
- Evidence: `install.md:43-47` (Plasma, systemd user manager, D-Bus, Ghostty) between the macOS and WSL blocks; checklist steps 6-8 (`:189-204`: reboot for the desktop session, Sway outputs, `./platforms/fedora/scripts/verify.sh`) are Fedora-only. The login-shell change itself is universal (`common/lib/common.sh:329`; `platforms/macos/lib/macos.sh:93`).
- Fix: split the checklist into portable and per-platform parts; move the reboot rationale under a Fedora heading.

### DOC-025 — `--dev-workflows` is documented as a universal execution control but is rejected on Parrot; `--smoke-test` is treated as universally transient
- Severity: **Low**
- Evidence: `installer-options.md:96` (from the hard-coded list `render-installer-options.py:50`); `platforms/parrot-ctf/install.sh:54-55` dies; `--smoke-test` accepted only on fedora-wsl (`platforms/fedora-wsl/install.sh:72`) yet in `validate-docs.py:56-64` `TRANSIENT_FLAGS` for every platform.
- Fix: per-platform transient list in both scripts, or a caveat column.

### DOC-026 — `macos.md:43-44` says the root entry point "reads only `--platform`"
- Severity: **Low**
- Evidence: `install.sh:14-16,41-43,57-68` also reads `--rerun` and the recorded platform.
- Fix: one-line edit.

### DOC-027 — WSL guide omits that the Windows bootstrap installs Scoop itself
- Severity: **Low**
- Evidence: `fedora-wsl.md:74-78`; `platforms/windows/install.ps1:419-447` downloads and runs `https://get.scoop.sh` when Scoop is absent; registered in `network-sources.tsv:13`.
- Fix: one sentence.

### DOC-028 — `docs/platforms/macos.md` (623 lines) restates ten sections owned elsewhere
- Severity: **Medium**
- Category: architecture / duplication
- Evidence: §3 package ownership (`:116-134` vs `package-ownership.md`), §4 workflows (`:136-172` vs `development.md`), LaTeX (`:174-212` vs `latex.md`), OCaml (`:214-243`), containers (`:244-271`), AI (`:272-327` vs `ai.md`), Tailscale (`:328-374`), keyboard table (`:415-432` vs generated reference), SFTP (`:529-558` vs `first-run.md`), rerun (`:560-576` vs `rerun.md`). Three of the drifts found in this audit (DOC-017/019/026) are in these duplicated sections.
- Fix: keep §1-2, §5, §6 permissions/Mission Control, §7, §9; reduce the rest to a sentence plus a link (~300 lines).

### DOC-029 — `theming.md` bat/Ghostty asset claims are unqualified by platform
- Severity: **Low**
- Evidence: `theming.md:276-280` "Bat uses its packaged Catppuccin themes" — on Parrot the repository installs them itself (`platforms/parrot-ctf/scripts/install-terminal.sh:41-59`); `:163-175` Ghostty theme files exist only where the `ghostty` package is stowed (`common/stow.sh:44-46`).
- Fix: qualify both paragraphs.

### DOC-030 — `shell.md` attributes autosuggestions and syntax highlighting to `.zshrc`
- Severity: **Low**
- Evidence: `shell.md:42-56`; both are sourced by the per-platform file (`.zshrc:277-279`; `platforms/*/stow/zsh-platform/.config/zsh/platform.zsh`), guarded on Fedora and Parrot, unconditional on macOS and WSL.
- Fix: move the two items to the platform-file description.

### DOC-031 — `terminal.md` documents no tmux plugin or theme mechanism
- Severity: **Low**
- Evidence: `tmux/.tmux.conf:30-32` sources `~/.config/dotfiles/tmux-theme.conf` and runs the pinned Catppuccin plugin installed by `common/install-tmux-theme.sh:9` (`v2.3.0`); `terminal.md:79-89` lists keys only. A tmux started before that step errors on line 32.
- Fix: one paragraph.

### DOC-032 — No Mistakes launcher-symlink behaviour is documented only in the macOS annex
- Severity: **Low**
- Evidence: `common/verify-ai.sh:107-113` and `profile-state.sh:26` (`no_mistakes_target_path`) are shared; `ai.md:463-464,483` describe one path; `macos.md:318-322` describes the symlink case.
- Fix: extend `ai.md:483` and the provenance table at `:274-278`.

### DOC-033 — `first-run.md` §6 "SFTP client" is not a user choice and is Fedora/KDE-specific
- Severity: **Low**
- Evidence: `first-run.md:118-176` (openssh-clients, Dolphin/KIO, `kio-extras`, Sway) in a document titled "Choices a user must make"; on Parrot the base list (`capabilities.tsv:5`) has no `openssh-client` row, so "part of the base workstation install" is Fedora-scoped.
- Fix: move to `docs/platforms/fedora.md` or `shell.md`; keep a one-line pointer.

## Installer contract and user-facing messages

### DOC-034 — `--non-interactive` is described three ways, and on macOS it can still block on a sudo prompt
- Severity: **High**
- Platforms: macos (behaviour), all (wording)
- Evidence: help strings `platforms/fedora/install.sh:63`, `fedora-wsl/install.sh:51`, `parrot-ctf/install.sh:33` ("Use defaults without prompting (requires cached sudo)"), `platforms/macos/bootstrap-help.txt:20` ("Use selected options without prompting"), `installer-options.md:95`; `common/lib/common.sh:263-273` `preflight_sudo`; macOS calls it only when Homebrew is missing (`platforms/macos/install.sh:149-152`) but later runs `sudo chsh` (`platforms/macos/lib/macos.sh:93`) whenever the login shell is not Zsh.
- Current: `./install.sh --platform macos --non-interactive` on a Mac with Homebrew but a Bash login shell stops on an interactive sudo prompt; three help texts say "defaults" when the flag uses the selected options.
- Fix: call `preflight_sudo "$interactive"` on macOS whenever the login shell must change; normalize the five strings.
- Regression test: `tests/test-macos.sh` case with Homebrew present, login shell Bash, `--non-interactive`, `sudo -n` failing → focused preflight error.

### DOC-035 — The confirmation prompt is undocumented, and pressing Enter cancels although every caller asks for default yes
- Severity: **High**
- Platforms: all
- Evidence: `common/lib/common.sh:240-256` reads `$1` only, renders `[y/N]`, maps `""` to `return 1` (verified in this audit); callers pass a second argument `y` at `platforms/fedora/install.sh:322`, `fedora-wsl/install.sh:197`, `macos/install.sh:244`, `parrot-ctf/install.sh:145`, `install-hardening.sh:132`, `install-asus-hardware.sh:302` (MOK enrollment); only `platforms/fedora/install.sh:126` (`n`) matches actual behaviour; no document mentions the `Continue with installation?` prompt (`install.md` shows bare `./install.sh`; `rerun.md:34,68` refers to "confirmation" without describing it).
- Current: Enter at "Continue with installation?" cancels; Enter at "Initiate MOK enrollment now?" declines.
- Fix (docs): show the resolved-choices summary and the prompt in `install.md`, state that the default is *no* or fix the code. Fix (code): honour `$2` and render `[Y/n]`/`[y/N]` accordingly, then re-check `install.sh:126`.
- Regression test: `tests/test-cli-contract.sh` already encodes current behaviour (`:23-27`); update it to the intended contract.
- Overlaps: DOC-034.

### DOC-036 — The "Safe rerun" recovery command on Fedora WSL and Parrot drops the user's options
- Severity: **High**
- Platforms: fedora-wsl, parrot-ctf
- Evidence: `platforms/fedora-wsl/install.sh:204` and `platforms/parrot-ctf/install.sh:152` hard-code `./install.sh --platform <p> --non-interactive`; consumed at `common/lib/execution-plan.sh:91` on failure; macOS uses `install_lifecycle_rerun_command` (`platforms/macos/install.sh:252`), Fedora a second hand-rolled renderer (`:171-204,329`); the library's own comment (`install-lifecycle.sh:157-165`) warns that a fixed string "would tell the user to install this platform's defaults instead of the machine they asked for"; `macos.md:573-575` documents the correct behaviour as the contract.
- Current: after `./install.sh --platform fedora-wsl --containers --ai --codex` fails, the printed recovery command has none of those options.
- Fix: use `install_lifecycle_rerun_command` on all four platforms; delete `build_rerun_command`.
- Regression test: failure-path test asserting the printed command contains the selected options on every platform.

### DOC-037 — `scripts/doctor.sh` tells the user to "rerun the recorded command", contradicting the documented model
- Severity: **Medium**
- Evidence: `scripts/doctor.sh:31`; `rerun.md:42-44,61-63` and `README.md:133-134` say no stored command is ever executed and `--rerun` is unavailable after a failed run (`install-lifecycle.sh:215-218`).
- Fix: name the failed step and point at `./install.sh --rerun --dry-run` or a fresh run with the user's options.

### DOC-038 — `./doctor` is absent from troubleshooting, verification, install and the docs index; its exit contract is undocumented
- Severity: **Medium**
- Evidence: mentioned only in `README.md:128,137-140`, `rerun.md:93` (as `./install.sh doctor`), `repository-conventions.md:40`; zero occurrences in `troubleshooting.md`, `verification.md`, `install.md`, `docs/README.md`; code sends users to it (`install-lifecycle.sh:202`); warnings exit 0, failures exit 1 (`doctor.sh:95-96`, observed on a throwaway HOME); `./doctor --help` runs the report instead of printing help.
- Fix: "Start with `./doctor`" section at the top of `troubleshooting.md`, an index entry, and one sentence on the exit contract.

### DOC-039 — Installer help and runtime messages point at README sections that no longer exist, and one points at a deprecated wrapper
- Severity: **Medium**
- Evidence: `common/install-ai.sh:82,84,89-90,531`; `platforms/fedora/scripts/install-tailscale.sh:36,140`; `platforms/macos/scripts/install-tailscale.sh:41-42`; `platforms/fedora/scripts/install-hardening.sh:36`; `platforms/fedora-wsl/scripts/install-containers.sh:27` — none of the six quoted headings exists in the 220-line README; `platforms/fedora/scripts/install-asus-hardware.sh:365` says "run ./scripts/verify.sh", which prints a `DEPRECATED:` banner (`scripts/verify.sh:11-13`).
- Fix: point at the real `docs/profiles/*.md` paths and the platform verifier; add a lint grep for `README\.md, "` / `README\.md's "` in tracked shell files.

### DOC-040 — Fedora WSL dry-run prints two AI sub-flags raw instead of `inherit`
- Severity: **Low**
- Evidence: `platforms/fedora-wsl/install.sh:174-177` (`$ai_gnhf`, `$ai_backpass` vs `${ai_codex:-inherit}`); the recorded selection one line later says `inherit`; Fedora and macOS print all four correctly.
- Fix: two `:-inherit` defaults.

## Verification and troubleshooting

### DOC-041 — `verification.md` omits seven verifier sections, is silently Fedora-only, and no document inventories the platform verifiers
- Severity: **High**
- Platforms: all
- Evidence: `verification.md:9-36` lists 19 items; `platforms/fedora/scripts/verify.sh` also emits SFTP baseline (`:59`), KDE integration (`:107,110`), Login shell (`:160`), Sway session (`:309`), Desktop tools (`:656`), Containers (`:672`), Tailscale (`:689`). `verification.md:3-7` names only the Fedora verifier; `platforms/macos/scripts/verify.sh --containers|--tailscale` and `scripts/verify.sh` (deprecated wrapper) are named in no document; the WSL verifier only in `latex.md:115`/`installation.md:78`; `verify.ps1` only in `fedora-wsl.md:115`. `capabilities.tsv` column `verifier` already holds the authoritative mapping and `doctor.sh:43` reads it.
- Fix: render a platform → verifier → flags table from the manifest; replace the bullet list with "one section per installed capability" plus that table.
- Regression test: `--check` for the rendered table.

### DOC-042 — `verification.md`'s second half duplicates `testing.md` and has drifted
- Severity: **Medium**
- Evidence: `verification.md:39-87` describes lint, the test runner and CI; `:82-85` omits the `cheatsheets` CI job (`validate.yml:65-101`), which `testing.md:219-221` has; `:44-48` says lint requires `shellcheck` only, while `lint.sh:29-32` hard-requires `python3` and runs six validators; `:58-75` names three "harnesses" matching no suite name.
- Fix: cut `:57-87` to a link to `testing.md`; fix the prerequisite sentence.

### DOC-043 — Stow conflicts are unreachable from any document
- Severity: **High**
- Platforms: all
- Evidence: `common/lib/preflight.sh:41-80` produces `Stow conflict [zsh]: existing file or directory: …` and `--adopt is never automatic`; `common/stow.sh:59-64` aborts under `set -e`; `grep -rn -i "stow conflict\|--adopt" docs/ README.md` → zero hits; `file-ownership.md:28-30` explains `--no-folding` but not what happens when a target exists.
- Current: the single most likely first-install failure for anyone with an existing `~/.zshrc`, `~/.tmux.conf` or `~/.config/git/config` has its remedy only in the error string.
- Fix: a troubleshooting section quoting the message and the remedy (move aside; never `--adopt`), and a sentence in `file-ownership.md`.

### DOC-044 — No Nerd Font is installed on Fedora, Fedora WSL or macOS, and nothing says so
- Severity: **High**
- Platforms: fedora, fedora-wsl, macos
- Evidence: the prompt is Starship's Catppuccin Powerline preset (`config/starship/prompt.toml`, `theming.md:233`); only Parrot installs a font (`platforms/parrot-ctf/scripts/install-terminal.sh:14-39`, verified at `verify.sh:262-283`); `platforms/fedora/scripts/install-system.sh:10-33`, `platforms/macos/Brewfile`, `platforms/fedora-wsl/scripts/install-system.sh` contain no font; `ghostty/.config/ghostty/shared.conf` sets no `font-family`; `grep -rni nerd docs/ README.md` hits only Parrot and supply-chain pages; no verifier checks glyph coverage.
- Current: a fresh Fedora or macOS install renders a prompt full of missing-glyph boxes; no troubleshooting entry.
- Fix: state once in `terminal.md` that the font is user-owned on those platforms and which one to install; add a troubleshooting entry "the prompt shows boxes".

### DOC-045 — `troubleshooting.md` has no installer, lifecycle, Mason or Neovim-bootstrap coverage
- Severity: **Medium**
- Evidence: all 13 entries verified accurate (coverage table in §6); not covered: preflight refusals (`preflight.sh:7,13,32,47`), stale/failed lifecycle state (`rerun.md:65-83` only), doctor warnings, missing provider (`preflight.sh:18-39`), Neovim first bootstrap/timeouts (`install-neovim-tools.sh:89-91,130-133`), Mason failures (`:180,203`), mise project-context bleed (designed away in `common.sh:84-144`, no entry).
- Fix: six short entries linking to the owning guides; do not duplicate WSL/macOS/Parrot/VM/hardware material already covered in their guides.

### DOC-046 — Troubleshooting's AI recovery step omits `--gnhf` and `--backpass`, producing a verifier failure
- Severity: **Medium**
- Evidence: `troubleshooting.md:98-99`; `common/install-ai.sh:16` `AI_OPTIONAL_COMPONENTS=(codex firstmate gnhf backpass)`; `verify-ai.sh:231-233` fails when the state records gnhf but `ai.toml` lacks it.
- Fix: name all four sub-flags.

### DOC-047 — `testing.md:33-36` describes a fixed seven-command stub list that the library does not have
- Severity: **Low**
- Evidence: `tests/lib/test.sh:187-232` provides generic `test_stub_install <name>`; each suite installs its own. Everything else checked in `testing.md` (suite names, CI jobs, self-hosted runners, schedule) is accurate.
- Fix: one sentence. Also mention `scripts/test-installer.sh` is a deprecated alias.

## Action registry and cheat sheets

### DOC-048 — 22 Neovim actions are `platform=all` but do not exist on the Parrot guest
- Severity: **High**
- Platforms: parrot-ctf
- Evidence: `config/actions.tsv:114-135` (`nvim.latex.*`, `nvim.markdown.*`, `nvim.dotnet.*`); `lua/config/profile.lua:23` imports `lua/plugins` for `workstation`, `:38` imports `ctf_plugins` (only `colorscheme.lua`, `mason.lua`) for `parrot-ctf`; the generated reference prints them under "Every platform"; `parrot-ctf.tex:36-38` says the guest excludes .NET and TeX.
- Fix: add a `workstation` platform value (or explicit per-platform rows) and validate `profile` against `capabilities.tsv`.

### DOC-049 — `sway.session.start`'s description and print reason are both wrong
- Severity: **High** (a normative registry row that the generated reference reproduces verbatim)
- Evidence: `actions.tsv:33` says the desktop entry launches it and it handles "environment, Waybar, wallpaper"; `sway/config:117` `exec sway-session-start`; the desktop entry (`assets/dotfiles-sway.desktop:4` → `assets/dotfiles-sway:13`) runs `/usr/bin/sway`; Waybar is `config:125`, wallpaper `config:35`; the script starts the sway-systemd session, restarts the portal and runs `dex-autostart`.
- Fix: correct both columns.

### DOC-050 — The Parrot sheet omits shared actions the guest has, with no recorded reason, and uses 35% of its page
- Severity: **High**
- Platforms: parrot-ctf
- Evidence: `common/stow.sh:28-38` stows `bin` (`theme`) and `zsh` (the whole `.zshrc` with `tar`, `untar`, `shell-integrations`, seven `bindkey`s) on Parrot; `platforms/parrot-ctf/install.sh:99` runs `theme`; `install-system.sh:17-49` installs `tmux fzf zoxide lazygit`; registry rows 61-97 exclude `parrot-ctf` from `sheets` without a `print_reason` (they are `print=true`), and `parrot-ctf.tex` does not `\input{common-workflow}`; rendered page 1 is ~65% empty.
- Fix: add at least `theme <f>`, `tar`/`untar`, `shell-integrations`, `Tab`/`Home`/`End`, `Ctrl+T`/`Alt+C`, tmux rows to the Parrot sheet (it fits on the existing page), or record why they are withheld.

### DOC-051 — The shared Terminal block on the WSL sheet names a binary the WSL runtime does not have and gives copy/paste keys for the wrong platforms
- Severity: **Medium**
- Platforms: fedora-wsl
- Evidence: `common-workflow.tex:6-7` (`ghostty +list-keybinds --default`; "Ctrl+Shift+C/V on Linux/Wayland, Cmd+C/V on macOS"), `\input` by `fedora-wsl.tex:33`; `platforms/fedora-wsl/scripts/stow.sh:10` `--headless` and `common/stow.sh:44-46`; `platforms/fedora-wsl/scripts/verify.sh:404-408` asserts no Ghostty config is deployed; `test-action-registry.sh:236-247`'s forbidden list for `fedora-wsl` lacks `ghostty`.
- Fix: a platform-conditional legend line, or move the Ghostty legend to the KDE/Sway/macOS sheets; add `fedora-wsl:ghostty +list-keybinds` to the forbidden list.

### DOC-052 — The WSL PDF's second page is an orphan footer on an otherwise blank page
- Severity: **Medium**
- Evidence: rendered `fedora-wsl-2.png`: only the `\csfoot` rule and footer text; `fedora-wsl.tex` uses one `multicols` block then `\csfoot`, whose `\vfill` pushes the footer past page 1; `docs/cheatsheets/verify.sh:35` budget 2 accepts it.
- Fix: reduce the WSL sheet's budget to 1 and place `\csfoot` inside the column flow or trim one note; `verify.sh` should additionally fail a page whose only content is the footer (e.g. `pdftotext` per page, fail if the last page has < N lines).

### DOC-053 — Sway and macOS sheets force a page break, leaving ~45-55% of page 1 empty (judgement)
- Severity: **Low**
- Evidence: `fedora-sway.tex:100` and `macos.tex:66` `\clearpage` before the shared block; rendered pages 1 use ~55% (Sway) and ~45% (macOS); the KDE sheet (`fedora-kde.tex`) proves the shared block coexists with a platform block on one page at 10 pt.
- Fix: let the shared block flow into the remaining column space (`\input` without `\clearpage`), keeping the two-page budget as the ceiling; or state in the README that page 2 is deliberately the shared block.

### DOC-054 — `theme.preserve-wallpaper` is printed on the KDE sheet but registered for `fedora-sway` only
- Severity: **Medium**
- Evidence: `fedora-kde.tex:25` (`\csnote`); `actions.tsv:138` `sheets=fedora-sway`; the Fedora hook applies the flag to KDE (`theme-hooks.d/fedora.sh:51`) and Sway (`:12`); `validate-actions.py:244-247` collects only `\csrow` keys, so prose is invisible in the reverse direction.
- Fix: `sheets=fedora-kde,fedora-sway`; add a `prose` marker convention so prose claims are deliberate and checked.

### DOC-055 — Repository-defined actions with no registry row
- Severity: **Medium**
- Evidence: `zsh/.config/zsh/.zshrc:27` `setopt AUTO_CD` (no mention anywhere in `*.md`/`*.sh`); `tmux/.tmux.conf:2-4,17` (1-based indexes, `mouse on`; registry has an `input=mouse` value with zero rows; sheet heading "tmux (prefix Ctrl+B, unmodified)"); `sway/config:17` `floating_modifier $mod normal` (single hit in the repo); `waybar/config.jsonc:9` `"disable-scroll": true`; `platforms/parrot-ctf/stow/command-shims/.local/bin/{bat,fd}`; `platforms/fedora-wsl/stow/nvim-wsl/.../wsl.lua:8-10,32-43` (`gx`→`wsl-open`, `"+y`/`"+p`→Windows clipboard). `validate-actions.py:141-190` reads none of these sources.
- Fix: add rows (`input=mode`/`mouse`/`command` as appropriate); extend extraction per DOC-063.

### DOC-056 — `Ctrl+R` and `<leader>cf` are customised but registered as pure `upstream`
- Severity: **Medium**
- Evidence: `.zshrc:135-143` `FZF_CTRL_R_OPTS`; `formatting.lua:12-21` Conform overrides; `actions.tsv:72,90` `origin=upstream`, `source=-`; `common-workflow.tex:34` "fzf (upstream defaults)"; `render-action-reference.py:62-65` defines `upstream` as "installing that tool is all this repository did". `keybindings.md:156-159` gets it right in prose.
- Fix: an `upstream-configured` origin or separate `repository` rows; drop "(upstream defaults)" from the heading.

### DOC-057 — `theme <f>` is printed twice on the KDE sheet with two descriptions
- Severity: **Low**
- Evidence: `fedora-kde.tex:23` and `common-workflow.tex:14` (via `\input`).
- Fix: drop the platform row or make the platform note a `\csnote`.

### DOC-058 — The registry `profile` column has no enum and mixes vocabularies
- Severity: **Low**
- Evidence: `validate-actions.py:83-85` checks non-emptiness only; values used: `base`, `sway`, `markdown`, `ctf-guest`, `latex`, `dotnet-debug`, `kde`, `vm-guest`; `markdown` matches no capability or profile in `capabilities.tsv`; the generated reference prints it under "Profile".
- Fix: validate against `capabilities.tsv` capability names plus `base`.

### DOC-059 — Weak `source_pattern`s prove nothing about the action
- Severity: **Low**
- Evidence: `actions.tsv:105-107,136` use a shebang (`#!/usr/bin/env bash|#!/bin/bash`); `:64` (`zsh.command.theme`) uses `preserve-wallpaper`; `:67` `zstyle ':completion:\*' menu select|menu select`.
- Fix: anchor on the action (`clip\.exe`, `Get-Clipboard`, `latte\|frappe\|macchiato\|mocha`).

### DOC-060 — `keybindings.md` VimTeX viewer paragraph is wrong for Fedora Sway
- Severity: **Low**
- Evidence: `keybindings.md:267-269` says the fallback is macOS `open`; `latex.lua:16-23` falls back to `xdg-open`; `open` comes only from `platforms/macos/stow/nvim-macos/.../macos.lua:10`; Okular is not installed by `install-latex.sh`, so `--latex --sway --no-kde` gets `xdg-open`.
- Fix: one sentence.

### DOC-061 — Stale claims in `cheatsheets/README.md`, `cheatsheet.sty`, `keybindings.md`'s trailing list, and the Sway grid note
- Severity: **Low**
- Evidence: `cheatsheets/README.md:40` "build all four" (five; `generate.sh:5,18`); `:33-35` "separate sources" vs `:80-83` "generated from the same registry"; `:111-112` instructs editing "the matching table in `../reference/keybindings.md`", which is inside the generated block (`:297-590`) and reverted by `--check`; `:99-107` misdescribes what `test-cheatsheet-bindings.sh` checks (it also checks swaylock, reload, resize, screenshot, cliphist, KDE, WSL, Parrot and discovery phrases, `:44-48,107-154`); `cheatsheet.sty:5-6` "the four sheets"; `keybindings.md:592-601` lists four sheets, omitting Parrot; `fedora-sway.tex:47` "Ctrl+Left from 1 goes to 3" for a `$mod+Ctrl+$left` (`Super+Ctrl+H`) binding (`sway/config:4,96-99`; there is no `Ctrl+Left` binding).
- Fix: six small edits.

### DOC-062 — The hand-written half of `keybindings.md` duplicates 52 registry rows and carries its own inaccuracies
- Severity: **Medium**
- Evidence: hand tables at `:57-65,76-84,161-165,172-176,186-193,202-220,232-241,257-265` (70 rows, 52 restating registry entries; `Ctrl+R` three times on the page); `:8-11` says only prose is hand-written; `:222` "see `lazyvim.json`" for extras declared in `profile.lua:8` (`lazyvim.json` has `"extras": []`); `:283-285` theme paragraph omits delta/git, fzf and Neovim, which `theme-shared-state.sh:13-19`, `.zshrc:130-131` and `bin/.local/bin/theme:134` cover.
- Fix: keep "Discover first", the terminfo table, the Ghostty/Lazygit/theme prose; delete the duplicated tables in favour of the generated block; correct the two sentences.

### DOC-063 — The action gate never compares a binding or a description to its source, and its prose fallback accepts any short binding
- Severity: **Medium**
- Category: false confidence
- Evidence: `validate-actions.py:108-133` (pattern-only), `:53` (first `\csrow` argument only), `:227-235,259` (whole-sheet substring fallback: `K`, `Tab`, `Space` all match `parrot-ctf.tex` today, reproduced in this audit); `:141-190` (four source shapes only); `tests/test-cheatsheet-bindings.sh:35-48,81-90` and `test-action-registry.sh:236-247` re-type literals by hand.
- Fix: require `source_pattern` to contain the binding's key text (or add `binding_pattern`); compare the second `\csrow` argument to `action` with token overlap; replace the substring fallback with an explicit `sheet:prose` marker; extend extraction (bindkey/setopt/floating_modifier/exec, tmux, Lua `keys=`/`lhs=`, all `zsh-platform` files, `.local/bin/*`); generate the test literals from the registry.

### DOC-064 — `verify.sh` is registered as an action for Parrot only
- Severity: **Low**
- Evidence: `actions.tsv:136` `parrot.verify`; the Fedora, WSL and macOS verifiers are equally user-invocable and unregistered.
- Fix: register all four or move the Parrot entry to prose; one consistent scope.

## Repository hygiene and contributor toolchain

### DOC-065 — A Python bytecode file is tracked, is rewritten by every test run, and no gate can see it
- Severity: **Medium**
- Evidence: `git ls-files tests/support` → `tests/support/__pycache__/dap-smoke.cpython-311.pyc`; `.gitignore` has no `__pycache__`/`*.pyc` rule; `tests/test-dap-smoke.py:15-20` imports `tests/support/dap-smoke.py` via `importlib` and regenerates the file (its header embeds the source mtime, so a fresh clone's first `./scripts/test.sh` rewrites the tracked file and dirties the tree); `scripts/validate-repository-hygiene.py` has no artefact rule (grep for `pyc`/`pycache` empty); `validate-shell-file-roles.py:50-56` ignores `.pyc`; CI's `git diff --check` reports whitespace only.
- Fix: `git rm --cached` it, add the ignore rules, add a hygiene rule rejecting tracked bytecode with a negative case in `tests/test-repository-hygiene.sh`.

### DOC-066 — Lint and tests depend on an undocumented toolchain; "run the same validation CI runs" is not reproducible outside the pinned container
- Severity: **Low**
- Evidence: `scripts/lint.sh:23-27` runs `shellcheck` with no `-S` threshold or version floor; under ShellCheck 0.9.0 it fails on 194 info-level notes that Fedora 44's ShellCheck does not emit; `scripts/test.sh:139` requires `nvim` but not a version, while `tests/test-csharpier-contract.lua` needs `vim.uv` (Neovim ≥ 0.10) and `test-idempotency.sh` runs the Fedora verifier, which needs `ssh`/`scp`/`sftp` on PATH (both failures reproduced in this audit; neither prerequisite is in `test.sh:143`'s preflight list, so they fail late instead of at preflight); neither `README.md:190-198` nor `docs/testing.md` states the required versions; `docs/platforms/README.md:22` gives "Neovim 0.12+" for the *workstation*, not for contributors.
- Fix: `shellcheck -S warning` (or pin a minimum version and say so), and a "Contributor toolchain" paragraph in `testing.md` listing ShellCheck, Neovim ≥ 0.10, zsh, stow, openssh-clients, python3, jq, rg.

### DOC-067 — Capability matrix legend and `terminal` modelling
- Severity: **Low**
- Evidence: `render-capability-matrix.py:31-35` renders a missing row as `—` and an unsupported row as `— unsupported`, with no legend distinguishing "not modelled" from "deliberately absent"; the `terminal` capability exists only as `fedora-wsl / windows-host` (`capabilities.tsv:42`), while Parrot installs a Konsole profile and font (`install-terminal.sh`) and Fedora/macOS ship Ghostty inside `base`, so the matrix shows `—` for a capability three platforms provide.
- Fix: add a legend line to the renderer; model `terminal` rows for all four platforms (Ghostty / Ghostty / windows-host / Konsole).

### DOC-068 — `repository-conventions.md`'s "five kinds" table contradicts `config/shell-file-roles.tsv`, the file it names as the authority
- Severity: **Medium**
- Category: maintainer guidance / competing sources of truth
- Evidence: `repository-conventions.md:34-36` says five kinds and that the TSV records them; the TSV defines ten roles (`public-entrypoint, platform-entrypoint, internal-executable, portable-wrapper, deprecated-wrapper, sourced-library, stowed-command, stowed-config, stowed-data, test-entrypoint`); `:40` lists four portable entry points while the TSV has ten `public-entrypoint` rows (omitting `scripts/doctor.sh`, `scripts/benchmark-shell-startup.sh`, `scripts/test-dev-workflows.sh`, `scripts/update-starship-themes.sh`, `docs/cheatsheets/{generate,verify}.sh`, all documented elsewhere as commands); `:41` calls `platforms/<platform>/scripts/*.sh` "Platform command … safe to run directly" while `shell-file-roles.tsv:14` gives that glob `internal-executable` (43 files the profile guides tell users to run); `shell-file-roles.tsv:6` gives `scripts/doctor.sh` `public-entrypoint` while describing it as "implementation behind ./doctor"; `validate-shell-file-roles.py:131-136` enforces mode only, never meaning.
- Fix: one vocabulary: add a `platform-command` role, reclassify `scripts/doctor.sh`, and make the conventions table either exhaustive or explicitly "examples; the TSV is exhaustive".

### DOC-069 — PowerShell and Python executables carry no role and no mode contract
- Severity: **Low**
- Evidence: `repository-conventions.md:73-77` promises every tracked file has a role and a mode; `validate-shell-file-roles.py:50-56` governs only `*.sh`, `*.zsh`, `.local/bin/*`, `doctor`, the Zsh files; unclassified public surface: `verify.ps1`, `platforms/windows/{install,verify,set-noctty-theme}.ps1`, `lib/wsl-version.ps1`, `tests/test-windows-*.ps1`, and eleven `scripts/*.py` of which nine are documented as commands (`scripts/validate-shell-file-roles.py` itself is documented nowhere although `repository-conventions.md:76` relies on it).
- Fix: extend `governed()` and add rows.

### DOC-070 — `nvim-lazyvim/.config/nvim/README.md` is the unmodified upstream LazyVim starter README over a heavily customised configuration
- Severity: **Low**
- Evidence: the file is the verbatim four-line starter text; the directory holds 19 tracked Lua files including `config/profile.lua`, `config/csharpier.lua`, `plugins/dotnet.lua`, `ctf_plugins/`, a Parrot profile with its own lock file; `third-party-notices.md:32` records it as "LazyVim starter template, modified"; nothing links to it, and `validate-docs.py:157` orphan-checks only under `docs/`.
- Fix: replace with a short page naming it as the repository's modified LazyVim config and linking `docs/workflows/editor.md` and the notices.

### DOC-071 — `docs/testing.md` never names `.github/workflows/validate.yml` or its four PR jobs
- Severity: **Low**
- Evidence: `testing.md:276-278` names `real-install.yml` with a job table; `:8-28` ("Fast PR validation") names no workflow, job or runner image; `grep -rn 'validate\.yml' --include='*.md'` hits only the generated `supply-chain-sources.md:103`; unstated anywhere: the `repository` job runs in a digest-pinned Fedora 44 container (`validate.yml:25`), the `macos` job runs 9 of ~70 suites (`:147-164`), `lint.sh` runs twice, a `windows` job exists.
- Fix: a four-row job table under `testing.md:8`.

### DOC-072 — Generated Starship themes are Catppuccin-derived but absent from the third-party notices
- Severity: **Low**
- Evidence: `third-party-notices.md:31` lists the ghostty/fzf/lazygit/git/starship-*palette* paths but not `starship/.config/starship/`, whose four generated files embed the palette values (`catppuccin-mocha.toml:1-4` names the sources); `third-party-notices.md:50-53` says the page is kept honest by `validate-repository-hygiene.py`, which only checks that listed paths exist, never that vendored material is listed.
- Fix: add the path to the palette row.

### DOC-073 — The install guide and generated rollback cells tell users to run an internal `common/` script
- Severity: **Medium**
- Evidence: `docs/workflows/install.md:161` "independently callable and safe to rerun through `common/install-ai.sh`"; `repository-conventions.md:44` classes `common/*.sh` as internal, "not the documented interface"; `shell-file-roles.tsv:13,17`; `ai.md:41,67,68,280` and `troubleshooting.md:98` use the supported `./scripts/install-ai.sh`; `config/network-sources.tsv:26,27` rollback cells → `docs/supply-chain-sources.md:88,102` name `./common/install-ai.sh --no-firstmate`.
- Fix: use `./scripts/install-ai.sh` in all three places and re-render.

---

# 9. Consolidated implementation plan

Ordered by dependency and value. Each workstream is one coherent ticket set.

**WS-A — Manifest truth and cross-validation** (first: everything else renders from it)
DOC-001, 002, 003, 004, 010, 011, 012, 025, 067.
Deliverables: `default=auto` and the `auto` vocabulary; a cross-manifest
check; a packages-vs-installer-arrays check; a verifier-mentions-capability
check; corrected rows; a shared platform-list helper; `capabilities.md`
rewritten to describe both manifests and the real procedure.

**WS-B — Installer contract and messages** (small, high user impact)
DOC-034, 035, 036, 037, 039, 040.
Deliverables: `confirm()` honouring its default; macOS sudo preflight;
normalised `--non-interactive` text; `install_lifecycle_rerun_command` on all
platforms; doctor message; README-heading references in scripts replaced and
lint-guarded; the prompt documented in `install.md`.

**WS-C — Verification and troubleshooting** (depends on WS-A's verifier column being trustworthy)
DOC-038, 041, 042, 043, 044, 045, 046, 047.
Deliverables: `verification.md` rendered from the manifest with a per-platform
verifier table; `troubleshooting.md` gains `doctor`, Stow conflict, font,
installer/lifecycle, Mason/Neovim entries and the four AI sub-flags; the
duplicated test prose removed.

**WS-D — Action registry and cheat sheets**
DOC-048, 049, 050, 051, 052, 053, 054, 055, 056, 057, 058, 059, 060, 061, 062, 063, 064.
Deliverables: `workstation` platform value; corrected rows; new rows for the
unregistered actions; Parrot sheet with the shared rows; WSL sheet without the
Ghostty legend and with budget 1; gate hardening (binding/description
comparison, prose marker, wider extraction, generated test literals);
`cheatsheets/README.md`, `cheatsheet.sty`, and the hand-written half of
`keybindings.md` cut down.

**WS-E — Derived prose replaced by generated or linked material**
DOC-005, 006, 007, 008, 009, 028, 062 (shared with WS-D).
Deliverables: generated blocks for `package-ownership.md` and
`file-ownership.md`'s state list; `installation.md` trees removed or
generated; `defaults.md` retitled or generated; one generated-artifacts list;
`macos.md` trimmed to platform-only content.

**WS-F — Platform and profile guide accuracy** (independent, cheap, can run in parallel with anything)
DOC-013, 014, 015, 016, 017, 018, 019, 020, 021, 022, 023, 024, 026, 027, 029, 030, 031, 032, 033, 073.
Deliverables: the truncated AI paragraph restored; dangling references turned
into links and a lint rule for `"…" (above|below)`; state-file, verifier and
scope corrections; editor provisioning section; install checklist split.

**WS-G — Repository hygiene, roles vocabulary and contributor toolchain**
DOC-065, 066, 068, 069, 070, 071, 072.
Deliverables: bytecode untracked and gated; ShellCheck severity floor or version floor; a contributor prerequisites paragraph; one role vocabulary across the conventions page and the roles manifest, extended to `.ps1`/`.py`; the LazyVim README replaced; a PR-job table in `testing.md`; the notices row completed.

---

# 10. Things that are already good

Do not redesign these:

- **The manifest → generator → `--check` → lint pattern.** Capability matrix,
  installer options, supply-chain sources, the action reference block and the
  Starship configs are all generated, all gated, all deterministic
  (regeneration in this audit produced no diff). Extend it; do not replace it.
- **`config/actions.tsv` as the single action registry**, with `print=false`
  requiring a recorded reason, and sheets checked against it in both
  directions. 31 exclusions carry defensible reasons. The AeroSpace (`tomllib`)
  and Waybar (`json`) extractors are real parsers, not regexes.
- **`docs/README.md`'s role table and precedence rule**, and the rule that
  guides never say "waiting for #N" (enforced by `validate-docs.py`). The
  repository has no stale normative issue dependency and no obsolete TODO.
- **`rerun.md`, `theming.md`'s precedence and action model, `shell.md`'s PATH
  policy and line-editing tables, `git-identity.md`, `parrot-ctf.md`,
  `parrot-ctf-shell-audit.md`, and the Sway section of `fedora.md`** were
  verified accurate line for line. The Git-identity "migration" is live code
  on every platform, not stale history.
- **Every documented install command line parses** against the current
  parsers; no obsolete flag or removed entry point is advertised.
- **Deprecation of the Fedora `scripts/*.sh` wrappers**: one notice to stderr,
  the replacement named, one removal-date constant, `DOTFILES_SUPPRESS_DEPRECATION`,
  and `config/shell-file-roles.tsv` classifying every shell file with an
  enforced mode. `repository-conventions.md`'s five-kind table matches it.
- **Platform-specific absence is modelled honestly** (`unsupported`,
  `windows-host`, `user-managed`), and the WSL terminal is never called
  Ghostty in any document; macOS `--latex` and WSL `--tailscale` are rejected
  with actionable messages that the docs mirror.
- **Cheat-sheet production**: budgets enforced, A4 checked, overfull boxes
  checked, byte reproducibility checked, PDFs untracked, all of it in CI.
- **The WSL guide's Windows section** matches `install.ps1` and
  `manifest.psd1` parameter for parameter; **`macos.md`'s defaults table**
  maps exactly onto the 13 managed keys and `--restore`.
- **`docs/testing.md`** is accurate about suites, CI jobs and self-hosted
  runners apart from one sentence (DOC-047).
- **Terra key pinning** (`config/terra-keys.tsv`) and the supply-chain tiers
  are documented and validated.

---

# 11. Appendix

## A. Documentation files (46 tracked Markdown files)

Root: `README.md`. Index: `docs/README.md`. Platforms: `docs/platforms/{README,fedora,fedora-wsl,macos,parrot-ctf}.md`. Profiles: `docs/profiles/{ai,containers,desktop-tools,hardening,tailscale,vm-guest,vm-host}.md`. Workflows: `docs/workflows/{development,editor,first-run,git,install,latex,rerun,shell,terminal,theming,verification}.md`. Reference: `docs/reference/{capability-matrix,defaults,git-identity,installer-options,keybindings,licensing,third-party-notices}.md`. Architecture: `docs/architecture/{file-ownership,installation,package-ownership,repository-conventions}.md`. Other: `docs/{capabilities,supply-chain,supply-chain-sources,testing,troubleshooting,parrot-ctf-shell-audit}.md`, `docs/cheatsheets/README.md`. Embedded: `nvim-lazyvim/.config/nvim/README.md` (upstream LazyVim starter README, unmodified), `platforms/fedora/stow/theme-assets/.local/share/wallpapers/README.md`, `common/assets/AGENTS.md` (shared agent instructions symlinked by the AI profile; documented in `ai.md:134-159`).

## B. Generated artifacts

| Artifact | Generator | Gate |
|---|---|---|
| `docs/reference/capability-matrix.md` | `scripts/render-capability-matrix.py` | `lint.sh:42` |
| `docs/reference/installer-options.md` | `scripts/render-installer-options.py` | `lint.sh:43` |
| `docs/reference/keybindings.md` (between markers, lines 297-590) | `scripts/render-action-reference.py` | `lint.sh:44` |
| `docs/supply-chain-sources.md` | `scripts/render-supply-chain.py` | `lint.sh:52` |
| `starship/.config/starship/catppuccin-{latte,frappe,macchiato,mocha}.toml` | `scripts/update-starship-themes.sh` | `lint.sh:35` |
| `docs/cheatsheets/*.pdf` (untracked) | `docs/cheatsheets/generate.sh` | `docs/cheatsheets/verify.sh` in the `cheatsheets` CI job |

## C. Printable PDF page counts (built in this audit)

| Sheet | Pages | Budget |
|---|---|---|
| fedora-kde | 1 | 1 |
| fedora-sway | 2 | 2 |
| fedora-wsl | 2 (page 2 is footer only) | 2 |
| macos | 2 | 2 |
| parrot-ctf | 1 | 1 |

## D. Custom action sources

`zsh/.zshenv`; `zsh/.config/zsh/.zshrc` (aliases, functions, `bindkey`, `setopt`, `FZF_CTRL_R_OPTS`); `platforms/{fedora,fedora-wsl,macos,parrot-ctf}/stow/zsh-platform/.config/zsh/{platform,platform-env}.zsh`; `bin/.local/bin/theme`; `tmux/.tmux.conf`; `nvim-lazyvim/.config/nvim/lua/plugins/{dotnet,latex,markdown,formatting}.lua` (keymaps; `keymaps.lua` has none); `platforms/fedora-wsl/stow/nvim-wsl/.config/nvim/lua/plugins/wsl.lua`; `platforms/macos/stow/nvim-macos/.config/nvim/lua/plugins/macos.lua`; `platforms/fedora/stow/sway/.config/sway/config` and `.local/bin/{sway-screenshot,sway-workspace-grid,sway-session-start,power-profile-status}`; `platforms/fedora/stow/waybar/.config/waybar/config.jsonc`; `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` and `.local/bin/aerospace-workspace-grid`; `platforms/fedora-wsl/stow/interop/.local/bin/{wsl-open,wsl-copy,wsl-paste}`; `platforms/parrot-ctf/stow/command-shims/.local/bin/{bat,fd}`. Confirmed to define no custom actions: `git/.config/git/config`, `lazygit/.config/lazygit/config.yml`, `bat/.config/bat/config`, `ghostty/.config/ghostty/{config,shared.conf}`.

## E. Public-facing scripts and entry points

| Path | Class | Documented |
|---|---|---|
| `install.sh` (+ `--platform`, `--rerun`, `doctor` subcommand) | canonical public entry point | README, install.md, rerun.md (`doctor` subcommand only in rerun.md) |
| `doctor` | canonical public entry point | README, repository-conventions.md; absent from troubleshooting/verification/index (DOC-038) |
| `scripts/lint.sh`, `scripts/test.sh` | canonical public (contributor) entry points | README, testing.md, verification.md |
| `verify.ps1`, `platforms/windows/install.ps1` | supported platform-specific entry points; unclassified by the roles manifest (DOC-069) | fedora-wsl.md only |
| `platforms/windows/{verify,set-noctty-theme}.ps1`, `lib/wsl-version.ps1` | internal (called by `install.ps1`/root `verify.ps1`) | none (acceptable) |
| `platforms/<p>/install.sh` | supported platform-specific direct entry point | help text; installation.md |
| `platforms/<p>/scripts/{install,verify}-*.sh`, `platforms/<p>/scripts/verify.sh` | supported platform-specific component commands | profile/platform guides; verifier flags under-documented (DOC-041) |
| `platforms/fedora/scripts/verify-parrot-isolation.sh` | supported platform-specific | vm-guest.md |
| `scripts/{install-ai,install-mise,install-neovim-tools,install-tmux-theme,verify-ai}.sh` | portable wrappers (supported aliases for `common/`) | troubleshooting.md, install.md |
| `scripts/install-{asus-hardware,containers,desktop-tools,hardening,kde-theme,latex,sway,system,tailscale,terra,vm-guest,vm-host}.sh`, `scripts/verify-*.sh`, `scripts/verify.sh`, `scripts/stow.sh`, `scripts/setup-local.sh`, `scripts/apply-kde-theme.sh`, `scripts/lib/theme-state.sh`, `scripts/test-installer.sh` | deprecated Fedora compatibility wrappers (notice to stderr, removal no earlier than 2027-03-15) | repository-conventions.md; still named by `install-asus-hardware.sh:365` (DOC-039) |
| `scripts/test-dev-workflows.sh` | supported public (installed-machine smoke tests) | development.md, latex.md, macos.md |
| `scripts/benchmark-shell-startup.sh`, `scripts/update-starship-themes.sh`, `scripts/test-dev-workflows.sh`, `docs/cheatsheets/{generate,verify}.sh` | public entry points per `shell-file-roles.tsv`, omitted from the conventions table (DOC-068) | shell.md, theming.md, development.md, cheatsheets/README.md |
| `scripts/render-*.py`, `scripts/validate-*.py` (11 files) | maintainer tools; unclassified by the roles manifest (DOC-069) | capabilities.md, testing.md, supply-chain.md; `validate-shell-file-roles.py` undocumented |
| `common/*.sh`, `scripts/install-main.sh`, `scripts/bootstrap-macos.sh`, `common/lib/*.sh` | internal implementation | repository-conventions.md; `install.md:159-162` and `troubleshooting.md` name `common/install-ai.sh`/portable wrappers as user-callable, which the conventions allow |
| `bin/.local/bin/theme`, stowed helpers (`sway-*`, `aerospace-workspace-grid`, `wsl-*`, `power-profile-status`, Parrot `bat`/`fd`) | installed user commands | registry / sheets (gaps in DOC-055) |
| `tests/**`, `tests/support/dap-smoke.py`, `tests/lib/test.sh` | test helpers | testing.md |
| `tests/integration/{fedora-clean-install,macos-dotnet-debug,wsl-open-real}.sh` | integration tests run by `real-install.yml`/`validate.yml` | named only in `supply-chain-sources.md`; no doc says how or when to run them (fold into DOC-071) |

## F. Historical references found and their classification

| Reference | Location | Classification |
|---|---|---|
| issue #148 (theme precedence on rerun) | `common/lib/theme-{hooks,selection}.sh:3`, four platform installers, `verify.sh:102`, `testing.md:83` | useful rationale |
| issue #125 (Starship generation) | `scripts/update-starship-themes.sh:6`, `test-starship-themes.sh` | useful rationale |
| issues #157, #168 (shell ergonomics, tar/untar) | `test-shell-startup.sh`, `parrot-ctf-shell-audit.md:28,57`, `testing.md:46-47` | useful rationale (role 7 / test header) |
| issues #159-163, #169, #210, #146, #149, #151, #16, #72 | test headers, `testing.md`, `validate-network-sources.py:187` | useful rationale / test provenance |
| "legacy" in `git-identity.md:42-43`, `first-run.md:96-101`, `vm-guest.md:70-75`, `development.md:75`, `supply-chain-sources.md:31,87` | live behaviour or deliberate control cases | legitimate troubleshooting/rationale context |
| `--smoke-test`, `--workflows` deprecated spellings | `fedora-wsl.md:563`, `macos.md`, installers | legitimate deprecation notice |
| README section names quoted in seven scripts | DOC-039 | **stale normative dependency** |
| `installation.md` "historical `scripts/*.sh` paths remain thin compatibility entry points" | `:60-61` | accurate, but should link the deprecation policy |
| `file-ownership.md:77-79` "when upgrading from a version that tracked these files accidentally" | live migration code in `common/setup-local.sh` | legitimate context; wrong script named (DOC-008) |
| `nvim-lazyvim/.config/nvim/README.md` upstream starter text | DOC-070 | **stale normative dependency** |
| `install.md:161`, `network-sources.tsv:26-27` rollback cells naming `common/install-ai.sh` | DOC-073 | **stale normative dependency** (internal path presented as the interface) |
| `docs/supply-chain.md` tiers vs `network-sources.tsv` | verified: six tiers, exact match, no duplicated prose with the generated inventory | — |
| `tests/test-macos-ai.sh:233-236` grep asserting no `issue #16` claim returns | executable anti-staleness gate | — |
| TODO/FIXME | none outside `mktemp` templates and the validator regex | — |
