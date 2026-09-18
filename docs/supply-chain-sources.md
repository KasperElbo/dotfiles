# Generated network-source inventory

Generated from `config/network-sources.tsv`; do not edit this table by hand.
Run `./scripts/render-supply-chain.py` after changing the manifest.

The tiers themselves, and what the repository does and does not claim about
reproducibility, are described in [supply-chain.md](supply-chain.md).

## Tier: `immutable-verified`

| Source | Component | Owner | Kind | Privilege | Requested | Resolved | Integrity | Cadence |
|---|---|---|---|---|---|---|---|---|
| `catppuccin-bat-themes` | Catppuccin bat/delta syntax themes | Catppuccin | `file` | `user` | `6810349b28055dce54076712fc05fc68da4b8ec0` | commit+sha256 | `sha256-pinned` | manual-bump |
| `hack-nerd-font` | Hack Nerd Font release archive | Nerd Fonts | `archive` | `user` | `pinned release + sha256` | release tag + sha256 | `sha256-pinned` | manual-bump |
| `terra-signing-key` | Terra repository signing key | Fyra Labs | `gpg-key` | `root` | `per-releasever` | gpg-fingerprint | `gpg-fingerprint-pinned` | per-fedora-release |
| `validation-image-fedora` | CI and clean-install validation base image | Fedora Project | `container-image` | `root` | `44` | sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80 | `image-digest-pinned` | manual-bump |

## Tier: `exact-commit`

| Source | Component | Owner | Kind | Privilege | Requested | Resolved | Integrity | Cadence |
|---|---|---|---|---|---|---|---|---|
| `catppuccin-kde` | Catppuccin KDE theme | Catppuccin | `git` | `user` | `v0.2.7` | git rev-parse HEAD | `git-tag-pinned` | manual-bump |
| `catppuccin-tmux` | Catppuccin tmux theme | Catppuccin | `git` | `user` | `v2.3.0` | git rev-parse HEAD | `git-tag-pinned` | manual-bump |
| `dotfiles-repository` | This repository, checked out by CI | KasperElbo | `git` | `user` | `github.sha` | git rev-parse HEAD | `git-commit-pinned` | per-commit |
| `lazy-nvim` | lazy.nvim plugin manager, cloned by CI to resolve plugin specs | folke | `git` | `user` | `lazy-lock.json` | lazy-lock.json | `git-commit-pinned` | manual-bump |
| `lazyvim-plugins` | Neovim plugin set | LazyVim and plugin authors | `git` | `user` | `lazy-lock.json` | lazy-lock.json | `git-commit-pinned` | manual-bump |

## Tier: `exact-version`

| Source | Component | Owner | Kind | Privilege | Requested | Resolved | Integrity | Cadence |
|---|---|---|---|---|---|---|---|---|
| `netcoredbg-legacy-release` | netcoredbg x64 build used as a debugger contract control | Samsung | `archive` | `user` | `3.1.3-1062` | release tag | `https-tls` | manual-bump |
| `opam-repository` | OCaml Platform packages | OCaml | `package-registry` | `user` | `5.5.0 compiler` | opam switch list | `registry-tls` | manual-bump |

## Tier: `version-line`

| Source | Component | Owner | Kind | Privilege | Requested | Resolved | Integrity | Cadence |
|---|---|---|---|---|---|---|---|---|
| `firstmate-repo` | FirstMate crew coordinator | kunchenguid | `git` | `user` | `default-branch` | firstmate_commit in ai state | `https-tls` | rolling |
| `homebrew-formulae` | Homebrew formulae and casks | Homebrew | `package-registry` | `user` | `Brewfile` | brew bundle list | `registry-tls` | rolling |
| `mason-registry` | Neovim LSP/DAP tooling | Mason registry | `package-registry` | `user` | `mason-packages.txt` | mason-package-versions.txt | `registry-tls` | rolling |
| `mise-tool-registry` | mise tool registry and backends | mise | `package-registry` | `user` | `config.toml` | mise ls | `registry-tls` | rolling |
| `npm-registry` | npm packages installed through mise | npm | `package-registry` | `user` | `latest` | mise ls | `registry-tls` | rolling |
| `scoop-noctty-bucket` | noctty terminal Scoop bucket | amanthanvi | `git` | `user` | `default-branch` | scoop bucket list | `https-tls` | rolling |
| `smoke-image-alpine` | Podman machine architecture smoke image | Docker Official Images | `container-image` | `user` | `latest` | podman image inspect | `registry-tls` | rolling |
| `smoke-image-busybox` | Podman rootless smoke-test image | Docker Official Images | `container-image` | `user` | `stable` | podman image inspect | `registry-tls` | rolling |

