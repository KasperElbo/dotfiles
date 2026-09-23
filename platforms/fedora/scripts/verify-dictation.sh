#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"
# shellcheck source=../../../common/lib/capabilities.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/capabilities.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
# shellcheck source=../lib/dictation.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/dictation.sh"

verify_reset

# Read-only throughout. Nothing here starts Handy, opens a microphone,
# downloads a model, or reads a transcription: the profile's whole point is
# that dictated text stays on the machine, and a verifier that touched any of
# it would be the one thing in this repository that did not honour that.

state_file="${DICTATION_STATE_FILE:-$(dictation_state_file)}"
sway_config="${DICTATION_SWAY_CONFIG:-$XDG_CONFIG_HOME/sway/config}"

# The Sway binding has one statement in this repository, and it is this row of
# the action registry. scripts/validate-actions.py holds that row against the
# tracked Sway config on every lint, so reading it here means a binding edited
# in one place and not the other fails there rather than quietly changing what
# this verifier looks for. manifest_field comes from common/lib/manifest.sh
# through capabilities.sh, sourced above.
ACTION_MANIFEST="${ACTION_MANIFEST:-$DOTFILES_ROOT/config/actions.tsv}"
DICTATION_SWAY_ACTION_ID="sway.dictation.toggle"

section "Dictation commands"

# handy is the application; wtype is how it puts the transcription into the
# focused window on Wayland. Without wtype Handy silently falls back to a path
# that does not work on wlroots, so a missing wtype is a failure, not a note.
check_command handy
check_command wtype

section "Fedora-owned Wayland dependencies"

# The package list is read from config/capabilities.tsv rather than repeated
# here, so the installer and the verifier cannot disagree about what the
# profile owns.
if ! declared_packages="$(capability_packages fedora dictation)"; then
  fail "Could not read the dictation packages from the capability manifest"
  declared_packages=""
fi

if [[ -n "$declared_packages" ]]; then
  while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    if rpm -q "$package" >/dev/null 2>&1; then
      pass "$package is installed"
    else
      fail "$package is not installed"
    fi
  done <<<"$declared_packages"
fi

section "Handy package ownership"

# What the repository says should be installed. It is read from
# platforms/fedora/lib/dictation.sh, the same file the installer reads, so the
# two cannot drift: a bump changes one file and both sides follow it.
pinned_version="$(dictation_pinned_version)"
pinned_sha256="$(dictation_pinned_sha256)"
pinned_rpm="$(dictation_pinned_rpm)"
pinned_nvra="$(dictation_pinned_nvra)"

