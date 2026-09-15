# Repository conventions

Conventions for changing this repository itself, as opposed to operating a
machine it has installed.

## Repository hygiene

Do not vendor entire third-party plugin repositories inside Stow packages.

Catppuccin tmux, for example, lives in:

```text
~/.local/share/tmux/plugins/catppuccin
```

and is installed by a pinned installer script.

Do not commit:

- Git identities
- private keys
- tokens
- machine-local theme state
- runtime logs
- nested Git repositories

Do not leave a package manager's lockfile at the repository root without the
project it belongs to. `./scripts/lint.sh` rejects a lone root lockfile: it
makes dependency and supply-chain tooling treat this repository as a project it
is not.

## Licensing

This repository's own scripts, configuration and documentation have **no
licence yet**; that is an open maintainer decision, with the options and their
practical consequences written down in
[`docs/reference/licensing.md`](../reference/licensing.md). Until it is made,
the default applies: all rights reserved.

Third-party material vendored or fetched here keeps its own upstream licence,
which that decision cannot change. What is incorporated, at which upstream
revision, and under which licence is indexed in
[`docs/reference/third-party-notices.md`](../reference/third-party-notices.md).
Retained upstream licence texts live in [`LICENSES/`](../../LICENSES) and beside the
material they cover.
