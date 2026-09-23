#!/usr/bin/env bash

# Mason package identity.
#
# Mason records an installation in <package>/mason-receipt.json, and it writes
# that file last: the staging directory is promoted, the bin/share/opt links
# are made, and only then is the receipt written. A package directory is
# therefore evidence that an installation was *started*, never that one
# finished. An interrupted install, a half-deleted package and a package that
# converged are all directories.
#
# This library is the one place that decides what "installed" means, so the
# verifier and the installer cannot drift apart: the verifier would otherwise
# pass a package the installer would have to repair, or the installer would
# skip one the verifier would fail. It is also where a pinned version is
# compared, because a package that exists at the wrong version is a repair
# candidate and not a missing one.
#
# It is written for Apple's Bash 3.2 (no mapfile, no associative arrays), like
# lib/verify.sh, because the macOS verifier may run under /bin/bash.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# Sourced by both lib/verify.sh and common/install-neovim-tools.sh, so the
# marker keeps a second source a no-op, as lib/common.sh's does.
# shellcheck disable=SC2034
DOTFILES_MASON_LOADED=true

# Set by mason_package_status and read by its callers.
MASON_PACKAGE_STATE=""
# shellcheck disable=SC2034
MASON_PACKAGE_DETAIL=""
# shellcheck disable=SC2034
MASON_PACKAGE_VERSION=""

# Set by mason_load_version_pins; MASON_VERSION_PINS is read by
# mason_version_pin and MASON_ERROR by its callers.
MASON_VERSION_PINS=""
# shellcheck disable=SC2034
# shellcheck disable=SC2034
MASON_ERROR=""

MASON_RECEIPT_NAME="mason-receipt.json"

# mason_root [data_home]
#
# Mason's install location: packages live under <root>/packages and the linked
# executables under <root>/bin. Both halves of this library address the root
# rather than the package directory, because a package's identity includes the
# links it claims to own outside its own directory.
mason_root() {
  printf '%s\n' "${1:-${XDG_DATA_HOME:-$HOME/.local/share}}/nvim/mason"
}

# mason_require_jq
#
# The receipt is JSON, and reading it with anything less than a JSON parser
# would accept a truncated or corrupt receipt as a valid one -- exactly the
# state this library exists to reject. jq is a baseline package on every
# platform whose installer or verifier reaches this code, so its absence is an
# error and never a quietly skipped check.
mason_require_jq() {
  command_exists jq && return 0
  # shellcheck disable=SC2034
  MASON_ERROR="jq is required to read Mason receipts and is not installed"
  return 1
}

# mason_percent_decode <value>
#
# A purl component is percent-encoded (RFC 3986). Only a "%" followed by two
# hexadecimal digits is an escape; every other "%" is a literal one the value
# is entitled to keep. printf '%b' over the whole string is not used, because
# it would also expand a backslash that came out of the receipt.
mason_percent_decode() {
  local value="$1" decoded="" rest="$1" literal escape

  case "$value" in
  *%*) ;;
  *)
    printf '%s\n' "$value"
    return 0
    ;;
  esac

  while [[ "$rest" == *%* ]]; do
    literal="${rest%%%*}"
    rest="${rest#*%}"
    escape="${rest:0:2}"
    decoded="$decoded$literal"
    if [[ "$escape" == [0-9A-Fa-f][0-9A-Fa-f] ]]; then
      decoded="$decoded$(printf "%b" "\\x$escape")"
      rest="${rest:2}"
    else
      decoded="$decoded%"
    fi
  done
  printf '%s\n' "$decoded$rest"
}

# mason_purl_version <purl>
#
# A Mason receipt names its source as a purl, "pkg:<type>/<namespace>/<name>@
# <version>?<qualifiers>#<subpath>". The namespace and name percent-encode any
# "@" they contain (a scoped npm package arrives as "%40scope%2Fname"), so the
# last unencoded "@" starts the version and nothing else can.
mason_purl_version() {
  local purl="$1" version

  [[ "$purl" == pkg:* ]] || return 1
  version="${purl%%#*}"
  version="${version%%\?*}"
  [[ "$version" == *@* ]] || return 1
  version="${version##*@}"
  [[ -n "$version" ]] || return 1
  mason_percent_decode "$version"
}

