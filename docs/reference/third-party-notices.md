# Third-party notices

This repository incorporates or derives from third-party material. This page
is the index of that material: what it is, where it came from, which upstream
revision it was taken at, and which licence governs it.

It deliberately does not reproduce upstream licence texts that are already
retained verbatim in this checkout. Where a full text is retained, the
`Licence text` column links to it; otherwise the licence is named and the
upstream project is linked.

Two things are kept separate on purpose:

- **This repository's own material** — the scripts, configuration, manifests
  and documentation written here. Its licence is a separate, still-open
  maintainer decision; see [licensing.md](licensing.md).
- **Third-party material** listed below. Its licence is set by its upstream
  author and is unaffected by whatever this repository eventually chooses.

Material that is only *installed* at runtime (distribution packages, Homebrew
formulae, mise tools, Mason packages, Neovim plugins) is not listed here: it
is never vendored into this repository. The inventory of everything this
repository fetches, with its pinning tier, is
[supply-chain-sources.md](../supply-chain-sources.md).

## Vendored and derived material

| Material | Path in this repository | Upstream | Revision / version | Licence | Licence text |
|---|---|---|---|---|---|
| Catppuccin wallpapers (converted to WebP, lock variants blurred/darkened) | `platforms/fedora/stow/theme-assets/.local/share/wallpapers/` | [zhichaoh/catppuccin-wallpapers](https://github.com/zhichaoh/catppuccin-wallpapers) | `1023077979591cdeca76aae94e0359da1707a60e` | MIT | [`LICENSES/Catppuccin.txt`](../../LICENSES/Catppuccin.txt) |
| Catppuccin palette values used by the tracked Ghostty, fzf, Lazygit, delta and Starship theme files | `ghostty/.config/ghostty/themes/`, `fzf/.config/fzf/themes/`, `lazygit/.config/lazygit/themes/`, `git/.config/git/themes/`, `config/starship/palettes/` | [catppuccin/catppuccin](https://github.com/catppuccin/catppuccin) | palette values, per-port | MIT | [`LICENSES/Catppuccin.txt`](../../LICENSES/Catppuccin.txt) |
| LazyVim starter template, modified | `nvim-lazyvim/.config/nvim/` | [LazyVim/starter](https://github.com/LazyVim/starter) | starter template | Apache-2.0 | [`nvim-lazyvim/.config/nvim/LICENSE`](../../nvim-lazyvim/.config/nvim/LICENSE) |

## Material fetched at install time, not vendored

These are not stored in this repository, but the repository pins them and
applies them to the machine, so their attribution belongs next to the list
above. Pinned revisions are held in `config/network-sources.tsv`, which is the
normative source for them.

| Material | Upstream | Pinned as | Licence |
|---|---|---|---|
| Catppuccin tmux theme | [catppuccin/tmux](https://github.com/catppuccin/tmux) | `catppuccin-tmux` (git tag) | MIT |
| Catppuccin KDE theme | [catppuccin/kde](https://github.com/catppuccin/kde) | `catppuccin-kde` (git tag) | MIT |
| Catppuccin bat/delta syntax themes | [catppuccin/bat](https://github.com/catppuccin/bat) | `catppuccin-bat-themes` (commit + sha256) | MIT |
| Hack Nerd Font | [ryanoasis/nerd-fonts](https://github.com/ryanoasis/nerd-fonts) | `hack-nerd-font` (release + sha256) | MIT (Hack: MIT; Bitstream Vera: Bitstream Vera Fonts Copyright) |

## Keeping this page honest

`scripts/validate-repository-hygiene.py` (run by `./scripts/lint.sh`) checks
that every licence text retained under `LICENSES/` is referenced here, and that
every repository path and licence file this page links to actually exists.
Adding vendored material therefore means adding a row here.
