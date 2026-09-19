#!/usr/bin/env bash
set -uo pipefail

# Installed-development workflow smoke tests.
#
# This is user-facing validation of a machine that has already been installed,
# not repository unit testing. Repository tests live in ./scripts/test.sh and
# never touch the network or the installed toolchain.
#
# Each workflow is independently selectable and reports its own result:
#
#   PASS  the workflow ran end to end on this machine
#   FAIL  the workflow ran and something was wrong
#   SKIP  a declared prerequisite is absent, with the reason
#
# A skipped workflow is not a pass and not a failure. Platforms genuinely
# differ: the reduced Parrot profile has no .NET or Node runtime, and saying so
# is more useful than installing runtimes to manufacture parity.
#
# Projects and artifacts exist only below a temporary directory, and every
# workflow's directory is removed as soon as it finishes, including when it
# fails part-way through.

# The library itself, not scripts/lib/common.sh: that wrapper is deprecated and
# announces itself on stderr, into output the Fedora and macOS real-install jobs
# capture and other suites assert on.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib/common.sh"
# Reuse the repository's shared reporting primitives rather than inventing a
# second result vocabulary for user-facing validation.
# shellcheck source=../common/lib/verify.sh
source "$DOTFILES_ROOT/common/lib/verify.sh"
# Selection state decides whether a missing optional toolchain is this
# machine's problem or simply something it was never asked to install.
# shellcheck source=../common/lib/install-lifecycle.sh
source "$DOTFILES_ROOT/common/lib/install-lifecycle.sh"
verify_reset

WORKFLOWS=(dotnet angular python json ocaml latex)
# --all covers the default language environments. The optional OCaml and LaTeX
# profiles are installed on request, so they are requested explicitly too.
DEFAULT_WORKFLOWS=(dotnet angular python json)

usage() {
  cat <<'EOF'
Usage: ./scripts/test-dev-workflows.sh [--all] [--dotnet] [--angular]
                                       [--python] [--json] [--ocaml] [--latex]

Run disposable development workflow smoke tests against this installed
machine. The default is --all, which covers the default language environments
(.NET, Angular/TypeScript, Python, JSON). The optional OCaml and LaTeX
profiles are checked explicitly with --ocaml and --latex.

Selectors combine, so --python --json runs exactly those two.

Each workflow reports PASS, FAIL, or SKIP with a reason, and the command exits
non-zero only when a workflow actually failed. Project sources and generated
artifacts exist only below a temporary directory and are always removed.

This is distinct from ./scripts/test.sh, which runs the repository's own
offline unit, contract and mocked-installer suites.
EOF
}

selected=()
select_workflow() {
  local wanted="$1" existing
  for existing in ${selected[@]+"${selected[@]}"}; do
    [[ "$existing" != "$wanted" ]] || return 0
  done
  selected+=("$wanted")
}

while (($#)); do
  case "$1" in
  --all)
    for workflow in "${DEFAULT_WORKFLOWS[@]}"; do select_workflow "$workflow"; done
    ;;
  --dotnet | --angular | --python | --json | --ocaml | --latex)
    select_workflow "${1#--}"
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    printf 'Unknown option: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  esac
  shift
done

