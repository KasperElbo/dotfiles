# Optional Podman container development profile: Fedora and Fedora WSL

`--containers` adds a complete, validated rootless container
development workflow. It is not part of the default `./install.sh` path,
appears in `--dry-run`, and can be run and rerun on its own:

```bash
./platforms/fedora/scripts/install-containers.sh
./platforms/fedora/scripts/install-containers.sh --dry-run
./platforms/fedora/scripts/verify-containers.sh
```

### Platform scope

Everything below this point — `install-containers.sh`/`verify-containers.sh`,
`--api-socket`/`--containers-api-socket`, the subuid/subgid allocation, and
the SELinux `:Z`/`:z` guidance — describes the **Fedora and Fedora WSL**
implementation specifically:

- **Fedora WSL**: supported, with WSL-specific preconditions
  (systemd required, cgroup v2, unprivileged user namespaces) checked
  explicitly before installing, and WSL-specific differences (SELinux
  enforcement, networking-mode expectations, bind-mount guidance,
  `DOCKER_HOST` scope) documented rather than assumed equivalent to native
  Fedora. See
  [Podman containers under WSL](../platforms/fedora-wsl.md#podman-containers-under-wsl),
  including that section's validation-status note.
- **macOS**: supported only through the explicit `--platform macos
  --containers` profile, with its own script
  (`platforms/macos/scripts/install-containers.sh`) that takes no arguments —
  it does not parse or reject `--api-socket` or any other flag, unlike every
  other platform's installer. It uses a rootless Linux VM (`podman machine`)
  and a dedicated smoke test; it does not reuse Fedora systemd, SELinux,
  subuid, or host-networking assumptions, and `verify.sh` there has no
  `--skip-smoke-test` option. It is also the one macOS capability no CI job
  installs — a hosted runner cannot start the Podman machine — so it is
  checked by hand. See
  [the macOS guide](../platforms/macos.md#optional-containers).
- **[Parrot Security Edition CTF guest](../platforms/parrot-ctf.md)**: not
  installed and not appropriate to layer on automatically. The guest is an
  intentionally disposable offensive-security lab environment, and container
  tooling there should stay optional and never interfere with Parrot's own
  security catalogue.

Rootless Podman is treated as the normal, supported mode; nothing here runs
containers as root, and no setuid/daemon-as-root shortcut is used.

| Concern | Convention |
|---|---|
| Runtime | Podman, rootless by default |
| OCI runtime | `crun`, a podman dependency |
| Rootless networking | `netavark`/`aardvark-dns` plus `pasta` (or `slirp4netns`), podman dependencies |
| Compose | `podman-compose`, picked up automatically by `podman compose` |
| Buildah / Skopeo | Not installed (see below) |
| Docker Engine / `docker` alias | Not installed |
| API socket | Rootless user socket, opt-in via `--api-socket`, never over TCP |

This profile touches nothing that the [VM-host](vm-host.md) profile, the
[hardening](hardening.md) profile, LazyVim, or the .NET/JS-TS-Angular/Python/
OCaml toolchains rely on: it does not change SELinux, firewalld, sudoers,
sysctl, libvirt, or any mise/opam-managed runtime, so it can be enabled
alongside any of them in any order. The optional [AI profile](ai.md) composes
the same way.

### Package ownership

```text
podman
podman-compose
```

Both come from Fedora/DNF, consistent with the rest of the workstation.
Podman's own RPM dependencies pull in whichever OCI runtime and rootless
networking stack the current Fedora release ships — `crun`, `netavark`,
`aardvark-dns`, and `pasta` (from the `passt` package) or `slirp4netns` — so
this profile does not pin those package names itself. Pinning them would
drift from whatever Fedora's own podman package actually requires release to
release; instead, `verify-containers.sh` checks the resulting rootless
network backend and OCI runtime at runtime, so the check tracks Fedora
rather than a hard-coded list.

**Buildah and Skopeo are deliberately not installed.** `podman build` already
uses Buildah's library internally, so a separate Buildah CLI would duplicate
that path without adding a capability this profile's workflows need. Skopeo's
distinct value is inspecting or copying images between registries without
a local container store; none of this profile's pull/run/build/Compose
workflows need that, so it is left out until a concrete use case asks for it.

**No Docker Engine, no `docker` alias.** This profile never installs Docker
Engine or Docker Desktop as a second runtime, and it never aliases `docker`
to `podman` or installs another compatibility shim. If a tool insists on the
literal `docker` command, install the small `podman-docker` RPM yourself and
review what it changes; the profile does not do this for you.

### Rootless setup: subuid/subgid

Rootless Podman maps container UIDs/GIDs into a range of extra UIDs/GIDs
owned by your normal user (`/etc/subuid` and `/etc/subgid`). Fedora's
`useradd` already assigns a range to every new local user, so on most
workstations this profile finds an existing entry and changes nothing.
Only when your user has no entry does the installer allocate one:

- It scans `/etc/subuid`/`/etc/subgid` for the highest range already in use
  and allocates the next free 65536-wide block at or above Fedora's own
  `100000` floor, so it never collides with another user's range.
- It applies the allocation with `usermod --add-subuids`/`--add-subgids`,
  then runs `podman system migrate` once so any already-initialized
  rootless storage adopts the new mapping without a logout.
- A user who already owns both ranges is left untouched on every rerun.

### Common Podman commands

```bash
podman pull IMAGE                       # fetch an image
podman run --rm -it IMAGE sh            # run and drop into a shell
podman build -t NAME .                  # build from a Containerfile
podman ps                               # list running containers
podman images                           # list local images
podman volume ls                        # list named volumes
podman logs -f CONTAINER                # follow a container's logs
podman exec -it CONTAINER sh            # shell into a running container
podman system prune                     # remove unused containers/images/networks
```

These are the same commands Docker users already know; the differences that
matter day to day are covered below. The printable per-profile
[cheat sheets](../cheatsheets/README.md) carry only the high-value entries,
not the full Podman CLI surface.

### Compose

`podman compose` is Podman's own front end for Compose files; it shells out
to `podman-compose`, which DNF installs and which `podman compose`
auto-detects on `PATH`. No custom orchestration wrapper is added. A minimal
multi-service project:

```yaml
# compose.yaml
services:
  web:
    image: docker.io/library/busybox:stable
    command: httpd -f -p 8080 -h /srv
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - site-data:/srv
volumes:
  site-data:
```

```bash
podman compose up -d
curl http://127.0.0.1:8080/
podman compose down -v
```

### SELinux volume labels

SELinux stays enabled and enforcing; this profile never disables or weakens
it to make a bind mount work. On an SELinux-enforcing host, a bind-mounted
host directory is denied by default because the host path's SELinux context
does not match what the container is allowed to read. Podman's `:Z`/`:z`
mount-flag suffixes ask Podman to relabel the path instead of turning
enforcement off:

| Suffix | Effect | Use when |
|---|---|---|
| `:Z` | Relabels the path for **exclusive** use by this one container | The default: only one container needs the path at a time |
| `:z` | Relabels the path for **shared** use by multiple containers | Several containers (or a Compose project's services) read/write the same host path concurrently |
| (none) | No relabeling; denied under enforcing SELinux unless the path already carries a compatible context | A path you have already labeled yourself, e.g. with `chcon` |

```bash
podman run --rm -v "$PWD:/work:Z" docker.io/library/busybox:stable ls /work
```

Named volumes (`podman volume create`, then `-v volume-name:/path`) do not
need a `:Z`/`:z` suffix: Podman manages their SELinux labels itself.

### Rootless API socket (Docker-compatible tooling)

Disabled by default; this profile does not assume you need Docker-compatible
tooling. Pass `--api-socket` to `install-containers.sh` (or
`--containers-api-socket` to the top-level `./install.sh`) only if something
you use expects a Docker-style API socket:

```bash
./platforms/fedora/scripts/install-containers.sh --api-socket
```

This enables `podman.socket` in your own **user** systemd instance
(`systemctl --user enable --now podman.socket`), never the system-wide
socket. Being a `.socket` unit rather than a permanently running daemon, it
is socket-activated: `podman.service` only starts on the first connection
and can idle back down afterward. The socket is a Unix domain socket at
`$XDG_RUNTIME_DIR/podman/podman.sock`, reachable only by your user account;
it is never bound to a TCP port or exposed to the network.

**Security implications:** anything that can write to that socket path can
control every container your rootless user can — equivalent to shell access
as that user, though not to root, since the daemon itself still runs
unprivileged inside your subuid/subgid mapping. Do not add other local users
to your primary group or otherwise widen access to `$XDG_RUNTIME_DIR` if you
enable this.

Only export `DOCKER_HOST` if you actually run Docker-CLI-compatible tooling
against it; this profile does not set it for you:

```bash
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
```

**Verification:** the installer records the selection as
`api_socket=enabled|disabled` in `$XDG_CONFIG_HOME/dotfiles/containers.conf`,
and `verify-containers.sh` checks the machine against that record rather than
accepting either outcome. With `api_socket=enabled`, the **user** unit must be
both enabled and active — a system-scoped `podman.socket` does not satisfy it,
because a rootless client does not use it — and anything less fails
verification. With `api_socket=disabled`, a disabled socket passes and an
independently enabled one is reported as a warning, since it may have been
enabled deliberately after installation. A missing or unreadable record for a
selected containers profile fails with the command needed to re-record it.
Verification never enables, starts, or stops the socket.

### Differences from Docker worth knowing day to day

- **No background daemon by default.** Rootless Podman runs each container
  as a direct child process tree of the command that started it; there is no
  always-on `dockerd` unless you opt into `--api-socket`, and even then it is
  socket-activated rather than permanently running.
- **Rootless by default, not an opt-in flag.** `podman info`'s
  `Host.Security.Rootless` should read `true`; there is no `sudo podman`
  needed for the workflows this profile validates.
- **`podman-compose` and `podman compose` are two different things.**
  `podman-compose` is the installed Python provider; `podman compose` is
  Podman's own subcommand that calls it. Prefer `podman compose` so the
  provider stays swappable.
- **`:Z`/`:z` matter under SELinux enforcement**; Docker installations
  typically run without SELinux enforcement engaged the same way, so a
  Compose file copied from a Docker-only project may need these added to
  its bind mounts. Named volumes need no such suffix.
- **No `docker` command** unless you deliberately install `podman-docker`
  yourself; scripts hard-coded to shell out to `docker` need either that
  package or a per-project alias, not a global one from this profile.
- **Plain `depends_on` in a Compose file can hang `podman compose up -d`
  indefinitely** if the dependency is a fast-exiting one-shot container (a
  migration/seed/init step). `podman-compose` implements `depends_on` by
  running `podman wait --condition=...` against the dependency, and that
  wait blocks on a state *transition* — if the dependency already finished
  before the wait call starts, the transition it's waiting for will never
  happen again. This bit the profile's own smoke test during validation
  when this profile was first validated; the fix was dropping `depends_on` and letting
  both services start concurrently, with the reachability check retrying
  until the seeded content actually appears. If you hit an unexplained hang
  on `podman compose up` with your own project, check for exactly this
  pattern before assuming a networking problem.

### Verification

`verify-containers.sh` checks `podman`/`podman-compose` are present,
`podman version`, rootless status and network backend from `podman info`,
the subuid/subgid mapping, and the API socket's state, then runs a smoke
test: pull, run, build, a `:Z`-labeled bind mount, a named volume, localhost
port publishing, container-to-container networking on a dedicated network,
and a two-service Compose project. Every smoke-test resource is uniquely
named per run and removed (containers, the built image, the volume, the
network, and temporary Compose/build directories) whether the run passes or
fails, so repeated verification never leaves containers, images, or volumes
behind. Pass `--skip-smoke-test` for an inspection-only run when you do not
want to touch the network or local container storage; `verify.sh`'s full
system check uses this so a routine `./install.sh` run does not repeat the
smoke test every time. `install-containers.sh` itself always runs the full
smoke test once, right after installing, so the end-to-end workflow is
proven immediately.

#### What the smoke test does to local image storage

The smoke test is the one part of verification that is not read-only, and
this is its whole mutation policy:

- **The base image is pinned by manifest-list digest**, not by the `:stable`
  tag it was taken from, so every run pulls exactly the reviewed content.
  The digest is recorded in `config/network-sources.tsv` as
  `smoke-image-busybox` and bumped deliberately.
- **If that image was already in local image storage, it is not re-fetched**
  and it is kept. The run touches neither the network nor image storage for
  it, and reports its image ID before and after to show it is unchanged.
- **If it was not, the run pulls it and removes it again afterwards**, so a
  machine that did not have the image ends verification without it.
- **The restore runs on every exit path** — a passing run, a failing check, a
  `podman` error, and `Ctrl-C` or a `SIGTERM` part-way through — and the run
  reports which of the two restores it owed under `Local image state`.
- **A removal that fails is said out loud**, as a warning naming the image and
  the `podman rmi` command to finish it by hand, because the image is then
  still on the machine.
- **`--skip-smoke-test` touches image storage not at all**; it pulls nothing
  and removes nothing.

This is the same policy the macOS verifier follows for its own container
probe, and it applies on Fedora WSL too, whose container verifier checks the
WSL prerequisites and then hands over to the Fedora one.

The saved local state file is:

```text
~/.config/dotfiles/containers.conf
```
