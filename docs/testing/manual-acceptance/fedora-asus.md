# Fedora ASUS workstation checklist

For a physical ROG Zephyrus G14 running one of the two supported hardware
profiles, `ga402xz` or `ga402rk` (see
[ASUS laptop hardware](../../platforms/fedora.md#asus-laptop-hardware)). The
hosted Fedora job installs the same code into a privileged systemd container,
which has no firmware, no DMI identity, no GPU, no graphical login and no lid
to close; everything below is what that container cannot show.

How to turn this into a record, what the four outcomes mean and what must stay
out of the record are in [the README](README.md). `<model>` below stands for
the machine's profile, `ga402xz` or `ga402rk`, and `<limit>` for its configured
charge limit.

## Before you start

- Update the operating system and firmware, then reboot, exactly as the
  [Fedora guide](../../platforms/fedora.md#asus-laptop-hardware) describes:

  ```bash
  sudo dnf upgrade --refresh
  sudo fwupdmgr refresh
  sudo fwupdmgr get-updates
  sudo fwupdmgr update
  sudo reboot
  ```

- Have an external monitor and its cable to hand, and a microphone if
  dictation is selected. An item that needs one you do not have is
  `not observed`, not `not applicable`.
- Run `sudo -v` before every verifier below. The hardware verifier reads the
  MOK state through non-interactive `sudo` and reports `NOT OBSERVED` without
  a cached authorization, which would turn a checkable item into a gap.

## Items

### FED-01 Hardware preflight on the real model

- **Boundary:** the DMI identity, kernel floor and Secure Boot state of a
  physical G14. The container has no DMI board name to match.
- **Applies when:** always.
- **Do:** run the read-only preflight, adding `--secure-boot` when the machine
  selects it:

  ```bash
  ./platforms/fedora/scripts/install-asus-hardware.sh --model <model> --secure-boot --preflight
  ```

- **Pass when:** it exits `0` and changes nothing, having matched the DMI
  board to `<model>`. On a machine that selects `--secure-boot`, it also
  refuses when Secure Boot is disabled in firmware; if that was tried, say so
  in the notes.

### FED-02 Install at the tested commit on hardware

- **Boundary:** the full installer, hardware profile included, on the real
  machine rather than in a container.
- **Applies when:** always.
- **Do:** install with every option this machine uses, then reboot once so the
  desktop session sees the login shell, completing MOK enrollment during that
  reboot if FED-03 applies:

  ```bash
  ./install.sh --platform fedora --dry-run --hardware <model> --secure-boot --charge-limit <limit> --kde --sway --dictation --tailscale
  ./install.sh --platform fedora --hardware <model> --secure-boot --charge-limit <limit> --kde --sway --dictation --tailscale
  ./doctor
  ```

  Leave out the options this machine does not select, and record the exact
  command line in the record's **Installer command** field.
- **Pass when:** the install exits `0` (or, on a GA402XZ awaiting MOK
  enrollment, stops as FED-03 describes and then completes when rerun), and
  `./doctor` reports `Checkout matches installed revision` with the tested
  commit.

### FED-03 MOK enrollment for the NVIDIA module

- **Boundary:** MOK Manager, a firmware-owned screen before the operating
  system boots, and the akmods signing certificate it enrolls.
- **Applies when:** the model is `ga402xz` and `--secure-boot` is selected.
  On a GA402RK this is `not applicable`: it has no out-of-tree module to sign.
- **Do:** accept the installer's offer to queue the certificate, reboot into
  MOK Manager, choose **Enroll MOK**, enter the temporary password, continue
  booting, and rerun the same install command. Then:

  ```bash
  sudo -v
  ./platforms/fedora/scripts/verify-asus-hardware.sh
  ```

- **Pass when:** the installer did not build or install the NVIDIA module
  before enrollment was confirmed, and the verifier reports
  `akmods signing certificate is enrolled`,
  `NVIDIA kernel module is available` and `NVIDIA driver is operational`.

### FED-04 Secure Boot stays enabled

- **Boundary:** the firmware's Secure Boot state after the whole install,
  which this repository never changes but must not break.
- **Applies when:** `--secure-boot` is selected.
- **Do:**

  ```bash
  mokutil --sb-state
  ./platforms/fedora/scripts/verify.sh
  ```

- **Pass when:** `mokutil` reports Secure Boot enabled, and both the
  Fedora security baseline and the hardware section of the verifier report
  `Secure Boot is enabled`.

### FED-05 Hardware verifier on the real machine

- **Boundary:** `asusd`, the ASUS Armoury interface, the masked power-profile
  services and the model's graphics stack, all of which need the real
  hardware to answer.
- **Applies when:** always.
- **Do:**

  ```bash
  sudo -v
  ./platforms/fedora/scripts/verify-asus-hardware.sh
  asusctl armoury list
  ```

- **Pass when:** the verifier reports no failure and no `NOT OBSERVED` line,
  including `DMI matches <model>`, `asusd.service is active` and
  `ASUS Armoury capabilities are available`. Warnings are allowed only where
  the notes explain them (a dGPU disabled in Armoury, for example).

### FED-06 Battery charge limit persists

- **Boundary:** the charge limit `asusd` applies through the kernel, across a
  reboot and a full power-off. A container has no battery.
- **Applies when:** `--charge-limit` is selected.
- **Do:** reboot, then run the checks; shut down completely, power on, and run
  them again:

  ```bash
  asusctl battery info
  ./platforms/fedora/scripts/verify-asus-hardware.sh
  ```

- **Pass when:** after both the reboot and the cold boot, the verifier reports
  `Battery charge limit is <limit>%` and `asusctl battery info` shows the same
  limit.

### FED-07 GPU and display behaviour

- **Boundary:** the real graphics stack and the firmware GPU controls, which
  this repository deliberately leaves unchanged.
- **Applies when:** always.
- **Do:** read the current GPU controls with `asusctl armoury list` and write
  the dGPU setting into the notes as it is, without changing it. In a Plasma
  session, attach the external monitor to each port that can carry a display
  in turn, HDMI and every USB-C port included, and name each port in the notes
  by where it is ("right USB-C").
- **Pass when:** the internal panel and every port the notes say should drive a
  display do so. On a GA402XZ, `nvidia-smi` answers; note that HDMI and the
  right USB-C port may depend on the NVIDIA dGPU, and record which ports worked
  in the current mode. On a GA402RK, the hardware verifier's
  `Both AMD GPUs use the amdgpu kernel driver` line is present, or its warning
  is explained by the dGPU setting in the notes.

### FED-08 KDE Plasma login

- **Boundary:** a real graphical login into Plasma. CI has no display manager
  and no graphical session.
- **Applies when:** Plasma is installed (`--kde`, or detected at install time).
- **Do:** log out, choose the Plasma session at the display manager, log in,
  open Ghostty, and run `./platforms/fedora/scripts/verify.sh` from it.
- **Pass when:** Plasma starts without falling back to a login screen, the
  shell in Ghostty is Zsh, the verifier reports no failure, and Plasma's
  `Meta+Alt+K` switches between US and Danish after the one-time layout setup
  in [the Fedora guide](../../platforms/fedora.md#keyboard-layouts).

### FED-09 Sway login

- **Boundary:** the `Sway (dotfiles)` login session starting on the real GPU,
  including the `--unsupported-gpu` path that `dotfiles-sway` takes only when
  the proprietary `nvidia_drm` module is loaded.
- **Applies when:** `--sway` is selected.
- **Do:** log out, choose **Sway (dotfiles)** at the display manager, log in,
  and run `./platforms/fedora/scripts/verify.sh` from a Ghostty window opened
  with `Super+Enter`.
- **Pass when:** Sway starts and stays up, Waybar shows workspaces, the active
  layout, network, audio, battery and clock, and the verifier's Sway session
  section reports no failure. Plasma is still offered at the display manager
  afterwards.

### FED-10 Sway keyboard workflow

- **Boundary:** keys reaching the compositor from the laptop's own keyboard,
  and from an external keyboard attached after login.
- **Applies when:** `--sway` is selected.
- **Do:** in Sway, try each binding in
  [the Sway shortcut table](../../platforms/fedora.md#optional-sway-session):
  `Super+Enter`, `Super+P`, `Super+H/J/K/L`, `Super+1..9`,
  `Super+Ctrl+H/J/K/L` from each corner of the grid, `Super+Alt+K`,
  `Super+Shift+V`, `Super+Shift+X`, the ASUS screenshot key and
  `Shift+Print`. Attach an external keyboard and press `Super+Alt+K` on it.
- **Pass when:** every binding does what the table says, grid movement wraps at
  each edge, and Waybar's layout code changes between `us` and `dk` on both
  keyboards.

### FED-11 Multiple monitors in Sway

- **Boundary:** output discovery and the display bindings with a real second
  output attached.
- **Applies when:** `--sway` is selected.
- **Do:** attach the external monitor, run `swaymsg -t get_outputs`, and write
  down only the connector names. Then use `Super+Tab`, `Super+Shift+Tab` and
  `Super+Ctrl+Tab`, and detach and reattach the monitor.
- **Pass when:** the new output is used without editing any tracked file,
  focus, a window and a whole workspace each move to the next display, and
  reattaching restores the output. Do not paste the `swaymsg` output: it
  contains each monitor's serial number.

### FED-12 Multiple monitors in Plasma

- **Boundary:** Plasma's own display handling on this hardware with a second
  output.
- **Applies when:** Plasma is installed.
- **Do:** in Plasma, attach the external monitor, arrange it in System
  Settings, log out and back in, then detach and reattach it.
- **Pass when:** the monitor lights up, the arrangement survives the new login,
  and windows return to a visible display when it is detached.

### FED-13 Suspend and resume from Plasma

- **Boundary:** firmware and driver suspend and resume on the real machine,
  which no runner can do.
- **Applies when:** Plasma is installed.
- **Do:** with the external monitor attached, close the lid, wait at least one
  minute, and open it. Run `./platforms/fedora/scripts/verify-asus-hardware.sh`
  after resuming.
- **Pass when:** the session resumes, both displays return, Wi-Fi reconnects, audio still plays, and the verifier result matches
  FED-05. On a GA402XZ, `nvidia-smi` still answers.

### FED-14 Suspend and resume from Sway

- **Boundary:** the same as FED-13, plus the Sway session's own
  `before-sleep` lock, because this repository never suspends the machine
  itself and leaves power policy to the system.
- **Applies when:** `--sway` is selected.
- **Do:** in Sway, with the external monitor attached, close the lid, wait at
  least one minute, and open it.
- **Pass when:** Swaylock is showing on resume, unlocking returns to the same
  workspaces, both outputs and Waybar are back, and `Super+Alt+K` still
  switches layouts.

### FED-15 Sway idle behaviour

- **Boundary:** the idle timers in the tracked Sway configuration: lock at 10
  minutes, displays off at 15, never suspend.
- **Applies when:** `--sway` is selected.
- **Do:** on mains power, leave the Sway session untouched for at least 16
  minutes, then press a key.
- **Pass when:** it locked by about 10 minutes, the displays were off by about
  15, the machine did not suspend, and the key turned the displays back on
  showing Swaylock.

### FED-16 Theme on a real desktop

- **Boundary:** the Fedora theme hook re-theming a running Plasma and a running
  Sway over their real session interfaces, which CI has neither of.
- **Applies when:** Plasma is installed or `--sway` is selected.
- **Do:** in each installed session, run `theme latte`, then `theme mocha`,
  then `theme mocha --preserve-wallpaper` after setting a wallpaper of your
  own, and finally put the machine's usual flavour back.
- **Pass when:** Plasma's colour scheme, cursor and wallpaper follow each
  flavour; in Sway, the borders, Waybar and wallpaper follow; and
  `--preserve-wallpaper` leaves your own wallpaper in place while the rest
  follows. Every `theme` run exits `0`; exit `3` means a hook left the desktop
  partly themed, and is a `fail`.

### FED-17 Dictation

- **Boundary:** a real microphone, and a transcription typed into the focused
  window through `wtype`.
- **Applies when:** `--dictation` is selected.
- **Do:** run `./platforms/fedora/scripts/verify-dictation.sh`. In Sway, start
  Handy from Fuzzel, choose a model in its window, focus a text field, press
  `Super+O`, speak one sentence, and press `Super+O` again. In Plasma, create
  the custom shortcut running `handy --toggle-transcription` as
  [the dictation guide](../../profiles/dictation.md#the-shortcut) describes,
  and repeat.
- **Pass when:** the verifier reports no failure, and in each session the
  sentence appears in the focused field without focus moving. Do not record the
  sentence itself.

### FED-18 Tailscale sign-in

- **Boundary:** the interactive login this repository never automates.
- **Applies when:** `--tailscale` is selected.
- **Do:** before signing in, run `./platforms/fedora/scripts/verify-tailscale.sh`;
  then run `sudo tailscale up`, complete the login in the browser, and run the
  verifier again. Reboot and run it once more.
- **Pass when:** the first run reports `NeedsLogin` or `NoState` (installed
  but not logged in), the second and third report
  `tailscale status: Running (authenticated and connected to a tailnet)`, and
  nothing between them asked for a key. Record only the verifier's verdict, never `tailscale status`
  output.

### FED-19 Rerun on the real machine

- **Boundary:** `--rerun` reapplying the remembered selection, hardware profile
  included, on hardware that is now configured.
- **Applies when:** always.
- **Do:**

  ```bash
  ./install.sh --rerun --dry-run
  ./install.sh --rerun
  sudo -v
  ./platforms/fedora/scripts/verify.sh
  ```

- **Pass when:** the dry run reconstructs the same options as the record's
  **Selected options**, the rerun exits `0` without asking for MOK enrollment
  again, and the verifier reports no failure.

## When this checklist must be redone

Besides the operating system, firmware, kernel-series, hardware-profile and
six-month triggers in [the README](README.md#when-a-record-must-be-redone),
any merged change to these paths makes a record for this checklist stale:

- `platforms/fedora/scripts/install-asus-hardware.sh`,
  `platforms/fedora/scripts/verify-asus-hardware.sh`,
  `platforms/fedora/lib/secure-boot.sh` and
  `platforms/fedora/lib/power-profiles.sh`
- `platforms/fedora/scripts/install-sway.sh`,
  `platforms/fedora/scripts/setup-local.sh`, `platforms/fedora/assets/`,
  `platforms/fedora/stow/sway/` and `platforms/fedora/stow/waybar/`
- `platforms/fedora/scripts/install-kde-theme.sh`,
  `platforms/fedora/scripts/apply-kde-theme.sh`,
  `platforms/fedora/lib/theme-desktop.sh` and
  `platforms/fedora/stow/theme-hooks/`
- `platforms/fedora/scripts/install-dictation.sh`,
  `platforms/fedora/scripts/verify-dictation.sh` and
  `platforms/fedora/lib/dictation.sh`
- `platforms/fedora/scripts/install-tailscale.sh`,
  `platforms/fedora/scripts/verify-tailscale.sh` and
  `platforms/fedora/lib/tailscale.sh`
- `platforms/fedora/scripts/verify.sh`
- the `fedora` rows for `kde`, `sway`, `hardware`, `dictation` and `tailscale`
  in `config/capabilities.tsv`

## Results table

Copy this into the record's **Results** section.

| ID | Outcome | Notes |
|---|---|---|
| FED-01 | | |
| FED-02 | | |
| FED-03 | | |
| FED-04 | | |
| FED-05 | | |
| FED-06 | | |
| FED-07 | | |
| FED-08 | | |
| FED-09 | | |
| FED-10 | | |
| FED-11 | | |
| FED-12 | | |
| FED-13 | | |
| FED-14 | | |
| FED-15 | | |
| FED-16 | | |
| FED-17 | | |
| FED-18 | | |
| FED-19 | | |
