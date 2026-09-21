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

### Noticing that a pinned source has moved

The rolling tiers announce their own updates. A package manager, a registry or
a version line tells the machine that something moved, and `brew upgrade`,
`sudo dnf upgrade --refresh`, `scoop update` or `mise upgrade` applies it with
no change to this repository at all. Neovim is the same story with its own
mechanism: lazy.nvim's update checker is enabled for the workstation profile,
and `:Lazy update` writes the new commits through the Stow symlink into the
checkout, so a plugin bump arrives as a `git diff` on `lazy-lock.json`.

`manual-bump` is the cadence with no such mechanism. Those rows are pinned to
an exact tag, commit or SHA-256 that nothing else would ever mention again, and
for a long time they were the strongest pins here with the weakest
notification. The scheduled real-install validation is not that notification:
it installs from every pin for real, so it catches one that has *broken* — a
download that 404s, a digest that no longer matches — but a pin three releases
old and still serving its bytes correctly produces a completely green run.

```bash
./scripts/check-pin-freshness.sh
```

asks each of those upstreams what it has now and prints it beside what this
repository pins. It is a report: it downloads no artifact, writes no file and
changes no pin. `git ls-remote` reads refs and transfers no objects, so the
whole thing needs no credential and no API budget.
`.github/workflows/pin-freshness.yml` runs it monthly and puts the table in the
run summary. It deliberately does not pass `--fail-on-stale`: a newer tag is a
prompt to go and review a release, not a defect. It *does* fail when a pin
could not be read or an upstream could not be reached, because a report that
silently reached nothing would read as "everything is current".

[`config/pin-freshness.tsv`](../config/pin-freshness.tsv) is what it reads. One
row per `manual-bump` source says which repository to ask, and which
`key="value"` assignment in which installer states the pin — read out of the
installer rather than repeated in the manifest, so a bump cannot leave the
report comparing against the previous release.

`./scripts/lint.sh` runs `scripts/validate-pin-freshness.py`, which holds the
two manifests to each other: every `manual-bump` source has exactly one
freshness row and nothing else does, each probe row names an installer that
really states its pin once, and a `requested` value that states the pin as a
literal must equal what that installer actually pins. So a pinned artifact
cannot be added without saying how a newer release of it would be noticed.

Some pins cannot be asked this way, and that is a row rather than an omission.
A `none` probe must carry its reason, and the report prints that reason, so a
source outside the mechanism stays visible in the output instead of quietly
absent from it. A probed row may carry a note too, and the report prints those
beside the table: a note there is usually the reason a row will keep reporting
`BEHIND`, as `netcoredbg-legacy-release` does now that upstream has stopped
publishing the macOS build this repository consumes. Printing it is what stops
a standing, explained difference reading as an unexamined one every month. Three are unprobed today: the OCaml compiler version, which is
resolved through opam rather than named by a git ref; the Neovim plugin set,
which has lazy.nvim's own checker; and the Fedora validation image, whose
current digest needs a registry token exchange against two further hosts.

Adopting whatever the report turns up stays a reviewed act, and is the same
work it always was: take the artifact, take its digest, edit the version and
the digest together, rerun the installer — which reinstalls precisely because
the recorded digest no longer matches the pinned one — and rerun the verifier.
Reviewing the new release is the whole reason the pin exists.

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

