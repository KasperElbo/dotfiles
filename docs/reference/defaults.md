# Fedora workstation defaults

What a `./install.sh --platform fedora` run with no optional flags ends up
with. This page is the reference machine this repository was written around;
it is **not** a cross-platform statement. The terminal, desktop and package
owners differ on every other platform — Noctty and the Windows host on WSL,
Konsole on the Parrot guest, AeroSpace and Homebrew on macOS — so read
[the capability matrix](capability-matrix.md) for what any given platform
actually supports, and [the platform guides](../platforms/README.md) for how it
differs.

| Layer | Default |
|---|---|
| Distribution | Fedora |
| Desktop | KDE Plasma / Wayland |
| Terminal | Ghostty |
| Shell | Zsh |
| Prompt | Starship |
| Terminal persistence | tmux |
| Editor | Neovim + LazyVim |
| Git TUI | Lazygit |
| GitHub CLI | `gh` |
| Runtime manager | mise |
| Theme | Catppuccin Macchiato |
| Accent | Mauve |
| KDE decoration | Classic |

Everything beyond that row set is opt-in. Which optional profiles exist, what
each one's flag is, and which platforms accept it are in the generated
[installer options](installer-options.md) and
[capability matrix](capability-matrix.md) rather than repeated here — that is
the pair of tables an added or retired flag updates automatically. The package
each of them installs, and its owner, is in
[package ownership](../architecture/package-ownership.md#package-inventory).

To see the exact set a given command line resolves to, without installing
anything:

```bash
./install.sh --platform fedora --dry-run
```

The goal is not to turn the workstation into a custom framework. The goal is a reproducible setup that remains understandable to someone already familiar with Fedora, Zsh, Neovim, Git, and the upstream tools themselves.
