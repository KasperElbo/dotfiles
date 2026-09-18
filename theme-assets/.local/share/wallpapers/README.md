# Catppuccin wallpapers

The four tracked wallpapers are adapted from the tropical-island series in
the MIT-licensed Catppuccin wallpaper collection at commit
`1023077979591cdeca76aae94e0359da1707a60e`:

- Latte: `landscapes/tropic_island_day.jpg`
- Frappé: `landscapes/tropic_island_morning.jpg`
- Macchiato: `landscapes/tropic_island_evening.jpg`
- Mocha: `landscapes/tropic_island_night.jpg`

The sources are stored at
<https://github.com/zhichaoh/catppuccin-wallpapers>. Each desktop image is
converted to a 3840x2160 WebP. Its matching `-lock.webp` derivative is blurred
and darkened for Swaylock.

The original artwork is Copyright (c) 2021 Catppuccin and licensed under the
MIT License; see `LICENSES/Catppuccin.txt` in this repository.

## Ownership

This is a shared Stow package at the top of the checkout, not a platform's.
Any platform that wants flavour-matched wallpapers names `theme-assets` in its
`config/capabilities.tsv` stow column and links this one copy; `common/stow.sh`
does not deploy it, because a headless machine has no use for it. Fedora and
macOS link it today. The `-lock.webp` derivatives are Swaylock's, on Fedora,
and that is why they are blurred and darkened rather than because every
consumer needs them that way.

macOS has no use for the `-lock.webp` files and is not expected to grow one.
Its lock screen shows the desktop wallpaper, which `theme` already sets, and
the only way to give the login window a different image is to write into a
root-owned system cache. That was rejected; `docs/platforms/macos.md` records
the reasoning under "Lock screen", and `tests/test-macos.sh` fails if the
macOS tree starts reaching for either the `-lock` assets or that cache. The
asymmetry with Fedora is deliberate.

There is one copy of each image on purpose. A second set, cropped or
re-encoded for another platform, would lose the pinned provenance above, so
add a consumer rather than a copy.