_mason_result() {
  MASON_PACKAGE_STATE="$1"
  # shellcheck disable=SC2034
  MASON_PACKAGE_DETAIL="$2"
  [[ "$1" == installed ]]
}

# mason_package_status <mason_root> <package> [expected_version]
#
# Decide whether <package> is installed, using Mason's own installation
# metadata and the artifacts that metadata claims, rather than the existence of
# a directory. Sets MASON_PACKAGE_STATE to one of:
#
#   installed         converged, and at <expected_version> when one was given
#   absent            no package directory at all
#   incomplete        a directory that does not carry a finished installation
#   version-mismatch  a finished installation of the wrong version
#
# MASON_PACKAGE_DETAIL carries the reason in a form fit to show a user, and
# MASON_PACKAGE_VERSION the version the receipt records when one could be read.
# Returns 0 only for "installed"; every other state is a repair candidate, and
# only "absent" is a fresh install.
mason_package_status() {
  local mason_root="$1" package="$2" expected_version="${3:-}"
  local package_dir="$mason_root/packages/$package"
  local receipt="$package_dir/$MASON_RECEIPT_NAME"
  local record name="" purl="" entry payload="false" links_state=""
  local field kind link_name link_target link_path
  local resolved_link resolved_target

  # shellcheck disable=SC2034
  MASON_PACKAGE_STATE=""
  # shellcheck disable=SC2034
  MASON_PACKAGE_DETAIL=""
  # shellcheck disable=SC2034
  MASON_PACKAGE_VERSION=""

  if [[ ! -d "$package_dir" ]]; then
    _mason_result absent "no package directory at $package_dir"
    return
  fi
  if [[ ! -e "$receipt" ]]; then
    _mason_result incomplete \
      "no Mason receipt at $receipt; Mason writes it last, so this installation did not finish"
    return
  fi
  if [[ ! -f "$receipt" || ! -r "$receipt" ]]; then
    _mason_result incomplete "Mason receipt could not be read: $receipt"
    return
  fi

  if ! record="$(jq -r '
      ["name", ((.name | strings) // "")],
      ["purl", ((((.source | objects).id) // ((.primary_source | objects).id) | strings) // "")],
      ["links", (
        if (.links | type) != "object" then "absent"
        elif (.links.bin | type) != "object" then "no-bin-object"
        else (.links.bin | length | tostring)
        end
      )],
      (((.links | objects).bin | objects) // {} | to_entries[] | ["bin", .key, (.value | tostring)])
      | @tsv
    ' "$receipt" 2>/dev/null)"; then
    _mason_result incomplete "Mason receipt is not valid JSON: $receipt"
    return
  fi

  while IFS="$(printf '\t')" read -r kind field link_target; do
    case "$kind" in
    name) name="$field" ;;
    purl) purl="$field" ;;
    links) links_state="$field" ;;
    bin)
      link_name="$field"
      link_path="$mason_root/bin/$link_name"
      if [[ ! -x "$link_path" ]]; then
        _mason_result incomplete \
          "the receipt claims the executable $mason_root/bin/$link_name, which is missing or not executable"
        return
      fi
      if [[ ! -e "$package_dir/$link_target" ]]; then
        _mason_result incomplete \
          "the receipt claims $package_dir/$link_target, which is missing"
        return
      fi
      # Both artifacts existing says nothing about the link joining them. Any
      # executable of the same name in Mason's bin directory satisfied the two
      # tests above -- /bin/true, another package's binary, an unrelated
      # script -- while the report said this package was installed and the
      # installer never queued it for repair.
      #
      # On macOS and Linux Mason makes every bin entry the same way: a
      # relative symlink from <root>/bin/<name> to the path the receipt
      # records under links.bin (mason-core/installer/linker.lua, symlink(),
      # at the mason.nvim commit lazy-lock.json pins). The packages whose
      # executable comes through npm:, pyvenv:, dotnet: and the other
      # delegated schemes are no exception: the wrapper script those schemes
      # generate is written INSIDE the package directory, and the receipt
      # records it as the link target (mason-core/installer/compiler/link.lua
      # and InstallContext:write_shell_exec_wrapper). A real macOS install
      # agrees: all twenty entries in its bin directory are relative symlinks
      # into ../packages, debugpy (pyvenv:) and roslyn (dotnet:) to their
      # wrappers and every npm: package to node_modules/.bin/<exec>. Only
      # Windows writes a .cmd file in place of a link, and this library never
      # runs there.
      #
      # So an entry that is not a symlink was not made by Mason, whatever it
      # runs, and the question "does it point at what the receipt claims"
      # always has an exact answer. Both sides are canonicalized, so a
      # relative and an absolute spelling of one file agree and so does a
      # mason root reached through a symlink.
      if [[ ! -L "$link_path" ]]; then
        _mason_result incomplete \
          "$mason_root/bin/$link_name is not a symlink; Mason links every executable into its package, so this is not the link Mason made"
        return
      fi

      resolved_link="$(resolve_existing_path "$link_path" 2>/dev/null || true)"
      resolved_target="$(resolve_existing_path "$package_dir/$link_target" 2>/dev/null || true)"

      if [[ -z "$resolved_link" || -z "$resolved_target" ]]; then
        _mason_result incomplete \
          "$mason_root/bin/$link_name could not be resolved against the $package_dir/$link_target the receipt claims"
        return
      fi

      if [[ "$resolved_link" != "$resolved_target" ]]; then
        _mason_result incomplete \
          "$mason_root/bin/$link_name resolves to $resolved_link, not the $package_dir/$link_target the receipt claims"
        return
      fi
      ;;
    esac
  done <<EOF
$record
EOF

  # A receipt with no links object is not a receipt Mason wrote: links is a
  # fixed field of the schema, carrying bin, share and opt, and deleting it
  # made the strictest part of this check vanish while the package still
  # reported installed. Reading the links object is therefore a precondition
  # for trusting the rest of the receipt, not a check of its own.
  #
  # An EMPTY links.bin is the same damage by another route: no bin row, so no
  # link check. Mason fills links.bin from the package spec's bin table and
  # nothing else (compiler/link.lua expand_bin, then linker.lua link), so a
  # receipt links no executable only when its registry entry declares none.
  # Every package in both Neovim inventories declares at least one, on every
  # platform target it ships, so an empty links.bin is not a receipt Mason
  # wrote for any package this repository installs. A package that links only
  # share or opt would be reported here by name, which is where to start if
  # an inventory ever gains one.
  case "$links_state" in
  absent)
    _mason_result incomplete \
      "the receipt in $package_dir carries no links object; Mason writes one, so this receipt is not the one Mason wrote"
    return
    ;;
  no-bin-object)
    _mason_result incomplete \
      "the receipt in $package_dir has a links.bin that is not an object, so the executables it claims cannot be read"
    return
    ;;
  0)
    _mason_result incomplete \
      "the receipt in $package_dir links no executables; every package this repository installs declares one, so this receipt is not the one Mason wrote"
    return
    ;;
  esac

  if [[ "$name" != "$package" ]]; then
    _mason_result incomplete \
      "the receipt in $package_dir names ${name:-no package}, not $package"
    return
  fi

  # A receipt on its own is not an installation. Mason extracts a package's
  # files before it writes the receipt, so a directory holding nothing else has
  # had its contents removed under a receipt that outlived them.
  for entry in "$package_dir"/* "$package_dir"/.[!.]*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ "${entry##*/}" != "$MASON_RECEIPT_NAME" ]] || continue
    payload="true"
    break
  done
  if [[ "$payload" != "true" ]]; then
    _mason_result incomplete "$package_dir holds a Mason receipt and nothing else"
    return
  fi

  MASON_PACKAGE_VERSION="$(mason_purl_version "$purl" || true)"

  if [[ -n "$expected_version" ]]; then
    if [[ -z "$MASON_PACKAGE_VERSION" ]]; then
      _mason_result version-mismatch \
        "pinned to $expected_version, but the receipt records no readable version (source: ${purl:-none})"
      return
    fi
    if [[ "$MASON_PACKAGE_VERSION" != "$expected_version" ]]; then
      _mason_result version-mismatch \
        "installed at $MASON_PACKAGE_VERSION, but pinned to $expected_version"
      return
    fi
  fi

  _mason_result installed "installed${MASON_PACKAGE_VERSION:+ at $MASON_PACKAGE_VERSION}"
}

