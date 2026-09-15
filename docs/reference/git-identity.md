# Machine-local Git identity

A Git identity — the `user.name` and `user.email` a commit is authored with —
is machine-local configuration, not repository content. This repository's
tracked `git/.config/git/config` includes two machine-local files that it never
tracks:

| Slot | Path | Included when |
|---|---|---|
| `local` | `~/.config/git/local` | always |
| `drdk` | `~/.config/git/drdk` | the remote URL matches `git@github.com:drdk/**` |

`common/setup-local.sh` creates both as empty, mode `0600` files on a fresh
machine. Filling them in is a
[manual post-install step](../../README.md#manual-post-install-checklist); the
installer never writes an identity of its own.

## Migration from the old layout

Earlier versions of this repository kept those two files *inside* the Stow
package, so `~/.config/git/local` was a symlink into the checkout — and, for
some Stow versions, the entire `~/.config/git` directory was one symlink.
Installing a current version replaces that layout with real machine-local
files, migrating the previous content where a source for it exists.

Sources are tried in this order, most explicit first:

| Source | Location | Enabled |
|---|---|---|
| `backup` | `$DOTFILES_GIT_IDENTITY_BACKUP_DIR`, default `$XDG_STATE_HOME/dotfiles/git-identity/<slot>` | always |
| `worktree` | the untracked file still at `git/.config/git/<slot>` in the checkout | always |
| `history` | the checkout's historical Git objects for that path | only when `DOTFILES_GIT_IDENTITY_HISTORY_RECOVERY=true` |

A candidate is installed only if it holds a real `[user]` section with a
`name` or `email` assignment. Content that validates is written byte-for-byte
at mode `0600`. Rerunning the installer over an already-migrated identity
changes nothing.

Every run reports one of three outcomes per slot:

- **migrated** — a valid source was found and installed;
- **nothing to migrate** — there was no legacy layout to convert;
- **manual action required** — a legacy layout existed but no valid source did.

## What a failed migration leaves behind

Nothing that could be mistaken for a recovered identity. The slot becomes a
comment-only file explaining that nothing was migrated and how to set the
identity by hand. Git reads it as an empty include, and neither a later
installer run nor a person reading the directory can misread it as success.

An empty file is never written as the *result* of a migration. The only empty
identity files this repository creates are the fresh-machine placeholders
described above.

## Privacy

Identity values are treated as private machine-local data:

- No message, log line, or test output ever prints a recovered name or email.
  Messages name the slot (`local`, `drdk`) and the kind of source, never the
  content.
- Files are created at mode `0600` and their parent directory at `0700`.

**History recovery has a privacy limitation, which is why it is off by
default.** These files were tracked in this repository's public history before
they moved out of the Stow package. Anything committed to a public repository
stays readable by anyone who clones it: deleting a file removes it from the
working tree, not from the object graph. Deleted public history is therefore
not a private backup, and this repository does not treat it as one. If you rely
on that history for recovery, understand that you are reading data that is
public, and prefer an explicit backup you control:

```bash
mkdir -p ~/.local/state/dotfiles/git-identity
cp ~/.config/git/local ~/.local/state/dotfiles/git-identity/local
chmod 600 ~/.local/state/dotfiles/git-identity/local
```

Enabling history recovery for one run, on a machine that still needs it:

```bash
DOTFILES_GIT_IDENTITY_HISTORY_RECOVERY=true ./install.sh
```

## Shallow and partial clones

Migration never depends on how deep the checkout is. The `backup` and
`worktree` sources do not read history at all. History recovery, when enabled,
detects a shallow clone, says so, and reports *manual action required* rather
than failing the install or fabricating a file.

The tests (`tests/test-git-identity.sh`) build their own temporary
repositories with exactly the history each scenario needs, so they behave
identically in a full clone, a shallow clone, and an export with no `.git` at
all.
