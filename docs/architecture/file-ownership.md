# Stow layout and machine-local state

## GNU Stow layout

Each top-level configuration directory is a Stow package:

```text
bat/
bin/
fzf/
ghostty/
git/
lazygit/
mise/
nvim-lazyvim/
starship/
tmux/
zsh/

platforms/fedora/stow/
├── theme-assets/   # shared KDE/Sway wallpapers
├── theme-hooks/    # Fedora desktop response to `theme`
├── zsh-platform/   # Fedora package paths for Zsh plugins
├── sway/           # only stowed with --sway
└── waybar/         # only stowed with --sway
```

Stow is run with `--no-folding`.

This is intentional. Individual tracked files are linked into normal directories so tracked and machine-local files can coexist.

Example:

```text
~/.config/git/
├── config          -> dotfiles/git/...
├── themes/...      -> dotfiles/git/...
├── local           # local, not tracked
└── drdk            # local, not tracked
```

---

## Machine-local state

The following files are intentionally outside the repository:

```text
~/.config/dotfiles/
├── theme
├── hardware.conf
├── ghostty.conf
├── git-theme
├── tmux-theme.conf
├── sway-theme.conf
├── waybar-theme.css
├── fuzzel.ini
├── mako.conf
└── swaylock.conf

~/.config/git/
├── local
└── drdk

~/.config/sway/
└── local.conf       # output names, positions, modes, and scaling
```

The shared Ghostty, Git, and tmux theme files are produced by the portable
theme state. The Sway, Waybar, Fuzzel, Mako, and swaylock files are produced by
the Fedora theme hook. `hardware.conf` is created only after an optional
hardware profile has been installed; it records the selected model and
verification requirements.

The Git files contain user-specific identity and optional authentication/signing configuration.

When upgrading from a version that tracked these files accidentally,
`scripts/setup-local.sh` replaces the old Stow links with private local files
before the remaining dotfiles are restowed.
