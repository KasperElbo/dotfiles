# AI-assisted development toolchain

AI-assisted development is an entirely optional workstation profile. **The
default `./install.sh`, with no AI-related flag, installs no Claude Code,
Codex, Herdr, GNHF, backpass, FirstMate, or any tool FirstMate requires, and
creates none of `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, or
`~/.config/opencode/AGENTS.md`.**
Select it explicitly:

```bash
./install.sh --ai                        # Claude Code + Herdr (core)
./install.sh --ai --codex                # + OpenAI Codex CLI
./install.sh --ai --firstmate            # + FirstMate and its required toolchain
./install.sh --ai --gnhf                 # + GNHF unattended overnight runs
./install.sh --ai --backpass             # + backpass instructions-file tuning
./install.sh --ai --codex --firstmate --gnhf --backpass   # all of the above
```

`--codex`, `--firstmate`, `--gnhf`, and `--backpass` require `--ai` and are
rejected otherwise (`--backpass` does not require `--firstmate` — the two
are independent). The profile is also independently callable and safe to
rerun:

```bash
./scripts/install-ai.sh [--codex] [--firstmate] [--gnhf] [--backpass] \
  [--no-codex] [--no-firstmate] [--no-gnhf] [--no-backpass] \
  [--non-interactive] [--dry-run] [--validate]
