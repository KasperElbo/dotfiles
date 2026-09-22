# Noctty integration for the portable theme command inside Fedora WSL.
#
# Windows owns the terminal for this profile, so the only theme effect here is
# the Noctty bridge. It is a named action with its own error boundary (issue
# #148): an absent or failing bridge is reported, not silently swallowed and
# not allowed to look like a complete application.

windows_root="${WINDOWS_SYSTEM_ROOT:-/mnt/c/Windows}"
powershell="$windows_root/System32/WindowsPowerShell/v1.0/powershell.exe"

# The status the bridge exits with when the Windows-side helper is not there.
# It has to be a status rather than silence: PowerShell exits 0 after doing
# nothing, and a bridge that did nothing is not a flavour that was applied.
noctty_bridge_absent=3

apply_noctty_theme() {
  # The flavour is validated by the portable theme command and again by the
  # Windows helper. Keep Windows PowerShell off the Linux PATH deliberately.
  #
  # The Windows bootstrap may not have run yet. That is a normal first-install
  # state rather than a failure, but it is not an application either, so the
  # command says which of the two it was instead of invoking a missing script
  # and turning setup output into a PowerShell error.
  local powershell_command
  # $helper and $env: belong to PowerShell; $flavour is set by the caller.
  # shellcheck disable=SC2016,SC2154
  powershell_command='$helper = Join-Path $env:LOCALAPPDATA "noctty\dotfiles\set-theme.ps1"; if (-not (Test-Path -LiteralPath $helper)) { exit '"$noctty_bridge_absent"' }; & $helper -Flavor "'"$flavour"'"'

  # The status is passed through rather than collapsed to 1: the caller tells
  # an absent helper from a failed one by exactly that number, and a `|| return
  # 1` here is what would hide the difference again.
  local status=0
  "$powershell" \
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -Command "$powershell_command" || status=$?

  ((status != noctty_bridge_absent)) || return "$status"

  ((status == 0)) || {
    printf '%s\n' \
      'Noctty: theme bridge unavailable; rerun platforms\windows\install.ps1 from Windows.' \
      >&2
    return "$status"
  }
}

# shellcheck disable=SC2154
case "$flavour" in
latte | frappe | macchiato | mocha) ;;
*)
  printf 'Noctty: refusing invalid Catppuccin flavour: %s\n' "$flavour" >&2
  unset windows_root powershell noctty_bridge_absent
  return 1
  ;;
esac

# Windows owns the terminal here, so Ghostty guidance from the portable
# command would be wrong on this profile.
theme_note_ghostty_handled

if [[ ! -x "$powershell" ]]; then
  theme_action_skipped fedora-wsl:noctty \
    "Windows PowerShell was not found at $powershell"
else
  # Three outcomes, not two. PowerShell being present says nothing about the
  # Windows bootstrap having run, and that middle state -- PowerShell there,
  # set-theme.ps1 not installed -- is the normal one on any WSL machine whose
  # Windows half is still to come.
  theme_action_or_skip fedora-wsl:noctty "$noctty_bridge_absent" \
    'the Noctty helper is not installed; run platforms\windows\install.ps1 from Windows' \
    apply_noctty_theme
fi

unset windows_root powershell noctty_bridge_absent
