# Noctty integration for the portable theme command inside Fedora WSL.

windows_root="${WINDOWS_SYSTEM_ROOT:-/mnt/c/Windows}"
powershell="$windows_root/System32/WindowsPowerShell/v1.0/powershell.exe"

# shellcheck disable=SC2154
case "$flavour" in
latte | frappe | macchiato | mocha) ;;
*)
  printf 'Noctty: refusing invalid Catppuccin flavour: %s\n' "$flavour" >&2
  unset windows_root powershell
  return 1
  ;;
esac

if [[ ! -x "$powershell" ]]; then
  printf 'Noctty: Windows PowerShell executable not found: %s\n' \
    "$powershell" >&2
else
  # The flavour is validated by the portable theme command and again by the
  # Windows helper. Keep Windows PowerShell off the Linux PATH deliberately.
  # shellcheck disable=SC2016
  powershell_command='& (Join-Path $env:LOCALAPPDATA "noctty\dotfiles\set-theme.ps1") -Flavor "'"$flavour"'"'

  if ! "$powershell" \
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -Command "$powershell_command"; then
    printf '%s\n' \
      'Noctty: theme bridge unavailable; rerun platforms\windows\install.ps1 from Windows.' \
      >&2
  fi

  unset powershell_command
fi

unset windows_root powershell
