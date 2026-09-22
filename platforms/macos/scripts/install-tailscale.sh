#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
# shellcheck source=../lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/macos.sh"

require_apple_silicon_macos
require_native_homebrew
activate_homebrew_path

info "Installing the optional Tailscale profile (Standalone macOS app)"
"$(homebrew_path)" install --cask tailscale-app

state_file="$XDG_CONFIG_HOME/dotfiles/macos-tailscale.conf"
profile_state_write "$state_file" tailscale installed variant=standalone-app

info "Opening Tailscale so macOS can request its Network Extension permission"
open -a Tailscale || warn "Open Tailscale manually from /Applications"

success "Optional Tailscale profile installed"

# ---------------------------------------------------------------------------
# What is left for the person to do
#
# The closing guidance reports what this machine actually looks like rather
# than assuming a fresh install: a machine that was already signed in, with the
# command-line tool already enabled, must not be told to do either again. The
# command-line tool is looked for in both places it can be - on PATH (the app's
# Settings -> CLI "Install Now" puts it at /usr/local/bin/tailscale) and inside
# the application bundle - and the connection state is read through whichever
# of them answers.
#
# Everything below is read-only: nothing here signs in, brings the tailnet up
# or installs the command-line tool. And none of it can fail the step, which
# has already done its install work: a probe that is missing, fails, hangs or
# answers with something unrecognized leaves the state unknown, and an unknown
# state gets the full interactive guidance a fresh install gets.
# ---------------------------------------------------------------------------

tailscale_path_cli="$(type -P tailscale 2>/dev/null || true)"
tailscale_bundle_cli="$(macos_applications_dir)/Tailscale.app/Contents/MacOS/Tailscale"
[[ -x "$tailscale_bundle_cli" ]] || tailscale_bundle_cli=""

tailscale_state=""
tailscale_state_problem="no Tailscale command-line tool was found to ask"
if ! command_exists jq; then
  tailscale_state_problem="jq is not available to read 'tailscale status --json'"
else
  for tailscale_cli in "$tailscale_path_cli" "$tailscale_bundle_cli"; do
    [[ -n "$tailscale_cli" ]] || continue
    info "Reading Tailscale's connection state with $tailscale_cli"
    status_json=""
    status_probe=0
    status_json="$(macos_tailscale_probe "$tailscale_cli" status --json 2>/dev/null)" ||
      status_probe=$?
    if ((status_probe == 0)); then
      tailscale_state="$(printf '%s' "$status_json" |
        jq -r '.BackendState // empty' 2>/dev/null | head -n 1 || true)"
      [[ -n "$tailscale_state" ]] && break
      tailscale_state_problem="'tailscale status --json' did not report a BackendState"
    elif macos_tailscale_probe_timed_out "$status_probe"; then
      # The application itself is not answering, so asking it again through
      # the other path would only wait out a second bound.
      tailscale_state_problem="'tailscale status --json' did not answer within ${DOTFILES_TAILSCALE_PROBE_TIMEOUT}s"
      break
    else
      tailscale_state_problem="'tailscale status --json' failed"
    fi
  done
fi

case "$tailscale_state" in
Running) tailscale_connection=connected ;;
NeedsLogin | NoState | Stopped | Starting | NeedsMachineAuth)
  tailscale_connection=not-connected
  ;;
"") tailscale_connection=unknown ;;
*)
  tailscale_connection=unknown
  tailscale_state_problem="Tailscale reported an unrecognized BackendState: $tailscale_state"
  ;;
esac

printf '\n'
if [[ "$tailscale_connection" == connected && -n "$tailscale_path_cli" ]]; then
  printf 'Tailscale is connected to a tailnet and the tailscale command is\n'
  printf 'available at %s. Nothing is left to set up.\n' "$tailscale_path_cli"
else
  case "$tailscale_connection" in
  connected)
    printf 'Tailscale is connected to a tailnet.\n'
    ;;
  not-connected)
    printf 'Tailscale is installed but not connected yet (it reports %s).\n' \
      "$tailscale_state"
    ;;
  unknown)
    printf 'Tailscale is installed, but its connection state could not be read\n'
    printf '(%s).\n' "$tailscale_state_problem"
    ;;
  esac

  if [[ "$tailscale_connection" != connected ]]; then
    cat <<'EOF'

Finish setup interactively:

  1. Approve the Network Extension permission prompt (or grant it later in
     System Settings -> General -> Login Items & Extensions -> Network
     Extensions).
  2. Open the Tailscale menu-bar icon and sign in to your tailnet.
EOF
  fi

  printf '\n'
  if [[ -n "$tailscale_path_cli" ]]; then
    printf 'The tailscale command is available at %s.\n' "$tailscale_path_cli"
  else
    cat <<'EOF'
Optional: enable the command-line tool from the Tailscale app's Settings ->
CLI section ("Install Now"; installs to /usr/local/bin/tailscale and asks
for your admin password once).
EOF
    if [[ -n "$tailscale_bundle_cli" ]]; then
      printf 'Until then, use the app bundle path:\n\n    %s status\n' \
        "$tailscale_bundle_cli"
    fi
  fi
fi

cat <<'EOF'

No account/tailnet policy is set by this installer. See
docs/profiles/tailscale.md for common follow-up commands.

EOF