if ((${#selected[@]} == 0)); then
  selected=("${DEFAULT_WORKFLOWS[@]}")
fi

test_root="$(mktemp -d)"
server_pid=""

stop_server() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  server_pid=""
}

cleanup() {
  stop_server
  rm -rf -- "$test_root"
}

trap cleanup EXIT INT TERM

passed=()
failed=()
skipped=()

# A workflow reports a missing prerequisite by calling `unsupported`, which is
# distinct from failing: it means this machine was never meant to run it.
SKIP_REASON=""
unsupported() {
  SKIP_REASON="$*"
  return 1
}

require_commands() {
  local command_name missing=()
  for command_name in "$@"; do
    command_exists "$command_name" || missing+=("$command_name")
  done
  ((${#missing[@]} == 0)) || unsupported "not installed: ${missing[*]}"
}

# Each workflow owns one directory below the temporary root and nothing else,
# so an injected failure cannot leave a generated project behind.
workflow_root() {
  local workflow="$1"
  printf '%s/%s\n' "$test_root" "$workflow"
}

run_workflow() {
  local workflow="$1"
  local root
  root="$(workflow_root "$workflow")"
  mkdir -p "$root"

  SKIP_REASON=""
  section "${workflow} workflow"

  if "prerequisites_$workflow" && "workflow_$workflow" "$root"; then
    pass "$workflow workflow"
    passed+=("$workflow")
  elif [[ -n "$SKIP_REASON" ]]; then
    printf '\033[1;36m?\033[0m SKIP %s: %s\n' "$workflow" "$SKIP_REASON"
    skipped+=("$workflow ($SKIP_REASON)")
  else
    fail "$workflow workflow" || true
    failed+=("$workflow")
  fi

  stop_server
  rm -rf -- "$root"
}

# ---------------------------------------------------------------------------
# .NET
# ---------------------------------------------------------------------------

prerequisites_dotnet() {
  require_commands dotnet
}

workflow_dotnet() {
  local root="$1"
  local project="$root/dotnet-smoke"
  local output="$root/dotnet-output.txt"
  local tests="$root/dotnet-tests"

  info "Creating and exercising a disposable .NET project"
  dotnet new console --output "$project" --no-restore || return 1
  dotnet new xunit --output "$tests" --no-restore || return 1
  (
    cd "$project" || exit 1
    dotnet restore &&
      dotnet build --no-restore &&
      dotnet run --no-build >"$output"
  ) || return 1
  (
    cd "$tests" || exit 1
    dotnet restore && dotnet test --no-restore
  ) || return 1

  grep -Fqx 'Hello, World!' "$output" || {
    warn ".NET application returned unexpected output"
    return 1
  }

  # CSharpier is owned by the project's local tool manifest, so the formatter
  # the editor uses must work from a restored project without any global
  # csharpier on PATH. See nvim-lazyvim/.config/nvim/lua/config/csharpier.lua.
  local formatting="$root/csharpier"
  local formatted="$root/csharpier-formatted.cs"
  # CSharpier reads the buffer from stdin and only uses --stdin-path to locate
  # the project's configuration, which is how Conform drives it. Feed it from a
  # copy so the fixture on disk stays the unformatted input.
  local unformatted="$root/csharpier-input.cs"
  cp -R "$DOTFILES_ROOT/tests/fixtures/dotnet-csharpier" "$formatting" || return 1
  cp "$formatting/src/BadlyFormatted.cs" "$unformatted" || return 1
  (
    cd "$formatting" || exit 1
    dotnet tool restore &&
      dotnet csharpier format --stdin-path src/BadlyFormatted.cs \
        <"$unformatted" >"$formatted"
  ) || {
    warn "project-local CSharpier could not format the disposable fixture"
    return 1
  }
  grep -Fq 'public int Value => 1 + 2;' "$formatted" || {
    warn "project-local CSharpier did not reformat the fixture"
    return 1
  }

  success ".NET create, restore, build, test, run and CSharpier checks passed"
}

# ---------------------------------------------------------------------------
# Angular / TypeScript
# ---------------------------------------------------------------------------

prerequisites_angular() {
  require_commands node npm curl
}

workflow_angular() {
  local root="$1"
  local project="$root/angular-smoke"
  local response="$root/angular-response.html"
  local log="$root/angular-server.log"
  local port

  port="$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')" ||
    return 1

  cp -R "$DOTFILES_ROOT/tests/fixtures/angular-smoke" "$project" || return 1

  info "Installing project-local Angular dependencies"
  (
    cd "$project" || exit 1
    npm install --no-audit --no-fund &&
      npm run format:check &&
      npm run lint &&
      npm test -- --watch=false &&
      npm run build -- --configuration development &&
      npm run build:debug
  ) || return 1

  find "$project/dist" -type f -name '*.map' -print -quit | grep -q . || {
    warn "Angular development build did not emit source maps"
    return 1
  }
  find "$project/dist/angular-smoke-debug" -type f -name '*.map' -print -quit |
    grep -q . || {
    warn "Angular debug build did not emit source maps"
    return 1
  }

  info "Starting and probing the Angular debug server"
  (
    cd "$project" || exit 1
    npm run start:debug -- --host 127.0.0.1 --port "$port"
  ) >"$log" 2>&1 &
  server_pid=$!

  local _
  for _ in {1..60}; do
    # network-source: local-only
    if curl --fail --silent --show-error \
      "http://127.0.0.1:$port" >"$response" 2>/dev/null; then
      break
    fi

    if ! kill -0 "$server_pid" 2>/dev/null; then
      sed -n '1,200p' "$log" >&2
      warn "Angular debug server stopped before becoming ready"
      return 1
    fi

    sleep 1
  done

  grep -Fq '<app-root>' "$response" || {
    sed -n '1,200p' "$log" >&2
    warn "Angular debug server did not return the application shell"
    return 1
  }

  stop_server
  success "Angular install, format, lint, test, build, debug-build, source-map and debug-serve checks passed"
}

# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------

prerequisites_python() {
  require_commands uv
}

workflow_python() {
  local root="$1"
  local project="$root/python-smoke"
  local output="$root/python-output.txt"

  cp -R "$DOTFILES_ROOT/tests/fixtures/python-smoke" "$project" || return 1

  info "Resolving the isolated Python environment with uv"
  (
    cd "$project" || exit 1
    uv sync --all-groups &&
      uv run python -m dotfiles_smoke >"$output" &&
      uv run pytest &&
      uv run ruff check . &&
      uv run ruff format --check . &&
      uv build
  ) || return 1

  grep -Fqx '42' "$output" || {
    warn "Python application returned unexpected output"
    return 1
  }
  find "$project/dist" -type f -name '*.whl' -print -quit | grep -q . || {
    warn "uv build did not create a Python wheel"
    return 1
  }

  success "Python resolve, run, test, lint, format and package checks passed"
}

# ---------------------------------------------------------------------------
# JSON / JSONC
# ---------------------------------------------------------------------------

prerequisites_json() {
  require_commands nvim || return 1
  [[ -d "$XDG_DATA_HOME/nvim/lazy" ]] ||
    unsupported "LazyVim is not installed for this user"
}

workflow_json() {
  local root="$1"
  local fixture="$root/json-workflow"
  local shadow_bin="$root/shadow-bin"

  cp -R "$DOTFILES_ROOT/tests/fixtures/json-workflow" "$fixture" || return 1

  # The editor-owned formatter must win over anything that merely happens to be
  # on PATH, so the check runs with a deliberately shadowing prettier in front.
  mkdir -p "$shadow_bin"
  cat >"$shadow_bin/prettier" <<'EOF'
#!/usr/bin/env bash
printf '{ "shadowing-global-prettier": true }\n'
EOF
  chmod +x "$shadow_bin/prettier"

  info "Editing, validating and formatting disposable JSON and JSONC files"
  PATH="$shadow_bin:$PATH" \
    DOTFILES_JSON_FIXTURE="$fixture" \
    DOTFILES_JSON_SHADOW_PRETTIER="$shadow_bin/prettier" \
    timeout --kill-after=30s 5m \
    nvim --headless \
    -c "luafile $DOTFILES_ROOT/tests/json-workflow.lua" \
    -c 'cquit 1' || return 1

  success "JSON filetype, Treesitter, jsonls, diagnostics and formatting checks passed"
}

# ---------------------------------------------------------------------------
# OCaml
# ---------------------------------------------------------------------------

prerequisites_ocaml() {
  require_commands opam || return 1
  [[ -f "$XDG_CONFIG_HOME/dotfiles/ocaml.conf" ]] ||
    unsupported "the OCaml profile is not installed"
}

workflow_ocaml() {
  local root="$1"
  local state_file="$XDG_CONFIG_HOME/dotfiles/ocaml.conf"
  local switch_name
  local project="$root/ocaml-smoke"
  local output="$root/ocaml-output.txt"
  local rules="$root/ocaml-rules.sexp"

  "$DOTFILES_ROOT/common/verify-ocaml.sh" || return 1

  switch_name="$(awk -F= '$1 == "switch" { print $2 }' "$state_file")"
  cp -R "$DOTFILES_ROOT/tests/fixtures/ocaml-smoke" "$project" || return 1

  info "Resolving and exercising the disposable OCaml project"
  (
    cd "$project" || exit 1
    opam install --switch "$switch_name" --yes . --deps-only --with-test &&
      opam exec --switch "$switch_name" -- dune describe rules >"$rules"
  ) || return 1

  grep -Fq '_build/default/bin/main.bc' "$rules" || {
    warn "Dune rule discovery did not expose the fixture bytecode target"
    return 1
  }

  (
    cd "$project" || exit 1
    opam exec --switch "$switch_name" -- dune build _build/default/bin/main.bc &&
      opam exec --switch "$switch_name" -- dune build &&
      opam exec --switch "$switch_name" -- dune exec dotfiles-smoke >"$output" &&
      opam exec --switch "$switch_name" -- dune runtest &&
      opam exec --switch "$switch_name" -- dune build @fmt
  ) || return 1

  find "$project/_build/default" -type f -name '*.bc' -print -quit | grep -q . || {
    warn "OCaml workflow did not produce a bytecode executable"
    return 1
  }
  grep -Fqx '42' "$output" || {
    warn "OCaml application returned unexpected output"
    return 1
  }

  success "OCaml resolve, build, run, test, format and bytecode checks passed"
}

# ---------------------------------------------------------------------------
# LaTeX
# ---------------------------------------------------------------------------

# TeX ownership differs per platform, and the same missing latexmk means two
# different things. Where the installer owns a selected LaTeX capability, a
# missing tool is a broken install and must fail. Where TeX is externally
# managed -- macOS -- the absence is expected and is a skip that names who owns
# the prerequisite, so nobody reads it as a repository defect.
prerequisites_latex() {
  local command_name platform owner
  local missing=()

  for command_name in biber latexindent latexmk pdflatex; do
    command_exists "$command_name" || missing+=("$command_name")
  done
  ((${#missing[@]} > 0)) || return 0

  if install_lifecycle_capability_selected latex; then
    warn "the LaTeX capability is recorded as installed, but the installer-owned" \
      "tools are missing: ${missing[*]}"
    return 1
  fi

  platform="$(install_lifecycle_platform 2>/dev/null || true)"
  case "$platform" in
  macos)
    owner="TeX is externally managed on macOS; install MacTeX or BasicTeX yourself, see docs/platforms/macos.md"
    ;;
  fedora | fedora-wsl)
    owner="rerun the installer with --latex to have the distribution own them"
    ;;
  *)
    owner="no LaTeX capability is recorded as installed on this machine"
    ;;
  esac
  unsupported "not installed: ${missing[*]} ($owner)"
}

workflow_latex() {
  local root="$1"
  local project="$root/latex-smoke"
  local formatted="$root/details-formatted.tex"
  local failed_build_log="$root/latex-expected-failure.log"

  cp -R "$DOTFILES_ROOT/tests/fixtures/latex-smoke" "$project" || return 1

  info "Formatting and building the disposable multi-file LaTeX project"
  latexindent "$project/sections/details.tex" >"$formatted" || return 1
  grep -Fq '\section{Details}' "$formatted" || {
    warn "latexindent did not return the fixture document"
    return 1
  }

  (
    cd "$project" || exit 1
    latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex
  ) || return 1

  [[ -s "$project/main.pdf" ]] || {
    warn "latexmk did not create main.pdf"
    return 1
  }
  grep -Fq 'VimTeX' "$project/main.bbl" || {
    warn "latexmk/Biber did not resolve the fixture bibliography"
    return 1
  }

  printf '\n\\ThisCommandDeliberatelyDoesNotExist\n' \
    >>"$project/sections/details.tex"

  if (
    cd "$project" || exit 1
    latexmk -g -pdf -file-line-error -interaction=nonstopmode \
      -halt-on-error main.tex
  ) >"$failed_build_log" 2>&1; then
    warn "the deliberately invalid LaTeX document unexpectedly compiled"
    return 1
  fi

  grep -Fq 'Undefined control sequence' "$project/main.log" || {
    warn "the deliberate compile error was not recorded in main.log"
    return 1
  }
  grep -Eq 'sections/details\.tex:[0-9]+:' "$project/main.log" || {
    warn "the compile error did not include a quickfix-compatible file and line"
    return 1
  }

  success "LaTeX formatting, multi-file build, Biber, PDF and error-log checks passed"
}

# ---------------------------------------------------------------------------

for workflow in "${WORKFLOWS[@]}"; do
  for requested in "${selected[@]}"; do
    [[ "$requested" == "$workflow" ]] || continue
    run_workflow "$workflow"
    break
  done
done

printf '\nDevelopment workflow summary — installed-machine evidence\n'
printf '  passed:  %d\n' "${#passed[@]}"
printf '  failed:  %d\n' "${#failed[@]}"
printf '  skipped: %d\n' "${#skipped[@]}"

if ((${#skipped[@]} > 0)); then
  printf '\nSkipped workflows:\n'
  printf '  - %s\n' "${skipped[@]}"
fi

if ((${#failed[@]} > 0)); then
  printf '\nFailed workflows:\n' >&2
  printf '  - %s\n' "${failed[@]}" >&2
  exit 1
fi

success "Disposable development workflow checks completed"
