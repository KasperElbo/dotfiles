# Licensing of this repository's own material

**Status: undecided — this requires a maintainer decision.**

The scripts, configuration, manifests and documentation written in this
repository currently carry no licence. Third-party material is a separate
matter and is already covered: see
[third-party-notices.md](third-party-notices.md).

This page exists so the decision is made deliberately rather than inherited
from a template. Nothing in the repository, its history, or its documentation
records a licence choice, so no licence has been assumed here.

## What "no licence" means today

Under the Berne Convention and the copyright law of essentially every
jurisdiction, work without an explicit licence is "all rights reserved" by
default. Practically, for a public repository:

- Anyone may read it and GitHub's terms permit viewing and forking on GitHub.
- Nobody has a clear right to copy the scripts into their own dotfiles,
  redistribute them, or reuse a fragment in another project.
- Contributors have no stated terms for the contributions they make.

For a personal dotfiles repository that may be exactly the intent. It is still
worth stating rather than leaving implicit.

## Reasonable choices

| Choice | What it means in practice here | Consider it if |
|---|---|---|
| **MIT** | Anyone may copy, modify and redistribute, including in closed-source work, provided the copyright notice and licence text travel with it. Shortest and most familiar in the dotfiles ecosystem. Matches the Catppuccin material already vendored. | You want other people to be able to lift a script or a profile without asking. |
| **Apache-2.0** | Same permissions as MIT, plus an explicit patent grant and a requirement to state significant modifications. Matches the LazyVim starter already vendored under `nvim-lazyvim/`. | You want the patent clause and an explicit contribution term, and do not mind a longer file. |
| **BSD-2-Clause / BSD-3-Clause** | Equivalent to MIT in effect; 3-Clause additionally forbids using the author's name to endorse derived work. | You specifically want the no-endorsement clause. |
| **GPL-3.0** | Derived works that are distributed must themselves be GPL-3.0. Copyleft. | You want reuse to stay open, and accept that it discourages absorption into permissively licensed projects. |
| **CC0-1.0 / Unlicense** | Effectively dedicates the material to the public domain, with no attribution requirement at all. | You consider this configuration not worth attributing and want zero friction. |
| **Deliberately none** | The status quo above, but stated explicitly in the README rather than left ambiguous. | The repository is a personal machine configuration you publish for reference, not for reuse. |

Whichever is chosen, it governs **only this repository's own material**. It
cannot and does not relicense vendored Catppuccin or LazyVim content, which
stays under its own terms.

## Finishing the decision

Everything except the choice itself is already in place. To finish:

1. Add the chosen licence text at the repository root as `LICENSE`
   (or record the deliberate "no licence" choice, in which case there is no
   `LICENSE` file and only step 3 applies).
2. Replace the **Status** line at the top of this page with, for example:

   ```
   **Status: decided — MIT.**
   ```

   `scripts/validate-repository-hygiene.py` requires that this page's status
   and the presence of a root `LICENSE` file agree, so the two cannot drift
   apart. The validator never picks a licence and never fails because one is
   missing; leaving the decision open is a supported state.
3. Link the result from the README's licensing section.

There is no CI pressure to do this quickly. The checks are written so that an
undecided repository is valid.
