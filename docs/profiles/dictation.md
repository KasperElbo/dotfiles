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
