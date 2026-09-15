#!/usr/bin/env bash
set -euo pipefail

# CSharpier is owned by the .NET project's local tool manifest. Two layers of
# evidence:
#
#   1. The Conform contract itself, always: the editor may only ever invoke
#      `dotnet csharpier`, and only inside a project that declares the tool.
#   2. A disposable .NET fixture, when a .NET SDK is present: the configured
#      invocation really formats, does not need a bare `csharpier` on PATH,
#      ignores a deliberately shadowing one, and reports an actionable message
#      when the local tool has not been restored.
#
# Layer 2 needs the .NET SDK and the NuGet registry, so it reports SKIP with a
# reason on hosts that do not have them rather than weakening layer 1.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'CSharpier ownership test failed: %s\n' "$*" >&2
  exit 1
}

skip() {
  printf 'SKIP: %s\n' "$*"
}

command -v nvim >/dev/null 2>&1 || fail "nvim is required for the Conform contract test"

fixture="$test_root/dotnet-csharpier"
unrelated="$test_root/unrelated-project"
cp -R "$repo_root/tests/fixtures/dotnet-csharpier" "$fixture"
mkdir -p "$unrelated"
printf 'class Unrelated { }\n' >"$unrelated/Program.cs"

argv_file="$test_root/argv.txt"
lua_output="$test_root/contract.out"
if ! env \
  "DOTFILES_CSHARPIER_FIXTURE=$fixture" \
  "DOTFILES_CSHARPIER_UNRELATED=$unrelated" \
  "DOTFILES_CSHARPIER_ARGV_OUT=$argv_file" \
  nvim --headless -u NONE -i NONE -l tests/test-csharpier-contract.lua \
  >"$lua_output" 2>&1; then
  sed 's/^/  /' "$lua_output" >&2
  fail "the CSharpier Conform contract is not satisfied"
fi
printf 'PASS: Conform invokes CSharpier through the project-local .NET tool\n'

# The repository must not acquire a second CSharpier through any other manager.
for owned_elsewhere in \
  "$repo_root/mise/.config/mise/config.toml" \
  "$repo_root/nvim-lazyvim/.config/nvim/mason-packages.txt" \
  "$repo_root/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/mason-packages.txt"; do
  if grep -Fiq csharpier "$owned_elsewhere"; then
    fail "CSharpier is declared outside the .NET project: $owned_elsewhere"
  fi
done
printf 'PASS: no duplicate CSharpier provider is declared\n'

mapfile -t formatter_argv <"$argv_file"
((${#formatter_argv[@]} > 0)) || fail "the resolved Conform invocation is empty"
[[ "${formatter_argv[0]}" == dotnet ]] ||
  fail "the resolved formatter command is not the .NET SDK: ${formatter_argv[0]}"

if ! command -v dotnet >/dev/null 2>&1; then
  skip "disposable .NET formatting fixture: the .NET SDK is not installed"
  printf 'CSharpier project-local ownership checks passed.\n'
  exit 0
fi

export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
# A local tool is resolved from the NuGet package store and the SDK's tool
# resolver cache, so a developer's own caches would make the unrestored case
# indistinguishable from a restored one. Give the fixture disposable caches: it
# starts genuinely unrestored, and `dotnet tool restore` is then the step that
# makes formatting work.
export NUGET_PACKAGES="$test_root/nuget"
export DOTNET_CLI_HOME="$test_root/dotnet-home"
mkdir -p "$DOTNET_CLI_HOME"

# A global CSharpier must never be reached. Any invocation of this shadow is a
# failure, and it is the only `csharpier` on PATH for the rest of the run.
shadow_bin="$test_root/shadow-bin"
shadow_log="$test_root/shadow.log"
mkdir -p "$shadow_bin"
cat >"$shadow_bin/csharpier" <<EOF
#!/usr/bin/env bash
printf 'shadowing global csharpier was invoked: %s\n' "\$*" >>"$shadow_log"
printf '// formatted by the shadowing global csharpier\n'
exit 0
EOF
chmod +x "$shadow_bin/csharpier"
export PATH="$shadow_bin:$PATH"

source_file="src/BadlyFormatted.cs"
unrestored_output="$test_root/unrestored.out"
if (cd "$fixture" && "${formatter_argv[@]/\$FILENAME/$source_file}" \
  <"$fixture/$source_file" >/dev/null 2>"$unrestored_output"); then
  fail "an unrestored local tool formatted the fixture anyway"
fi
if ! grep -Fq 'dotnet tool restore' "$unrestored_output"; then
  # The SDK prints the restore hint on stdout in some versions; Conform shows
  # whichever stream carried it, so accept either here.
  (cd "$fixture" && "${formatter_argv[@]/\$FILENAME/$source_file}" \
    <"$fixture/$source_file" >"$unrestored_output" 2>&1) || true
  grep -Fq 'dotnet tool restore' "$unrestored_output" ||
    fail "an unrestored local tool did not report an actionable restore message"
fi
printf 'PASS: an unrestored local tool reports how to restore it\n'

if ! (cd "$fixture" && dotnet tool restore) >"$test_root/restore.log" 2>&1; then
  sed 's/^/  /' "$test_root/restore.log" >&2
  skip "disposable .NET formatting fixture: 'dotnet tool restore' is unavailable offline"
  printf 'CSharpier project-local ownership checks passed.\n'
  exit 0
fi

formatted="$test_root/formatted.cs"
(cd "$fixture" && "${formatter_argv[@]/\$FILENAME/$source_file}" \
  <"$fixture/$source_file" >"$formatted") ||
  fail "the configured CSharpier invocation failed after 'dotnet tool restore'"

[[ -s "$formatted" ]] || fail "the configured CSharpier invocation produced no output"
grep -Fq 'public int Value => 1 + 2;' "$formatted" ||
  fail "the fixture was not reformatted by CSharpier"

# The project's own pinned tool is the reference implementation: the editor
# must produce byte-identical output, not merely something plausible.
reference="$test_root/reference.cs"
(cd "$fixture" && dotnet tool run csharpier format --stdin-path "$source_file" \
  <"$fixture/$source_file" >"$reference") ||
  fail "the fixture's pinned CSharpier could not be invoked directly"
cmp -s "$formatted" "$reference" ||
  fail "editor formatting differs from the project's pinned CSharpier"
printf 'PASS: editor formatting matches the project pinned CSharpier exactly\n'

[[ ! -e "$shadow_log" ]] ||
  fail "a shadowing global csharpier was used: $(cat "$shadow_log")"
printf 'PASS: a shadowing global csharpier on PATH is never used\n'

printf 'CSharpier project-local ownership checks passed.\n'
