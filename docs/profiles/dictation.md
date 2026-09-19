# Optional dictation profile

Local, offline voice dictation: press a key, speak, and have the transcription
typed into whatever application has focus. It is an optional desktop profile,
not part of the default installation, it appears in `--dry-run`, and it can be
installed and reverified on its own.

The application differs per platform, because no single tool is the right
answer on all three. What stays the same everywhere is the promise: the
transcription happens **on this machine**, no account or API key is configured
by this repository, and nothing the profile produces — recorded audio,
transcription history, downloaded speech models, provider tokens or
application state — is ever written into this checkout or committed.

Each platform's section below states which application it installs, who owns
the installation, how it is verified, and how to remove it.

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
