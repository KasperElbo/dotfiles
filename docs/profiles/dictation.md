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
