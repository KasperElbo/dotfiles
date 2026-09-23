#!/usr/bin/env bash
# The macOS installer's --help text, shared by platforms/macos/install.sh and
# scripts/bootstrap-macos.sh. The bootstrap prints it under Apple's Bash 3.2,
# before a modern Bash exists, so this file stays within that dialect: it
# sources only the generated option listing beside it and defines one function.

# The persistent options, generated from config/install-options.tsv by
# scripts/render-installer-usage.py so the listing cannot drift from what the
# parser accepts and records.
# shellcheck source=usage-options.sh
source "$(dirname "${BASH_SOURCE[0]}")/usage-options.sh"

macos_usage() {
  cat <<'EOF'
Usage: ./install.sh --platform macos [options]

Options:
EOF
  usage_persistent_options
  cat <<'EOF'

  Dictation uses Ghost Pepper, which needs Microphone and Accessibility
  approval afterwards.
  AI subcomponents are additive: omitting one leaves it installed.
  --no-<component> is the only thing that removes one, and it confirms first.
  An unsupported component rejects only its own flag.

Execution controls, for this run only:
  --dev-workflows/--no-dev-workflows
                     Disposable development workflow smoke tests
                     (--workflows/--no-workflows are deprecated spellings)
  --dry-run          Show the resolved plan without changing anything
  --non-interactive  Never prompt; resolve every choice from the given
                     options and their defaults. Requires cached sudo
                     (run 'sudo -v' first) where the run needs it.
  -h, --help         Show this help
EOF
}