## Tier: `os-rolling`

| Source | Component | Owner | Kind | Privilege | Requested | Resolved | Integrity | Cadence |
|---|---|---|---|---|---|---|---|---|
| `fedora-os-repos` | Fedora base system packages | Fedora Project | `rpm-repo` | `root` | `releasever` | dnf-history | `repo-gpg` | distribution |
| `parrot-os-repos` | Parrot base system packages | Parrot Security | `apt-repo` | `root` | `release` | dpkg-status | `repo-gpg` | distribution |
| `rpmfusion-free-release` | RPM Fusion free release package | RPM Fusion | `rpm-package` | `root` | `releasever` | rpm -q rpmfusion-free-release | `https-tls` | per-fedora-release |
| `rpmfusion-nonfree-release` | RPM Fusion nonfree release package | RPM Fusion | `rpm-package` | `root` | `releasever` | rpm -q rpmfusion-nonfree-release | `https-tls` | per-fedora-release |
| `tailscale-repo` | Tailscale package repository | Tailscale | `rpm-repo` | `root` | `stable` | rpm -q tailscale | `repo-gpg` | rolling |
| `terra-repo` | Terra packages (ghostty, mise, starship) | Fyra Labs | `rpm-repo` | `root` | `terra-release` | rpm -q terra-release | `repo-gpg` | rolling |

## Tier: `reviewed-live`

| Source | Component | Owner | Kind | Privilege | Requested | Resolved | Integrity | Cadence |
|---|---|---|---|---|---|---|---|---|
| `homebrew-installer` | Homebrew installer script | Homebrew | `remote-script` | `root` | `HEAD` | brew --version | `https-tls` | rolling |
| `mise-installer` | mise standalone installer script | jdx | `remote-script` | `user` | `latest` | mise --version | `https-tls` | rolling |
| `no-mistakes-installer` | No Mistakes push gate installer | kunchenguid | `remote-script` | `user` | `main` | no_mistakes_digest in ai state | `https-tls` | rolling |
| `scoop-installer` | Scoop installer script | Scoop | `remote-script` | `user` | `latest` | scoop --version | `https-tls` | rolling |
| `starship-installer` | Starship prompt installer script | Starship | `remote-script` | `user` | `latest` | starship --version | `https-tls` | rolling |
| `treehouse-installer` | Treehouse worktree isolation installer | kunchenguid | `remote-script` | `user` | `live` | treehouse_digest in ai state | `https-tls` | rolling |
| `wsl-distribution-catalog` | WSL distribution catalog | Microsoft | `json-api` | `user` | `master` | wsl --list --online | `https-tls` | rolling |

## Rollback and recovery

