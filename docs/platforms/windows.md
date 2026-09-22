# Windows host

Windows is a platform of this repository, but not a workstation it builds. It
is the *host* of the [Fedora on WSL](fedora-wsl.md) variant: it owns WSL 2 and
the Fedora distribution that runs on it, the terminal that draws the Fedora
shell, and the one optional desktop application that is Windows-side by nature.
Everything else — the shell, the editor, the multiplexer and every development
command — belongs to Fedora and is installed from inside it.

That boundary is why this platform looks different from the other four. It has
no `install.sh` of its own, so `--platform windows` is not a thing to run and
is deliberately rejected; its installer is PowerShell. It deploys no Stow
tree, because Noctty is configured by files copied into
`%LOCALAPPDATA%`, not by symlinks into this checkout. Its three capabilities are
recorded in `config/capabilities.tsv` like every other platform's, and they are
proved by `platforms/windows/verify.ps1`.

- Installer: `platforms\windows\install.ps1`
- Verifier: `platforms\windows\verify.ps1`, also reachable as `.\verify.ps1`
- Capabilities: `base`, `terminal`, `dictation` — see the
  [capability matrix](../reference/capability-matrix.md) and the
  [verifier reference](../reference/verifiers.md)
- Package manager: Scoop, per-user
- Selection record: `%LOCALAPPDATA%\dotfiles\windows-selection.json`

## Install

From a **normal, non-administrator** PowerShell session in this checkout:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\platforms\windows\install.ps1 -DryRun
.\platforms\windows\install.ps1
```

The script refuses to run from an elevated session. It elevates the WSL phase
itself, through a separate `Start-Process -Verb RunAs` window whose transcript
is read back and printed here, so a failure inside it is reported rather than
left as an exit code. Scoop, Noctty and Handy stay per-user and are never
installed with administrator rights.

Its options:

| Option | What it does |
|---|---|
| `-FedoraDistribution NAME` | Use an exact name from `wsl --list --online` instead of discovering the newest `FedoraLinux` entry. A name that is neither installed nor in Microsoft's catalogues is refused straight away, before any administrator prompt or WSL update. |
| `-SkipNoctty` | Install and validate Fedora WSL without installing or configuring Noctty. |
| `-SkipNocttyConfiguration` | Install Noctty but write none of its configuration. |
| `-Handy` | Also install the optional Handy voice-dictation application. |
| `-DryRun` | Print the planned changes; install nothing and write no configuration. |

## `base` — WSL 2 and the Fedora distribution

The baseline this platform owns is a Fedora distribution running on WSL 2. The
script:

1. Reports the installed WSL package version against the
   `MinimumProvenWslVersion` recorded in `platforms\windows\manifest.psd1`
   (2.7.13). An older or unreadable version is a warning with the command to
   fix it, not a refusal.
2. Resolves which Fedora to install: the newest `FedoraLinux` entry
   `wsl --list --online` advertises, falling back to Microsoft's published
   distribution catalogue when the Store catalogue advertises none. If neither
   knows about Fedora, it asks for elevation to run `wsl --update` and looks
   again.
3. Asks for elevation once more to make WSL 2 the default version and install
   the distribution with `--no-launch`, or to convert an existing WSL 1
   installation to WSL 2. A distribution absent from the Store catalogue is
   installed with `--web-download`.
4. Records the resolved selection in
   `%LOCALAPPDATA%\dotfiles\windows-selection.json`, written to a temporary
   file and moved into place.

`wsl --update` checks `api.github.com` for the current version before doing
anything else, which commonly fails on a restricted network. A failure of that
check during the installation phase is treated as non-fatal and reported as a
warning: an already-installed WSL platform can still install the distribution.

The run ends by re-reading the installed distribution list. If Fedora is not
yet present on WSL 2 — the usual reason is a pending Windows restart — the
script exits **2** with the command to run afterwards, and writes no selection
record. Otherwise it prints the two remaining manual steps: complete Fedora's
first-run user setup, then clone this repository inside Fedora and run
`./install.sh --platform fedora-wsl`.

## Terminal

The terminal capability is **Noctty**, installed for the current user from its
own Scoop bucket (`noctty/noctty`), which the script adds if it is not already
present. If Scoop itself is missing, the official installer from
`https://get.scoop.sh` is downloaded to a temporary file, run, and deleted.
Nothing is installed twice: an existing `noctty` command, or a current
executable under `~\scoop\apps\`, is left alone.

Its configuration is a marked block at the top of
`%LOCALAPPDATA%\noctty\config.ghostty`, between
`# BEGIN dotfiles Fedora WSL` and `# END dotfiles Fedora WSL`. The block
includes two files and sets the command that starts the selected distribution;
anything you write below the block is preserved, and a `command =` of your own
anywhere outside the block wins — the script then omits its own and says so.

