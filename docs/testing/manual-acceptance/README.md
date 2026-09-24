# Manual acceptance records

Some of what this repository supports can only be seen on a real machine, by a
person sitting in front of it: firmware and Secure Boot on a physical ASUS
laptop, a graphical Plasma or Sway login, suspend and resume, a second monitor,
macOS privacy approvals, an interactive Tailscale sign-in, a microphone. No
hosted runner has any of those, and the repository says so wherever the gap
exists. What it lacked was a versioned record of the last time somebody
actually looked, tied to the commit that was installed and the machine it was
installed on.

A **manual acceptance record** is that record. It is a Markdown file under
[`records/`](#where-records-live), written after one person has worked through
one checklist on one real machine at one exact commit, and committed so that a
later reader can tell what was observed, when, at which revision, and what was
not.

## Manual evidence is not CI evidence

The two kinds of evidence answer different questions and are never counted as
each other. [Verification and installation testing](../../testing.md) describes
the automated tiers in full; the short version:

| | Automated evidence | Manual acceptance record |
|---|---|---|
| Produced by | `.github/workflows/validate.yml` (lint and the mocked suites, on every pull request) and `.github/workflows/real-install.yml` (real installs on disposable runners, weekly or on dispatch) | A person working through a checklist in this directory on a machine they own |
| Where it lives | Workflow run logs and summaries on GitHub | A committed file under `records/` |
| What it can prove | That the installers, verifiers and gates behave as their contracts say, on machines that are disposable and have no firmware, display, microphone or identity | What happened at the hardware and interactive boundaries those machines cannot reach |
| Repeatability | Rerun on demand against any commit | Each record is one observation; rerunning is a new record |
| Freshness | Every run is current for the commit it ran | Goes stale; see [when a record must be redone](#when-a-record-must-be-redone) |

Every checklist item is there because of something CI cannot show. Where an
item runs a verifier or the installer, it is because its verdict on *real
hardware*, with the options that machine uses, is the evidence — a
`NOT OBSERVED` on a hosted runner becoming a pass on the machine — not because
the verifier itself is under test.

A record is evidence about a checkout, never a statement of what is supported.
[`config/capabilities.tsv`](../../capabilities.md) stays the only authority on
that. A `fail` in a record is a defect report against the commit it names; it
does not demote a capability, and a `pass` does not promote one.

## The checklists

Each supported real-hardware target has its own checklist. A record follows
exactly one of them.

| Checklist | Machine | Boundaries it covers |
|---|---|---|
| [Fedora ASUS workstation](fedora-asus.md) | A physical ROG Zephyrus G14 running a supported hardware profile, `ga402xz` or `ga402rk` | Hardware preflight and verifier, Secure Boot and MOK enrollment, charge-limit persistence, GPU and display behaviour, KDE Plasma and Sway logins, suspend and resume, multiple monitors, the keyboard workflow, theming a real desktop, dictation and Tailscale sign-in |
| [Apple Silicon macOS](macos.md) | A physical Apple Silicon Mac, not a virtual machine | SIP observed on real hardware, AeroSpace Accessibility approval, the keyboard and multi-display workflow, wallpaper and lock screen, dictation with Microphone and Accessibility approval, Tailscale sign-in, and Podman machine startup where nested virtualisation exists |
| [Windows host](windows-host.md) | A physical Windows machine hosting Fedora on WSL | The PowerShell bootstrap run for real, Noctty drawing the Fedora shell, the theme crossing the WSL boundary, clipboard and browser interop, and Handy's microphone approval |

Both ASUS hardware profiles are supported, so each model in use needs a record
of its own: a GA402XZ record says nothing about a GA402RK, whose graphics stack
is different.

Two targets deliberately have no checklist here:

- **The Parrot CTF guest** is a virtual machine, not hardware. Its clean-install
  evidence is the self-hosted `parrot-real-vm` job in
  `.github/workflows/real-install.yml`, and the host-side isolation check,
  `platforms/fedora/scripts/verify-parrot-isolation.sh`, already separates what
  it verified from what needs manual assurance in its own output. See
  [the Parrot guide](../../platforms/parrot-ctf.md).
- **The Fedora WSL install itself** is exercised by the self-hosted
  `fedora-wsl-real` job, which imports a clean distribution for every run. The
  Windows host checklist covers only the Windows-side interactive parts that job
  never touches.

## The four outcomes

Every checklist item in a record gets exactly one of these four words, spelled
exactly like this. They mean what the verifiers' own outcomes mean (see
[verification](../../workflows/verification.md#what-a-verifier-proves)), so a
verifier line and a record line never disagree about vocabulary.

| Outcome | Meaning | Notes required |
|---|---|---|
| `pass` | The action was performed on this machine at this commit, and what was observed met the item's **Pass when** criterion. | No |
| `fail` | The action was performed, and what was observed did not meet the criterion. A failure is recorded as it was seen; it is not retried until it passes and then written down as a pass. | Yes: what was seen, and the issue it was reported in |
| `not observed` | The item applies to this machine and its selection, but its result was not seen: it was not attempted, it could not be attempted (no second monitor to hand, no microphone), or it was attempted and the result could not be read. This is missing evidence, not a pass. | Yes: why it was not seen |
| `not applicable` | The item's **Applies when** condition is false for this machine: the option was not selected, or the hardware model does not have the component. It is decided by the selection and the hardware, never by what was convenient to test. | Yes: which option or model makes it inapplicable |

`not applicable` is the one that is easy to misuse. An item that applies but was
skipped is `not observed`. MOK enrollment on a GA402RK is `not applicable`,
because that model has no NVIDIA module to sign; MOK enrollment on a GA402XZ
installed with `--secure-boot` that nobody got round to checking is
`not observed`.

## Keeping personal data out

Records are public, versioned and permanent: anything committed to one stays in
the history even after the line is removed. This follows the
[repository conventions](../../architecture/repository-conventions.md#repository-hygiene)
on what must never be committed, and tightens them for records, whose whole
purpose is to describe a real machine.

| Record this | Not this |
|---|---|
| The marketing model and board: `ROG Zephyrus G14 GA402XZ` | The serial number, the asset tag, or `dmidecode` output |
| The BIOS or firmware version string | A disk, partition, machine or hardware UUID, or an Apple UDID |
| The OS release and kernel version | The hostname, or the name the machine has on any network |
| Connector names: `eDP-1`, `HDMI-A-1`, "left USB-C" | Raw `swaymsg -t get_outputs` output, which includes each monitor's serial number |
| The verifier line, such as `tailscale status: Running (connected to a tailnet)` | `tailscale status` or `tailscale ip` output, the tailnet name, a `*.ts.net` name, peer names or any address |
| "Signed in to Tailscale interactively" | The account, the identity provider, or an email address |
| "MOK enrolled with a temporary password" | The MOK password, the key, or the certificate's contents |
| `~/.config/dotfiles/hardware.conf` | `/home/<you>/...` or `/Users/<you>/...`: write paths from `~` |
| "Dictated one sentence into TextEdit; it was pasted" | The dictated text, or anything read from a transcription history |
| Whether a network was reachable | Wi-Fi network names, MAC addresses, or IP addresses |

Before committing, read the whole record once for anything the table would put
in the right-hand column. Verifier output is safe to quote line by line, but
paste only the lines an item asks for: some verifier lines name local paths,
and a whole transcript is where a hostname or an account name slips in.

`./scripts/lint.sh` backs this with a pattern check (below), which catches the
shapes a pattern can catch — email addresses, MAC and IP addresses outside the
documentation ranges, `*.ts.net` names, UUIDs, a serial-number field, a home
directory path. It cannot recognise a hostname or a password, so the read
through is still the rule and the lint gate is the backstop.

## Where records live

```text
docs/testing/manual-acceptance/records/YYYY-MM-DD-<checklist>-<short-sha>.md
```

- `YYYY-MM-DD` is the record's **Date**, the day the checklist was worked through.
- `<checklist>` is the checklist's file name without `.md`: `fedora-asus`,
  `macos` or `windows-host`.
- `<short-sha>` is the first seven or more characters of the tested **Commit**.

For example, `records/2026-10-04-fedora-asus-1a2b3c4.md`. A record is never
edited to describe a later run; a later run is a new file, and the older record
stays as the history of what was true then. Correcting a transcription mistake
in a record is fine, and the commit that does it should say so.

Every record is listed in the index below, newest first. The documentation
gate requires it: a document nothing links to fails `./scripts/lint.sh`.

### Record index

No record has been made yet. Until one exists, every boundary these checklists
cover has no manual evidence at any commit, which is exactly what the platform
guides already say about it.

## How to make a record

1. Pick the checklist for the machine, and the commit to test. Test a commit on
   `main`, or one that will reach `main` without being rewritten: the gate
   requires the commit to be in the history of the tree the record is added to.
2. Check out that commit with a clean tree. `git status --short` must print
   nothing, and `git rev-parse HEAD` is the **Commit** field.
3. Install at that commit with the options the machine uses, and confirm with
   `./doctor` that it reports `Checkout matches installed revision` followed
   by the same commit. (The Windows host has no `./doctor`; `git rev-parse HEAD`
   in the checkout the bootstrap ran from is the commit.)
4. Copy [the template](template.md) to its path under `records/`, fill in the
   **Record** table, and paste the checklist's results table into **Results**.
5. Work through every item in order, and give each one an outcome and, where the
   outcome needs it, a note. Put every command you ran, exactly as typed, into
   **Commands**.
6. Write down in **Known exclusions** anything this machine could not exercise,
   and anything you did differently from the checklist.
7. Read the record against [the privacy table](#keeping-personal-data-out), add
   it to [the record index](#record-index), run `./scripts/lint.sh`, and commit.

## When a record must be redone

A record describes one commit on one machine configuration. It stops being
current evidence, and that checklist must be worked through again, when any of
these happens after the tested commit:

- **A change touches the boundary.** Any merged change to the files an item
  exercises: the platform's installer, verifier or libraries for that item, its
  Stow package or asset, its pinned artifact, or its row in
  `config/capabilities.tsv`. Each checklist lists the paths that count for it.
- **The operating system moves.** A Fedora release upgrade; a macOS major
  upgrade, such as 26 to 27; a Windows feature update.
- **The kernel series changes on the GA402XZ.** Moving from one kernel series
  to the next, such as 7.1.x to 7.2.x, rebuilds the NVIDIA akmod and signs it
  again, which is exactly the Secure Boot and GPU boundary. The GA402RK uses
  the in-kernel `amdgpu` driver and follows the Fedora release rule instead.
- **The firmware moves.** An ASUS BIOS or EC update, applied through `fwupdmgr`
  or otherwise.
- **The hardware profile changes.** A different model, a different machine, a
  newly supported model, or a change to the machine's `--hardware`,
  `--secure-boot` or `--charge-limit` selection.
- **The record is six months old.** A record older than six months is stale
  even if nothing above happened.

The six-month ceiling matches the slowest cadence that still moves underneath
these checklists without touching this repository. Fedora releases roughly
every six months, so the ceiling guarantees at least one record per Fedora
release. Several things a record depends on update themselves outside any
repository diff — Ghost Pepper through its own Sparkle updater, AeroSpace and
the Tailscale app through Homebrew, the NVIDIA driver through RPM Fusion, and
firmware through `fwupdmgr` — and a longer ceiling would let a record outlive
all of them.
A shorter one would make the records a chore that stops being done, which is
worse than an honest six-month-old one.

The ceiling is a review rule, not a lint failure. A gate that fails when the
calendar moves would fail an unchanged checkout, and a check that can fail on a
commit that did nothing wrong teaches people to ignore it. The place it is
applied is the release review described in
[Maintenance/release role](../../testing.md#maintenancerelease-role): before a
release, each target in use has a current record, or the release notes say
which boundary has none.

## What the lint gate checks

`scripts/validate-acceptance-records.py`, run by `./scripts/lint.sh`, holds
every record to the rules above and every checklist to its own shape. For a
record, it requires:

- a file name of the form above, agreeing with the record's own **Date**,
  **Checklist** and **Commit**;
- a **Record** table naming the checklist, a full 40-character lowercase
  commit SHA, a real calendar date that is neither in the future nor earlier
  than the commit, the hardware and its firmware, the operating system, the
  installer command and the selected options, with no template placeholder
  left in any of them;
- that commit to be an ancestor of `HEAD`, when the history is present (a
  shallow clone cannot answer, and the gate says it did not check rather than
  passing silently; CI checks out the full history);
- the **Record**, **Commands**, **Results** and **Known exclusions** sections;
- one results row for every item in the named checklist, none missing, none
  repeated and none invented, each with one of the four outcomes and a note
  wherever that outcome requires one;
- none of the personal-data shapes listed under
  [keeping personal data out](#keeping-personal-data-out). The report names
  the line and the kind of match, never the matched text, so the CI log does
  not repeat what the record should not have contained.

For a checklist, it requires every item to carry an ID, **Boundary**,
**Applies when**, **Do** and **Pass when**, and the checklist's copyable
results table to list exactly its items, with every outcome still blank.

`tests/test-acceptance-records.sh` proves each of those rules can fail, on a
fixture record that is valid except for the one defect under test.
