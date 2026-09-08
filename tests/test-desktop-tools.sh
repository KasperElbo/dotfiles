#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mock_bin="$test_root/bin"
command_log="$test_root/commands.log"
mkdir -p "$mock_bin" "$test_root/home" "$test_root/xdg" "$test_root/data/applications"

# Fixture .desktop files: set_default_mime_type only claims a mimetype when a
# matching desktop entry actually exists, so create the ones this profile uses.
for desktop_entry in \
  org.kde.gwenview.desktop org.kde.okular.desktop org.kde.ark.desktop \
  mpv.desktop; do
  : >"$test_root/data/applications/$desktop_entry"
done

mime_store="$test_root/mimeapps.store"
: >"$mime_store"

cat >"$mock_bin/dnf" <<'EOF'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >>"$COMMAND_LOG"
EOF

cat >"$mock_bin/rpm" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == -q ]]; then
  for present in \$RPM_PRESENT; do
    [[ "\$2" == "\$present" ]] && exit 0
  done
  exit 1
fi
exit 0
EOF

cat >"$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
if [[ "$1" == dnf ]]; then
  exit 0
fi
"$@"
EOF

cat >"$mock_bin/xdg-mime" <<'EOF'
#!/usr/bin/env bash
store="$XDG_MIME_STORE"
case "$1" in
query)
  mime="$3"
  awk -F= -v m="$mime" '$1 == m { print substr($0, length(m) + 2) }' "$store"
  ;;
default)
  desktop="$2"
  shift 2
  for mime in "$@"; do
    if grep -q "^$mime=" "$store" 2>/dev/null; then
      sed -i "s#^$mime=.*#$mime=$desktop#" "$store"
    else
      printf '%s=%s\n' "$mime" "$desktop" >>"$store"
    fi
  done
  ;;
esac
EOF

chmod +x "$mock_bin"/*

printf 'ID=fedora\n' >"$test_root/os-release"

test_environment=(
  env
  "HOME=$test_root/home"
  "XDG_CONFIG_HOME=$test_root/xdg"
  "XDG_DATA_HOME=$test_root/data"
  "PATH=$mock_bin:$PATH"
  "COMMAND_LOG=$command_log"
  "OS_RELEASE_FILE=$test_root/os-release"
  "XDG_MIME_STORE=$mime_store"
)

run_install() {
  RPM_PRESENT="${RPM_PRESENT:-}" "${test_environment[@]}" \
    "$repo_root/scripts/install-desktop-tools.sh" "$@" >/dev/null
}

# --- dry-run makes no changes and reports missing baseline packages -------

dry_run_output="$(RPM_PRESENT="" "${test_environment[@]}" \
  "$repo_root/scripts/install-desktop-tools.sh" --dry-run)"
grep -Fq 'Currently missing and would be installed: ark gwenview okular' \
  <<<"$dry_run_output"
grep -Fq 'Force-override existing default applications: false' <<<"$dry_run_output"
grep -Fq 'No changes were made.' <<<"$dry_run_output"

force_dry_run_output="$(RPM_PRESENT="" "${test_environment[@]}" \
  "$repo_root/scripts/install-desktop-tools.sh" --dry-run --force-defaults)"
grep -Fq 'Force-override existing default applications: true' \
  <<<"$force_dry_run_output"
grep -Fq 'overriding any existing default' <<<"$force_dry_run_output"

if [[ -s "$command_log" ]]; then
  printf 'Dry-run executed a mutating command.\n' >&2
  exit 1
fi
if [[ -s "$mime_store" ]]; then
  printf 'Dry-run changed MIME associations.\n' >&2
  exit 1
fi

# --- missing baseline apps are installed, never assumed present -----------

RPM_PRESENT="" run_install
grep -Fq 'sudo dnf install -y ark gwenview okular' "$command_log"
grep -Fq 'sudo dnf install -y gimp pdfarranger skanpage xdg-utils' \
  "$command_log"
grep -Fq 'sudo dnf install -y mpv' "$command_log"
printf 'PASS: missing Fedora KDE baseline apps are installed\n'

# --- an already-present baseline is reused, not reinstalled ----------------

: >"$command_log"
: >"$mime_store"
RPM_PRESENT="ark gwenview okular" run_install
if grep -E '^sudo dnf install -y ark gwenview okular' "$command_log"; then
  printf 'Desktop-tools profile reinstalled an already-present KDE baseline app.\n' >&2
  exit 1
fi
grep -Fq 'sudo dnf install -y gimp pdfarranger skanpage xdg-utils' \
  "$command_log"
printf 'PASS: an existing Fedora KDE baseline is reused, not duplicated\n'

# --- default applications are set for images, PDFs, archives and media -----

grep -Fqx 'image/jpeg=org.kde.gwenview.desktop' "$mime_store"
grep -Fqx 'application/pdf=org.kde.okular.desktop' "$mime_store"
grep -Fqx 'application/zip=org.kde.ark.desktop' "$mime_store"
grep -Fqx 'video/mp4=mpv.desktop' "$mime_store"
printf 'PASS: sensible default applications are set for each category\n'

# --- rerunning is idempotent and does not touch an existing user choice ----

state_file="$test_root/xdg/dotfiles/desktop-tools.conf"
first_state="$(sha256sum "$state_file")"

sed -i 's#^image/jpeg=.*#image/jpeg=some-other-viewer.desktop#' "$mime_store"

RPM_PRESENT="ark gwenview okular" run_install
second_state="$(sha256sum "$state_file")"

[[ "$first_state" == "$second_state" ]]
grep -Fqx 'image/jpeg=some-other-viewer.desktop' "$mime_store"
grep -Fqx 'application/pdf=org.kde.okular.desktop' "$mime_store"
printf 'PASS: rerunning is idempotent and keeps an existing user MIME choice\n'

# --- --force-defaults overrides an existing choice on request ---------------

RPM_PRESENT="ark gwenview okular" run_install --force-defaults
grep -Fqx 'image/jpeg=org.kde.gwenview.desktop' "$mime_store"
grep -Fqx 'application/pdf=org.kde.okular.desktop' "$mime_store"
grep -Fqx 'force_defaults=true' "$state_file"
printf 'PASS: --force-defaults overrides an existing default application\n'

# --- RPM Fusion is enabled before mpv is installed --------------------------

if grep -Fq 'terra' "$command_log"; then
  printf 'Desktop-tools profile must not depend on the Terra repository.\n' >&2
  exit 1
fi
grep -Fq 'rpmfusion' "$command_log"
printf 'PASS: RPM Fusion is enabled for full multimedia codec support\n'

printf 'Desktop-tools package, MIME-association, and idempotency tests passed.\n'