The same library carries one operation that is not a transfer:
`fetch_host_reachable`, the reachability probe a platform preflight runs before
it changes anything, once per host the resolved plan downloads from. It asks for headers only and discards them, is never
retried, and counts any HTTP answer as reachable, because only a failure to
resolve, to connect, to establish a verified TLS session, or to finish within
its own ceiling proves the network path unusable. It keeps the HTTPS and TLS
floor above, but is bounded separately and far more tightly
(`DOTFILES_FETCH_PROBE_TIMEOUT`, `DOTFILES_FETCH_PROBE_MAX_TIME`), so an offline
machine is refused in seconds rather than after a download budget. Which run
probes which host, and what the refusal means, is in
[troubleshooting](troubleshooting.md#the-installer-refuses-to-start).

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

The bootstrap runs once: a rerun sees `terra-release` installed and stops
there. What governs every later Terra package is the repository file
`terra-release` drops and the key left in the RPM keyring, so
`platforms/fedora/scripts/verify.sh` re-checks both on every run, read-only
and without `sudo`. It fails when DNF's effective `gpgcheck` for the `terra`
repository is not `1`, and when the fingerprint pinned for the running Fedora
release is missing from the RPM keyring. When the running release has no
pinned row it warns instead, mirroring the installer.

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

Creating that directory and clearing tool declarations out of it is install-time
work, done once by `mise_prepare_context`. `run_mise` itself only reads: if the
context is missing, or has acquired one of the four filenames mise reads as
directory configuration, it refuses and says so instead of rebuilding. That
split is what lets a verifier use the same entry point, because
[verification is read-only](workflows/verification.md) and an inspection that
rebuilt the context would delete exactly the contamination it exists to report
and then pass. Every verifier that reaches mise therefore reports the context's
state as its own check, and the remedy for either diagnostic is to re-run the
platform installer.

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
   the four lines above it.
3. Run `./scripts/render-supply-chain.py` to refresh the generated inventory.

`./scripts/lint.sh` runs `scripts/validate-network-sources.py`, which fails on
an unregistered `curl`, `wget`, PowerShell download, remote `git clone`/`fetch`,
`--repofrompath`, remote release RPM, or container image, and on the two
constructs that give the machine a new package trust root, a DNF repository
added with `dnf config-manager addrepo` and a signing key imported with
`rpm --import`, however their argument is spelled. It also fails on a registry
row whose tier and integrity mechanism contradict each other, and on one whose
`integrity` is `image-digest-pinned` while a consumer names some other
reference — a digest the job does not pull is a claim about a run that never
happens.

A construct counts however it is written. A clone spelled as an argument
vector — `vim.fn.system({ "git", "clone", … })`, which is how the Neovim
bootstrap spawns it — is the same clone as a command line. A container image
written as Docker Hub shorthand, `parrotsec/core:latest`, pulls the same code
as `docker.io/parrotsec/core:latest`; shorthand counts when the line puts it in
a container context (a `docker`/`podman` command, a workflow `container:` or
`image:` key, a build `FROM`), because `owner/name:tag` outside one is ordinary
text — a desktop association reads exactly the same.

The scan covers every tracked file outside `tests/` (except
`tests/integration/`) that is shell, PowerShell, YAML, Python, or Lua by any of
four signals: its suffix, a known basename (`Brewfile`), a classification in
[`config/shell-file-roles.tsv`](../config/shell-file-roles.tsv), or a shell or
Python shebang. An extensionless command such as `./doctor`, a stowed
`~/.local/bin` helper, editor configuration, and a package manifest are
therefore all held to the same rule as an installer.

`common/lib/fetch.sh` is scanned like anything else. It performs every
repository-controlled download, so exempting it would exempt the one file a
hardcoded URL would do the most damage in. Its primitives take the URL from
their caller and say so with `# network-source: caller-provided`; the call site
carries the annotation that names the real source.

An annotation covers the host it names, not whatever construct happens to
follow it. When a construct writes a host out in full — on its own line or on a
continuation of it — at least one of the annotations covering it must name a
source served by that host, so a new download dropped under an existing comment
inherits nothing. A URL built from a variable names no host the validator can
check, and is covered by its annotation alone.

A construct that genuinely reaches no external network (a loopback probe, a
request to the container under test) is annotated
`# network-source: local-only`, which is still a deliberate, reviewable act.
That annotation covers loopback hosts only.

## Actions and images CI runs

A workflow downloads and executes code too, and the same position applies to
it. Every third-party `uses:` step is pinned to a full 40-character commit SHA,
with the tag it was in a trailing comment, so a reader can see which release is
running and a bump is a reviewable commit here:

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

A tag is not a pin. `actions/checkout@v7` is whatever its owner last pointed
`v7` at, which is exactly what the tier table refuses to call `exact-commit`
anywhere else. A local action (`uses: ./…`) is this repository's own code and
carries no pin; a container image names provenance through
`config/network-sources.tsv` like any other image.

`scripts/validate-repository-hygiene.py` enforces both halves — a mutable
reference and a bare SHA with no tag comment each fail — and
`tests/test-repository-hygiene.sh` breaks a fixture workflow once per rule.

The images CI runs are pinned the same way, by digest: the Fedora validation
container in `validate.yml` and the Parrot boundary image in
`real-install.yml`. A boundary check that pulls a moving tag proves whatever
upstream published that morning, and a failure could not be told apart from a
regression.

## Authenticating the rate-limited API

Treehouse and No Mistakes resolve their own latest release through
`api.github.com`, and mise asks the same API about its GitHub-backed tools.
Anonymously that is 60 requests per hour *per address*, shared with everyone
else on it. On GitHub's hosted runners that quota is routinely spent by other
tenants, and the installer then fails inside an upstream script with a bare
`403` — an outage that says nothing about this repository:

```
API rate limit exceeded for 13.105.117.77
curl: (56) The requested URL returned error: 403
Failed to determine latest version
ERROR: The Treehouse installer failed.
```

The `macos` job in `.github/workflows/real-install.yml` therefore exports the
workflow's own token (as both `GITHUB_TOKEN` and `GH_TOKEN`) on the two steps
that install the AI profile, which raises the limit to 5000 requests per hour.

Exporting it is not enough on its own: which variable an upstream script reads
is the upstream's choice, and these read neither. An install and a rerun a
minute apart, both with `GITHUB_TOKEN` exported, resolved and then failed —
which an authenticated caller's 5000 per hour cannot do. So `install-ai.sh`
also offers the credential the one way `curl` scopes by host: a `netrc` in the
staged installer's private `CURL_HOME` naming `api.github.com` and nothing
else. Every other host the script contacts is sent no credential.

The boundaries are the reason this is acceptable:

- the token is scoped by `permissions: contents: read`, so it can read this
  repository and do nothing else, and it exists for the life of one CI job;
- it is exported on exactly the two steps that run the staged installers,
  never job-wide;
- offering it through `netrc` widens nothing — a token exported into a step is
  already in the environment of every process that step runs, including these
  scripts; this only makes it usable for the one request it was exported for;
- the file is written `0600` inside the `0700` staging directory and is
  deleted with it when the script returns.

A real workstation install is unaffected. With no token in the environment the
installer prepares nothing at all, so no credential file is ever created on a
user's machine, and a user who hits the anonymous limit is hitting it on their
own address. `tests/test-ai-profile.sh` holds both halves to that: with a token
the staged installer is handed exactly one `netrc` entry, for that host, at
that mode, in a directory that does not outlive the run; without one it is
handed nothing.

## Secrets

No installer stores, requests, or logs a credential, API key, auth token, or
private repository URL, and none is required to install: the one token this
repository uses is the ephemeral CI token described above, which is supplied
by GitHub Actions to its own job. Staged installer content lives in a
mode-0600 file inside a 0700 directory and is deleted immediately after it
runs. Tests use fixtures, never real secrets.
