# Optional desktop-tools profile

`--desktop-tools` adds a small, deliberate set of day-to-day desktop
applications for a general-purpose Fedora KDE workstation. It is not part of
the default `./install.sh` path, appears in `--dry-run`, and can be run and
rerun on its own:

```bash
./platforms/fedora/scripts/install-desktop-tools.sh
./platforms/fedora/scripts/install-desktop-tools.sh --dry-run
./platforms/fedora/scripts/verify-desktop-tools.sh
```

The Fedora KDE baseline was inspected first so the profile reuses what is
already an adequate default instead of installing a duplicate:

| Category | Reused from the KDE baseline | Added by this profile | Why |
|---|---|---|---|
| Images | Gwenview (fast viewer, EXIF-aware rotation) | GIMP | The baseline has no general-purpose raster editor |
| PDF | Okular (viewer, annotation) | pdfarranger | Okular views and annotates but does not merge, split, reorder, or extract pages |
| Archives | Ark (integrated with Dolphin) | — | Already covers common formats graphically |
| Media | — | mpv | The baseline has no reliable general-purpose audio/video player for files it does not already handle |
| Scanning | — | Skanpage | The baseline has no scanning/document-capture front end |

The installer checks with `rpm -q` before touching Gwenview, Okular, or Ark,
and only installs one if it is genuinely missing; a normal Fedora KDE
workstation triggers no baseline installs at all.

Rejected alternatives:

- **Krita** and **Pinta** for the image editor: Krita is a digital-painting
  application, heavier than needed for crop/resize/retouch tasks; Pinta is
  lighter but has seen little maintenance. GIMP remains the maintained,
  general-purpose choice.
- **Xournal++** for PDF annotation: Okular already annotates PDFs well, so
  adding a second annotation tool would duplicate a responsibility the
  baseline already covers. pdfarranger is deliberately a page-manipulation
  tool, not another viewer or annotator.
- **LibreOffice Draw** for PDF manipulation: it is a full office suite; the
  issue this profile implements explicitly asks not to conflate a PDF
  workflow with an office suite unless one is genuinely needed.
- **Haruna** or **Dragon Player** for media: both are Plasma-integrated but
  pull in additional Plasma/QML runtime dependencies for a single-purpose
  player; mpv is a smaller, Wayland-native binary with broader format support
  through ffmpeg and works identically under Sway.

### Package ownership

All additions are Fedora/DNF-owned, consistent with the rest of the
workstation:

```text
gimp
pdfarranger
skanpage
```

The profile re-requests `xdg-utils` because it uses `xdg-mime` to claim MIME
defaults, but it does not own it: the Fedora baseline installs `xdg-utils` and
`config/capabilities.tsv` records it under `base`, which is why it is not in
the list above.

`mpv` also comes from DNF, but requires the RPM Fusion repositories (enabled
automatically, the same way `install-asus-hardware.sh` already can) because
Fedora's own repositories ship only `ffmpeg-free`, a patent-conservative
build that omits codecs several common media files use. RPM Fusion's `mpv`
package pulls in its full `ffmpeg` as an ordinary DNF dependency instead.
No Flatpak is used anywhere in this profile: every selected application is
actively maintained, Wayland/KDE-friendly, and already well packaged for
Fedora, so Flatpak's extra sandboxing and duplicated runtime would add
overhead without a concrete advantage. See the [Fedora multimedia
guidance](https://rpmfusion.org/Configuration) for the underlying RPM Fusion
setup this profile automates.

### File associations

The installer sets default applications with `xdg-mime` for the mimetypes
each new or reused tool owns (common image formats to Gwenview, PDF to
Okular, common archive formats to Ark, common audio/video formats to mpv).
By default each mimetype is only claimed if it currently has no default or
is already set to the profile's choice; an existing, different default you
or another application configured is left untouched and logged, on both the
first run and every rerun. GIMP, pdfarranger, and Skanpage do not claim any
file associations: they are opened explicitly (from Dolphin's "Open With"
menu, `gimp`/`pdfarranger`, or the applications menu), not made the default
handler for a mimetype another tool already owns.

Pass `--force-defaults` to `install-desktop-tools.sh` (or
`--desktop-tools-force-defaults` to the top-level `./install.sh`) to
override an existing, different default instead of leaving it alone. This
replaces any prior choice — yours or another program's — for the mimetypes
listed above with the profile's own; it does not touch any other mimetype.
Use it when you want this profile's choices to win outright, for example on
a fresh machine coming from a different desktop's defaults. The chosen mode
is recorded as `force_defaults` in the profile's state file so a later
unqualified rerun still shows what the last run actually did.

The saved local state file is:

```text
~/.config/dotfiles/desktop-tools.conf
```
