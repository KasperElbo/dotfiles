-- Writeups are Markdown, so the guest carries the workstation's Markdown
-- editing unchanged: table editing, the <leader>m group, rendered colours and
-- project ownership of markdownlint and markdown-toc. Prettier needs no
-- exception here: the guest installs none, so Conform formats with a
-- project's own Prettier when one exists and otherwise skips it quietly.
return require("plugins.markdown")
