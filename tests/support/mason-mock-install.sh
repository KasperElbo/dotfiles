#!/usr/bin/env bash
set -euo pipefail

# Leave behind what a finished Mason install leaves behind, so a mocked
# bootstrap produces evidence that common/lib/mason.sh accepts and a suite can
# damage on purpose.
#
# Usage: mason-mock-install.sh [--pins <file>] <mason_root> <package[@version]> ...
#
# --pins names a common/mason-package-versions.txt-shaped file. A target that
# carries no "@version" of its own is then installed at the version that file
# pins it to, which is how a fixture models a machine the pins are satisfied
# on rather than one the verifier is about to report.
#
# <mason_root> is the directory holding "packages" and "bin", which is
# $XDG_DATA_HOME/nvim/mason. Mason stores a package under its plain name
# whether or not the request carried an "@version" pin, and records the
# resolved version in the receipt's purl, so that is what this writes.
#
# A real install extracts the package's files, links its executables into
# <root>/bin and only then writes <package>/mason-receipt.json. The order
# matters to what a suite can model: removing the receipt leaves exactly the
# tree an interrupted install leaves.

pin_file=""
if [[ "${1:-}" == --pins ]]; then
  pin_file="${2:?--pins requires a file}"
  shift 2
fi

mason_root="${1:?mason root is required}"
shift

# The version <pin_file> records for a package, or nothing.
pinned_version() {
  [[ -n "$pin_file" ]] || return 0
  awk -v package="$1" '$1 == package { print $2; exit }' \
    <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$pin_file")
}

# The executable a package exposes is registry data this mock cannot know, so
# it uses the package's own name, except where this repository depends on a
# different one by name.
mock_bin_name() {
  case "$1" in
  tree-sitter-cli) printf 'tree-sitter\n' ;;
  *) printf '%s\n' "$1" ;;
  esac
}

mkdir -p "$mason_root/bin"

for target in "$@"; do
  package="${target%%@*}"
  version="${target#"$package"}"
  version="${version#@}"
  [[ -n "$version" ]] || version="$(pinned_version "$package")"
  [[ -n "$version" ]] || version="1.0.0-mock"
  bin_name="$(mock_bin_name "$package")"
  package_dir="$mason_root/packages/$package"

  mkdir -p "$package_dir"
  cat >"$package_dir/$bin_name" <<'PAYLOAD'
#!/usr/bin/env bash
exit 0
PAYLOAD
  chmod +x "$package_dir/$bin_name"
  ln -sf "../packages/$package/$bin_name" "$mason_root/bin/$bin_name"

  # Schema 2.0, the shape mason.nvim writes at the commit
  # nvim-lazyvim/.config/nvim/lazy-lock.json pins.
  cat >"$package_dir/mason-receipt.json" <<RECEIPT
{
  "name": "$package",
  "schema_version": "2.0",
  "metrics": { "start_time": 0, "completion_time": 1 },
  "source": { "type": "registry+v1", "id": "pkg:mock/$package@$version" },
  "registry": { "proto": "github" },
  "install_options": {},
  "links": { "bin": { "$bin_name": "$bin_name" }, "share": {}, "opt": {} }
}
RECEIPT
done