```

`--dry-run` prints exactly which components would be installed, kept, or
removed and where, without touching the filesystem; `--validate` runs
verification only. Nothing here authenticates any agent, pushes, merges,
force-pushes, or deletes Git branches, or requests API credentials — see
[Authentication](#authentication) below.

### Platform scope

Fedora, Fedora WSL, and macOS all expose `--ai` and every subcomponent flag,
and all three run the same `common/install-ai.sh` and `common/verify-ai.sh`.
There is no platform-specific AI installer, and no platform adds a Homebrew,
DNF, or global-npm copy of a tool mise already owns. On macOS the AI step is
planned after mise so every command resolves through the same mise environment;
see [the macOS guide](../platforms/macos.md#ai-assisted-development-toolchain) for the
per-component Apple Silicon support table and the real-runner evidence behind
it. The Parrot CTF profile declares the AI profile unsupported.

Support for a component is per platform, and losing one never disables `--ai`
itself: if `config/capabilities.tsv` demotes a component on a platform, that
platform's installer refuses the selection before installing anything. On
**macOS**, `platforms/macos/install.sh` rejects exactly that sub-flag with a
dedicated, actionable message and installs the rest of the profile normally.
On **Fedora and Fedora WSL**, sub-capabilities instead go through the shared
`capability_validate_selection` preflight, which fails the whole run rather
than continuing without the unsupported component.

## Subcomponent transitions are additive

Selection is **additive**, not desired-state. Omitting a sub-flag on a later
run means *leave that subcomponent exactly as it is*; it never uninstalls
anything and never rewrites the recorded state to `disabled` behind a
component that is still on disk:

```bash
./install.sh --ai --codex     # Codex is installed
./install.sh --ai             # Codex is still installed, and still recorded
```

Removal is always explicit:

```bash
./scripts/install-ai.sh --no-codex                    # asks first
./scripts/install-ai.sh --no-codex --non-interactive  # unattended acknowledgement
```

A removal deletes only what the recorded provenance still proves this
repository installed — a mise tool declared in the managed
`~/.config/mise/conf.d/ai.toml`, a FirstMate checkout whose remote and commit
still match what was recorded, or a Treehouse/No Mistakes binary whose
SHA-256 still matches. If you replaced one of those yourself, the installer
**refuses the whole removal before changing anything** and tells you which
path to handle by hand. It never deletes credentials, project data, or an
unowned path that merely looks like an installer target.

`common/verify-ai.sh` fails when an enabled component is missing or broken,
and reports — rather than silently rewriting — a component that is disabled
but still present, naming the `--no-<component>` flag that would remove it.

## How remote installers are handled

No component is installed by piping a download into a shell. Remote installer
content is downloaded into a mode-0600 temporary file under a bounded
timeout/retry policy, rejected unless it survives validation (transport
failure, empty body, wrong shape, or a digest mismatch where a digest
exists), executed only then by an explicit interpreter, deleted immediately,
and followed by verification of the exact expected target. The SHA-256 of the
installer that actually ran, and of the binary it produced, are both recorded
in the profile state. See [docs/supply-chain.md](../supply-chain.md) for
the full policy, the provenance tiers, and why FirstMate, Treehouse, and No
Mistakes remain deliberately rolling.

Every mise call the profile makes runs in a deterministic context, so a
`.mise.toml` in whatever directory you happened to start the installer from
cannot change which tools get installed.

## Core agent: Claude Code

Claude Code (`anthropics/claude-code`) is the preferred/core coding agent.
Anthropic documents several install methods (native installer, Homebrew,
apt/dnf/apk, npm); this profile deliberately installs it through **mise's npm
backend** (`npm:@anthropic-ai/claude-code`), the same ownership model this
repository already uses for `npm:@mermaid-js/mermaid-cli` and `npm:neovim`.
This trades the native installer's silent background auto-update for one
consistent, mise-owned update/uninstall path shared with Codex and Herdr, and
avoids adding a second, Fedora-only package-management path (the `dnf` Claude
Code repository) that would not carry over to Fedora WSL or macOS unchanged.

### Claude Code does not update itself

Choosing mise as the owner is not enough on its own, and the reason is worth
stating exactly, because the obvious fix is the wrong one.

Claude Code decides how it was installed by looking at its own executable path.
mise's npm backend puts the package under
`installs/npm-anthropic-ai-claude-code/<version>/lib/node_modules/@anthropic-ai/claude-code/…`,
and that path contains `/node_modules/@anthropic-ai/`, so the tool reads itself
as an ordinary global npm install. Its update route for that case is `npm
install -g @anthropic-ai/claude-code@<target>`, and npm's global prefix for the
mise-managed Node is **the Node installation directory** — `installs/node/<version>`
— not the backend prefix mise installed into. So the update never replaces the
mise copy. It writes a second one beside it, which then shadows the first, and
verification correctly reports a duplicated provider.

The division of responsibility is:

```text
mise         -> installs and updates Claude Code
Claude Code  -> must not replace or update its own package
```

Two places carry that block, and they prove different things.

**Claude Code's own settings file is the block.** `common/install-ai.sh`
declares both keys under the `env` key of `~/.claude/settings.json`:

```json
{ "env": { "DISABLE_UPDATES": "1", "DISABLE_AUTOUPDATER": "1" } }
```

The tool reads that file however it was launched, which is the property that
makes the setting hold. Both keys because they are not interchangeable across
versions: only builds new enough to know about `DISABLE_UPDATES` honour it,
while every build reads `DISABLE_AUTOUPDATER`. `DISABLE_UPDATES` is also the
stronger of the two where it is read, blocking manual `claude update` and
`claude install` as well as the background check, which `DISABLE_AUTOUPDATER`
alone leaves free to replace the mise-owned package.

That file is **merged, never overwritten and never symlinked**: Claude Code
writes to it itself, and so does the user. Every other key is preserved. A file
that does not parse as JSON, or whose `env` is not an object, is reported and
left exactly as it is, and the install does not claim success — guessing at the
intent of a configuration file this repository did not write is the one thing
an ownership model must not do.

**`zsh/.zshenv` is the second line, not the block.** It exports the same
setting for every top-level Zsh, interactive or not. What that cannot cover is
a Claude Code started by something that is not a descendant of such a shell —
an editor, a launcher, a terminal session that predates the install — and such
a process reads none of `.zshenv`. A shell-exported variable is not a control
over a program you did not launch from that shell, and relying on it alone is
what let the duplicate come back after every cleanup.

Verification asks both, and says which is which: that the settings file
declares both keys with the value the tool's gate accepts, that a fresh
non-interactive login still exports `DISABLE_UPDATES`, that `claude` resolves
to the dedicated mise installation or its shim, and that no AI package is
duplicated in the active Node prefix. A duplicate is reported with the command
that removes only it — `npm uninstall -g <package> && mise reshim` — and the
installer does not run that command itself. A package this repository did not
install is unproven external state, and deleting it silently is the other thing
the ownership model must not do. See
[Anthropic's documentation on disabling auto-updates](https://code.claude.com/docs/en/setup#disable-auto-updates).

The generated AI mise configuration enables npm lifecycle scripts and includes
optional dependencies only for the Claude Code tool installation
(`--ignore-scripts=false --include=optional`). This is required because
Anthropic's npm package uses `postinstall` to link its platform-native binary,
while mise's npm backend disables lifecycle scripts by default. The profile
therefore accepts lifecycle scripts from Claude Code's installation graph,
not from the other npm tools. Verification runs `claude --version` through
mise's explicit environment, so an omitted or failed native binary cannot
appear healthy merely because a shim or npm wrapper exists. If that specific
failure occurs immediately after installation, the installer removes and
reinstalls only Claude Code once, then repeats the health check. It does not
change the user's global npm configuration. See
[Anthropic's setup documentation](https://docs.anthropic.com/en/docs/claude-code/setup)
and [mise's npm lifecycle-script documentation](https://mise.jdx.dev/dev-tools/backends/npm.html#lifecycle-scripts).

Claude Code runs in any Git repository, including one checked out through
`git worktree`; it has no special worktree requirements of its own. See
[Optional: FirstMate and its required toolchain](#optional-firstmate-and-its-required-toolchain)
below for how this repository gives an agent a safe, isolated worktree rather
than pointing it at your primary checkout.

## Shared agent instructions: AGENTS.md

`--ai` unconditionally links a single instructions file to every installed
harness's global-instructions path, so editing one file changes what every
agent sees, rather than maintaining a separate copy per tool. The file is
`common/assets/AGENTS.md`, a tracked copy of the same personal instructions
used on this user's NixOS/home-manager machines
([`KasperElbo/dotfiles-nix`](https://github.com/KasperElbo/dotfiles-nix),
`home/AGENTS.md`) — mirrored here manually, not fetched at install time, so
this profile stays usable offline and has no runtime dependency on that
repository. Re-sync it by hand if the upstream copy changes.

It is symlinked, unconditionally, to:

| Harness | Path |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md` |
| Codex CLI | `~/.codex/AGENTS.md` (`$CODEX_HOME/AGENTS.md` if set) |
| OpenCode | `~/.config/opencode/AGENTS.md` |

