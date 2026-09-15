# Supply chain, reproducibility, and network policy

This document is the authoritative statement of what this repository trusts,
how strongly each thing is pinned, and what happens when a download goes wrong.
The machine-readable source of truth is
[`config/network-sources.tsv`](../config/network-sources.tsv); the rendered
inventory is [supply-chain-sources.md](supply-chain-sources.md), and the
per-capability ownership model stays in
[`config/capabilities.tsv`](../config/capabilities.tsv). Nothing here is a
hand-maintained parallel table: the inventory is generated, and CI fails if it
drifts from the manifest.

## What this repository actually claims

It is **configuration-reproducible**. Given the same commit, the same platform,
and the same capability selection, it deploys the same tracked configuration
and asks for the same declared tool set.

It is **not** bit-for-bit machine reproduction, and no claim here should be
read that way. Two machines installed from the same commit a month apart will
differ wherever a source sits in a rolling tier: distribution packages,
Homebrew formulae, npm `latest`, and the handful of upstreams that publish only
a live install script. That is a deliberate trade, not an oversight — a
workstation that never receives a security update is worse than one whose exact
package versions differ. What the repository does guarantee is that every such
source is *declared*, that its tier is written down, and that what was actually
installed can be read back out of the profile state.

## Provenance and reproducibility tiers

Every network source carries exactly one tier. Strongest first:

| Tier | Meaning | Rebuild in a year gives you |
|---|---|---|
| `immutable-verified` | An immutable artifact, verified against a digest, signature, or key fingerprint this repository pins. | The same bytes, or a hard failure. |
| `exact-commit` | An exact commit, tag, or release reference. | The same source tree. |
| `exact-version` | An exact semantic version requested from an upstream index. | The same version; the artifact is the upstream's to keep stable. |
| `version-line` | A channel or version line (`latest`, `stable`, a major line). | Whatever that line points at then. |
| `os-rolling` | Owned by the OS or its package manager. | Whatever the distribution ships then. |
| `reviewed-live` | Live upstream content, reviewed by a human, verified only by TLS. | Whatever upstream serves then. |

A wildcard is never an exact pin. `3.14.x` is a version line, and the registry
linter rejects it in an `exact-*` row.

`immutable-verified` is reserved for sources whose integrity mechanism actually
checks content this repository pinned (`sha256-pinned`,
`gpg-fingerprint-pinned`, `image-digest-pinned`). TLS alone is transport
security, not provenance, and never earns that tier.

### What stays rolling, and why

- **Distribution packages** (Fedora, Parrot, RPM Fusion, Terra, Tailscale) are
  `os-rolling` on purpose. Pinning them would mean declining security updates.
  They are signed by their repositories' keys.
- **Homebrew formulae and casks** are a version line. Homebrew does not support
  installing a formula at an arbitrary historical version without a tap of your
  own, and bottles are checksummed by Homebrew itself.
- **npm packages installed through mise** (`claude-code`, `herdr`, `codex`,
  `gnhf`, the `*-axi` tools, `backpass`, `acpx`) request `latest`. These are
  fast-moving agent tools where running a months-old release is its own
  hazard. mise records what it installed.
- **The mise, Starship, Scoop, and Homebrew install scripts** are
  `reviewed-live`: each upstream publishes only a live script, with no release
  artifact and no checksum to pin. They are downloaded to a private file,
  validated, and executed by an explicit interpreter — never piped into a
  shell.
- **Treehouse and No Mistakes** are `reviewed-live` for the same reason. What
  the repository adds is accountability: the SHA-256 of the script that
  actually ran is recorded in the AI profile state.
- **FirstMate** is a deliberate rolling channel on its upstream default branch;
  it publishes no releases. The resolved commit is recorded, so the installed
  revision is always knowable and restorable.

The repository deliberately does **not** hash a live, mutable URL at install
time and call the result a pin. A digest computed from whatever was served this
minute proves only that the download was not corrupted in flight; it says
nothing about what the next machine will get. Where such a digest is recorded,
it is recorded as an audit record of what ran, and is labelled that way.

## Bounded network behaviour

[`common/lib/fetch.sh`](../common/lib/fetch.sh) is the only sanctioned way for
repository code to pull bytes off the network:

- HTTPS only, with `--proto '=https' --tlsv1.2`.
- A connect timeout and a total timeout (`DOTFILES_FETCH_CONNECT_TIMEOUT`,
  `DOTFILES_FETCH_MAX_TIME`).
- A bounded number of attempts with exponential backoff
  (`DOTFILES_FETCH_ATTEMPTS`, `DOTFILES_FETCH_RETRY_DELAY`).
- A single clear terminal failure naming the URL and the budget spent.
- Destination files are created mode 0600 *before* any remote byte lands.
- An HTTP 200 with an empty body is a failure, not a success.

Retries apply **only** to safe, idempotent GETs into a file. Package manager
transactions, remote scripts, and anything else whose retry could duplicate a
side effect are never retried automatically, and must never be routed through
this library.

`scripts/bootstrap-macos.sh` spells the same bounds out inline: it runs under
Apple's Bash 3.2 before any repository library exists.

## No `curl | sh`

A piped installer reports the *consumer* shell's exit status, so a failed
download can look like a successful install. Every remote script this
repository runs is instead:

1. downloaded into a mode-0600 file inside a private temporary directory;
2. rejected on transport failure, an empty body, binary content, or content
   that does not look like a shell script at all;
3. checked against a pinned digest when one exists;
4. executed only then, by an explicit interpreter, so a missing or hostile
   shebang cannot choose one;
5. removed immediately afterwards;
6. followed by verification of the exact expected command path — which must
   resolve to a regular file, owned by the invoking user, executable, and able
   to run `--version` or `--help`.

