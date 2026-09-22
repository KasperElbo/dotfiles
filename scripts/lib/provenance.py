#!/usr/bin/env python3
"""The sentence a generated region says to someone reading the rendered page.

Four of the eight generated documents are whole files, and each opens with a
visible "Generated from …; do not edit" line. The other four splice a generated
region into a hand-written page, and they carried the identical sentence inside
the `<!-- … -->` marker comment, which every Markdown renderer strips. On
GitHub's rendered view, in an editor preview, anywhere but the raw bytes, those
four pages announced nothing: a section simply began.

That is not only a trust gap. Running the renderer with no arguments -- the
command the stale-gate's own error message tells a contributor to run --
rewrites the region and discards anything hand-written inside it, printing
nothing. So the warning has to be where the person about to lose work can read
it, which means outside the comment.

The markers themselves stay HTML comments: `splice()` finds them by their exact
text in both the renderer and the tracked file, so they are a format, not prose.
"""

from __future__ import annotations

# `sources` names the registry or scripts the region is derived from, already
# marked up as code; `renderer` is the file name under `scripts/`.
VISIBLE_PROVENANCE = (
    "*Generated from {sources} by `scripts/{renderer}`. Anything written by "
    "hand between the markers around this section is discarded the next time "
    "that runs — edit the source and regenerate.*"
)