| Source | URL | Rollback | Consumers |
|---|---|---|---|
| `catppuccin-bat-themes` | `https://raw.githubusercontent.com/catppuccin/bat/${bat_theme_commit}/themes/${encoded_name}` | restore the previous commit and digests | `platforms/parrot-ctf/scripts/install-terminal.sh` |
| `catppuccin-kde` | `https://github.com/catppuccin/kde.git` | reinstall the previous tag | `platforms/fedora/scripts/install-kde-theme.sh` |
| `catppuccin-tmux` | `https://github.com/catppuccin/tmux.git` | git checkout the previous tag | `common/install-tmux-theme.sh` |
| `dotfiles-repository` | `https://github.com/KasperElbo/dotfiles.git` | git checkout the previous commit | `.github/workflows/real-install.yml` |
| `fedora-os-repos` | `https://mirrors.fedoraproject.org` | sudo dnf history undo | `platforms/fedora/scripts/install-system.sh` `platforms/fedora-wsl/scripts/install-system.sh` |
| `firstmate-repo` | `https://github.com/kunchenguid/firstmate.git` | git -C ~/.local/share/firstmate checkout <commit> | `common/install-ai.sh` |
| `hack-nerd-font` | `https://github.com/ryanoasis/nerd-fonts/releases/download/v${font_version}/Hack.tar.xz` | reinstall the previous version directory | `platforms/parrot-ctf/scripts/install-terminal.sh` |
| `homebrew-formulae` | `https://formulae.brew.sh` | brew uninstall | `platforms/macos/Brewfile` `platforms/macos/scripts/install-system.sh` |
| `homebrew-installer` | `https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh` | Homebrew uninstall script | `scripts/bootstrap-macos.sh` `platforms/macos/install.sh` `platforms/macos/scripts/install-system.sh` |
| `lazy-nvim` | `https://github.com/folke/lazy.nvim.git` | git restore lazy-lock.json and rerun the job | `nvim-lazyvim/.config/nvim/lazy-lock.json` `.github/workflows/validate.yml` |
| `lazyvim-plugins` | `https://github.com/LazyVim/LazyVim` | git restore lazy-lock.json and :Lazy restore | `nvim-lazyvim/.config/nvim/lazy-lock.json` |
| `mason-registry` | `https://github.com/mason-org/mason-registry` | Mason uninstall | `common/install-neovim-tools.sh` `common/mason-package-versions.txt` |
| `mise-installer` | `https://mise.run` | rm ~/.local/bin/mise and rerun | `platforms/fedora-wsl/install.sh` `platforms/parrot-ctf/install.sh` `platforms/fedora-wsl/scripts/install-system.sh` `platforms/parrot-ctf/scripts/install-system.sh` |
| `mise-tool-registry` | `https://mise.jdx.dev/registry.html` | mise uninstall | `mise/.config/mise/config.toml` `common/install-mise.sh` |
| `netcoredbg-legacy-release` | `https://github.com/Samsung/netcoredbg/releases/download/3.1.3-1062/netcoredbg-osx-amd64.tar.gz` | pin the previous release tag | `tests/integration/macos-dotnet-debug.sh` |
| `no-mistakes-installer` | `https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh` | ./scripts/install-ai.sh --no-firstmate then rerun | `common/install-ai.sh` |
| `npm-registry` | `https://registry.npmjs.org` | mise uninstall | `common/install-ai.sh` |
| `opam-repository` | `https://opam.ocaml.org` | opam switch remove | `common/install-ocaml.sh` |
| `parrot-os-repos` | `https://deb.parrot.sh` | sudo apt-get install --reinstall | `platforms/parrot-ctf/scripts/install-system.sh` |
| `rpmfusion-free-release` | `https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm` | sudo dnf remove rpmfusion-free-release | `platforms/fedora/lib/fedora.sh` `platforms/fedora/scripts/install-asus-hardware.sh` `platforms/fedora/scripts/install-desktop-tools.sh` |
| `rpmfusion-nonfree-release` | `https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_version}.noarch.rpm` | sudo dnf remove rpmfusion-nonfree-release | `platforms/fedora/lib/fedora.sh` `platforms/fedora/scripts/install-asus-hardware.sh` `platforms/fedora/scripts/install-desktop-tools.sh` |
| `scoop-installer` | `https://get.scoop.sh` | scoop uninstall | `platforms/windows/install.ps1` |
| `scoop-noctty-bucket` | `https://github.com/amanthanvi/scoop-noctty` | scoop bucket rm noctty | `platforms/windows/install.ps1` |
| `smoke-image-alpine` | `docker.io/library/alpine:latest` | podman rmi | `platforms/macos/scripts/install-containers.sh` `platforms/macos/scripts/verify.sh` |
| `smoke-image-busybox` | `docker.io/library/busybox:stable` | podman rmi | `platforms/fedora/scripts/verify-containers.sh` |
| `starship-installer` | `https://starship.rs/install.sh` | rm ~/.local/bin/starship and rerun | `platforms/fedora-wsl/install.sh` `platforms/fedora-wsl/scripts/install-system.sh` |
| `tailscale-repo` | `https://pkgs.tailscale.com/stable/fedora/tailscale.repo` | sudo rm /etc/yum.repos.d/tailscale.repo | `platforms/fedora/lib/tailscale.sh` `platforms/fedora/scripts/install-tailscale.sh` |
| `terra-repo` | `https://repos.fyralabs.com/terra$releasever` | sudo dnf remove terra-release | `platforms/fedora/install.sh` `platforms/fedora/lib/fedora.sh` `platforms/fedora/scripts/install-terra.sh` `platforms/fedora/scripts/install-asus-hardware.sh` |
| `terra-signing-key` | `https://repos.fyralabs.com/terra$releasever/key.asc` | sudo rpm -e --allmatches gpg-pubkey-<id> | `config/terra-keys.tsv` `platforms/fedora/install.sh` `platforms/fedora/lib/fedora.sh` `platforms/fedora/scripts/install-terra.sh` `platforms/fedora/scripts/install-asus-hardware.sh` |
| `treehouse-installer` | `https://kunchenguid.github.io/treehouse/install.sh` | ./scripts/install-ai.sh --no-firstmate then rerun | `common/install-ai.sh` |
| `validation-image-fedora` | `docker.io/library/fedora:44` | pin the previous digest | `.github/workflows/validate.yml` `tests/integration/fedora-clean-install.sh` |
| `wsl-distribution-catalog` | `https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json` | not-applicable | `platforms/windows/install.ps1` |
