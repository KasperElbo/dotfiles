# Manual acceptance record template

Copy this file to
`docs/testing/manual-acceptance/records/YYYY-MM-DD-<checklist>-<short-sha>.md`,
replace every `<...>` placeholder, and delete this paragraph and every
*Guidance* line. [The README](README.md) explains the outcomes, the privacy
rule and when a record must be redone; the lint gate rejects a record that
still contains a placeholder in its **Record** table.

## Record

| Field | Value |
|---|---|
| Checklist | `<fedora-asus.md, macos.md or windows-host.md>` |
| Commit | `<the full 40-character output of git rev-parse HEAD>` |
| Date | `<YYYY-MM-DD, the day the checklist was worked through>` |
| Hardware | <marketing model and board, for example ROG Zephyrus G14 GA402XZ or MacBook Pro 16-inch M5 Pro> |
| Firmware | <BIOS, EC or system firmware version string> |
| Operating system | <release, for example Fedora Linux 44 KDE Plasma Desktop Edition, macOS Tahoe 26.6.2 or Windows 11 25H2> |
| Kernel version | <uname -r on Linux; leave out on macOS and Windows> |
| Desktop versions | <Plasma, Sway, AeroSpace or Noctty versions exercised> |
| Installer command | `<the exact install command line, with every option it passed>` |
| Selected options | <the reconstructed options ./install.sh --rerun --dry-run printed, or the install.ps1 switches on Windows> |
| Peripherals | <what was attached: external monitor and its connector, microphone, dock; never a serial number> |

*Guidance:* the **Commit** is the checkout that was installed and tested, not
the commit that adds this record. It must match the revision `./doctor`
reports as installed.

## Commands

*Guidance:* every command run for this record, in order and exactly as typed.
Leave output out unless an item asks for a specific line.

```text
<commands>
```

## Results

*Guidance:* paste the results table from the end of the checklist here, then
fill in one outcome per row: `pass`, `fail`, `not observed` or
`not applicable`. Every outcome other than `pass` needs a note.

| ID | Outcome | Notes |
|---|---|---|

## Known exclusions

*Guidance:* what this machine or this run could not exercise, and anything done
differently from the checklist. Write "None" if there is nothing.

<exclusions>
