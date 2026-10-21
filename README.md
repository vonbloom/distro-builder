# distro-builder

Build and distribution tooling for a personal, immutable CachyOS/Arch-based distro on
[arkdep](https://github.com/arkanelinux/arkdep). The root filesystem of each laptop is a read-only
btrfs image built here; interactive software lives in a distrobox (`userland`), whose image is
also built here, with a small repository of prebuilt AUR packages. An installer ISO puts the whole thing on a
new machine.

| Tool | What it produces | Where it is published | When |
|---|---|---|---|
| [`image/`](image/README.md) | arkdep images, one per device recipe | `http://<server>/<recipe>/` | weekly (Sunday 08:00 Europe/Madrid) |
| [`bootc/`](bootc/README.md) | bootc images of the same recipes (trial: the T480 runs them) | registry `<server>:5000/<recipe>` | weekly (Sunday 13:00 Europe/Madrid) |
| [`userland/`](userland/README.md) | the image of the `userland` and `playground` distroboxes | registry `<server>:5000/userland` | weekly (Sunday 15:00 Europe/Madrid) |
| [`aur/`](aur/README.md) | the pacman repository `[aur]` | `http://<server>/aur/` | daily (04:00 UTC) |
| [`iso/`](iso/README.md) | the installer ISO | `http://<server>/iso/` | by hand |

`<server>` stands for the [build server](#build-server)'s address, here and in the other
documents.

Each directory has a `README.md` with its usage and a `CLAUDE.md` with implementation notes and the
pitfalls already hit; [`serve/README.md`](serve/README.md) covers the web server, the status page
and the registry.

```
image/    arkdep image recipes (arkdep-build.d/, frozen since 2026-10-18: fixes only, for the P14s
          until it runs bootc), build, prune, notify-image
bootc/    the bootc host images: layers/ (base, modules/, desktop/, host/<host>: a packages.list
          and an overlay/ each, a host's layers.list), Containerfile, apply-layers, build (push to
          the registry as candidate, boot test, then latest), test (the boot test in a VM), prune,
          install (from the ISO)
userland/ the userland distrobox image: Containerfile, packages.list, distrobox.ini (the box
          manifest, carried by the image), dbus-1/, build; prune is bootc/prune
aur/      packages.list (AUR packages) and local/ (own PKGBUILDs), built into the [aur] repository
          by build and aur-build.sh
iso/      installer ISO (Containerfile, build): Arch releng profile + podman + bootc/install as
          /root/install, and arkdep + airootfs/root/ (install-arkdep, arkdep.config); test-vm
          (by hand), test-install (unattended, both modes)
serve/    nginx quadlet serving /mnt/repo (/<recipe>/, /aur/, /iso/) and the status page at /
          (web/index.html; status-gen writes /run/distro-status, served at /status/;
          build-trigger starts builds: POST /api/build/<unit>, polkit rule distro-trigger.rules);
          distro-registry.container: registry:2 on port 5000 (plain HTTP), storage
          /mnt/repo/registry (bootc and userland images)
systemd/  build-image@.{service,timer}, build-bootc@.{service,timer}, build-aur.{service,timer},
          build-userland.{service,timer}, build-iso.service, distro-status.{service,timer} (the
          status page's data, every minute), distro-trigger.{socket,service} (manual builds)
lib/      builder.sh (ensure_builder: rebuild a podman builder image when older than 7 days),
          sign.sh (detached GPG signatures with the server key), push-image.sh (chunkah + signed
          skopeo push to the registry, tag_image: bootc and userland images), retry-once (a build
          unit's single retry, build-bootc@), build-lock (one build at a time), config.sh (the
          server's address, below)
keys/     distro-builder.asc: public signing key, trusted by arkdep, pacman and the installer;
          distro-builder-sigstore.pub: public key of the bootc image signatures;
          cachyos.asc: the CachyOS repositories' key (bootc images)
docs/     todo.md: pending improvements; layers.md: prospect of layered bootc images (base,
          desktop, host) for every machine, a thin client included; fedora.md: trial of the host
          images on fedora-bootc, translation of the recipes
fedora/   package lists of the Fedora trial per layer (base, modules/, desktop/, host/):
          packages.list, remove.list (docs/fedora.md)
ci/       check: static checks, run by GitHub Actions (.github/workflows/check.yml) on every push
install   sets up the build server (below)
```

## Checks

`ci/check` runs the static checks: shellcheck of every shell script (warnings and errors, from the
pinned `koalaman/shellcheck` image through podman or docker), Python syntax, no stray files tracked
(`__pycache__`, editor swap files), commands executable (`bin/`, `sbin/` and the tools'
extensionless scripts) and the structure arkdep-build needs from each device recipe. GitHub Actions
runs it on every push (`.github/workflows/check.yml`; a failure shows on the commit and GitHub
sends an email); run it before pushing.

## Build server

Everything builds on one server (Debian 13, user `admin`, checkout `/home/admin/distro-builder`),
never on the laptops. Requirements:

- rootful podman (builds run with `sudo`; image and ISO builds need `--privileged` for btrfs and
  loop devices) and the `loop` module;
- `/mnt/repo` mounted from a file server (NFS): images, AUR packages and ISOs are written there
  and served from there;
- `notify-ha` and the `notify-failure@.service` template, installed by the homelab repo (Ansible
  role `notify_ha`), for the Home Assistant notifications;
- port 5000 reachable from the LAN for the container registry (the bootc and userland images);
- KVM (`/dev/kvm`; in a VM, CPU type `host` for nested KVM), `qemu-system-x86` and `ovmf` for the
  boot test of the bootc images (`bootc/test`), set up by the homelab repo too;
- its address as the clients reach it, in `/etc/distro-builder/config` (`SERVER=<address>`,
  written by `install` when run with `SERVER=`).

The address is the only value the builds take from outside the repository: the files that go
into an image or the ISO carry `@SERVER@` in its place, replaced when they are built
(`lib/config.sh`, read by every build script). The images keep it in
`/usr/lib/distro-builder/config`, where `iso/test-vm` and `iso/test-install` find it on a laptop.
A local test run sets `SERVER` in the environment instead.

Here the server is a VM that the homelab repo rebuilds from scratch rather than backing it up:
Ansible creates it, clones this repository and runs `install`. To set up a server by hand:

```sh
git clone https://github.com/vonbloom/distro-builder.git ~/distro-builder
sudo SERVER=<address> ~/distro-builder/install   # also ARKDEP_RECIPES="p14s t480" BOOTC_RECIPES=
```

`install` links the units in `systemd/` into `/etc/systemd/system`, the quadlets
`serve/distro-repo.container` and `serve/distro-registry.container` into `/etc/containers/systemd`,
creates `/mnt/repo/registry`, `/mnt/repo/bootc` and `/mnt/repo/userland`, installs the polkit rule
of the build trigger, enables `build-aur.timer`, `build-userland.timer`, the weekly
`build-image@<recipe>.timer` of the recipes in `ARKDEP_RECIPES` (default `p14s`) and
`build-bootc@<recipe>.timer` of those in `BOOTC_RECIPES` (default `t480`), `distro-status.timer`,
`distro-trigger.socket` and `podman-auto-update.timer`, and (re)starts the web server and the
registry. The defaults are what each laptop runs while arkdep
and bootc are compared (P14s arkdep, T480 bootc); the other recipes' timers are disabled, and their
builds stay available by hand (`systemctl start`, or the status page, which lists the arkdep and
bootc builds of every recipe). It is idempotent: run it again to change the schedules, or after
changing `systemd/` or `serve/`.

Every build unit pulls the checkout (`git pull --ff-only`, as `admin`) before building, so a
push to GitHub is enough for the next build to use it. A failed pull does not stop the build. The
units and timers themselves are only reloaded by systemd: after changing a file in `systemd/`,
run `sudo systemctl daemon-reload` on the server once the pull has brought it in.

Each tool builds inside its own throwaway podman *builder* image (`arkdep-builder`, `aur-builder`,
`iso-builder`). `lib/builder.sh` (`ensure_builder`) rebuilds a builder image from scratch when it
is missing, older than 7 days or `--rebuild-builder` is given, so the tools and package databases
inside never go stale.

### Signatures

Everything published is signed with the build server's key (ed25519,
`CF47 1E66 8597 4BF4 3EA1  1362 3F9E BD77 B1E6 0E55`, public part in `keys/distro-builder.asc`):
images (`<image>.tar.zst.sig`), the `[aur]` packages and database, and the ISO checksums. The
build scripts sign after their container has finished (`lib/sign.sh`), so the containers, which
run unreviewed AUR code, never see the key. It lives only in `/etc/distro-builder/gnupg` (root,
mode 700) on the server, backed up in the homelab vault, from which the "Build server" play
restores it. Without the key (a local test run) nothing is signed and the scripts say so.

The bootc images are signed with a second key, in sigstore format (ECDSA P-256, public part in
`keys/distro-builder-sigstore.pub`), the format `podman`, `skopeo` and bootc verify natively: the
private key and its passphrase live in `/etc/distro-builder/sigstore` (root, mode 700) and in the
homelab vault, like the GPG key. `lib/push-image.sh` signs each bootc and userland image when
pushing it; the signature is stored in the registry next to the image (`sha256-<digest>.sig`).
Without that key the bootc and userland builds fail rather than push an image every client would
refuse (`ALLOW_UNSIGNED=1` for local test runs).

Clients get the public key from this repository, not from the server they verify:

- laptops: `/arkdep/keys/trusted-keys`, which arkdep checks every image against with `gpgv`
  (`gpg_signature_check` in `/arkdep/config`: `1` verifies when a signature exists, `2` refuses
  unsigned images). The installer sets it up; on an existing machine:
  `sudo sh -c 'gpg --dearmor < keys/distro-builder.asc > /arkdep/keys/trusted-keys'`;
- the `[aur]` clients: `pacman-key --add` + `--lsign-key` (see [aur/README.md](aur/README.md));
- the registry's clients (bootc systems, and podman on every laptop for the userland image):
  `/etc/pki/containers/distro-builder.pub` in the image, required for `<server>:5000` by
  `/etc/containers/policy.json` (the base layer `bootc/layers/base`, and the generic overlay of
  `image/arkdep-build.d/depends` for arkdep; bootc
  refuses unsigned updates, podman unsigned pulls); `bootc/install` sets the same up in the live
  system before pulling the image.

### Notifications

Every unit has `OnFailure=notify-failure@%n.service`, so a failed build sends a `[FAILED]` push to
Home Assistant with the end of its journal. The bootc builds retry a failure once, half an hour
later, and only the second failure is reported; a bootc image that fails its boot test is such a
failure ([bootc/README.md](bootc/README.md#building-and-updates)). A successful image build sends "New image ..." (tag
`image-<recipe>`) with its package count, kernel and the changes since the previous image; it is
sent as a warning when the package count drops by more than 20 % (see
[image/README.md](image/README.md#sanity-check)). A bootc image build sends the same as "New bootc image ..." (tag
`bootc-<recipe>`), and a userland image build as "New userland image ..." (tag `userland-userland`,
without a kernel).
