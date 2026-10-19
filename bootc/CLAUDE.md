# bootc images (`bootc/`)

- `build-bootc@<recipe>`: `bootc/build` (podman build `--pull=newer --no-cache --no-hostname`:
  `newer` keeps the local base image when Docker Hub does not answer, the build upgrades its
  packages anyway; package list to `/mnt/repo/bootc/<recipe>/candidate.packages`, and no push
  with more than 20 % fewer packages than the newest `<recipe>-<date>.pkgs`, `ALLOW_FEWER_PACKAGES=1`
  for a recipe that drops them on purpose; chunkah rechunk into an OCI directory layout in
  `/var/tmp` (`-o oci:`, gzip layers), pushed as it is by skopeo (`copy --preserve-digests`) to
  `192.168.2.50:5000/<recipe>:candidate`, signed, then remove the local image; that part is
  `push_image` in `lib/push-image.sh`, shared with the userland image), then `bootc/test` (below).
  Only when it passes does `tag_image` (same file) point `<date>` and `latest` at the candidate:
  its manifest copied byte for byte through the registry API, so the digest and the signature are
  the candidate's. The list becomes `<recipe>-<date>.pkgs`, then `bootc/prune` and
  `image/notify-image` with `REPO_PATH=/mnt/repo/bootc/<recipe> KIND=bootc`. Weekly, Sunday 13:00
  Europe/Madrid.
- A failure is retried once, 30 min later and without holding the lock meanwhile:
  `Restart=on-failure`, `RestartMode=direct` (no `OnFailure=` for the first failure),
  `RestartPreventExitStatus=99`, and `lib/retry-once` exits 99 when `NRestarts` is already 1, so
  `notify-failure@` reports only the retry's failure. `NRestarts` is reset by every start (timer,
  status page, by hand). The retry runs the `git pull` again.
