# Choices a user must make

The installer deliberately does not guess personal or security-sensitive
information. These are the things you set up yourself, once, after the first
install. ASUS laptop hardware is its own opt-in profile and lives in the
[Fedora guide](../platforms/fedora.md#asus-laptop-hardware).

The installer intentionally does not guess personal or security-sensitive information.

## 1. Catppuccin flavor

All four Catppuccin flavors are supported:

| Flavor | Character |
|---|---|
| Latte | Light |
| Frappé | Soft dark |
| Macchiato | Medium dark — **default** |
| Mocha | Darkest |

Switch at any time with:

```bash
theme latte
theme frappe
theme macchiato
theme mocha
```

On the Fedora desktop and on macOS, where this repository manages a
flavour-matched wallpaper, `--preserve-wallpaper` changes the flavour while
keeping the wallpaper you have:

```bash
theme macchiato --preserve-wallpaper
```

Without it, `theme` replaces the desktop wallpaper on those two platforms — in
KDE or Sway on Fedora, and on every display on macOS. It preserves only the
desktop wallpaper: the KDE and Sway lock screens keep following the selected
flavour, and the Mac lock screen shows the desktop wallpaper either way. On
Fedora WSL and the Parrot guest there is no repository-managed wallpaper, so
the flag is accepted and has nothing to preserve.

The selection is stored locally in:

```text
~/.config/dotfiles/theme
```

Changing flavor does **not** modify tracked dotfiles, and a later installer run
without `--theme` keeps whatever is stored there — see
[Catppuccin theming](theming.md) for the full precedence.

`theme` reports what it applied. It exits 0 when everything applicable
succeeded, 3 when the shared theme state is current but an independent platform
action failed (naming it), and 1 when the shared state itself could not be
written.

## 2. Git identity

Shared Git behavior is tracked, but identities are local.

Configure:

```text
~/.config/git/local
```

Example:

```gitconfig
[user]
    name = Your Name
    email = you@example.com
```

A separate DR/work identity can be placed in:

```text
~/.config/git/drdk
```

Example:

```gitconfig
[user]
    name = Your Work Name
    email = you@work.example
```

The tracked Git configuration conditionally applies the DR profile for remotes matching the `drdk` GitHub organization.

Both files are machine-local, created at mode `0600`, and never committed. If
you are upgrading a machine that predates this layout — where these files were
symlinks into the checkout — the installer migrates them, and reports per slot
whether it migrated, found nothing to migrate, or needs manual action. It never
invents an identity and never prints one.
[`docs/reference/git-identity.md`](../reference/git-identity.md) describes the
migration sources, what a failed migration leaves behind, and the privacy
limits of recovering identities from public history.

## 3. SSH authentication

SSH authentication is intentionally not automated.

Supported approaches include:

- 1Password SSH Agent
- normal OpenSSH keys
- another existing SSH agent

Verify authentication with:

```bash
ssh -T git@github.com
```

## 4. GitHub CLI authentication

After installation:

```bash
gh auth login \
  --hostname github.com \
  --git-protocol ssh \
  --web \
  --skip-ssh-key
```

Multiple GitHub CLI accounts can be managed independently with:

```bash
gh auth switch
```

## 5. Commit signing

SSH commit signing is optional and user-specific.

For 1Password:

1. Open the SSH key in 1Password.
2. Choose **Configure Commit Signing**.
3. Copy the Git configuration snippet.
4. Put the signing configuration in `~/.config/git/local`.
5. Register the public key on GitHub as a **Signing key**.

Do not commit signing keys or user-specific signing configuration to this repository.

## 6. SFTP client

Not actually a choice: command-line SFTP is part of every platform's base
install with no installer flag to select. On Fedora it comes from the
`openssh-clients` package — the same package that provides `ssh` and
`scp` — so there is never a second SSH implementation to manage. This
section documents the Fedora/KDE case; see
[the macOS guide](../platforms/macos.md#sftp-client) for that platform's
equivalent.

```bash
sftp user@host
```

Common interactive commands:

```text
ls
cd
lcd
pwd
lpwd
get
put
mget
mput
mkdir
rm
exit
```

Non-interactive transfers use `scp`:

```bash
scp file.txt user@host:/remote/path/
scp -r local-dir/ user@host:/remote/path/
scp user@host:/remote/path/file.txt .
```

Both tools use standard SSH authentication: `~/.ssh/config`, SSH keys,
ssh-agent (including a 1Password-backed agent), and password authentication
when a server requires it. No credentials, keys, or host-specific bookmarks
are tracked by this repository; that state stays machine-local.

Verify the baseline with:

```bash
command -v sftp
command -v scp
ssh -V
```

**KDE**: Dolphin/KIO already provides a native SFTP workflow, reused instead
of installing a dedicated application. `platforms/fedora/scripts/install-kde-theme.sh`
explicitly ensures Fedora's `kio-extras` package — which supplies Dolphin's
`sftp://` support — is installed, rather than assuming it. Open a location
directly:

```text
sftp://user@host/path
```

either by typing it into Dolphin's location bar or from the Network places
sidebar entry. It authenticates through the same SSH key/agent as the CLI,
and supports normal drag/drop and recursive folder transfers. This is reused
as-is; no dedicated SFTP application is installed for KDE.

**Sway**: the optional `--sway` session runs on top of the same Fedora KDE
Plasma base as the rest of this profile, so Dolphin and the `kio-extras`
sftp:// support ensured above are available there too — launch Dolphin from
Fuzzel exactly as under Plasma. No dedicated Sway-specific GUI SFTP client is
added, since Dolphin already solves the same usability gap in both sessions.

A standalone GUI client such as FileZilla was evaluated and rejected: Dolphin
already gives both KDE and Sway a working native SFTP path with SSH key/agent
support, drag/drop, and recursive transfers, so a second GUI application would
duplicate functionality rather than close a real gap.

This is Fedora-specific: the base package list on other platforms differs
(Parrot's base install, for example, has no `openssh-client`/`openssh-clients`
row of its own).

## 7. AI agent authentication

Only relevant if the optional AI profile (`--ai`) is selected; see
[the AI profile guide](../profiles/ai.md) for the full picture. Nothing here
is stored in this repository, and none of it is requested or configured by
the installer:

- Claude Code: run `claude`, follow the browser login prompt (or set
  `ANTHROPIC_API_KEY`).
- Codex (if installed): run `codex`, choose "Sign in with ChatGPT" (or
  configure an OpenAI API key).
- FirstMate (if installed): uses your own `gh auth login`.
- GNHF (if installed): no separate auth; shells out to your already-signed-in
  `claude` (or configured `--agent`). Read its README before your first
  unattended run.
- backpass (if installed): no separate auth; every model call goes through
  `acpx` to a harness you have already authenticated.
