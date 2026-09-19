# Optional dictation profile

Local voice dictation: press a shortcut, speak, and have the transcription
inserted into whatever application has focus.

Dictation is optional desktop tooling. It is never part of a default
bootstrap, it is opt-in per platform, it appears in a dry run before anything
is installed, and it is safe to run again.

Two rules hold wherever it is installed:

- **Transcription is local.** This repository configures no cloud
  transcription endpoint, account, API key or provider token. Where an
  application offers cloud transcription or AI post-processing, it stays an
  explicit user opt-in made in that application, not a setting shipped here.
- **Nothing dictation-related is committed.** Recorded audio, transcription
  history, downloaded speech models, credentials and application state live in
  the operating system's per-user application data. No installer here writes
  any of it into the checkout, and
  [repository conventions](../architecture/repository-conventions.md#repository-hygiene)
  records that none of it may ever be tracked.

Each platform names its own application, provider, shortcut and state
locations below.

## Fedora

Fedora gets **[Handy](https://github.com/cjpais/Handy)**, driven from Sway.

```bash
./install.sh --dictation
./platforms/fedora/scripts/install-dictation.sh
./platforms/fedora/scripts/install-dictation.sh --dry-run   # show the plan first
./platforms/fedora/scripts/verify-dictation.sh              # re-run verification any time
```

### The shortcut

**Super+O** starts and stops a dictation. **Sway owns that key**, not Handy:

```ini
bindsym $mod+o exec pkill -USR2 -x handy
```

`pkill` delivers SIGUSR2 to the running Handy process; it does not terminate
it. `-x` matches the process name exactly, so the signal cannot land on some
unrelated process whose name merely contains `handy`. The binding is in the
tracked Sway config and is therefore present whether or not the profile is
installed — with Handy not running, nothing matches and the key does nothing.

Handy must be running for the key to mean anything. Start it from Fuzzel, or
add `exec handy --start-hidden` to `~/.config/sway/local.conf` if you want it
every session. That file is machine-local and untracked on purpose: whether a
microphone-adjacent application autostarts is a per-machine decision.

On **KDE Plasma** there is no automated setup. Create the shortcut by hand in
*System Settings → Shortcuts → Custom Shortcuts*, as a Command/URL action
running `handy --toggle-transcription`. Plasma's own global-shortcut service
can register an application shortcut that wlroots cannot, so the CLI flag is
enough there and no signal is needed.

### Why a compositor-owned key rather than Handy's own shortcut

Handy's built-in global shortcut does not work on wlroots compositors, and
that is not a blocker. A Wayland application cannot grab a key it does not
have focus for; the way it is meant to ask is the
`org.freedesktop.portal.GlobalShortcuts` portal, which
`xdg-desktop-portal-wlr` does not yet implement. The upstream bug for this
(cjpais/Handy#1555) is open and the portal work is unmerged, so waiting for it
was never an option.

Handy is built to be driven from outside for exactly this reason. It
documents, for Wayland, that the window manager should keep the binding and
either run `handy --toggle-transcription` or signal the running instance, and
its own documentation gives a Sway config line as the example. This profile
takes the signal route, which needs no second process to start up and reach
the single-instance socket.

Handing the key to Sway is also simply the idiomatic thing on Sway: every
other shortcut on this machine is a `bindsym`, registered in
`config/actions.tsv` and printed on the Sway cheat sheet, and dictation has no
business being the one exception that hides its key inside an application's
settings.

### What is installed, and who owns it

| Component | Owner | Why |
|---|---|---|
| `wtype` | dnf (Fedora package) | Types the transcription into the focused window through the Wayland virtual-keyboard protocol |
| `gtk-layer-shell` | dnf (Fedora package) | Runtime library Handy links against; without it Handy fails to start |
| Handy | pinned upstream release `.rpm`, verified by SHA-256 | Not packaged by Fedora, Terra or Flathub |

`wtype` matters beyond convenience. Handy's other Linux text-insertion
backend, `dotool`, writes to `/dev/uinput` and requires adding your account to
the `input` group — which is a permanent, machine-wide capability to inject
keystrokes into every session. **This profile does not use `dotool` and never
runs `usermod -aG input`.** The `wtype` path needs no device node, no group
and no privileged daemon.

Handy's recording overlay is disabled by default on Linux, which this profile
leaves alone: on several compositors the overlay is treated as the active
window and steals focus, and a focus change is precisely what breaks pasting
back into the window you were dictating into.

### The pinned release artifact

Handy has no Fedora, Terra or Flathub package, so this profile owns one
upstream artifact rather than a repository. `platforms/fedora/scripts/install-dictation.sh`
pins the version, the exact file name, and the SHA-256 of that file, and
refuses to install anything whose digest does not match. The artifact is
registered as `handy-release` in `config/network-sources.tsv` at the
`immutable-verified` tier with `sha256-pinned` integrity — the same treatment
the pinned Hack Nerd Font archive gets.

**The digest is load-bearing, because there is no RPM signature on this
file.** Upstream signs its release artifacts with Tauri's updater format
(minisign), not with an RPM GPG signature, so a locally downloaded `.rpm` is
unsigned as far as dnf is concerned. What replaces the missing signature is
the digest, checked before dnf is invoked at all — a stronger statement than
"some key in this machine's keyring signed it", because it names one exact
artifact rather than one publisher.

**Nothing here relaxes signature checking to make that work.** The installer
passes no flag and sets no option that weakens dnf: no `--nogpgcheck`, no
`gpgcheck` override, no repository is touched. Fedora does not GPG-check a
local package file by default, so a plain `dnf install <file>` is all that is
needed, and the two Fedora packages are installed in an ordinary repository
transaction with signature checking fully intact. If a machine has
deliberately set `localpkg_gpgcheck=1` in its own `dnf.conf`, dnf will refuse
this unsigned artifact — and refusing is the correct answer there. That is a
policy decision the machine's owner made, and this profile does not override
it; install Handy by hand on such a machine, having checked the digest
yourself.

An unset or malformed pin is a hard stop *before* the download, not a warning:
an artifact nothing can check is an artifact this profile will not install.

#### Bumping the pinned Handy release

Pick the release, download exactly the artifact you intend to pin, take its
digest, and record all three values together:

```bash
version=0.9.7
curl -fsSLO "https://github.com/cjpais/Handy/releases/download/v${version}/Handy-${version}-1.x86_64.rpm"
sha256sum "Handy-${version}-1.x86_64.rpm"
```

Then edit `handy_version` and `handy_rpm_sha256` in
`platforms/fedora/scripts/install-dictation.sh`. `handy_rpm` and the URL are
derived from the version and need no edit. Rerun
`./platforms/fedora/scripts/install-dictation.sh`; it reinstalls because the
recorded digest no longer matches the pinned one.

To roll back, restore the previous version and digest and rerun the installer.

### Rerunning

The installer is idempotent. It compares the recorded state against the pin
and skips the download and the dnf transaction entirely when the machine
already has exactly the pinned artifact. Anything else — a different version
recorded, a different digest recorded, no state at all, or a missing `handy`
command — is treated as "not the pinned artifact" and reinstalls.

Ownership is decided from this profile's own recorded state rather than from
an RPM package name, because the package name in a Tauri-built `.rpm` comes
from the upstream product name and is not this repository's to assume.

### Models, state and privacy

Handy is offline by construction: local Whisper and Parakeet models, no cloud
transcription path, no account, no API key. There is nothing to leave
unconfigured because there is nothing to configure.

Everything Handy produces or downloads lives in one directory:

```text
~/.config/com.pais.handy/          # settings, transcription history, state
~/.config/com.pais.handy/models/   # downloaded speech models (hundreds of MB)
```

No model is downloaded at install time; Handy fetches the one you choose the
first time you open it. None of this is inside the checkout, none of it is
tracked, and the verifier fails if any of it ever appears there. Exclude
`~/.config/com.pais.handy/` from backups you would not want holding dictated
text — the history is a plain database of everything you have ever said to it.

The one file this profile writes outside Handy's own directory is
`~/.config/dotfiles/dictation.conf`, the machine-local profile state: which
version and digest are installed, and which text-insertion backend is in use.
It contains no audio, no transcriptions and no credentials.

### Verification

`./platforms/fedora/scripts/verify-dictation.sh` is read-only. It never starts
Handy, opens a microphone, downloads a model or reads a transcription. It
checks that `handy` and `wtype` are present, that the declared Fedora packages
are installed, that `handy` is owned by an rpm and is not shadowed by a
duplicate Flatpak installation, that the recorded state names a
digest-verified artifact and the `wtype` backend, that the Sway config carries
the dictation binding, and that no Handy state has appeared inside the
checkout. `./platforms/fedora/scripts/verify.sh` runs it automatically when
the profile's state file exists, so an unselected profile verifies clean by
being absent.

Verification deliberately proves ownership and wiring rather than
transcription quality: whether a model produces good text is not a property a
script can assert, and the useful question — "is the thing installed, from
where this repository says, and can the key reach it" — is.

### Uninstalling

```bash
sudo dnf remove Handy                      # the pinned rpm
rm ~/.config/dotfiles/dictation.conf       # the profile state
rm -rf ~/.config/com.pais.handy            # settings, history and models
```

`wtype` and `gtk-layer-shell` are ordinary Fedora packages and are left alone;
remove them separately if nothing else wants them. The Sway binding stays in
the tracked config and becomes a no-op again.

### Why Handy and not OpenWhispr

OpenWhispr was the leading candidate and was rejected for Fedora on three
concrete grounds, each of which is about Sway specifically:

- **It wants the `input` group.** Its Linux text-insertion path asks for
  `sudo usermod -aG input $USER`, a permanent machine-wide keystroke-injection
  capability, where Handy's `wtype` path needs nothing of the sort.
- **Its automatic hotkey binding is Hyprland-only.** It configures a
  compositor binding through `hyprctl` and has no equivalent for Sway, so on
  this machine the binding would have to be written by hand anyway — which
  removes the advantage it had over Handy.
- **Its CLI cannot toggle a dictation.** There is no flag and no signal to
  start or stop recording from outside the application, so a
  compositor-owned key has nothing to invoke. Handy's `--toggle-transcription`
  and SIGUSR2 exist precisely for this case.

Handy's known Wayland weakness is its *own* global shortcut, which this
profile does not use and does not need. Trading a broken in-application
shortcut for a working compositor-owned one is a better deal than trading a
working shortcut for an `input`-group requirement.
## macOS

```bash
./install.sh --platform macos --dictation
./platforms/macos/scripts/install-dictation.sh --dry-run   # show the plan first
./platforms/macos/scripts/install-dictation.sh             # install on its own
./platforms/macos/scripts/verify.sh --dictation            # reverify any time
```

macOS installs **[Ghost Pepper](https://github.com/matthartman/ghost-pepper)**,
an MIT-licensed, macOS-only menu-bar application (macOS 14.0+, Apple Silicon).
Hold a key, speak, release, and the transcription is pasted into the focused
application. Transcription runs locally through WhisperKit, and the optional
text cleanup runs against a local model. It talks to no transcription service
and needs no credentials.

### Why Ghost Pepper here, and what it cost

Ghost Pepper was chosen for macOS over the cross-platform alternative because
it is the better macOS application: entirely on-device, hold-to-talk rather
than a toggle, and native to this platform rather than a port to it.

**The alternative that was available and not taken.** Handy has an official
Homebrew cask and runs on macOS, Linux and Windows. Selecting it everywhere
would have meant one tool on all three platforms, one mental model, and — on
macOS specifically — a `brew install --cask` line in
`platforms/macos/Brewfile` instead of everything described below. That is a
real cost paid deliberately: this profile is not the same application on every
platform, and macOS carries an installation mechanism it would not otherwise
need.

**What that mechanism costs.** There is no Homebrew cask for Ghost Pepper, so
it cannot be declared in the Brewfile with every other macOS application. The
only alternatives were an unpinned "download whatever is current" path, which
this repository's supply-chain rules forbid, or the pinned-artifact mechanism
it already uses for the Hack Nerd Font: an exact release URL plus a SHA-256.
The pinned route was taken, and it costs two things:

- **A manual version bump.** The pinned tag and digest live in
  `platforms/macos/lib/dictation.sh`, and the registry row
  `ghost-pepper-release` in `config/network-sources.tsv` records the cadence as
  `manual-bump`. Nothing updates them automatically; a new upstream release is
  adopted by editing those constants, and the verifier fails until the
  installed build matches the pin again.
- **A checksum this repository computes.** Upstream publishes no checksum file
  alongside its releases, so the recorded SHA-256 was computed here from the
  downloaded asset rather than copied from upstream. It pins exactly the bytes
  that were reviewed; it is not independent attestation by the author.

### This does not weaken Gatekeeper or SIP

This repository keeps System Integrity Protection and Gatekeeper enabled, on
the same grounds as [the AeroSpace-over-yabai
decision](../platforms/macos.md#5-aerospace-decision-record), and installing an
application from a downloaded disk image would normally be exactly where that
position gets quietly traded away.

It is not traded away here. Ghost Pepper is signed with an Apple Developer ID
and has been Apple-notarized since v2.0.0, so Gatekeeper accepts it as it
ships. The installer therefore never removes a quarantine attribute, never
runs `spctl --master-disable` or `csrutil disable`, and never strips or
re-signs anything; the application is copied with `ditto`, which preserves the
signature, and left for Gatekeeper to assess on its first launch. The
verifier asserts all of this rather than assuming it: that the signature
verifies, that it is the pinned Developer ID team, and that `spctl --assess`
accepts the bundle — which for a Developer ID application is what proves the
notarization ticket is good.

Had Ghost Pepper not been notarized, this profile would have required an
exception to that position and would not have been added.

### Package ownership

```text
GhostPepper.app     # /Applications, installed from the pinned release DMG
```

One provider, named in `config/capabilities.tsv` as `upstream-dmg`. The
verifier fails if a Homebrew cask ever supplies a second copy, so a future
cask is adopted deliberately rather than ending up installed twice.

| | |
|---|---|
| Upstream | [matthartman/ghost-pepper](https://github.com/matthartman/ghost-pepper) |
| Licence | MIT |
| Pinned as | `ghost-pepper-release` in `config/network-sources.tsv` |
| Pin lives in | `platforms/macos/lib/dictation.sh` |
| Installed to | `/Applications/GhostPepper.app` |
| Bundle identifier | `com.github.matthartman.ghostpepper` |
| Machine state | `~/.config/dotfiles/macos-dictation.conf` |

Rerunning the installer is a no-op once the pinned version is installed:
nothing is downloaded, nothing is mounted, and the state file is rewritten
byte-identically. A version other than the pinned one is replaced.

### First-run permissions

Open the application once, then grant two permissions. Both prompts are
interactive by design: the installer prints these steps and stops, and nothing
here scripts, pre-approves or bypasses a macOS privacy prompt.

1. **Open Ghost Pepper once** from `/Applications`. It is a menu-bar
   application, so it has no Dock window. Gatekeeper checks the signature and
   notarization on this first launch.
2. **Microphone** — approve the prompt on the first recording, or grant it in
   System Settings → Privacy & Security → Microphone.
3. **Accessibility** — System Settings → Privacy & Security → Accessibility,
   then enable Ghost Pepper. This is what lets the application see the global
   hold-to-talk hotkey and simulate the paste keystroke into the focused
   application. Without it the hotkey does nothing at all, which is the single
   most common reason dictation appears to be broken.

Screen Recording is **not** required for dictation and is not requested by
this profile. Ghost Pepper asks for it only for its optional on-screen context
features; leave it off unless you specifically want those.

### The shortcut

The hold-to-talk shortcut is chosen in Ghost Pepper's own settings rather than
written by this repository, because it is the kind of per-machine preference
the application already owns and stores itself.

Two constraints when choosing it:

- Avoid the `Ctrl+Option` combinations
  [AeroSpace owns](../platforms/macos.md#6-aerospace-permissions-and-keyboard-model)
  for workspace and window control.
- Leave Right Option alone. This repository deliberately keeps Right Option as
  a macOS modifier for symbol entry (Left Option is what Ghostty sends as Alt);
  binding dictation to it would take that back.

### Where state and models live

Everything Ghost Pepper writes stays under `~/Library`, outside this
repository:

| What | Where |
|---|---|
| Application support, transcription history, local index | `~/Library/Application Support/` and `~/Library/Containers/` under the bundle identifier |
| Downloaded speech and cleanup models | the application's own support directory, on first use |
| Preferences, including the chosen shortcut | `~/Library/Preferences/com.github.matthartman.ghostpepper.plist` |
| What this repository recorded | `~/.config/dotfiles/macos-dictation.conf` |

Only the last of those is written by this profile, and it holds the pinned
version, digest, bundle identifier and signing team — nothing about what was
said. Recorded audio, transcription history, models and any credential the
application may later be given are outside the checkout by construction, so
there is nothing for a commit to pick up.

Models are downloaded by the application on first use, not by the installer:
they are large, they are the user's choice, and they are not pinned here.

### Upstream updates

Ghost Pepper bundles the Sparkle updater and can update itself in place. If it
does, the installed build stops matching the pin and
`./platforms/macos/scripts/verify.sh --dictation` says so by name. That is the
intended behaviour — it is how a drift from the reviewed artifact becomes
visible. Resolve it either by bumping the pin in
`platforms/macos/lib/dictation.sh` to the release now installed, or by
rerunning the installer to put the pinned build back.

### Verification

`./platforms/macos/scripts/verify.sh --dictation`, which the installer also
runs at the end of a `--dictation` install, checks that:

- the application is installed at the declared path and reports the pinned
  version;
- its executable is arm64 or universal;
- no Homebrew cask supplies a competing copy;
- its code signature verifies and names the pinned Developer ID team;
- Gatekeeper assesses the bundle as acceptable;
- the recorded machine state names the pinned version.

Microphone and Accessibility consent is reported as **not observed**, not as a
pass or a failure. macOS keeps those grants in a SIP-protected TCC database
that no ordinary process may read, so there is no safe observable check and
this verifier does not invent one.

A machine that never selected the profile passes with "not installed"; a
machine with the application or the state file present but the profile
unselected fails, because that is an unowned copy.

### Removal

```bash
rm -rf /Applications/GhostPepper.app
rm ~/.config/dotfiles/macos-dictation.conf
```

That removes the application and this repository's record of it. Ghost
Pepper's own data — history, models, preferences — is left alone deliberately;
delete its directories under `~/Library` yourself if you want it gone too.
## Windows

Windows uses [Handy](https://handy.computer), installed per-user with Scoop
from Scoop's official `extras` bucket.

Handy is offline by construction: it transcribes with local Whisper or
Parakeet V3 models, has no cloud transcription path and needs no account.

### Install

Dictation is opt-in, so the Windows bootstrap installs it only when asked:

```powershell
# Preview first; nothing is installed or written.
.\platforms\windows\install.ps1 -Handy -DryRun

# Install Fedora WSL, Noctty and Handy.
.\platforms\windows\install.ps1 -Handy
```

Without `-Handy`, nothing dictation-related is installed, the `extras` bucket
is not added, and verification stays clean.

The script runs as a normal, non-administrator user. It adds the official
`extras` bucket if it is missing and installs `extras/handy` into the same
per-user Scoop root as Noctty; nothing is installed machine-wide and nothing
is elevated. Rerunning is a no-op once Handy is present.

### Package ownership

| What | Value |
|---|---|
| Provider | Scoop, per-user |
| Bucket | `extras` (`https://github.com/ScoopInstaller/Extras`) |
| Package | `extras/handy` |
| Executable | `handy.exe`, resolved through Scoop's shims |
| Declared in | `platforms/windows/manifest.psd1` (`Scoop.ExtrasBucket`, `Scoop.HandyPackage`) |
| Provenance | `scoop-extras-bucket` in [`config/network-sources.tsv`](../supply-chain-sources.md) |

Scoop's `extras` manifest for Handy pins the upstream release installer by
SHA-256 for both `x64` and `arm64`, so an update is a reviewed manifest bump
upstream rather than an unpinned "download the latest" step. Update it the
same way as everything else Scoop owns:

```powershell
scoop update handy
```

### Why Scoop and not WinGet — a decision record

Issue #282 assumed Handy was only distributed through WinGet
(`winget install cjpais.Handy`) and therefore asked for two changes: allow
WinGet for native Windows desktop applications, and narrow the existing
regression test that rejects `winget install` in the Windows installer so it
only protected Noctty's Scoop ownership.

That was investigated and turned out to be unnecessary. `handy` is in Scoop's
official `extras` bucket, hash-pinned, for both `x64` and `arm64`. Installing
it there means:

- the Windows bootstrap keeps exactly one package manager, so there is no
  second update path and no way to end up with two copies of an application;
- ownership stays per-user and non-administrator, like the rest of the Scoop
  path;
- verification proves Handy the same way it proves Noctty, through the same
  bucket, package, shim and current-executable checks.

So the package-manager boundary was not widened and the guard was not
narrowed. `tests/test-windows-bootstrap.sh` still rejects `winget install`
anywhere in `platforms/windows/install.ps1`, as a global prohibition, and
`tests/test-windows-verifier.ps1` rejects any mention of WinGet in the
verifier. If a future Windows application genuinely has no Scoop manifest,
that is the point at which the boundary should be reopened deliberately — not
before.

### Shortcut

Handy owns its own global shortcut, configured in its settings window. This
repository does not write Handy's configuration, so the binding is a first-run
choice rather than a tracked file.

`Ctrl+Alt+Space` is the recommended binding here: it does not collide with
Windows' own `Win+H` voice typing, with the `Ctrl+Shift+...` bindings Noctty
uses — including `Ctrl+Shift+,` for reloading the terminal configuration — or
with normal text entry. Hold it to dictate and release to transcribe, or
switch Handy to toggle mode in its settings.

### First run

1. Launch Handy once from the Start menu; Scoop registers the shortcut.
2. Allow microphone access when Windows asks. The installer never suppresses
   or pre-answers that prompt.
3. Choose a model in Handy's settings and let it download. Parakeet V3 is the
   CPU-friendly default; the Whisper models are larger and use the GPU when
   one is available.
4. Set the global shortcut.

### Where state lives

Nothing below is in this repository, and nothing below may be copied into it:

| What | Where |
|---|---|
| Application | `%USERPROFILE%\scoop\apps\handy\current` |
| Shim on `PATH` | `%USERPROFILE%\scoop\shims\handy.exe` |
| Settings, transcript history, downloaded models | `%APPDATA%\com.pais.handy` (models under its `models` subdirectory) |
| Logs | `%LOCALAPPDATA%\com.pais.handy\logs` |

Back those up — or deliberately exclude them — as application data. The
downloaded models are large and re-downloadable, and the transcript history is
a record of everything dictated, so it deserves the same treatment as any
other sensitive local store.

### Verify

```powershell
.\verify.ps1
```

When Handy was selected, verification requires the `extras` bucket, the
`handy` package, a `handy` command resolving through Scoop's shims, and a
current executable inside Scoop's `apps` directory. When it was not selected,
their absence passes. Verification never launches Handy, records audio or
reads its transcript history.

### Uninstall

```powershell
scoop uninstall handy

# Optional: drop the bucket if nothing else uses it.
scoop bucket rm extras

# Optional: remove settings, history and downloaded models.
Remove-Item -Recurse -Force "$env:APPDATA\com.pais.handy"
```

Rerun `.\platforms\windows\install.ps1` without `-Handy` afterwards so the
recorded Windows selection no longer claims dictation is installed.
