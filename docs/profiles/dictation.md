# Optional voice dictation profile

An optional, per-platform speech-to-text profile: press one key, speak, and
have the transcription typed into whatever window has focus. It is never part
of a default install, it always appears in `--dry-run`, and it is safe to
rerun.

Two rules hold on every platform, and the rest of this page is platform
detail:

- **Transcription is local.** The baseline is an offline model running on the
  machine. No profile here configures an account, an API key, a provider token
  or a cloud endpoint; if an application offers cloud transcription or AI
  post-processing, turning it on stays your decision, made in the application.
- **Nothing dictation produces is ever committed.** Recorded audio,
  transcription history, downloaded speech models, and application settings
  and state all live in the application's own directory under your home
  directory, outside this checkout. The installers write exactly one file, the
  machine-local profile state in `~/.config/dotfiles/`, which is also outside
  the checkout.

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