# A verifier that cannot read its own expectation has nothing to check against,
# and must say so rather than passing the checks it can still reach.
if [[ ! "$pinned_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  fail "This repository states no usable pinned SHA-256 for Handy, so nothing" \
      "below can establish that what is installed is what it pins; see" \
      "docs/profiles/dictation.md, 'Bumping the pinned Handy release'"
fi

# One owner, and it must be the pinned rpm. An AppImage or a Flatpak installed
# beside it would shadow the rpm on PATH and update on a different schedule,
# which is exactly the duplicate ownership this profile exists to avoid.
#
# Identity, not merely ownership. `rpm -qf` answering at all says only that
# some package claims the file; this compares its name-version-release.arch
# against the pinned artifact's, which is the one fact that ties the binary on
# PATH to the release this repository chose and digest-verified. Checking only
# that *an* rpm owned it accepted a machine running an unrelated build.
#
# Nothing here runs handy. Its version is read from the package database, not
# from the application, because starting a dictation application to interview
# it is exactly the thing this profile promises not to do.
if handy_path="$(command -v handy 2>/dev/null)"; then
  if owning_nvra="$(dictation_owning_nvra "$handy_path")"; then
    if [[ "$owning_nvra" == "$pinned_nvra" ]]; then
      pass "handy is the pinned rpm: $owning_nvra"
    else
      fail "handy at $handy_path belongs to $owning_nvra, not the pinned" \
        "$pinned_nvra; this machine is running a different build from the one" \
        "this repository pins and digest-verified, so rerun" \
        "./install.sh --dictation"
    fi

    # An rpm whose installed files no longer match what it shipped is an
    # altered package: the digest checked at download time says nothing about
    # bytes replaced afterwards. rpm's own database holds the per-file digests,
    # so this asks it rather than recomputing anything, and it neither starts
    # the application nor reads a model or a transcription.
    #
    # A configuration file the operator edited is not tampering, so the `c`
    # attribute is excluded; every other discrepancy is reported.
    if rpm_verify_output="$(rpm -V "$owning_nvra" 2>/dev/null)"; then
      pass "every file $owning_nvra installed still matches what it shipped"
    elif [[ -z "$rpm_verify_output" ]]; then
      # Discrepancies are printed; a non-zero status with nothing to show means
      # rpm could not answer, which is not the same as an intact package and
      # must not be reported as one.
      fail "rpm could not verify the files $owning_nvra installed, so nothing" \
        "here shows that the package on disk is still the one that was" \
        "installed"
    else
      altered="$(awk '$2 != "c" { print }' <<<"$rpm_verify_output")"
      if [[ -n "$altered" ]]; then
        fail "files installed by $owning_nvra no longer match what the" \
          "package shipped, so the verified artifact is not what is on disk" \
          "now: ${altered//$'\n'/; }"
      else
        pass "every file $owning_nvra installed still matches what it shipped"
      fi
    fi
  else
    fail "handy at $handy_path is owned by no rpm; this profile installs" \
      "Handy from a pinned release rpm, so an unowned binary is a second," \
      "unmanaged copy"
  fi
fi

if command_exists flatpak; then
  if flatpak info com.pais.handy >/dev/null 2>&1; then
    fail "Handy is also installed as a Flatpak (com.pais.handy); remove it" \
      "with 'flatpak uninstall com.pais.handy' so the pinned rpm is the" \
      "only owner"
  else
    pass "no duplicate Flatpak installation of Handy"
  fi
else
  pass "flatpak is not installed; no duplicate Flatpak ownership is possible"
fi

section "Recorded dictation profile"

if [[ ! -e "$state_file" ]]; then
  fail "No dictation profile state at $state_file; rerun" \
    "./install.sh --dictation"
elif ! profile_state_validate_file "$state_file" dictation >/dev/null 2>&1; then
  fail "The dictation profile state at $state_file is not readable as a" \
    "dictation profile"
else
  recorded_version="$(profile_state_read "$state_file" version dictation 2>/dev/null || true)"
  recorded_sha="$(profile_state_read "$state_file" sha256 dictation 2>/dev/null || true)"
  recorded_rpm="$(profile_state_read "$state_file" rpm dictation 2>/dev/null || true)"
  recorded_provider="$(profile_state_read "$state_file" provider dictation 2>/dev/null || true)"
  recorded_backend="$(profile_state_read "$state_file" paste_backend dictation 2>/dev/null || true)"

  # State is this profile's own record of what it did, so every value below is
  # checked against the repository's pin rather than accepted for being
  # well-formed. A syntactically valid digest of sixty-four zeroes used to pass
  # here and be reported as a digest-verified rpm.
  if [[ "$recorded_version" == "$pinned_version" ]]; then
    pass "Handy $recorded_version, the release this repository pins"
  else
    fail "the recorded state says Handy ${recorded_version:-no version}, but" \
      "this repository pins $pinned_version; the record is stale, so rerun" \
      "./install.sh --dictation"
  fi

  if [[ ! "$recorded_sha" =~ ^[0-9a-f]{64}$ ]]; then
    fail "the recorded state has no usable SHA-256 for the installed" \
      "artifact, so what is installed cannot be tied to a pinned release"
  elif [[ "$recorded_sha" == "$pinned_sha256" ]]; then
    pass "the installed artifact's digest is the pinned one"
  else
    fail "the recorded state was installed from an artifact whose SHA-256 is" \
      "$recorded_sha, but this repository pins $pinned_sha256; rerun" \
      "./install.sh --dictation"
  fi

  if [[ "$recorded_provider" == "$DICTATION_HANDY_PROVIDER" ]]; then
    pass "provider: $recorded_provider"
  else
    fail "the recorded state names provider" \
      "'${recorded_provider:-none}', not '$DICTATION_HANDY_PROVIDER'; this" \
      "profile owns the pinned-release-rpm route only"
  fi

  if [[ "$recorded_rpm" == "$pinned_rpm" ]]; then
    pass "artifact: $recorded_rpm"
  else
    fail "the recorded state names artifact '${recorded_rpm:-none}', not the" \
      "pinned $pinned_rpm; rerun ./install.sh --dictation"
  fi
  if [[ "$recorded_backend" == wtype ]]; then
    pass "text insertion backend: wtype (no /dev/uinput, no 'input' group)"
  else
    fail "unexpected text-insertion backend '$recorded_backend'; this" \
      "profile owns the wtype path only"
  fi
fi

section "Sway dictation binding"

# The Sway configuration is not one file: the tracked config includes the
# theme and the machine-local ~/.config/sway/local.conf, and for two bindings
# of one key Sway keeps the last one it reads. So the binding is looked for in
# the configuration as Sway loads it, includes expanded in place, and the last
# binding of its key is the one that has to be it. This reads what Sway loads
# on its next start or reload; Sway offers no IPC that lists live bindings.
#
# sway_collect_lines <file>: appends every live top-level line of <file> to
# SWAY_LINES, and the file it came from to SWAY_LINE_FILES, in load order,
# with each include expanded where it stands. Lines inside a block (a mode,
# bar or input) are not default-mode bindings and are left out. Comments are
# dropped, and leading and trailing whitespace, which Sway ignores, trimmed.
SWAY_LINES=()
SWAY_LINE_FILES=()
declare -A SWAY_INCLUDED=()

sway_collect_lines() {
  local file="$1" line depth=0 target included

  [[ -z "${SWAY_INCLUDED[$file]:-}" && -r "$file" ]] || return 0
  SWAY_INCLUDED[$file]=1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" && "$line" != \#* ]] || continue

    if ((depth > 0)); then
      [[ "$line" != *"{" ]] || depth=$((depth + 1))
      [[ "$line" != "}" ]] || depth=$((depth - 1))
      continue
    fi
    if [[ "$line" == *"{" ]]; then
      depth=1
      continue
    fi

    if [[ "$line" =~ ^include[[:space:]]+(.+)$ ]]; then
      # Sway expands an include with wordexp(3): a leading ~, and a path
      # relative to the including file's directory, both glob-expanded.
      target="${BASH_REMATCH[1]}"
      target="${target#[\"\']}"
      target="${target%[\"\']}"
      # shellcheck disable=SC2088 # A literal ~ in the config, expanded here.
      [[ "$target" != "~/"* ]] || target="$HOME/${target#"~/"}"
      [[ "$target" == /* ]] || target="$(dirname -- "$file")/$target"
      while IFS= read -r included; do
        [[ -z "$included" ]] || sway_collect_lines "$included"
      done < <(compgen -G "$target" || true)
      continue
    fi

    SWAY_LINES+=("$line")
    SWAY_LINE_FILES+=("$file")
  done <"$file"
}

# sway_binding_keys: fills SWAY_KEYS with the key each line of SWAY_LINES
# binds or unbinds, empty for any other line, normalised the way Sway
# compares them: each variable substituted as `set` had it at that line
# (longest name first, so $mod never eats $mod2), case folded, and the
# +-separated parts in a fixed order.
SWAY_KEYS=()

sway_binding_keys() {
  local -A variables=()
  local -a words
  local index word name key

  for index in "${!SWAY_LINES[@]}"; do
    SWAY_KEYS[index]=""
    read -r -a words <<<"${SWAY_LINES[index]}"
    case "${words[0]:-}" in
    set)
      [[ "${words[1]:-}" != \$* ]] || variables[${words[1]}]="${words[2]:-}"
      continue
      ;;
    bindsym | unbindsym) ;;
    *) continue ;;
    esac

    for word in "${words[@]:1}"; do
      [[ "$word" != --* ]] || continue
      while IFS= read -r name; do
        [[ -z "$name" ]] || word="${word//"$name"/"${variables[$name]}"}"
      done < <(for name in "${!variables[@]}"; do
        printf '%d %s\n' "${#name}" "$name"
      done | sort -rn | cut -d' ' -f2-)
      key="$(tr '+' '\n' <<<"${word,,}" | sort | tr '\n' '+')"
      SWAY_KEYS[index]="${key%+}"
      break
    done
  done
}

# The compositor owns the key. Handy's own global shortcut cannot be
# registered on a wlroots compositor (no GlobalShortcuts portal), so the
# tracked Sway config is what makes dictation reachable at all.
if [[ -e "$sway_config" ]]; then
  # Ask for the binding as a live line, not as text occurring somewhere in the
  # file. A commented-out `# bindsym $mod+o exec pkill -USR2 -x handy` is
  # exactly the shape a substring search cannot see past, and it is the shape
  # someone leaves behind after turning the key off: Sway ignores the line, the
  # key does nothing, and the check said the toggle was bound.
  #
  # The line comes from config/actions.tsv rather than being written out here,
  # so the binding has one statement in this repository.
  if ! sway_binding_pattern="$(
    manifest_field "$ACTION_MANIFEST" source_pattern id "$DICTATION_SWAY_ACTION_ID"
  )"; then
    fail "config/actions.tsv has no $DICTATION_SWAY_ACTION_ID row, so there is" \
      "no statement of the dictation binding to check $sway_config against"
  else
    sway_collect_lines "$sway_config"
    sway_binding_keys

    # The dictation binding is the live line the registry describes; its key
    # is then whatever that line binds, so the registry stays the one
    # statement of both.
    sway_toggle_index=""
    for index in "${!SWAY_LINES[@]}"; do
      if [[ "${SWAY_LINES[index]}" =~ ^${sway_binding_pattern}$ ]]; then
        sway_toggle_index="$index"
        break
      fi
    done

    if [[ -z "$sway_toggle_index" ]]; then
      fail "$sway_config has no live dictation binding, nor does any file it" \
        "includes; the Sway session owns the dictation key, so without it" \
        "nothing can start a transcription"
    else
      sway_last_index="$sway_toggle_index"
      for index in "${!SWAY_KEYS[@]}"; do
        [[ "${SWAY_KEYS[index]}" != "${SWAY_KEYS[sway_toggle_index]}" ]] ||
          sway_last_index="$index"
      done

      if [[ "${SWAY_LINES[sway_last_index]}" =~ ^${sway_binding_pattern}$ ]]; then
        pass "Sway binds the dictation toggle (pkill -USR2 -x handy)"
      else
        fail "Sway rebinds the dictation key later, in" \
          "${SWAY_LINE_FILES[sway_last_index]}:" \
          "'${SWAY_LINES[sway_last_index]}'; Sway keeps the last binding of a" \
          "key, so the dictation toggle is overridden"
      fi
    fi
  fi
else
  not_observed "No Sway configuration at $sway_config; the dictation binding" \
    "belongs to the optional Sway session and there is none to check here" \
    "(on KDE the shortcut is created by hand, see docs/profiles/dictation.md)"
fi

section "Privacy posture"

# Not a claim that no audio was ever recorded -- nothing can verify that --
# only that this repository is not where any of it could land.
if [[ "$DOTFILES_ROOT" == /* ]] && [[ -d "$DOTFILES_ROOT" ]]; then
  if [[ -e "$DOTFILES_ROOT/.config/com.pais.handy" ]] ||
    [[ -e "$DOTFILES_ROOT/com.pais.handy" ]]; then
    fail "Handy application state exists inside the checkout at" \
      "$DOTFILES_ROOT; models, history and settings belong in" \
      "$HOME/.config/com.pais.handy and must never be committed"
  else
    pass "no Handy models, history or settings inside the checkout"
  fi
fi

finish_verification "Dictation verification"
