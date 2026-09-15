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

On the Fedora desktop, where this repository manages a flavour-matched
wallpaper, `--preserve-wallpaper` changes the flavour while keeping the
wallpaper currently selected in KDE or Sway:

```bash
theme macchiato --preserve-wallpaper
```

It preserves only the desktop wallpaper; the KDE and Sway lock screens keep
following the selected flavour. On Fedora WSL, macOS and the Parrot guest there
is no repository-managed wallpaper, so the flag has nothing to preserve.

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

Not actually a choice: SFTP/SCP ship as part of every platform's base
install with no installer flag to select. What differs — the exact package,
and whether a GUI (Dolphin/KIO) client is also wired up — is platform- and
desktop-specific, so it is documented where the rest of that platform's
choices live: see
[the Fedora guide](../platforms/fedora.md#sftp-client) (covers KDE and Sway)
and [the macOS guide](../platforms/macos.md#sftp-client).

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
