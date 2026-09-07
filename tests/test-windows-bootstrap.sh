#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/platforms/windows/install.ps1"

[[ -f "$installer" ]]

grep -Fq -- "wsl.exe @arguments" "$installer"
grep -Fq -- "--list', '--online', '--quiet" "$installer"
grep -Fq -- "'^FedoraLinux(?:-\d+)?$'" "$installer"
grep -Fq -- "--set-default-version', '2'" "$installer"
grep -Fq -- "--install', '--distribution', \$Distribution, '--no-launch'" "$installer"
grep -Fq -- "--set-version', \$Distribution, '2'" "$installer"

grep -Fq 'https://get.scoop.sh' "$installer"
grep -Fq 'https://github.com/amanthanvi/scoop-noctty' "$installer"
grep -Fq "'install', 'noctty/noctty'" "$installer"
grep -Fq "command = direct:wsl.exe --distribution \$Distribution" "$installer"
grep -Fq '# BEGIN dotfiles Fedora WSL' "$installer"
grep -Fq 'leaving it unchanged' "$installer"

if grep -Fqi 'winget install' "$installer"; then
  printf 'Windows bootstrap must use the currently supported Noctty Scoop bucket.\n' >&2
  exit 1
fi

if grep -Fq 'FedoraLinux-44' "$installer"; then
  printf 'Windows bootstrap must discover the current Fedora WSL name dynamically.\n' >&2
  exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
  # The variables in this command belong to PowerShell, not Bash.
  # shellcheck disable=SC2016
  pwsh -NoProfile -Command '
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      $args[0], [ref]$tokens, [ref]$errors
    ) | Out-Null
    if ($errors.Count -gt 0) {
      $errors | ForEach-Object { Write-Error $_ }
      exit 1
    }
  ' "$installer"
fi

printf 'Windows Fedora WSL and Noctty bootstrap tests passed.\n'
