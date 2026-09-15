# Licensing of this repository's own material

**Status: decided — MIT.**

The scripts, configuration, manifests and documentation written in this
repository are licensed under the MIT License. The text is at
[`LICENSE`](../../LICENSE) in the repository root, copyright Kasper Elbo.

Third-party material is a separate matter and is covered separately: see
[third-party-notices.md](third-party-notices.md).

## What MIT means here

Anyone may copy, modify and redistribute this repository's own material,
including inside closed-source work, provided the copyright notice and the
licence text travel with it. In practice, for a dotfiles repository:

- Lifting a script, a profile, or a whole platform layer into your own
  dotfiles needs no permission and no notification.
- Redistributing a modified version is fine, with the notice kept.
- There is no warranty, and no liability for the author. Read the installers
  before running them on a machine you care about; several of them use `sudo`
  and change system state.

This licence governs **only this repository's own material**. It does not
relicense anything vendored from upstream.

## What it does not cover

| Material | Governed by |
|---|---|
| Catppuccin wallpapers and palette-derived theme files | Catppuccin's MIT licence, [`LICENSES/Catppuccin.txt`](../../LICENSES/Catppuccin.txt) |
| The modified LazyVim starter under `nvim-lazyvim/` | Apache-2.0, [`nvim-lazyvim/.config/nvim/LICENSE`](../../nvim-lazyvim/.config/nvim/LICENSE) |
| Everything fetched at install time — distribution packages, Homebrew formulae, mise tools, Mason packages, Neovim plugins | Its own upstream licence; none of it is vendored here |

[third-party-notices.md](third-party-notices.md) is the index: what is
incorporated, at which upstream revision, and under which licence.

## What was considered

Recorded so the choice reads as deliberate rather than inherited from a
template:

| Choice | Why not |
|---|---|
| **MIT** | **Chosen.** Shortest and most familiar in the dotfiles ecosystem, and it matches the Catppuccin material already vendored here. |
| Apache-2.0 | Same permissions plus a patent grant and a modification-notice requirement. Matches the vendored LazyVim starter, but the patent clause earns little for shell scripts and configuration, at the cost of a much longer file. |
| BSD-2-Clause / BSD-3-Clause | Equivalent in effect to MIT; 3-Clause adds a no-endorsement clause that nothing here needs. |
| GPL-3.0 | Copyleft would discourage exactly the reuse this repository is published for — lifting a fragment into someone else's setup. |
| CC0-1.0 / Unlicense | Public-domain dedication drops attribution entirely; MIT keeps it at negligible cost to a reuser. |
| Deliberately none | The status quo before this decision: all rights reserved by default, which made reuse legally unclear for anyone who wanted it. |

## Keeping the record honest

`scripts/validate-repository-hygiene.py`, run by `./scripts/lint.sh`, requires
that this page's **Status** line and the presence of a root `LICENSE` file
agree. Removing `LICENSE` without changing the status here fails, and so does
the reverse. Changing the licence therefore means changing both, plus the
summary in the [README](../../README.md#licensing) and in
[repository-conventions.md](../architecture/repository-conventions.md#licensing).