# mason_load_version_pins <pin_file>
#
# Read "<package> <version>" pins into MASON_VERSION_PINS. A pin file that is
# absent is not an error -- nothing has to be pinned -- but one that cannot be
# read, or that carries a line this parser does not recognise, is: silently
# skipping a malformed pin would install whatever the registry advertises under
# the name of a pinned package. Returns 1 with MASON_ERROR set, so a
# verifier can report it and an installer can die on it.
mason_load_version_pins() {
  local pin_file="$1"
  local pin_line pin_package pin_version pin_extra filtered

  MASON_VERSION_PINS=""
  # shellcheck disable=SC2034
  MASON_ERROR=""

  [[ -e "$pin_file" ]] || return 0
  if [[ ! -f "$pin_file" || ! -r "$pin_file" ]]; then
    # shellcheck disable=SC2034
    MASON_ERROR="Mason version pin file is not readable: $pin_file"
    return 1
  fi
  if ! filtered="$(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$pin_file")"; then
    # shellcheck disable=SC2034
    MASON_ERROR="Mason version pin file could not be read: $pin_file"
    return 1
  fi
  [[ -n "$filtered" ]] || return 0

  while IFS= read -r pin_line; do
    read -r pin_package pin_version pin_extra <<EOF
$pin_line
EOF
    [[ -n "${pin_package:-}" ]] || continue
    if [[ -n "${pin_extra:-}" ]]; then
      # shellcheck disable=SC2034
      MASON_ERROR="Invalid Mason version pin: $pin_line"
      return 1
    fi
    if [[ ! "$pin_package" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
      # shellcheck disable=SC2034
      MASON_ERROR="Invalid Mason package name in version pins: $pin_package"
      return 1
    fi
    if [[ -z "${pin_version:-}" ]]; then
      # shellcheck disable=SC2034
      MASON_ERROR="Mason version pin is missing a version: $pin_package"
      return 1
    fi
    if [[ ! "$pin_version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
      # shellcheck disable=SC2034
      MASON_ERROR="Invalid Mason version pin for $pin_package: $pin_version"
      return 1
    fi
    MASON_VERSION_PINS="$MASON_VERSION_PINS$pin_package $pin_version
"
  done <<EOF
$filtered
EOF
  return 0
}

# mason_version_pin <package>
#
# The pinned version of <package>, or nothing when it is not pinned. One pin
# file serves every Neovim profile, so a pin naming a package the caller does
# not install is simply never asked for.
mason_version_pin() {
  local package="$1" pin_package pin_version

  [[ -n "$MASON_VERSION_PINS" ]] || return 0
  while read -r pin_package pin_version; do
    if [[ "$pin_package" == "$package" ]]; then
      printf '%s\n' "$pin_version"
      return 0
    fi
  done <<EOF
$MASON_VERSION_PINS
EOF
  return 0
}

# mason_read_inventory <inventory_file>
#
# The package names in a Mason inventory, comments and blank lines removed, in
# file order. Prints nothing and returns 1 when the file cannot be read, so a
# read failure is never delivered to a caller as an empty inventory.
mason_read_inventory() {
  local inventory="$1" filtered

  [[ -f "$inventory" && -r "$inventory" ]] || return 1
  filtered="$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$inventory")" || return 1
  [[ -z "$filtered" ]] || printf '%s\n' "$filtered"
}
