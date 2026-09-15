#!/usr/bin/env bash

# Machine-local Git identity migration.
#
# A Git identity (name/email) is privacy-sensitive machine-local
# configuration, not repository content. Two rules follow from that and are
# load-bearing for everything below:
#
#   1. Nothing here ever prints, logs, or echoes a recovered name or email.
#      Messages name the identity slot and the kind of source, never content.
#   2. A migration that cannot find a valid source says so. It never leaves
#      behind a file that a later run — or a human — would mistake for a
#      successfully migrated identity.
#
# Sources are tried in a fixed order, most explicit first:
#
#   backup    an explicit machine-local backup directory the user controls
#             ($DOTFILES_GIT_IDENTITY_BACKUP_DIR, default
#             $XDG_STATE_HOME/dotfiles/git-identity)
#   worktree  the file still present at the former in-repository Stow path,
#             which is untracked and machine-local (see .gitignore)
#   history   opt-in recovery from a repository's historical objects
#
# History recovery is off by default. It is a compatibility fallback for
# machines installed before these files left the Stow package, and it is a
# poor place to keep private state: objects reachable in a public repository
# are readable by anyone who clones it, and a shallow clone may not have them
# at all. See docs/reference/git-identity.md.

# Identity slots the repository's own git config includes.
# Public state consumed by sourcing scripts.
# shellcheck disable=SC2034
GIT_IDENTITY_NAMES=(local drdk)

# Outcome tokens returned through GIT_IDENTITY_OUTCOME.
# Public state consumed by sourcing scripts and tests.
# shellcheck disable=SC2034
GIT_IDENTITY_OUTCOME_MIGRATED="migrated"
GIT_IDENTITY_OUTCOME_NONE="nothing-to-migrate"
GIT_IDENTITY_OUTCOME_MANUAL="manual-action-required"
GIT_IDENTITY_OUTCOME=""

git_identity_backup_dir() {
  printf '%s\n' \
    "${DOTFILES_GIT_IDENTITY_BACKUP_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/git-identity}"
}

git_identity_history_repo() {
  printf '%s\n' "${DOTFILES_GIT_IDENTITY_HISTORY_REPO:-${DOTFILES_ROOT:-}}"
}

git_identity_history_enabled() {
  [[ "${DOTFILES_GIT_IDENTITY_HISTORY_RECOVERY:-false}" == "true" ]]
}

git_identity_worktree_path() {
  printf '%s/git/.config/git/%s\n' "${DOTFILES_ROOT:-}" "$1"
}

git_identity_repo_relative_path() {
  printf 'git/.config/git/%s\n' "$1"
}