Alongside it, into `%LOCALAPPDATA%\noctty\`, the script copies:

| Copy | From this checkout |
|---|---|
| `dotfiles\ghostty.conf` | `ghostty\.config\ghostty\shared.conf` |
| `dotfiles\set-theme.ps1` | `platforms\windows\set-noctty-theme.ps1` |
| `themes\*.conf` | every tracked theme in `ghostty\.config\ghostty\themes` |
| `dotfiles\theme.conf` | created once, from the `theme =` line of the shared config |

They are copies, compared by SHA-256 and rewritten only when they differ, which
is what makes a rerun cheap and what makes Noctty independent of where this
checkout lives. It also means a checkout that has moved on is not picked up
until you rerun the script. `dotfiles\theme.conf` is written once and then left
alone: it is the selected flavour, and it is what the theme helper rewrites.

## Dictation

`-Handy` installs [Handy](../profiles/dictation.md#windows), an offline
voice-dictation application, from Scoop's official `extras` bucket
(`extras/handy`). It is opt-in and changes nothing about the WSL or terminal
bootstrap: it is desktop tooling, never a prerequisite, and it goes through
exactly the same per-user Scoop path as Noctty rather than adding a second
package manager. The profile guide has the shortcut, the first-run steps, and
where models and transcripts are kept.

## Verify

```powershell
.\verify.ps1
```

`.\verify.ps1` at the repository root forwards to
`platforms\windows\verify.ps1`, passing through `-StatePath` when you give one.
The verifier is read-only: it never installs, updates, authenticates, creates
configuration, launches a WSL distribution, or starts the dictation
application. It reports `[PASS]`/`[FAIL]` lines and warnings, ends with a
counted summary, and exits 1 when anything failed.

What it checks, in order:

- **Selection state.** That
  `%LOCALAPPDATA%\dotfiles\windows-selection.json` exists, parses, and carries
  the schema version the manifest declares.
- **Scoop ownership.** Only for what the selection says was selected: Scoop
  resolves through its own shims, and each selected package's bucket exists,
  its package exists, its command resolves through the Scoop shims and its
  current executable lives under Scoop's `apps` directory. With nothing
  Scoop-owned selected, the absence of Scoop is a pass rather than a failure.
- **Managed configuration.** Every copy listed above exists, is not a broken
  link, does not point at another checkout, and still matches this checkout by
  hash; and the marked block in `config.ghostty` contains both `config-file`
  includes and either the expected `command =` or the note that a user-managed
  command replaced it.
- **The WSL boundary.** `wsl.exe` exists, the installed WSL version satisfies
  the proven baseline, and the recorded distribution is present and on WSL 2.

Verification of everything *inside* Fedora is the Fedora WSL verifier's job;
see [Fedora on WSL](fedora-wsl.md#validation).

## What this platform deliberately does not have

- **No `--platform windows`.** The portable installer runs
  `platforms/<name>/install.sh`; this platform has none, so `./install.sh`
  rejects the name and lists only the platforms it can actually run.
- **No `./doctor` path, deliberately.** `./doctor` reports the lifecycle of an
  `./install.sh` run, which this platform does not have; `.\verify.ps1` is its
  read-only equivalent. See
  [troubleshooting](../troubleshooting.md#doctor-is-a-linux-and-macos-command).
- **No Stow packages.** Noctty's configuration is copied, not linked, so the
  `stow` column of every `windows` row is `-` — the manifest's marker for
  none — and there is no Stow script under `platforms/windows/` to compare it
  against.
- **No installer options to remember.** `config/install-options.tsv` is the
  contract of the Bash installers' argv parsers; the PowerShell switches above
  are recorded in this platform's own selection state instead, which is what
  the verifier reads.
