# Windows host checklist

For a physical Windows machine hosting Fedora on WSL, set up as
[the Windows host guide](../../platforms/windows.md) describes. Two automated
jobs already cover parts of this platform, and this checklist does not repeat
them: the hosted `windows-boundary` job runs the bootstrap and verifier test
suites against temporary state, with WSL itself replaced where a suite needs
it, and the self-hosted `fedora-wsl-real` job installs Fedora WSL
from a clean imported export. Neither one runs `install.ps1` for real, opens
Noctty, crosses the clipboard or a browser, or hears a microphone.

How to turn this into a record, what the four outcomes mean and what must stay
out of the record are in [the README](README.md). The record's **Commit** is
`git rev-parse HEAD` in the Windows checkout the bootstrap ran from; the
Fedora-side checkout used in WIN-03 must be at the same commit.

## Items

### WIN-01 Bootstrap for real

- **Boundary:** the PowerShell bootstrap on a real Windows installation:
  elevation for the WSL phase, the Store or web catalogue, Scoop, and a
  pending restart.
- **Applies when:** always.
- **Do:** from a normal, non-administrator PowerShell session in the
  checkout:

  ```powershell
  Set-ExecutionPolicy -Scope Process Bypass
  .\platforms\windows\install.ps1 -DryRun
  .\platforms\windows\install.ps1 -Handy
  ```

  Leave out `-Handy` if this machine does not select it, and record the exact
  command in the record's **Installer command** field.
- **Pass when:** the dry run installs and writes nothing, the install asks for
  administrator approval only for the WSL phase, and it exits `0`. An exit `2`
  that names a pending Windows restart also passes if, after the restart, the
  same command exits `0`; say so in the notes.

### WIN-02 Windows verifier

- **Boundary:** Scoop ownership, the copied Noctty configuration and the WSL
  version on the real host.
- **Applies when:** always.
- **Do:** `.\verify.ps1`
- **Pass when:** it reports no `[FAIL]` line and exits `0`.

### WIN-03 Fedora install inside the distribution the bootstrap chose

- **Boundary:** the Fedora distribution `install.ps1` resolved and installed,
  rather than the golden export the self-hosted job imports.
- **Applies when:** always.
- **Do:** complete Fedora's first-run user setup, clone this repository inside
  Fedora at the tested commit, and run:

  ```bash
  ./install.sh --platform fedora-wsl
  ./platforms/fedora-wsl/scripts/verify.sh
  ./doctor
  ```

- **Pass when:** the install exits `0`, the verifier reports no failure, and
  `./doctor` reports `Checkout matches installed revision` with the tested
  commit.

### WIN-04 Noctty draws the Fedora shell

- **Boundary:** the terminal on the Windows side starting the WSL
  distribution, which no runner opens.
- **Applies when:** Noctty is installed (`-SkipNoctty` was not passed).
- **Do:** start Noctty from the Start menu, after closing every Fedora window
  and running `wsl --shutdown` so it starts the distribution itself.
- **Pass when:** Noctty opens straight into the recorded Fedora distribution at
  a Zsh prompt, with the Starship prompt and the selected Catppuccin flavour.

### WIN-05 The theme crosses the WSL boundary

- **Boundary:** the Fedora WSL theme hook updating Noctty's managed
  configuration through Windows PowerShell.
- **Applies when:** Noctty is installed and its configuration is managed
  (`-SkipNocttyConfiguration` was not passed).
- **Do:** in Noctty, run `theme latte`, then put the machine's usual flavour
  back with another `theme` run.
- **Pass when:** each `theme` run exits `0` and Noctty shows the new colours,
  after `Ctrl+Shift+,` if they did not change by themselves.

### WIN-06 Clipboard and browser interop

- **Boundary:** the explicit Windows executables the interop policy keeps
  working while Windows directories stay off `PATH`.
- **Applies when:** always.
- **Do:** in Fedora:

  ```bash
  printf 'clipboard-check' | wsl-copy
  wsl-paste
  wsl-open https://github.com
  ```

  and paste into Notepad.
- **Pass when:** `wsl-paste` prints `clipboard-check`, Notepad receives the
  same text, and the URL opens in the Windows default browser.

### WIN-07 Handy dictation and microphone approval

- **Boundary:** the Windows microphone prompt, which the installer never
  suppresses or pre-answers, and a real microphone.
- **Applies when:** `-Handy` is selected.
- **Do:** follow Handy's
  [first run](../../profiles/dictation.md#first-run) on Windows: launch it from
  the Start menu, allow microphone access when Windows asks, choose a model,
  and set the shortcut (`Ctrl+Alt+Space` is the recommended one). Dictate one
  sentence into Notepad and one into a Noctty prompt.
- **Pass when:** Windows asked for microphone access and the grant was made,
  and each sentence appears in the focused window. Do not record the sentences
  themselves.

## When this checklist must be redone

Besides the Windows feature-update and six-month triggers in
[the README](README.md#when-a-record-must-be-redone), any merged change to
these paths makes a record for this checklist stale:

- `platforms/windows/install.ps1`, `platforms/windows/verify.ps1`,
  `platforms/windows/manifest.psd1`, `platforms/windows/set-noctty-theme.ps1`
  and `platforms/windows/lib/`
- `platforms/fedora-wsl/stow/interop/` and
  `platforms/fedora-wsl/stow/theme-hooks/`
- the `windows` rows in `config/capabilities.tsv`

## Results table

Copy this into the record's **Results** section.

| ID | Outcome | Notes |
|---|---|---|
| WIN-01 | | |
| WIN-02 | | |
| WIN-03 | | |
| WIN-04 | | |
| WIN-05 | | |
| WIN-06 | | |
| WIN-07 | | |