# git_identity_is_valid <path>: succeed only when the file holds a usable
# [user] section — a [user] header plus at least one name/email assignment
# inside it. Nothing is printed; only the exit status describes the file.
git_identity_is_valid() {
  local path="$1"

  [[ -f "$path" && -s "$path" ]] || return 1

  awk '
    /^[[:space:]]*[;#]/ { next }
    /^[[:space:]]*\[/ {
      section = tolower($0)
      sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
      sub(/[[:space:]]*\].*$/, "", section)
      sub(/[[:space:]].*$/, "", section)
      in_user = (section == "user")
      next
    }
    in_user && tolower($0) ~ /^[[:space:]]*(name|email)[[:space:]]*=/ {
      found = 1
      exit
    }
    END { exit found ? 0 : 1 }
  ' "$path"
}

# _git_identity_try_candidate <source-file> <destination>: install a candidate
# byte-for-byte at mode 0600 when it validates. Returns 1 without touching the
# destination when the candidate is absent or does not hold a [user] section.
_git_identity_try_candidate() {
  local candidate="$1"
  local destination="$2"

  [[ -f "$candidate" ]] || return 1
  git_identity_is_valid "$candidate" || return 2

  atomic_write_file "$destination" <"$candidate" || return 1
}

# _git_identity_recover_from_history <name> <destination>: opt-in fallback.
# Walks the revisions that touched the former in-repository path and installs
# the newest blob that validates. Missing objects (a shallow or partial clone)
# are a normal, non-fatal outcome: this function fails, it never aborts and it
# never writes an unvalidated blob.
_git_identity_recover_from_history() {
  local name="$1"
  local destination="$2"
  local repo revision relative staged status

  repo="$(git_identity_history_repo)"
  [[ -n "$repo" && -d "$repo" ]] || return 1
  command_exists git || return 1
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 1

  if [[ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null || printf true)" == "true" ]]; then
    warn "Git identity history recovery: '$repo' is a shallow clone, so historical identity objects may be absent."
  fi

  relative="$(git_identity_repo_relative_path "$name")"
  staged="$(mktemp "${destination}.XXXXXX")" || return 1

  while IFS= read -r revision; do
    [[ -n "$revision" ]] || continue
    git -C "$repo" cat-file -e "${revision}:${relative}" 2>/dev/null || continue
    git -C "$repo" show "${revision}:${relative}" >"$staged" 2>/dev/null || continue
    if git_identity_is_valid "$staged"; then
      status=0
      atomic_write_file "$destination" <"$staged" || status=$?
      rm -f -- "$staged"
      return "$status"
    fi
  done < <(git -C "$repo" log --all --format='%H' -- "$relative" 2>/dev/null || true)

  rm -f -- "$staged"
  return 1
}

# git_identity_recover <name> <destination>: install the best available legacy
# identity for <name> at <destination>. On success the source kind is printed
# on stdout (backup|worktree|history) and the destination holds the source
# bytes at mode 0600. On failure nothing is written and nothing is printed.
git_identity_recover() {
  local name="$1"
  local destination="$2"
  local candidate status

  candidate="$(git_identity_backup_dir)/$name"
  status=0
  _git_identity_try_candidate "$candidate" "$destination" || status=$?
  if ((status == 0)); then
    printf 'backup\n'
    return 0
  elif ((status == 2)); then
    warn "Ignoring backup Git identity '$name': no usable [user] section."
  fi

  candidate="$(git_identity_worktree_path "$name")"
  status=0
  _git_identity_try_candidate "$candidate" "$destination" || status=$?
  if ((status == 0)); then
    printf 'worktree\n'
    return 0
  elif ((status == 2)); then
    warn "Ignoring legacy in-repository Git identity '$name': no usable [user] section."
  fi

  if git_identity_history_enabled &&
    _git_identity_recover_from_history "$name" "$destination"; then
    printf 'history\n'
    return 0
  fi

  return 1
}

# git_identity_write_manual_placeholder <path> <name>: the file a failed
# migration leaves behind. It is deliberately not a valid identity: Git reads
# it as an empty include, and neither a person nor a later run can mistake it
# for recovered content.
git_identity_write_manual_placeholder() {
  local path="$1"
  local name="$2"

  cat <<EOF_PLACEHOLDER | atomic_write_file "$path"
# No Git identity was migrated into this file.
#
# This file is machine-local: it is never committed and never leaves this
# machine. Nothing was recovered for the '$name' identity, so set it by hand:
#
#     git config --file "$path" user.name "Your Name"
#     git config --file "$path" user.email "you@example.com"
#
# Alternatively, drop a copy of a previous identity at
# "$(git_identity_backup_dir)/$name" and run ./install.sh again.
#
# See docs/reference/git-identity.md.
EOF_PLACEHOLDER
}

# git_identity_migrate <name> <path>: migrate one identity slot into <path>,
# which is a legacy symlink that must be replaced by a machine-local file.
# Sets GIT_IDENTITY_OUTCOME to one of the outcome tokens above and reports the
# outcome to the user without disclosing identity content.
git_identity_migrate() {
  local name="$1"
  local path="$2"
  local replacement source_kind

  replacement="$(mktemp "$(dirname "$path")/.${name}.XXXXXX")" || return 1

  if source_kind="$(git_identity_recover "$name" "$replacement")"; then
    mv -- "$replacement" "$path"
    chmod 600 "$path"
    GIT_IDENTITY_OUTCOME="$GIT_IDENTITY_OUTCOME_MIGRATED"
    info "Git identity '$name': migrated from the $source_kind source."
    return 0
  fi

  rm -f -- "$replacement"
  git_identity_write_manual_placeholder "$path" "$name"
  chmod 600 "$path"
  # shellcheck disable=SC2034
  GIT_IDENTITY_OUTCOME="$GIT_IDENTITY_OUTCOME_MANUAL"
  warn "Git identity '$name': manual action required — no migration source was found. See $path."
  return 0
}
