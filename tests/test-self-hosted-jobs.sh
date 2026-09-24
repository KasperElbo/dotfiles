#!/usr/bin/env bash
# The self-hosted real-install jobs' own guards (#501). Neither job can run
# here, so each guard is read out of real-install.yml as the structure GitHub
# reads and its run block is executed against a fixture home, rather than
# retyped into this suite.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

# step_body <job> <step name>: that step's run block, exactly as the workflow
# carries it, refusing when the job or the step is not there so a renamed step
# fails this suite instead of testing nothing.
step_body() {
  python3 - "$repo_root" "$1" "$2" <<'PYTHON'
import importlib.util
import pathlib
import sys

root, job_name, step_name = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location(
    "hygiene", root / "scripts" / "validate-repository-hygiene.py")
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)
workflow = hygiene.read_workflow(root / ".github/workflows/real-install.yml", "real-install.yml")
job = workflow.get("jobs").get(job_name)
if job is None:
    raise SystemExit(f"real-install.yml has no job {job_name!r}")
for step in job.get("steps").value:
    name = step.get("name")
    if name is not None and name.value == step_name:
        print(step.get("run").value)
        break
else:
    raise SystemExit(f"job {job_name!r} has no step {step_name!r}")
PYTHON
}

guard="$(step_body parrot-real-vm 'Refuse a guest that was not reverted to its clean snapshot')"

# run_guard: the step as the runner would run it, in a home of the suite's own.
run_guard() {
  run_capture env -i PATH="$PATH" HOME="$TEST_ROOT/home" bash -c "$guard"
}

test_new_root
run_guard
assert_success
printf 'PASS: a guest with no earlier installation is accepted\n'

for left in .local/state/dotfiles .config/dotfiles .local/share/mise; do
  test_new_root
  mkdir -p "$TEST_ROOT/home/$left"
  run_guard
  assert_failure
  assert_contains "$TEST_OUTPUT" "  $TEST_ROOT/home/$left"
  assert_contains "$TEST_OUTPUT" 'Revert it to its clean snapshot and dispatch the job again.'
done
printf 'PASS: lifecycle state, saved selections and mise data each refuse the guest\n'

# The XDG roots the installer honours are the ones the guard reads.
test_new_root
mkdir -p "$TEST_ROOT/xdg-state/dotfiles"
run_capture env -i PATH="$PATH" HOME="$TEST_ROOT/home" XDG_STATE_HOME="$TEST_ROOT/xdg-state" \
  bash -c "$guard"
assert_failure
assert_contains "$TEST_OUTPUT" "  $TEST_ROOT/xdg-state/dotfiles"
printf 'PASS: state under a relocated XDG_STATE_HOME refuses the guest\n'

# The rerun is verified, not only run.
rerun="$(step_body parrot-real-vm 'Idempotent rerun and verifier')"
assert_contains "$rerun" './platforms/parrot-ctf/scripts/verify.sh'
printf 'PASS: the Parrot rerun is followed by the verifier\n'

# The WSL sweep is PowerShell and cannot run here; its shape is held instead:
# it must be the job's first step, so it runs before the import it protects.
first="$(python3 - "$repo_root" <<'PYTHON'
import importlib.util
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "hygiene", root / "scripts" / "validate-repository-hygiene.py")
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)
workflow = hygiene.read_workflow(root / ".github/workflows/real-install.yml", "real-install.yml")
print(workflow.get("jobs").get("fedora-wsl-real").get("steps").value[0].get("name").value)
PYTHON
)"
assert_eq 'Remove disposable distros an interrupted run left behind' "$first" \
  'the WSL job must sweep stale distros before it imports one'
printf 'PASS: the WSL job sweeps stale distros before importing\n'

# The runner each job lands on is its exact label list (#538). Dropping
# `self-hosted` sends a job to GitHub's hosted pool, and dropping its own label
# lets it land on any runner of that class; either passed every check while the
# page kept describing the old list. Both lists are held here, and the page's
# label blocks are held to them.
# runs_on <job>: that job's runs-on labels, comma-separated, as GitHub reads them.
runs_on() {
  python3 - "$repo_root" "$1" <<'PYTHON'
import importlib.util
import pathlib
import sys

root, job_name = pathlib.Path(sys.argv[1]), sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "hygiene", root / "scripts" / "validate-repository-hygiene.py")
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)
workflow = hygiene.read_workflow(root / ".github/workflows/real-install.yml", "real-install.yml")
job = workflow.get("jobs").get(job_name)
if job is None:
    raise SystemExit(f"real-install.yml has no job {job_name!r}")
labels = job.get("runs-on")
if labels is None or not isinstance(labels.value, list):
    raise SystemExit(f"job {job_name!r} does not run on a list of runner labels")
print(", ".join(str(label.value) for label in labels.value))
PYTHON
}

# documented_labels <lead-in>: the text block that follows <lead-in> in
# docs/testing.md, which is where a runner's owner reads what to label it.
documented_labels() {
  python3 - "$repo_root/docs/testing.md" "$1" <<'PYTHON'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(re.escape(sys.argv[2]) + r"\n\n```text\n(?P<labels>[^\n]*)\n```", text)
if match is None:
    raise SystemExit(f"docs/testing.md has no label block after {sys.argv[2]!r}")
print(match["labels"])
PYTHON
}

wsl_labels='self-hosted, Windows, X64, dotfiles-wsl'
parrot_labels='self-hosted, Linux, X64, dotfiles-parrot-vm'
assert_eq "$wsl_labels" "$(runs_on fedora-wsl-real)" 'the WSL job runs on exactly its runner'
assert_eq "$parrot_labels" "$(runs_on parrot-real-vm)" 'the Parrot job runs on exactly its runner'
assert_eq "$wsl_labels" "$(documented_labels 'The optional clean WSL job expects a runner labelled:')" \
  'docs/testing.md documents the WSL runner the job runs on'
assert_eq "$parrot_labels" "$(documented_labels 'The optional real Parrot VM job expects a runner labelled:')" \
  'docs/testing.md documents the Parrot runner the job runs on'
printf 'PASS: both self-hosted jobs run on exactly the runners docs/testing.md documents\n'

printf '\nAll self-hosted job guard checks passed.\n'