Non-destructive: if any of those three paths already holds a real file, or a
symlink pointing somewhere else, `install-ai.sh` leaves it untouched and
prints a warning rather than overwriting a harness-specific file you put
there yourself. Edit `common/assets/AGENTS.md` in this repository to change
it for every harness at once; `common/verify-ai.sh` confirms all three links
still resolve to it.

## Optional: OpenAI Codex CLI

`--codex` additionally installs the Codex CLI (`npm:@openai/codex`) through
the same mise ownership as Claude Code, so the two coexist without a second
install mechanism or a PATH ownership conflict. Codex is otherwise
independent of Claude Code: install either, both, or neither.

## Agent workspace/runtime: Herdr

[Herdr](https://herdr.dev) is a terminal multiplexer built specifically for
AI coding agents — persistent panes/tabs/workspaces, detach/reattach, and
agent-state awareness (working/idle/blocked) for Claude Code, Codex, and
similar tools. It is installed unconditionally with `--ai` (via `mise use -g
herdr`, matching mise's own documented install method), not gated behind
`--firstmate`, because it is useful the moment you have even a single Claude
Code session and is a single small, mise-owned binary rather than a heavy
dependency.

Responsibility split, so Ghostty, tmux, and Herdr never become three
competing layout/session systems:

```text
Ghostty -> terminal emulator / host window
tmux    -> lightweight shell/session multiplexing where still useful
Herdr   -> AI-agent workspace/orchestration (panes aware of agent state,
           detach/reattach, launching Claude Code/Codex workers)
```

Ghostty remains the normal terminal; this profile does not install a second
terminal emulator. Run `herdr` inside Ghostty in a project directory to start
a workspace, detach, and `herdr` again to reattach — see
[herdr.dev/docs](https://herdr.dev/docs) for the current pane/workspace
commands and socket API rather than duplicating fast-moving upstream option
lists here. Herdr's agent-aware panes make tmux's own session/window
management redundant for a multi-agent workflow; this repository does not
add glue code to bridge the two; use tmux (already installed, intentionally
thin) for ordinary shell multiplexing outside of agent work, and Herdr for
agent panes.

Both use `Ctrl+B` as their prefix, and neither is reconfigured here to avoid
the other. Side by side — one in each Ghostty tab — that costs nothing, since
a prefix is grabbed per process tree, and the split above is the reason not to
nest them in the first place. Nested anyway, the outer one takes the prefix
and the inner never sees it; tmux's own stock `bind-key -T prefix C-b
send-prefix` is the way through, so `Ctrl+B Ctrl+B` reaches a Herdr running
inside tmux, the same double-prefix dance nested tmux has always used.

## Optional: FirstMate and its required toolchain

`--firstmate` installs [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate)
itself, plus every tool its own `docs/configuration.md` lists as required
(not merely nice-to-have) — all from the same author (Kun Chen), each
independently installable and independently useful on its own:

| Tool | What it's for | Owner |
|---|---|---|
| [firstmate](https://github.com/kunchenguid/firstmate) | the coordinator itself — a Claude-Code-compatible distribution, not a package | `git clone`/`git pull --ff-only` to `~/.local/share/firstmate` |
| [Treehouse](https://github.com/kunchenguid/treehouse) | pools isolated Git worktrees for crewmates (`get`/`enter`/`status`/`return`/`prune`/`destroy`/`lease`) | own install script, to `~/.local/bin/treehouse` |
| [No Mistakes](https://github.com/kunchenguid/no-mistakes) | local push-validation gate (see below) | own install script; a regular file at `~/.local/bin/no-mistakes` on Fedora/Fedora WSL, or on macOS a launcher symlink at `~/.local/bin/no-mistakes` pointing at `~/.no-mistakes/bin/no-mistakes` |
| [gh-axi](https://github.com/kunchenguid/gh-axi) | agent-ergonomic wrapper around the already-installed, already-authenticated `gh` CLI | mise, `npm:gh-axi` |
| [chrome-devtools-axi](https://github.com/kunchenguid/chrome-devtools-axi) | agent-ergonomic browser automation (launches its own headless Chrome; no separate browser install needed) | mise, `npm:chrome-devtools-axi` |
| [lavish-axi](https://github.com/kunchenguid/lavish-axi) | serves FirstMate's "rich-review" surfaces for HTML artifacts, locally | mise, `npm:lavish-axi` |
| [tasks-axi](https://github.com/kunchenguid/tasks-axi) | backlog/task manager FirstMate uses for crewmate handoff (edits a local `backlog.md`) | mise, `npm:tasks-axi` |
| [quota-axi](https://github.com/kunchenguid/quota-axi) | reports local LLM subscription quota windows so FirstMate's dispatch can decide whether to start/parallelize work; read-only, never mints/rotates credentials | mise, `npm:quota-axi` |

Requires `gh`, `tmux`, and `jq` (all already installed by the base profile);
can use Herdr as an alternative crew backend to tmux once installed above.
None of these need a separate account: `gh-axi`/`quota-axi` read your
already-authenticated `gh`/agent-CLI credentials, and the rest need no auth
at all.

FirstMate lets one coordinator session (Claude Code, by default here) talk to
you while it delegates isolated implementation work to crewmates it spawns
and supervises, each in its own Treehouse worktree, reporting plain outcomes
back to you. Registering a specific project and choosing one of its three
project modes (`direct-PR`, `local-only`, or `No Mistakes`, which runs full
CI validation before merge — very likely via the standalone No Mistakes tool
above, though FirstMate's docs don't explicitly confirm that link) is a
per-project, per-user decision this installer does not and cannot make
safely on your behalf. After installing:

```bash
cat ~/.local/share/firstmate/README.md    # follow FirstMate's own setup docs
gh auth login                             # if you have not already
treehouse --help                          # usable directly, with or without FirstMate
```

then launch a coordinator session there and register your project as
documented in that repository. This installer never runs `gh auth login`,
registers a project, `no-mistakes init` in any repository, or
`gh-axi`/`lavish-axi setup hooks` (their optional agent SessionStart hooks)
for you — all deliberate, manual, per-repository or per-preference steps.

### No Mistakes, in more detail

[No Mistakes](https://github.com/kunchenguid/no-mistakes) is a local Git
push-validation gate: instead of `git push origin <branch>`, you run
`git push no-mistakes <branch>`. That spins up a disposable worktree, runs
a validation pipeline, auto-applies safe mechanical fixes, escalates
anything that touches your intent for you to approve/fix/skip, and only
forwards to your real remote (opening a PR) once everything passes. It is
**strictly per-invocation** — nothing happens to a normal `git push`, and it
never intercepts one. Setup (`no-mistakes init`, which creates a local bare
repo under `~/.no-mistakes/repos/` and adds the `no-mistakes` remote) is
per-repository and always manual; installing this profile only puts the
`no-mistakes` binary on `PATH`.

Each tool above is installed through exactly one mechanism: mise for the
five `*-axi` npm packages (same ownership as Claude Code/Codex/GNHF), and an
official install script for Treehouse/No Mistakes (neither has a mise
registry entry or an OS package). `verify-ai.sh` checks all seven the same
way it checks everything else in this profile — mise ownership for the
mise-managed ones, PATH-resolution-to-the-installed-copy for the other two.

### What "installed" means for the mise packages

Every package in the managed `ai.toml` is declared at `latest`, which is
deliberate for an agent toolchain. `latest` is a request, though, not an
answer, so the installer records what it resolved to: one
`<tool>_version=<version>` line per declared package in
`~/.config/dotfiles/ai.conf`, read back from `mise ls <spec> --json` after
the install. The key is the package name with any npm scope and the `npm:`
prefix removed and `-` replaced by `_`, so
`"npm:@anthropic-ai/claude-code"` is recorded as `claude_code_version`.

That is what a rollback reads after a bad release, and what answers, later,
whether this machine ever ran one. A package the listing does not report as
installed fails the run rather than being recorded as installed.

### What "installed" means for the three non-package tools

FirstMate publishes no releases, and neither Treehouse nor No Mistakes
publishes a checksum for its install script, so all three sit in this
repository's `reviewed-live`/rolling tiers rather than being pinned. What
makes that accountable is that the installer records exactly what it got:

| Tool | Channel | Recorded in `~/.config/dotfiles/ai.conf` |
|---|---|---|
| FirstMate | upstream default branch, deliberately rolling | `firstmate_source`, `firstmate_commit` |
| Treehouse | live install script | `treehouse_source`, `treehouse_digest` (the script that ran), `treehouse_target_digest` (the binary it produced), `treehouse_target_path` (where that binary actually lives, if it differs from `~/.local/bin/treehouse`) |
| No Mistakes | live install script | `no_mistakes_source`, `no_mistakes_digest`, `no_mistakes_target_digest`, `no_mistakes_target_path` (where the binary actually lives, if `~/.local/bin/no-mistakes` is a launcher symlink rather than the binary itself — the normal case on macOS; see "Optional: FirstMate" above) |

`common/verify-ai.sh` and `no_mistakes_target_path`/`treehouse_target_path`
are shared across every platform: when either command is a launcher symlink,
verification confirms it still resolves to the recorded target path rather
than assuming the launcher itself is the installed binary, and a
`--no-firstmate` removal deletes the resolved target, not merely the
launcher.

To update, rerun `./scripts/install-ai.sh --firstmate`. To pin FirstMate to
the revision you have today, `git -C ~/.local/share/firstmate checkout
<commit>` using the recorded `firstmate_commit` — note that a later rerun
will fast-forward it again. `verify-ai.sh` reports when a recorded digest or
commit no longer matches what is on disk, because that is also the point at
which a `--no-firstmate` removal will refuse to delete the file.

The digests above are audit records of what was installed, **not** integrity
pins: hashing a live, mutable URL at install time proves the download was not
corrupted in flight, and nothing about what the next machine will receive. If
an upstream later publishes a real checksum, set
`TREEHOUSE_INSTALL_SCRIPT_SHA256` or `NO_MISTAKES_INSTALL_SCRIPT_SHA256` and
the installer enforces it as a hard precondition. See
[docs/supply-chain.md](../supply-chain.md).

## Optional: GNHF unattended overnight agent orchestrator

`--gnhf` additionally installs
[GNHF](https://github.com/kunchenguid/gnhf) ("Good Night, Have Fun") through
mise (`npm:gnhf`), the same ownership as Claude Code/Codex. It has no
relation to FirstMate, Herdr, or Treehouse, and needs no separate account —
it shells out to whichever already-authenticated agent CLI you point it at
(`--agent`, default `claude`) in non-interactive mode.

**Read this before your first run.** GNHF runs a coding agent through many
iterations completely unattended: each iteration gets one objective-directed
change, and on success it **commits automatically with no human checkpoint**
— you review the result afterward, not each step. A failed iteration is
rolled back with `git reset --hard` (scoped to GNHF's own commits). There is
no sandboxing beyond `--max-iterations`/`--max-tokens` caps and an abort
after repeated consecutive failures: the agent has the same permissions your
normal Claude Code/Codex session would.

Two defaults keep this compatible with this profile's non-destructive
posture despite that:

- By default GNHF works on a new local `gnhf/<slug>` branch in your repo,
  not your current checkout (an isolated worktree is available via its own
  `--worktree` flag).
- By default GNHF **never pushes**. Pushing is strictly opt-in via GNHF's
  own `--push` flag, which this installer never adds for you and does not
  wrap or default on in any way.

So the "no autonomous push without explicit action" invariant holds even
with GNHF installed — but "many unsupervised commits before you look" is a
real, different trust model from the rest of this profile, and is exactly
why GNHF is its own opt-in flag rather than bundled with core `--ai`. Treat
"point GNHF at an objective and let it run overnight" as a deliberate
choice each time, the same way you would `--hardening` or a raw `sudo`
command — not something to leave on a machine that other people can queue
work on. Config lives at `~/.gnhf/config.yml` (created on first run,
untracked, machine-local).

## Optional: backpass instructions-file tuning

`--backpass` additionally installs
[backpass](https://github.com/kunchenguid/backpass) and
[acpx](https://github.com/openclaw/acpx) through mise (`npm:backpass`,
`npm:acpx`), plus `lavish-axi` if it isn't already installed (it's shared
with `--firstmate`; declared once either way, never twice). Unlike every
other subcomponent above, **it is independent of `--firstmate`** — no real
integration between them exists beyond a shared dependency on `lavish-axi`
for review UIs, so `--ai --backpass` alone works fine.

backpass reads agent session transcripts (Claude, Codex, Pi, OpenCode,
Grok, Cursor CLI, Hermes) directly off disk, distills them (96–99% token
reduction) locally, and proposes evidence-backed edits to your
`AGENTS.md`/`CLAUDE.md` — one card per edit, with the diff, the evidence
quotes, and their sources, served through `lavish-axi`. **`backpass apply`
is the only command that writes anything**, and only for edits you
individually ACCEPT; rejections are remembered and not re-proposed unless
new evidence appears.

What to know before your first run:

- It is not purely offline: the distilled (secret-redacted) trace still
  travels over the network, through `acpx`, to whichever model you
  configure. Same trust boundary as the agent CLI you already use, not a
  new one — but not zero-exposure either.
- Its default model routing can call a **non-Claude model** for analysis
  and/or synthesis (with a Claude fallback). Pin one provider explicitly
  with `--analysis-agent`/`--synthesis-agent` if that matters to you; this
  installer does not change backpass's own defaults.
- It edits the single file that steers every future agent session in a
  repository. The mandatory review gate is real, but it's still worth
  reading each diff carefully rather than rubber-stamping — that's on you,
  not the tool.
- Setup (`backpass init`) is per-repository and always manual; installing
  this profile only puts `backpass`/`acpx` on `PATH`.

### Other Kun Chen tools evaluated but not installed

One more tool from the same ecosystem came up during review and is not
installed by this profile:

- **[AXI](https://github.com/kunchenguid/axi)** (`kunchenguid/axi`) itself
  is not a tool to install — it is a design specification (10 principles)
  plus a catalog of 70+ community reference implementations (Jujutsu,
  npm/PyPI/Cargo, cloud platforms, Slack/Notion/Jira, and more) for
  building token-efficient, agent-ergonomic CLI wrappers. `gh-axi`,
  `chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, and `quota-axi` above
  are the reference implementations this profile actually uses (because
  FirstMate requires them, or because `--backpass` needs `lavish-axi`); the
  rest of the catalog is not — install one yourself only if you personally
  use that specific tool a lot with an agent (for example
  `npm install -g gh-axi` standalone, without `--firstmate`, works fine
  against your existing `gh`).

## Non-destructive defaults

None of this profile's own tooling pushes branches, merges pull requests,
force-pushes, or deletes branches on its own. No Mistakes (installed with
`--firstmate`) only ever acts when you explicitly run
`git push no-mistakes <branch>` instead of your normal push — it never
intercepts a plain `git push`, and its own setup (`no-mistakes init`) is
per-repository and manual, never run by this installer. FirstMate's own
project modes gate publication behind an explicit captain decision
(`local-only` waits for an approved fast-forward merge; `direct-PR` opens a
PR for human review; its `No Mistakes` mode additionally runs full CI, very
likely via that same tool, before merge) — this repository does not enable
an autonomous push/merge mode by default, and installing this profile does
not change any existing Git signing,
authentication, or identity configuration (see "Git, SSH and GitHub
authentication" in [first-run choices](../workflows/first-run.md)). GNHF, if
selected, defaults to committing on its own local `gnhf/<slug>` branch and
never pushes; pushing is opt-in via GNHF's own `--push` flag, which this
installer never adds on your behalf (see "Optional: GNHF" above for the
part of its behavior — unsupervised, per-iteration commits — that this
invariant does not cover). Prefer Claude Code and Codex's own review/PR-
oriented workflows, with a human decision at the publication/merge
boundary, as shown in the normal usage flow below.

## Normal usage

```text
open repository
  -> start/reattach a Herdr workspace (or a plain tmux/Ghostty session)
  -> use Claude Code directly, or start a FirstMate coordinator session
  -> delegate isolated work into a Treehouse worktree (directly, or through
     FirstMate's own crewmates), or a plain `git worktree` if Treehouse
     is not installed
  -> review the resulting diff and run tests
  -> create a PR (gh pr create, or let Claude Code/Codex/FirstMate open one)
  -> a human decides whether to merge
```

## Authentication

Never committed to this repository: API keys, OAuth tokens, provider
credentials, GitHub tokens, or agent session state. Authenticate each tool
interactively, on the machine, after installing:

- **Claude Code**: run `claude`, follow the browser login prompt (or set
  `ANTHROPIC_API_KEY` for API-key auth). State lives in `~/.claude/` and
  `~/.claude.json`, untracked and machine-local.
- **Codex**: run `codex`, choose "Sign in with ChatGPT" (or configure an
  OpenAI API key). State lives under `~/.codex/`, untracked and
  machine-local.
- **FirstMate**: uses your already-authenticated `gh` (`gh auth login`); it
  does not manage its own separate credentials.
- **GNHF**: no separate account; it shells out to your already-authenticated
  `claude` (or another configured `--agent`). Its own config lives at
  `~/.gnhf/config.yml`, untracked and machine-local.
- **backpass**: no separate account; every model call goes through `acpx`
  to a harness you have already authenticated. Per-repository state lives
  under a git-excluded `.backpass/` directory (see `.git/info/exclude`),
  untracked and machine-local.

Revoke access by signing out of each tool, or by deleting its state
directory above; none of it is readable from this repository.

## Verification

```bash
./scripts/verify-ai.sh
```

checks that Claude Code, Herdr, and (if selected) Codex/GNHF/gh-axi/
chrome-devtools-axi/lavish-axi/tasks-axi/quota-axi/backpass/acpx resolve on
PATH through mise's shim (or directly to the executable mise reports) rather
than a second install shadowing it elsewhere on PATH (catching duplicate
npm/Homebrew/native-installer ownership of the same tool), and, if
selected, that FirstMate is cloned with `gh`, `tmux`, and `jq` present, and
that Treehouse/No Mistakes resolve to the copies this profile installed at
`~/.local/bin/treehouse` and `~/.local/bin/no-mistakes`, and that
`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, and
`~/.config/opencode/AGENTS.md` are still symlinked to
`common/assets/AGENTS.md` (see "Shared agent instructions" above).
`platforms/fedora/scripts/verify.sh` (and the Fedora WSL equivalent) run
this automatically whenever the AI profile's state file is present, and
separately confirm that **no** AI-owned file exists when it is not.

## Ownership summary

| Component | Owner | Update |
|---|---|---|
| Claude Code | mise (`npm:@anthropic-ai/claude-code`) | `mise upgrade` |
| Codex CLI | mise (`npm:@openai/codex`) | `mise upgrade` |
| Herdr | mise (registry) | `mise upgrade` |
| GNHF | mise (`npm:gnhf`) | `mise upgrade` |
| backpass, acpx | mise (`npm:backpass`, `npm:acpx`) | `mise upgrade` |
| FirstMate | `git clone`/`git pull --ff-only` to `~/.local/share/firstmate` | rerun `--firstmate` |
| Treehouse | own install script, to `~/.local/bin/treehouse` (no mise registry entry) | rerun `--firstmate` |
| No Mistakes | own install script, to `~/.local/bin/no-mistakes` (no mise registry entry) | rerun `--firstmate` |
| gh-axi, chrome-devtools-axi, tasks-axi, quota-axi | mise (`npm:<name>`), all with `--firstmate` | `mise upgrade` |
| lavish-axi | mise (`npm:lavish-axi`), with `--firstmate` and/or `--backpass` (declared once either way) | `mise upgrade` |
| `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md` | symlinks to `common/assets/AGENTS.md`, unconditionally with `--ai` | edit `common/assets/AGENTS.md` |

See [AI agent tooling](../architecture/package-ownership.md#ai-agent-tooling) for how this avoids
duplicate installs of the same tool. Every mise-managed tool above is
declared in an **untracked, machine-local** mise config file, not the tracked
`~/.config/mise/config.toml` this repository always installs:

```text
~/.config/mise/conf.d/ai.toml
```

mise merges every `*.toml` file under `~/.config/mise/conf.d/` alongside its
main global config, so this file adds Claude Code/Codex/Herdr to mise's view
without the default, always-applied mise config ever gaining an AI-related
dependency. `install-ai.sh` writes and owns this file; deleting it and
rerunning the AI profile recreates it.

The AI profile is unsupported on the
[Parrot Security Edition CTF guest](../platforms/parrot-ctf.md): install or
invoke AI tooling there only as a conscious per-lab decision after confirming
that challenge data may leave the guest.

The saved local state file is:

```text
~/.config/dotfiles/ai.conf
```
