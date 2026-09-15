# Noctty integration for the portable theme command inside Fedora WSL.
#
# Windows owns the terminal for this profile, so the only theme effect here is
# the Noctty bridge. It is a named action with its own error boundary (issue
# #148): an absent or failing bridge is reported, not silently swallowed and
# not allowed to look like a complete application.

windows_root="${WINDOWS_SYSTEM_ROOT:-/mnt/c/Windows}"
powershell="$windows_root/System32/WindowsPowerShell/v1.0/powershell.exe"

apply_noctty_theme() {
  # The flavour is validated by the portable theme command and again by the
  # Windows helper. Keep Windows PowerShell off the Linux PATH deliberately.
  #
  # The Windows bootstrap may not have run yet. Treat the absent bridge as a
  # normal first-install state rather than invoking a missing script and
  # turning setup output into a PowerShell error.
  local powershell_command
  # $helper and $env: belong to PowerShell; $flavour is set by the caller.
  # shellcheck disable=SC2016,SC2154
  powershell_command='$helper = Join-Path $env:LOCALAPPDATA "noctty\dotfiles\set-theme.ps1"; if (Test-Path -LiteralPath $helper) { & $helper -Flavor "'"$flavour"'" }'

  "$powershell" \
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -Command "$powershell_command" || {
    printf '%s\n' \
      'Noctty: theme bridge unavailable; rerun platforms\windows\install.ps1 from Windows.' \
      >&2
    return 1
  }
}

# shellcheck disable=SC2154
case "$flavour" in
latte | frappe | macchiato | mocha) ;;
*)
  printf 'Noctty: refusing invalid Catppuccin flavour: %s\n' "$flavour" >&2
  unset windows_root powershell
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
  theme_action fedora-wsl:noctty apply_noctty_theme
fi

unset windows_root powershell
