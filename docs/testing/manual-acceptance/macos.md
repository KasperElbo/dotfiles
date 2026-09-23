# Apple Silicon macOS checklist

For a physical Apple Silicon Mac, set up as the
[macOS guide](../../platforms/macos.md) describes. The hosted `macos-26` job
installs the same code on real Apple Silicon, but that runner is a virtual
machine with no one at the keyboard: it cannot grant a privacy permission,
sign in to anything, attach a second display, hear a microphone or start a
Podman machine, and it cannot observe System Integrity Protection. Everything
below is what that runner cannot show.

How to turn this into a record, what the four outcomes mean and what must stay
out of the record are in [the README](README.md).

## Before you start

- Finish Software Update, and record the macOS version from
  **About This Mac**.
- The Mac must be physical. A Podman machine needs the hardware
  virtualisation a virtual Mac does not pass through, which is why the hosted
  runner cannot start one.
- Have an external display to hand, and use the built-in microphone or
  another one. An item that needs one you do not have is `not observed`.

## Items

### MAC-01 Install at the tested commit on hardware

- **Boundary:** the full install, including the optional profiles no CI job
  selects together, on the machine itself.
- **Applies when:** always.
- **Do:** install with every option this machine uses:

  ```bash
  ./install.sh --platform macos --dry-run --containers --tailscale --dictation
  ./install.sh --platform macos --containers --tailscale --dictation
  ./doctor
  ```

  Leave out the options this machine does not select, and record the exact
  command line in the record's **Installer command** field.
- **Pass when:** the install exits `0`, and `./doctor` reports
  `Checkout matches installed revision` with the tested commit.

### MAC-02 System Integrity Protection and Gatekeeper on real hardware

- **Boundary:** SIP, which the hosted runner can only report as
  `NOT OBSERVED`.
- **Applies when:** always.
- **Do:**

  ```bash
  ./platforms/macos/scripts/verify.sh --defaults --containers --tailscale --dictation
  ```

  with the flags matching this machine's selection.
- **Pass when:** the verifier reports
  `System Integrity Protection is enabled` and `Gatekeeper is enabled`, and no
  failure. The Ghost Pepper consent line is expected to be `NOT OBSERVED`;
  MAC-08 covers it.

### MAC-03 AeroSpace Accessibility approval

- **Boundary:** the Accessibility grant AeroSpace needs, which only a person
  can make and which macOS keeps where no process may read it.
- **Applies when:** always.
- **Do:** if AeroSpace already has the permission from an earlier install,
  remove it from **System Settings → Privacy & Security → Accessibility**
  first, so the grant itself is exercised. Run the verifier, then grant
  Accessibility to AeroSpace, and run it again. Log out and back in.
- **Pass when:** before the grant the verifier warns
  `AeroSpace CLI cannot reach the window manager; open it and grant Accessibility access`;
  after it, it reports `AeroSpace is running and Accessibility control works`,
  `AeroSpace configuration passes native validation without warnings` and
  `AeroSpace loaded the tracked XDG configuration`. AeroSpace is running again
  after the new login, and neither Full Disk Access nor Screen Recording was
  asked for.

### MAC-04 Keyboard workflow

- **Boundary:** keys reaching AeroSpace and Ghostty from a real keyboard with
  a Danish layout.
