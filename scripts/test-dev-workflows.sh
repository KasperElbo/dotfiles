#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/test-dev-workflows.sh [--angular | --python | --all]

Run disposable, network-dependent development workflow smoke tests. The
default is --all. Project dependencies are installed only below a temporary
directory and are removed when the script exits.
EOF
}

run_angular=true
run_python=true

if (($# > 1)); then
  usage >&2
  exit 2
fi

case "${1:---all}" in
--all) ;;
--angular)
  run_python=false
  ;;
--python)
  run_angular=false
  ;;
-h | --help)
  usage
  exit 0
  ;;
*)
  usage >&2
  exit 2
  ;;
esac

test_root="$(mktemp -d)"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi

  rm -rf -- "$test_root"
}

trap cleanup EXIT

run_angular_workflow() {
  require_command node
  require_command npm
  require_command curl

  local project="$test_root/angular-smoke"
  local response="$test_root/angular-response.html"
  local log="$test_root/angular-server.log"
  local port

  port="$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"

  cp -R "$DOTFILES_ROOT/tests/fixtures/angular-smoke" "$project"

  info "Installing project-local Angular dependencies"
  (
    cd "$project"
    npm install --no-audit --no-fund
    npm run format:check
    npm run lint
    npm test -- --watch=false
    npm run build -- --configuration development
    npm run build:debug
  )

  find "$project/dist" -type f -name '*.map' -print -quit |
    grep -q . || die "Angular development build did not emit source maps"

  find "$project/dist/angular-smoke-debug" -type f -name '*.map' -print -quit |
    grep -q . || die "Angular debug build did not emit source maps"

  info "Starting and probing the Angular debug server"
  (
    cd "$project"
    npm run start:debug -- --host 127.0.0.1 --port "$port"
  ) >"$log" 2>&1 &
  server_pid=$!

  local _
  for _ in {1..60}; do
    if curl --fail --silent --show-error \
      "http://127.0.0.1:$port" >"$response" 2>/dev/null; then
      break
    fi

    if ! kill -0 "$server_pid" 2>/dev/null; then
      sed -n '1,200p' "$log" >&2
      die "Angular debug server stopped before becoming ready"
    fi

    sleep 1
  done

  grep -Fq '<app-root>' "$response" || {
    sed -n '1,200p' "$log" >&2
    die "Angular debug server did not return the application shell"
  }

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""

  success "Angular install, format, lint, test, build, debug-build, source-map and debug-serve checks passed"
}

run_python_workflow() {
  require_command uv

  local project="$test_root/python-smoke"
  local output="$test_root/python-output.txt"

  cp -R "$DOTFILES_ROOT/tests/fixtures/python-smoke" "$project"

  info "Resolving the isolated Python environment with uv"
  (
    cd "$project"
    uv sync --all-groups
    uv run python -m dotfiles_smoke >"$output"
    uv run pytest
    uv run ruff check .
    uv run ruff format --check .
    uv build
  )

  grep -Fqx '42' "$output" || die "Python application returned unexpected output"
  find "$project/dist" -type f -name '*.whl' -print -quit |
    grep -q . || die "uv build did not create a Python wheel"

  success "Python resolve, run, test, lint, format and package checks passed"
}

if [[ "$run_angular" == true ]]; then
  run_angular_workflow
fi

if [[ "$run_python" == true ]]; then
  run_python_workflow
fi

success "Disposable development workflow checks passed"