Where an upstream puts the binary behind that command path is the upstream's
own choice: No Mistakes on darwin/arm64 installs into `~/.no-mistakes/bin` and
leaves a launcher symlink on `PATH`, while Treehouse writes the binary straight
to the command path. Verification resolves the chain first and asks every
question of the file it names, and the profile state records that file's path
alongside its digest — so a later `--no-firstmate` removes the binary an
upstream installed, not just the launcher pointing at it, and refuses when the
command now resolves somewhere else.

Only after that verification may any state record the component as installed.

## The Terra trust boundary

Terra's own documentation bootstraps with `dnf install --nogpgcheck
--repofrompath ... terra-release`, because the repository's signing key ships
*inside* `terra-release`. This repository does not accept that.

Terra also publishes the per-release key at
`https://repos.fyralabs.com/terra<releasever>/key.asc`. The installer therefore:

1. fetches that key through the bounded fetch policy;
2. refuses to import it unless its primary fingerprint matches the value pinned
   for that Fedora release in [`config/terra-keys.tsv`](../config/terra-keys.tsv);
3. imports it with `rpm --import`;
4. installs `terra-release` **with GPG checking enabled** — `--nogpgcheck` is
   gone;
5. fails if `terra-release` did not end up installed.

Pinning the fingerprint is what makes this more than trust-on-first-use: a
later compromise of the distribution host cannot silently substitute a
different signing key.

**The remaining boundary** is a Fedora release newer than the pinned set. There
is no fingerprint to compare against, so the installer prints the downloaded
key's fingerprint and refuses to continue unless a human acknowledges it —
either interactively, or with `TERRA_TRUST_KEY_FINGERPRINT=<fingerprint>` for
an unattended run. Adding the release to `config/terra-keys.tsv` is the
permanent fix, and the file documents how to read the fingerprint.

## Deterministic mise context

mise composes configuration from the global config *and* every
`mise.toml`/`.mise.toml` between the working directory and the filesystem root.
A dotfiles bootstrap started from inside an unrelated project would otherwise
install that project's tools, or let them influence resolution.

Every mise call this repository makes — global install, AI install,
verification, and resolution — goes through `run_mise` in
[`common/lib/common.sh`](../common/lib/common.sh), which:

- runs mise from an empty, repository-owned context directory under
  `$XDG_STATE_HOME/dotfiles/mise-context`, and
- sets `MISE_CEILING_PATHS` to that same directory.

`MISE_CEILING_PATHS` is mise's own supported mechanism: it stops the ancestry
walk at the named directory and excludes that directory itself. The neutral
working directory gives the same guarantee on a mise too old to know the
setting, so the isolation does not depend on a version check. Explicit
`MISE_DATA_DIR` and shim/PATH behaviour is unchanged.

The global config and its `conf.d` fragments still apply — that is exactly the
manifest a global bootstrap is meant to install. `--dry-run` and verbose output
print which logical config is in play.

## AI component transitions

Optional AI subcomponents use **additive** semantics:

- An omitted sub-flag means *leave the installed component unchanged*. It never
  means "reconcile to absent", and it never rewrites state to `disabled` behind
  a component that is still on disk.
- An explicit `--no-<component>` is the only thing that removes anything.
- Removals are shown by `--dry-run`, and an apply run confirms them
  interactively, or requires `--non-interactive` as the explicit
  acknowledgement.

A removal deletes only what the recorded provenance still proves this
repository installed:

| Component | Ownership proof |
|---|---|
| mise-managed tools | Declared in the managed `~/.config/mise/conf.d/ai.toml`, identified by its header. |
| FirstMate | `.git` present, `remote.origin.url` equals the recorded source, worktree clean, `HEAD` equals the recorded commit. |
| Treehouse, No Mistakes | The file's SHA-256 still equals the digest recorded when it was installed. |

If any of those checks fails — a user replaced the binary, repointed the
checkout, or the component predates provenance recording — the installer
**refuses the whole removal before changing anything** and reports the exact
path for manual action. It never deletes credentials, project data, or an
unowned path that merely looks like an installer target.

State separates three concepts in the one existing `ai` profile state file, so
no second state system exists:

- `requested` — the desired optional-component set from the last run;
- the per-component keys (`codex`, `firstmate`, …) — what was observed
  installed, and by which provider;
- `firstmate_source`/`firstmate_commit`, `treehouse_source`/`treehouse_digest`,
  `no_mistakes_source`/`no_mistakes_digest` — provenance.

Verification fails for an enabled component that is missing or broken, and
reports — never silently rewrites — a component that is disabled but still
present, naming the `--no-<component>` flag that would remove it.

## Adding a network source

1. Add a row to `config/network-sources.tsv` with an owner, tier, privilege,
   integrity mechanism, cadence, rollback strategy, and consumers.
2. Annotate the call site with `# network-source: <id>`, on the line or within
   the four comment lines above it.
3. Run `./scripts/render-supply-chain.py` to refresh the generated inventory.

`./scripts/lint.sh` runs `scripts/validate-network-sources.py`, which fails on
an unregistered `curl`, `wget`, PowerShell download, remote `git clone`/`fetch`,
`--repofrompath`, remote release RPM, or container image — and on a registry
row whose tier and integrity mechanism contradict each other. A construct that
genuinely reaches no external network (a loopback probe, a request to the
container under test) is annotated `# network-source: local-only`, which is
still a deliberate, reviewable act.

## Secrets

No installer stores, requests, or logs a credential, API key, auth token, or
private repository URL. Staged installer content lives in a mode-0600 file
inside a 0700 directory and is deleted immediately after it runs. Tests use
fixtures, never real secrets.