- `bootc/test [--from <previous> | --fallback <other>] <image>` (since 2026-10-18, the update
  test too; the fallback since 2026-10-19):
  `podman pull --signature-policy` with the base layer's `policy.json` pointed at
  `keys/distro-builder-sigstore.pub` (what the clients check: a missing signature or blob fails
  here), `bootc install to-disk --via-loopback --generic-image` (no firmware boot entry on the
  build server) onto a sparse 20 GB raw file in `/var/tmp`, ext4 like `bootc/install`, with
  `console=ttyS0 systemd.journald.forward_to_console=1`,
  `systemd.mount-extra=LABEL=EFI-SYSTEM:/boot:vfat:ro` and `--root-ssh-authorized-keys` (a
  throwaway key), then QEMU (KVM, q35, Debian's OVMF 4M, user networking with SSH forwarded to
  `127.0.0.1:$SSH_PORT`, 10022). A boot passes when root's SSH answers with a new boot ID and
  `systemctl is-system-running --wait` says `running`, and no line of the serial log matches
  `FAILURE` (also during the shutdown of an update), within `BOOT_TIMEOUT`; the end of the boot
  comes from SSH, not "Startup finished" on the console, whose getty writes terminal resets into
  the middle of the journal's lines (`iso/test-install` saw one cut). On failure the matching
  lines and the tail go to the journal and so to the notification, the whole serial log to
  `candidate.log` (and `candidate-update.log`) next to the package lists.
  - The ESP karg: the ESP read-only at `/boot` (with systemd's `fmask=0022`), as bootc writes it
    for an install onto partitions (`bootc/install`: `systemd.mount-extra=UUID=<ESP>:/boot:auto:ro`).
    `to-disk`'s own layout writes none and leaves the ESP to systemd-gpt-auto-generator: an
    automount, read-write and `umask=0077`, under which the first fallback runs passed without
    exercising the read-only remounts of `bootc-boot-count` and `systemd-bless-boot` (a bless that
    failed on the T480's read-only ESP would make every good update fall back after three boots).
    The test fails when `/boot` is not mounted `ro` after the first boot. The waybar indicator,
    which reads the entries as the user, runs as `nobody` in the fallback test.
  - `bootc/build` runs it twice: the candidate installed new with `--fallback
    <repository>:latest`: installed with `--target-imgref` latest (what an install follows), so
    the VM's own `bootc-update` stages latest as the clients' timer does; the staged entry gets
    `systemd.unit=reboot.target` (edited in `entries.staged` in a mount namespace of its own,
    found by the `depl_id` like `bootc-boot-count`), and after the reboot the candidate's
    `bootc-boot-count` counts it, three boots reboot at once (no SSH: `boot` just waits for a new
    boot ID), and the fourth must be the candidate again: its digest booted, latest's entry
    `+0-3`, `bootc-update` reporting "No update staged" (bootc upgrade skips the rollback) and
    "Did not boot", the indicator's class `failed` (when the image has the sway layer). Then
    `--from <repository>:latest`:
    the current latest installed and booted, given a machine's state over SSH (`useradd`, the
    hostname, a line appended to `/etc/issue`, `fw allow 12345`, a file in `/var/lib`), `bootc
    switch` to the candidate inside the VM (the clients' pull: composefs, the signature, chunkah's
    layers), `systemctl reboot` in the same QEMU, then: booted digest = the candidate's manifest in
    the registry, rollback = latest, two boot entries, the local state kept, and, when latest has
    `bootc-boot-count` (the finalization at the shutdown is latest's), the update counted and
    marked good (`systemd-bless-boot.service` active, no counter left in the entry names). A
    host's first image (no latest) gets only the install. `--from` and `--fallback` need signed
    images: the VM's own policy checks.
  - A unit that fails only in a VM gets an exception in `FAILURE`, never removed from the image.
    Needs `/dev/kvm` (VM 202 `cpu: host`, nested KVM on zeus), `qemu-system-x86` + `ovmf`
    (homelab "Build server" play), ssh and python3. Not tested: hardware drivers, the desktop.
    Serial log lines that are no unit failures and do not fail it: systemd-resolved "Failed to
    open /etc/resolv.conf: Permission denied" (a fresh install only, before tmpfiles links it),
    and, on the T480 too, `systemd-tmpfiles` "fchmod() of / failed: Read-only file system" and
    `set-wireless-regdom` exiting 1. Its EXIT trap runs with `set +e`: with `set -e` the second
    `podman rmi` of an image already removed made a passed test exit 1. The zram device reset at
    the shutdown (`systemd-zram-setup@.service`'s `ExecStop=`) once failed with "Device or resource
    busy" right after the swap on it went off, a failed unit in the shutdown of an update: the base
    layer ignores that failure (drop-in `reset.conf`), harmless at a shutdown.
  - The SSH login as root starts root's user manager: `deploy-userland` (a user unit enabled
    for every user) has `ConditionUser=!@system` since then, or it would clone the dotfiles and
    pull the userland image for root, and the login would wait for it. The user managers' lines
    (`systemd[<pid>]` other than 1, `USER_MANAGER`) do not count as failures: in root's,
    pipewire's `ConditionUser=!root` left wireplumber and filter-chain with "Dependency failed"
    (the first two test builds, 2026-10-18). No user manager runs for root on a real machine.
- Promoting a candidate by hand, after reviewing a failed test (`candidate.log`,
  `candidate-update.log`) and deciding it is the test's fault: from the server's checkout, as
  root, `. lib/push-image.sh && tag_image <host> candidate <YYYY-MM-DD> latest`, then
  `mv /mnt/repo/bootc/<host>/candidate.packages /mnt/repo/bootc/<host>/<host>-<YYYY-MM-DD>.pkgs`
  (the date of the candidate's build: its `org.opencontainers.image.version`). Never for a
  failure of the image itself: fix it and build again.
- Build and prune run under `/run/build-image.lock` with the other builds: memory, and the
  registry's `garbage-collect` must never run during a push (it deletes blobs of unfinished
  uploads). prune deletes manifests through the API (`REGISTRY_STORAGE_DELETE_ENABLED`), runs
  `registry garbage-collect --delete-untagged` in the `distro-registry` container and then restarts
  it: registry:2 caches blob descriptors in memory, and without the restart a later push skipped
  uploading a blob the collection had deleted (a broken image, seen in a test). That restart is why
  `build-bootc@` has `Wants=distro-registry.service`, not `Requires=` (a restart of a required unit
  stops the requiring one, prune included).
- `bootc` comes from `[aur]` (`aur/local/bootc`, without the `selinux` feature, which links
  libselinux), signed: the build trusts `keys/distro-builder.asc` and adds `[aur]` only for that
  `pacman -S`. Local test runs: `REGISTRY=127.0.0.1:5000 PKGS_DIR=... AUR_SERVER=... AUR_SIGLEVEL=Never
  ALLOW_UNSIGNED=1` (as root, with KVM and the Arch OVMF paths of `bootc/test`).
  Test runs on the server: `REPOSITORY=test/<recipe> PKGS_DIR=/var/tmp/...` from a copy of the
  checkout (`git ls-files -z | tar --null -T - -c...`, never edit `/home/admin/distro-builder`:
  its `git pull --ff-only` would fail), then delete the test manifests through the registry API.
- chunkah (`quay.io/coreos/chunkah`) and skopeo (`quay.io/skopeo/stable`) run as containers pinned
  to a version (`lib/push-image.sh`): chunkah's gzip output is byte-identical for identical input
  (two runs, 2026-10-09), so unchanged layers keep their digests and clients skip them; a new
  chunkah could change every digest and make every client download the whole image (~1 GiB). Bump
  the pin on purpose.
  The push went from `podman load` + `podman push` (an uncompressed import of ~3.5 GB, then
  recompression) to skopeo on 2026-10-09: the first image pushed that way uploads, and clients
  download, every layer once (podman's gzip bytes differ from chunkah's).
- The CachyOS key is `keys/cachyos.asc` (exported from `cachyos-keyring` 20240331, fingerprint
  `882DCFE48E2051D48E2562ABF3B607488DB35A47`, the same key keyserver.ubuntu.com serves) and
  `cachyos-keyring` comes from `[cachyos]`: until 2026-10-18 each build fetched the key from the
  keyserver and the keyring from a fixed URL, two outside services that could fail the build. The
  arkdep recipe (`common/extensions/pre_build.sh`) and the userland image still do.
- `push_image` labels the image `org.opencontainers.image.revision` with the checkout's commit
  (`git describe --always --dirty --abbrev=40`; `safe.directory` because root runs git in admin's
  checkout; `unknown` in a copy without `.git`): which change built an image that misbehaves.
- `layers/` (since 2026-10-18; until then `build-recipe.sh` replayed the arkdep recipes and undid
  what bootc does not want): `layers/host/<host>/layers.list` names the layers in order (it must
  start with `base`; `ci/check` checks the names), and `apply-layers` applies each one, then the
  host directory: `pacman -S --needed` of its `packages.list` (one transaction per layer:
  `linux-cachyos` and `dracut` must stay in the same one, dracut provides the kernel's initramfs
  dependency), then its `overlay/` (below). Then the sigstore key from `keys/`, `preset-all` (system
  and `--global`), `locale-gen`, `pacman -Scc`. The build argument and the unit instance keep the
  name `RECIPE` (`build-bootc@<host>`, the registry repository). A file that a later layer's
  package also ships must not be in an earlier layer's overlay (pacman: "exists in filesystem").
  Copied from the arkdep recipes with the bootc adjustments made in the files: the scripts in
  `/usr/bin` (not `/usr/local/bin`, a link to `/var` under bootc) and the references to them,
  `nsswitch.conf` without `altfiles`, the overlay's `resolv.conf` link as
  `etc/tmpfiles.d/systemd-resolve.conf`, the kernel arguments of the arkdep boot template as
  `usr/lib/bootc/kargs.d/10-base.toml`, no btrbk. Checked on 2026-10-18 against `build-recipe.sh`'s
  t480 image of the same commit, both built back to back (rootless podman on the P14s): the same
  packages and versions (btrbk aside), the same files, modes, owners and enabled units, the same
  initramfs byte for byte. Contents differed only in two comments of `sudoers` and `pam_env.conf`
  (`build-recipe.sh`'s `/usr/local/bin` sed ran over package files too), in files generated anew by
  every build (`/etc/nvme/hostid`, `hostnqn`, `java-cacerts.jks`, the `-` backups of the account
  files) and in dynamic system IDs: `systemd-sysusers` numbers new users and groups in transaction
  order (one transaction per layer now), so `libvirt`, `qemu`, `dnsmasq`, `fwupd`, `git`, `seat`...
  got other numbers. No image file is owned by them, and an installed system keeps its own
  `/etc/passwd` and `/etc/group` (changed locally by the install, so bootc's merge keeps the local
  copy and sysusers adds new accounts at boot): only a new install sees the new numbers.
- Presets: first match wins; `base/.../81-base.preset` ends with `disable *` (also what systemd's
  `90-systemd.preset` would enable), every other layer has its own `80-<layer>.preset`, which
  sorts before it. Units bootc systems need in the base layer: `@{HOMEDIRS}+=/var/home/` for
  AppArmor (`/home` links to `/var/home`), `bootc-update`, the masked random seed unit, the
  `systemd-boot-update.service` drop-in (below). The registry's client config (`/etc/containers`:
  insecure in `registries.conf.d`, `registries.d`, `policy.json`) is in the base layer and, the same
  files, in the arkdep recipes' generic overlay (the arkdep images pull the userland image from the
  registry too). The key: `apply-layers` here, `common/extensions/post_install.sh` for arkdep
  (`image/build` mounts `keys/`).
- Signing (sigstore, since 2026-10-08): `bootc/build` pushes the candidate with
  `--sign-by-sigstore-private-key /etc/distro-builder/sigstore/distro-builder.private
  --sign-passphrase-file .../passphrase` (root only, restored from the homelab vault); the dated
  tag and `latest` get the same manifest (same digest, same signature). Without the key
  `push_image` fails (`ALLOW_UNSIGNED=1` for local test runs): until 2026-10-18 it pushed unsigned
  with a warning, and every client would have refused the image and stopped updating without a
  word. The push goes to `192.168.2.50:5000`, not localhost: the
  signature names the reference it was pushed as, and the clients' policy uses `matchRepository`.
  skopeo (like podman) only writes sigstore attachments with `use-sigstore-attachments` in
  registries.d: the server gets the base layer's `registries.d/50-distro-builder.yaml` from
  `install`, and `lib/push-image.sh` mounts `/etc/containers/registries.d` into the skopeo
  container. The clients'
  `policy.json` keeps Arch's default (accept anything) for every other registry, so distrobox and dev
  container images are unaffected. composefs bootc pulls through skopeo's image proxy with the default
  config, which applies `/etc/containers/policy.json` (`bootc_composefs/repo.rs`). `prune` deletes every
  `sha256-<digest>.sig` tag whose digest no tag names any more: those of the deleted dated tags,
  and those of images replaced by a second build of the same day (the dated tag and `latest` move
  to the new image; until 2026-10-09 the old one stayed, untagged, with its signature, ~1 GiB
  each, because the garbage collection only ran when a dated tag was deleted). Deleting such a
  signature triggers the collection, which removes the untagged image. `candidate` is not a date:
  prune keeps it; after a failed boot test it names the failed image until the next build moves
  it, and then prune deletes that image's signature and the collection the image. `prune --dry-run` lists it all. Check a policy by hand with skopeo in a container:
  `skopeo copy --policy P --registries.d D --src-tls-verify=false docker://192.168.2.50:5000/t480:latest dir:/tmp/x`
  (an unsigned image: "A signature was required, but no signature exists").
- Updates on bootc systems: `bootc-update.timer` (base layer, enabled by `81-base.preset`) runs
  `bootc-update`:
  `bootc upgrade` (stage only) and `/run/bootc-update/staged` (recipe, version, package list URL)
  for the waybar indicator. The version is `org.opencontainers.image.version` (the date tag), set
  by `bootc/build` as a label (bootc's ostree backend) and a manifest annotation (the composefs
  backend reads only that, bootc-dev/bootc#2227). `bootc-fetch-apply-updates.timer` stays disabled: it reboots by
  itself and only runs on ostree boots (`/run/ostree-booted`).
- `arkdep-update-status` (sway layer) serves both: arkdep when `/arkdep/config` exists, bootc
  otherwise.
- Boot counting (since 2026-10-19; composefs bootc sets up none, `bootc-boot-failure-detection(7)`:
  "likely to be added in the future"; bootc's ostree backend leaves it to greenboot):
  - `bootc-boot-count` (base layer) is an extra `ExecStop=` of `bootc-finalize-staged.service`
    (drop-in `boot-count.conf`): ExecStop lines run in order, the next only after a success, so it
    runs once bootc has swapped `entries.staged` into `entries` at the shutdown. It finds the
    staged deployment's entry by the `depl_id` of `/run/composefs/staged-deployment` in its
    `composefs.digest=` option (the kernel directory can be an older deployment's, reused when
    kernel and initramfs are the same) and renames it `<name>+3.conf`, the ESP remounted
    read-write in the unit's mount namespace. Not at staging time (`bootc-update`): `bootc switch`
    or `bootc upgrade` by hand would miss it, and bootc writes `entries.staged` anew at each
    staging, without counters (primary `-1.conf` with sort-key `bootc-<os>-0`, the booted one
    `-0.conf` with `-1`). bootc reads the entries by contents (any `*.conf`), so the counter in
    the name does not disturb it. `bootc rollback` writes its entries at once (no finalization):
    not counted, it goes to an image that has booted.
  - `systemd-bless-boot.service`, added by its generator only on a boot systemd-boot counted
    (`LoaderBootCountPath`), drops the counter after `boot-complete.target`, which
    `systemd-boot-check-no-failures.service` (`81-base.preset`) makes wait for `default.target`
    without a failed unit. Without that unit `boot-complete.target` only needs `sysinit.target`:
    arkdep's `+3` entries on the P14s are marked good 12 s into the boot. The bless unit gets the
    same read-write remount drop-in as `systemd-boot-update`, in the same process as the command
    (below).
  - After three boots that did not get there the entry is `+0-3`: systemd-boot sorts it last and
    boots the other one. bootc then takes the booted deployment for a queued rollback (it sorts by
    sort-key only, and the default entry is not the booted one), and `bootc upgrade` skips an
    image that is already a deployment (`validate_update` in `bootc_composefs/update.rs`:
    "matching a non-booted deployment (staged/rollback) means skip"), so the failed image is not
    staged again until `latest` moves on; `bootc switch` to it fails ("same fs-verity digest").
    `bootc-update` prints "Did not boot: <title>" and the indicator turns red (class `failed`).
    `sudo bootc rollback` would make it the default again (bootc asserts exactly two entries).
  - A kernel panic hangs (no `panic=` on the command line) and emergency mode waits: every try
    ends with the power button. An unattended machine with automatic reboots (yamaha) wants
    `panic=`. The first update to an image with counting is finalized by the image before it: not
    counted.
- `apply-layers` copies the overlays like arkdep-build's `cp -r`: `tar --no-same-owner --no-same-permissions` into a staging directory, then `cp -r` to `/`
  (existing files and directories keep owner and mode). Plain `tar -xp` kept the checkout's UID
  1000 and 775 modes, also on existing dirs (`/usr`, `/usr/lib`, `/etc/systemd`): sudo ignored
  `sudoers.d` and iwd failed on D-Bus. `COPY` gave existing dirs the checkout's 775 (server umask
  0002), and tar replaced existing files with the overlay's mode (libvirt's 600 `default.xml` became
  644). The Containerfile fails the build when `pacman -Qkk` reports an owner or mode mismatch
  (expected: `/proc`, `/sys`, `utempter`) or a file belongs to UID 1000; at runtime `/var/...`
  entries also differ (created by tmpfiles). `/etc/resolv.conf` is bind mounted during the build:
  the base layer links it with `/etc/tmpfiles.d/systemd-resolve.conf`, which replaces systemd's
  file of that name (its only line is the stub-resolv.conf link; two entries for the path logged
  "Duplicate line" at every boot).
- bootc mounts the ESP read-only at `/boot` (`systemd.mount-extra=...:/boot:auto:ro`), so
  `systemd-boot-random-seed.service` is masked in the base layer (systemd-boot refreshes the
  seed), and `systemd-boot-update.service` (enabled since 2026-10-18: nothing else updates
  systemd-boot on the ESP) gets a drop-in that remounts `/boot` read-write in the unit's own mount
  namespace (`PrivateMounts=yes`), as bootc does to write the entries (`mount_esp_writable` in
  `bootc_composefs/boot.rs`): the remount changes the superblock, but the system's mount keeps its
  own read-only flag. Without it `bootctl update` fails as soon as the image has a newer
  systemd-boot than the ESP (the boot test cannot see it: it installs the image's own). The
  remount runs in the same process as the command (`ExecStart=` replaced by `sh -c 'mount -o
  remount,rw /boot; exec <upstream command>'`): a remount in `ExecStartPre=`, the first version of
  this drop-in and of `systemd-bless-boot`'s, does not reach `ExecStart=`, which still found
  `/boot` read-only (`systemd-bless-boot`: "Read-only file system", bootc/test with the ESP
  read-only, 2026-10-19). Keep the replaced command in line with upstream's unit.
- `network-online.target`: `systemd-networkd-wait-online` runs with `--any` (drop-in in the base
  layer, and in the arkdep recipes' generic overlay): by default it waits for every managed link,
  and an Ethernet port without a cable (or `wg0`) stays "configuring", a 2 min timeout and a failed
  unit (the T480's `degraded`, 2026-10-17). `archlinux-keyring-wkd-sync.timer` (enabled by
  archlinux-keyring with a link in `/usr/lib`, out of reach of the presets) is masked in the base
  layer: it was the only unit pulling in `network-online.target` there, and its weekly refresh
  changed `/etc/pacman.d/gnupg`, which bootc's `/etc` merge then keeps as a local change, so the
  keyrings of later images would not reach it. pacman is not used on a bootc host.
- DHCP: `ClientIdentifier=mac` in `80-wifi.network` and `89-ethernet.network` (2026-10-18; the
  arkdep recipes too). networkd's default client identifier is a DUID made from the machine-id,
  which is new with every install (the T480 went from .182 to .194) and, on arkdep, with every
  deployment (`/etc/machine-id` is not migrated: the P14s changed address with each image). The
  addresses stay dynamic: the same one comes back while the DHCP server remembers the lease.
- `bootc/install` (live ISO, `/root/install`; whole disk with `--disk`, or keeping a home
  partition): every question also an option, so that `iso/test-install` can run it unattended.
  The root is `mkfs.ext4 -O verity` like bootc's own `to-disk` (since 2026-10-18; btrfs before),
  mounted `noatime` (`rootflags=noatime`). podman's storage cannot sit on the live overlayfs root:
  on a whole disk it borrows the new home partition (`.bootc-install`, removed afterwards, so the
  install needs no RAM for the image), keeping a home a tmpfs (~5 GB of RAM). `TMPDIR` and
  `/var/tmp` (bind mount) go there too: the live overlay has 256 MiB without `cow_spacesize=`, and
  `bootc install` mounts the host's `/var/tmp` into its container for its temporary files
  (`ensure_mirrored_host_mount`); the T480's first install filled it ("no space left on device"
  pulling into the composefs repository, 2026-10-18), which `iso/test-install` had not seen
  because it booted the ISO with `cow_spacesize=2G` (now only for an ISO without podman). The ISO brings podman, the base
  layer's registry config, its `policy.json` as `/etc/containers/distro-builder-policy.json` (the
  pull uses it with `--signature-policy`; the live system's own belongs to containers-common) and
  the sigstore key; on another live system the installer installs podman and writes the same
  files (the key from GitHub). `wipefs` + `mount -t ext4` (udev's
  cached probe may still say the old filesystem), the target at
  `/target` in the container (`/mnt` links to `var/mnt` in a bootc image), user/hostname/Wi-Fi
  written to `/state/deploy/<id>/etc` and `/state/os/default/var` (`useradd --prefix`), and an
  `efibootmgr` entry (bootc only installs the `EFI/BOOT` fallback, bootc-dev/bootc#2557). It deletes the ESP's
  `bootc_*.conf` entries (and `EFI/Linux/bootc_composefs-*`) whose root is the reformatted
  partition or gone: they share title and sort key with the new one and the version is a hash, so
  systemd-boot booted a stale one in a rehearsal. It writes `loader.conf`: the menu hidden
  (`timeout 0` since 2026-10-19: boot counting falls back without it; Space held at power-on or
  the power menu's `systemctl reboot --boot-loader-menu=0` shows it) and the arkdep installer's
  other lines. bootc only writes `timeout 5` when the file is missing, and `bootctl install` has
  just created it with every line commented out (bootc-dev/bootc#2558). `loader.conf` belongs to
  the machine, not the image: a change here reaches installed machines only by hand (`README.md`,
  boot menu; the ESP is read-only, remounted inside `unshare -m`). Rehearsed in a VM
  booted from the ISO with a T480-like layout (2026-10-08); `iso/test-install` since 2026-10-18.
- `fs-verity ... FILE CORRUPTED!` in the T480's kernel log (kernel 7.2.9-1-cachyos) is a btrfs
  bug with compressed extents (the root was mounted `compress=zstd:1` by `bootc/install` until
  2026-10-18), not damaged data: the reads succeed on retry. Details, reproducer and options in
  `docs/todo.md`. Gone with the ext4 root; `bootc/test` counts it as a failure again.
- Boot entry titles: bootc uses `PRETTY_NAME` and `VERSION_ID` of the image's `/usr/lib/os-release`;
  the Containerfile sets them to `Arch Linux (<recipe> <tag>)` and `<tag>.<HHMM>` (`VERSION` and
  `VERSION_ID` build args from `bootc/build`; systemd-boot appends the version to equal titles, two
  builds of a day), and links `/etc/os-release` to it (the Arch container image ships its own
  copy) before dracut runs: dracut writes `initrd-release` from `/etc/os-release`, and the
  copy's `VERSION_ID` (the Arch image's build, e.g. `20261011.0.609834`) made a new initramfs
  with every new Arch image until 2026-10-18 (the T480's 2026-10-11 and 2026-10-16 images: the
  same `vmlinuz`, initramfs differing in `initrd-release`, `libzstd` and plymouth's `libfreetype`).
  The initramfs must stay byte for byte the same when its contents do: bootc's soft reboot
  requires the same boot digest (sha256 of `vmlinuz` + initramfs) and kernel command line.
