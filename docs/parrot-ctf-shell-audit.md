# Parrot 7.3 shell compatibility audit

The Parrot CTF profile deliberately uses the repository's shared Zsh setup;
it does not source Parrot's Bash startup files. This audit records what was
reviewed and which small pieces are retained.

## Sources reviewed

- Parrot's current `parrot-core` skeleton
  [`.bashrc`](https://github.com/ParrotSec/parrot-core/blob/525964d68c4d3eab46a62353ce37c92b3cdb95f4/skel/.bashrc)
- The matching `base-files`
  [`share/dot.bashrc`](https://github.com/ParrotSec/base-files/blob/902e264e33602deec754869b8cd2f0a552ae9e65/share/dot.bashrc),
  which is installed as the default root/system Bash configuration
- Parrot's package install behavior, which deploys the skeleton/default Bash
  files to the generated user, root, and system locations used by a clean
  installation

The upstream files were identical for the behavior classified below.

## Classification

| Stock behavior | Classification | Parrot Zsh decision |
|---|---|---|
| Parrot prompt, terminal title and color setup | Generic/cosmetic | Excluded; Starship and Catppuccin own the prompt |
| `ls`, `ll`, `la`, `l`, colored `grep` variants | Redundant or conflicting | Excluded; shared `eza`, `bat`, and shell conventions remain authoritative |
| `em`, `_`, `_i`, `fucking`, `please`, `wget -c` | Surprising generic overrides | Excluded |
| `tarnow`, `untar`, directory traversal aliases | Generic conveniences | Excluded from the Parrot layer; do not import Bash aliases wholesale |
| `psmem`, `psmem10`, colored `man` wrapper | Generic conveniences | Excluded |
| `hex-encode`, `hex-decode`, `rot13` | Useful CTF helpers | Preserved as explicit Zsh functions, backed by APT-owned `xxd`/`tr` |
| Bash completion and `/etc/profile.d/*.sh` loading | Bash-only initialization | Excluded; Zsh completion and explicit platform hooks own this behavior |

## Globbing decision

The profile uses `unsetopt NOMATCH`.

- Targeted `noglob` wrappers were rejected because Parrot's security catalogue
  changes and a maintained command list would inevitably be incomplete. They
  would also disable useful filename expansion for every invocation of each
  wrapped tool.
- `unsetopt NOMATCH` passes an unmatched `*`, `?`, or bracket expression to the
  invoked tool, matching Bash's practical behavior for common URL, payload,
  and fuzzer arguments. Patterns that match local files still expand normally.
- Global `NO_GLOB` was rejected because it would also break ordinary filename
  expansion such as `ls *.txt` and `rm build/*`.

This is not a substitute for quoting. Existing local matches still expand,
and shell syntax such as brace expansion has its own rules. Quote arguments
when the target tool must always receive the exact bytes.

The behavior is isolated to the Parrot profile in
`platforms/parrot-ctf/stow/zsh-platform`; Fedora, WSL, and macOS retain normal
Zsh `NOMATCH` behavior.