- **Applies when:** always.
- **Do:** try each AeroSpace binding in
  [the keyboard reference](../../reference/keybindings.md#aerospace):
  `Control+Option+Enter`, `Control+Option+1..9`, `Control+Option+H/J/K/L`,
  `Ctrl+Opt+Cmd+H/J/K/L` from each corner of the grid, `Control+Option+F`, and
  resize mode with `Control+Option+R`. In Ghostty, press Left Option+C at a
  shell prompt, then type a symbol from behind Right Option.
- **Pass when:** every binding does what the reference says, grid movement
  wraps at each edge, Left Option+C opens fzf's directory picker, and Right
  Option still types the symbol the layout puts behind it.

### MAC-05 Multiple displays

- **Boundary:** AeroSpace's workspace-to-display ownership and hiding with a
  real second display, which no runner has.
- **Applies when:** always.
- **Do:** attach the external display and arrange it as the guide's
  [multi-monitor section](../../platforms/macos.md#multi-monitor-and-mission-control)
  says, then use `Control+Option+Tab`, `Ctrl+Opt+Shift+Tab` and
  `Ctrl+Opt+Cmd+Tab`. Detach the display and reattach it.
- **Pass when:** focus, a window and a whole workspace each move to the next
  display, no hidden window shows at the edge of another display, and after
  detaching every window is reachable from a workspace on the remaining one.

### MAC-06 Desktop wallpaper

- **Boundary:** the wallpaper hook's Apple Events call, and the Automation
  permission it needs.
- **Applies when:** always. The hook is part of the baseline `theme` command,
  independent of `--defaults`.
- **Do:** the five steps of the guide's
  [desktop wallpaper](../../platforms/macos.md#desktop-wallpaper) manual
  acceptance check, with the external display attached, approving the
  Automation prompt if the first run asks for it.
- **Pass when:** each step shows what the guide says it should, on every
  display, and every `theme` run exits `0`.

### MAC-07 Lock screen

- **Boundary:** the lock screen showing the current wallpaper.
- **Applies when:** always.
- **Do:** the four steps of the guide's
  [lock screen](../../platforms/macos.md#lock-screen) manual acceptance check.
- **Pass when:** the lock screen shows the Mocha wallpaper, and then the Latte
  one, as the steps describe.

### MAC-08 Dictation and its privacy approvals

- **Boundary:** the Microphone and Accessibility grants Ghost Pepper needs,
  which the verifier deliberately reports as `NOT OBSERVED`, and a real
  microphone.
- **Applies when:** `--dictation` is selected.
- **Do:** if either permission is already granted from an earlier install,
  turn it off in **System Settings → Privacy & Security** first, so the
  approval itself is exercised. Then follow the three
  [first-run permission](../../profiles/dictation.md#first-run-permissions)
  steps in order, choosing a hold-to-talk shortcut that avoids the
  `Ctrl+Option` combinations and Right Option. Hold it and speak one sentence
  into TextEdit, and again into a Ghostty prompt. Run
  `./platforms/macos/scripts/verify.sh --dictation`.
- **Pass when:** both grants could be made, the sentence is pasted into both
  applications, Screen Recording was never needed, and the verifier reports no
  failure. Do not record the sentence itself.

### MAC-09 Tailscale sign-in

- **Boundary:** the Network Extension approval and the interactive login this
  repository never automates.
- **Applies when:** `--tailscale` is selected.
- **Do:** approve the Network Extension prompt the app raised when the
  installer opened it, then run `./platforms/macos/scripts/verify.sh --tailscale`
  before signing in. Sign in from the app, and run the verifier again. Restart
  the Mac and run it once more.
- **Pass when:** the first run reports the app installed and a
  `(installed but not logged in)` state; the second and third report
  `tailscale status: Running (connected to a tailnet)`. Record only those
  verifier lines, never `tailscale status` output.

### MAC-10 Podman machine startup

- **Boundary:** `vfkit` starting the Podman machine on hardware with nested
  virtualisation, which the hosted runner lacks. This is the one macOS
  capability no CI job installs.
- **Applies when:** `--containers` is selected.
- **Do:** run the guide's
  [manual check](../../platforms/macos.md#optional-containers):

  ```bash
  podman machine list
  podman info
  podman run --rm docker.io/library/alpine:latest uname -m
  podman-compose version
  ./platforms/macos/scripts/verify.sh --containers
  ```

  Then restart the Mac, run `./platforms/macos/scripts/install-containers.sh`
  and the verifier again.
- **Pass when:** there is one machine and it is running, `podman info` reports
  `rootless: true`, the container prints `aarch64`, `podman-compose` answers,
  and the verifier reports `Podman machine is reachable`,
  `Podman machine connection is rootless` and `Containers run as ARM64`. After
  the restart the installer starts the stopped machine again and the verifier
  passes the same way.

### MAC-11 Native integration

- **Boundary:** the clipboard and the default applications, which the
  installer deliberately never touches during verification.
- **Applies when:** always.
- **Do:** from the guide's
  [native integration](../../platforms/macos.md#8-identity-authentication-and-native-integration)
  section:

  ```bash
  printf 'clipboard-check' | pbcopy
  pbpaste
  open https://github.com
  open README.md
  ```

- **Pass when:** `pbpaste` prints `clipboard-check`, the URL opens in the
  default browser and the README in its default application.

### MAC-12 Rerun with the optional profiles

- **Boundary:** `--rerun` replaying a selection that includes the profiles CI
  never selects on macOS.
- **Applies when:** always.
- **Do:**

  ```bash
  ./install.sh --rerun --dry-run
  ./install.sh --rerun
  ```

- **Pass when:** the dry run reconstructs the same options as the record's
  **Selected options**, and the rerun exits `0` without asking for any
  permission granted above again.

## When this checklist must be redone

Besides the macOS-upgrade and six-month triggers in
[the README](README.md#when-a-record-must-be-redone), any merged change to
these paths makes a record for this checklist stale:

- `platforms/macos/install.sh`, `platforms/macos/Brewfile`,
  `platforms/macos/scripts/verify.sh`, `platforms/macos/lib/macos.sh` and
  `scripts/bootstrap-macos.sh`
- `platforms/macos/stow/aerospace/`, `platforms/macos/stow/ghostty-macos/` and
  `platforms/macos/stow/theme-hooks/`
- `platforms/macos/scripts/install-containers.sh`
- `platforms/macos/scripts/install-tailscale.sh`
- `platforms/macos/scripts/install-dictation.sh` and
  `platforms/macos/lib/dictation.sh`, including a Ghost Pepper pin bump
- the `macos` rows for `base`, `containers`, `tailscale` and `dictation` in
  `config/capabilities.tsv`

## Results table

Copy this into the record's **Results** section.

| ID | Outcome | Notes |
|---|---|---|
| MAC-01 | | |
| MAC-02 | | |
| MAC-03 | | |
| MAC-04 | | |
| MAC-05 | | |
| MAC-06 | | |
| MAC-07 | | |
| MAC-08 | | |
| MAC-09 | | |
| MAC-10 | | |
| MAC-11 | | |
| MAC-12 | | |
