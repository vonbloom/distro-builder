# bootc images (`bootc/`)

@README.md

- `build-bootc@<recipe>`: `bootc/build` (podman build `--pull=newer --no-cache --no-hostname`:
  `newer` keeps the local base image when Docker Hub does not answer, the build upgrades its
  packages anyway; package list to `/mnt/repo/bootc/<recipe>/candidate.packages`, compared with the
  newest `<recipe>-<date>.pkgs` for the 20 % check; chunkah rechunk into an OCI directory layout in
  `/var/tmp` (`-o oci:`, gzip layers), pushed as it is by skopeo (`copy --preserve-digests`),
  signed, then remove the local image; that part is `push_image` in `lib/push-image.sh`, shared with
  the userland image), then `bootc/test` (below). On a pass `tag_image` (same file) points `<date>`
  and `latest` at the candidate: its manifest copied byte for byte through the registry API, so the
  digest and the signature are the candidate's. The list becomes `<recipe>-<date>.pkgs`, then
  `bootc/prune` and `image/notify-image` with `REPO_PATH=/mnt/repo/bootc/<recipe> KIND=bootc`.
- The retry does not hold the lock while it waits: `Restart=on-failure`, `RestartMode=direct` (no
  `OnFailure=` for the first failure), `RestartPreventExitStatus=99`, and `lib/retry-once` exits
  99 when `NRestarts` is already 1, so `notify-failure@` reports only the retry's failure.
  `NRestarts` is reset by every start (timer, status page, by hand). The retry runs the `git pull`
  again.
- `bootc/test [--from <previous> | --fallback <other>] <image>` (since 2026-10-18, the update
  test too; the fallback since 2026-10-19):
  `podman pull --signature-policy` with the base layer's `policy.json` pointed at
  `keys/distro-builder-sigstore.pub` (a missing signature or blob fails here),
  `bootc install to-disk --via-loopback --generic-image` (no firmware boot entry on the build
  server) onto a sparse 20 GB raw file in `/var/tmp`, ext4 like `bootc/install`, with
  `console=ttyS0 systemd.journald.forward_to_console=1`,
  `systemd.mount-extra=LABEL=EFI-SYSTEM:/boot:vfat:ro` and `--root-ssh-authorized-keys` (a
  throwaway key), then QEMU (KVM, q35, Debian's OVMF 4M, user networking with SSH forwarded to
  `127.0.0.1:$SSH_PORT`, 10022). A boot passes when root's SSH answers with a new boot ID and
  `systemctl is-system-running --wait` says `running`, and no line of the serial log matches
  `FAILURE` (also during the shutdown of an update), within `BOOT_TIMEOUT`; the end of the boot
  comes from SSH, not "Startup finished" on the console, whose getty writes terminal resets into
  the middle of the journal's lines (`iso/test-install` saw one cut). On failure the matching
  lines and the tail go to the journal and so to the notification.
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
    Besides KVM, QEMU and OVMF (the main README, build server) it needs ssh and python3. Serial
    log lines that are no unit failures and do not fail it: systemd-resolved "Failed to
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
- The shared lock (`/run/build-image.lock`, taken through `lib/build-lock`) is there for memory,
  and because the registry's `garbage-collect` must never run during a push (it deletes blobs of
  unfinished uploads). prune
  deletes manifests through the API (`REGISTRY_STORAGE_DELETE_ENABLED`), runs
  `registry garbage-collect --delete-untagged` in the `distro-registry` container and then restarts
  it: registry:2 caches blob descriptors in memory, and without the restart a later push skipped
  uploading a blob the collection had deleted (a broken image, seen in a test). That restart is why
  `build-bootc@` has `Wants=distro-registry.service`, not `Requires=` (a restart of a required unit
  stops the requiring one, prune included).
- `bootc` from `[aur]` is signed: the build trusts `keys/distro-builder.asc` and adds `[aur]` only
  for that `pacman -S` (the `selinux` feature, left out, links libselinux).
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
- `layers/` (until 2026-10-18 `build-recipe.sh` replayed the arkdep recipes and undid what bootc
  does not want): a host's `layers.list` must start with `base` (`ci/check` checks the names).
  `apply-layers` applies each layer, then the host directory: `pacman -S --needed` of its
  `packages.list` (one transaction per layer: `linux-cachyos` and `dracut` must stay in the same
  one, dracut provides the kernel's initramfs dependency), then its `overlay/` (below). Then the
  sigstore key from `keys/`, `preset-all` (system and `--global`), `locale-gen`, `pacman -Scc`.
  The build argument and the unit instance keep the name `RECIPE` (`build-bootc@<host>`, the
  registry repository). A file that a later layer's package also ships must not be in an earlier
  layer's overlay (pacman: "exists in filesystem"). The bootc adjustments made in the files copied
  from the arkdep recipes, besides those of the README's problems found (`/usr/bin`, the
  `resolv.conf` link): the references to the scripts, `nsswitch.conf` without `altfiles`, the
  kernel arguments of the arkdep boot template as `usr/lib/bootc/kargs.d/10-base.toml`, no btrbk.
  Checked on 2026-10-18 against `build-recipe.sh`'s
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
  `systemd-boot-update.service` drop-in (below). The registry's client config (`/etc/containers`)
  is the same in the arkdep recipes' generic overlay because the arkdep images pull the userland
  image from the registry too. The key: `apply-layers` here, `common/extensions/post_install.sh`
  for arkdep (`image/build` mounts `keys/`).
- Signing (sigstore, since 2026-10-08): `bootc/build` pushes the candidate with
  `--sign-by-sigstore-private-key /etc/distro-builder/sigstore/distro-builder.private
  --sign-passphrase-file .../passphrase`. `ALLOW_UNSIGNED=1` for local test runs; until 2026-10-18
  a push without the key went unsigned with a warning, and every client would have refused the
  image and stopped updating without a word. The push goes to `<server>:5000`, not localhost: the
  signature names the reference it was pushed as, and the clients' policy uses `matchRepository`.
  skopeo (like podman) only writes sigstore attachments with `use-sigstore-attachments` in
  registries.d: the server gets the base layer's `registries.d/50-distro-builder.yaml` from
  `install`, and `lib/push-image.sh` mounts `/etc/containers/registries.d` into the skopeo
  container. The clients' `policy.json` keeps Arch's default (accept anything) for every other
  registry, so distrobox and dev container images are unaffected. composefs bootc pulls through
  skopeo's image proxy with the default config, which applies `/etc/containers/policy.json`
  (`bootc_composefs/repo.rs`). Until 2026-10-09 an image replaced by a second build of the same
  day stayed, untagged, with its signature (~1 GiB each: the garbage collection only ran when a
  dated tag was deleted); deleting such a signature triggers the collection, which removes the
  untagged image. `candidate` is not a date: prune keeps it; after a failed boot test it names the
  failed image until the next build moves it, and then prune deletes that image's signature and
  the collection the image.
- `bootc-update` (run by `bootc-update.timer`, base layer, enabled by `81-base.preset`):
  `bootc upgrade` (stage only) and `/run/bootc-update/staged` (recipe, version, package list URL)
  for the waybar indicator. The version is the date tag, `org.opencontainers.image.version` (label
  and manifest annotation: README, problems found). `bootc-fetch-apply-updates.timer` stays
  disabled: it reboots by itself and only runs on ostree boots (`/run/ostree-booted`).
- `arkdep-update-status` (sway layer) tells the two apart by `/arkdep/config`: arkdep when it
  exists, bootc otherwise.
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
  - After three failed boots the entry is `+0-3` and sorts last. bootc then takes the booted
    deployment for a queued rollback (it sorts by sort-key only, and the default entry is not the
    booted one), and `bootc upgrade` skips an image that is already a deployment (`validate_update`
    in `bootc_composefs/update.rs`: "matching a non-booted deployment (staged/rollback) means
    skip"): that is why the failed image is not staged again until `latest` moves on. `bootc
    switch` to it fails ("same fs-verity digest"). The report: `bootc-update` prints "Did not
    boot: <title>", the indicator gets the class `failed`. `sudo bootc rollback` would make it the
    default again (bootc asserts exactly two entries).
  - No `panic=` on the command line: a kernel panic hangs. An unattended machine with automatic
    reboots (the thin client of `docs/layers.md`) wants `panic=`. The first update to an image
    with counting is finalized by the image before it: not counted.
- `apply-layers` puts the `SERVER` build argument in place of `@SERVER@` in the staged overlay
  files (`grep -rlZF | xargs sed -i`, which keeps their mode), and refuses to run without it.
- `apply-layers` copies the overlays like arkdep-build's `cp -r`: `tar --no-same-owner
  --no-same-permissions` into a staging directory, then `cp -r` to `/` (existing files and
  directories keep owner and mode; plain `tar -xp`: README, problems found). `COPY` gave existing
  dirs the checkout's 775 (server umask 0002), and tar replaced existing files with the overlay's
  mode (libvirt's 600 `default.xml` became 644). The Containerfile fails the build when
  `pacman -Qkk` reports an owner or mode mismatch (expected: `/proc`, `/sys`, `utempter`) or a file
  belongs to UID 1000; at runtime `/var/...` entries also differ (created by tmpfiles). The base
  layer's `/etc/tmpfiles.d/systemd-resolve.conf` (the `resolv.conf` link) replaces systemd's file
  of that name (its only line is the stub-resolv.conf link; two entries for the path logged
  "Duplicate line" at every boot).
- The read-only ESP (`systemd.mount-extra=...:/boot:auto:ro`; systemd-boot refreshes the random
  seed, so its unit is masked): `systemd-boot-update.service` (enabled since 2026-10-18: nothing
  else updates systemd-boot on the ESP) gets a drop-in that remounts `/boot` read-write in the
  unit's own mount namespace (`PrivateMounts=yes`), as bootc does to write the entries
  (`mount_esp_writable` in `bootc_composefs/boot.rs`): the remount changes the superblock, but the
  system's mount keeps its own read-only flag. Without it `bootctl update` fails as soon as the
  image has a newer systemd-boot than the ESP (the boot test cannot see it: it installs the image's
  own). The remount runs in the same process as the command (`ExecStart=` replaced by `sh -c
  'mount -o remount,rw /boot; exec <upstream command>'`): a remount in `ExecStartPre=`, the first
  version of this drop-in and of `systemd-bless-boot`'s, does not reach `ExecStart=`, which still
  found `/boot` read-only (`systemd-bless-boot`: "Read-only file system", bootc/test with the ESP
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
  which is new with every install (the T480 changed address) and, on arkdep, with every
  deployment (`/etc/machine-id` is not migrated: the P14s changed address with each image). The
  addresses stay dynamic: the same one comes back while the DHCP server remembers the lease.
- `bootc/install`: the root is `mkfs.ext4 -O verity` like bootc's own `to-disk` (btrfs before
  2026-10-18), mounted `noatime` (`rootflags=noatime`). podman's storage cannot sit on the live
  overlayfs root: on a whole disk it borrows the new home partition (`.bootc-install`, removed
  afterwards, so the install needs no RAM for the image), keeping a home a tmpfs (~5 GB of RAM).
  `TMPDIR` and `/var/tmp` (bind mount) go there too: the live overlay has 256 MiB without
  `cow_spacesize=`, and `bootc install` mounts the host's `/var/tmp` into its container for its
  temporary files (`ensure_mirrored_host_mount`); the T480's first install filled it ("no space
  left on device" pulling into the composefs repository, 2026-10-18), which `iso/test-install` had
  not seen because it booted the ISO with `cow_spacesize=2G` (now only for an ISO without podman).
  The ISO brings podman, the base layer's registry config, its `policy.json` as
  `/etc/containers/distro-builder-policy.json` (the pull uses it with `--signature-policy`; the
  live system's own belongs to containers-common) and the sigstore key; on another live system the
  installer installs podman and writes the same files (the key from GitHub). `wipefs` +
  `mount -t ext4` (udev's cached probe may still say the old filesystem), the target at `/target`
  in the container (`/mnt` links to `var/mnt` in a bootc image), user/hostname/Wi-Fi written to
  `/state/deploy/<id>/etc` and `/state/os/default/var` (`useradd --prefix`), and an `efibootmgr`
  entry. It deletes the ESP's `bootc_*.conf` entries (and `EFI/Linux/bootc_composefs-*`) whose
  root is the reformatted partition or gone: they share title and sort key with the new one and
  the version is a hash, so systemd-boot booted a stale one in a rehearsal. It writes
  `loader.conf`: the menu hidden (`timeout 0`, since 2026-10-19: boot counting falls back without
  it) and the arkdep installer's other lines. `loader.conf` belongs to the machine, not the image:
  a change here reaches installed machines only by hand (`README.md`, boot menu).
- `fs-verity ... FILE CORRUPTED!` in the T480's kernel log (kernel 7.2.9-1-cachyos) was the btrfs
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

## What the layers hold: notes and pitfalls

The arkdep recipes have the same files (`image/arkdep-build.d/depends/generic` and `depends/sway`,
the scripts in `/usr/local/bin` there): a fix the P14s needs while it runs arkdep goes to both.

Base layer (`layers/base`):

- **NoExtract and hardlinks**: pacman cannot create a hardlink whose target was excluded. This broke
  `glibc-locales` (shared `LC_*` files). Locales are now generated with `locale-gen` from
  the overlay's `etc/locale.gen`; do not reintroduce `glibc-locales`.
  When adding a NoExtract rule, check the package for hardlinks (`bsdtar -tvf` shows `link to`).
- **NoExtract rules** live in `pacman.conf` (last matching pattern wins). They drop docs, non
  ca/es/en translations, headers (no compiler on host), unused JetBrains Mono Nerd variants and
  Intel platform firmware not used by any device. `i915` firmware must stay (T480).
- **Mirrors**: a single stalled mirror fails the whole transaction ("Operation too slow"); keep
  several servers in `mirrorlist`.
- **dracut modules left out** (`dracut.conf.d/20-omit-unused.conf`): no LUKS (`crypt`,
  `systemd-cryptsetup`, `dm`, `fido2`, `pkcs11`), RAID, LVM, TPM measurements or `hwdb` in the
  initramfs, and of fsck only ext4's (the root; the arkdep recipes, with a btrfs root, have none).
  Encrypting a disk or using RAID, LVM or TPM-bound secrets needs their modules back there first, or
  the system will not find its root.
- **Memory tuning** is a hand-picked subset of `cachyos-settings` (the package itself is not
  installed: it pulls `ananicy-cpp` and gaming/NVIDIA tweaks): `sysctl.d/99-optimizations.conf`,
  zram as big as RAM, `udev/rules.d/30-zram.rules` (zswap off once zram is up) and
  `tmpfiles.d/thp.conf`. Compare with the current package (`pacman -Sp cachyos-settings`) when
  revisiting it. Its `systemd-oomd` slice defaults are left out on purpose: oomd kills whole leaf
  cgroups, and the `userland` distrobox is a single podman scope holding Brave, VS Code and the
  terminals, so it would be the likely victim when dev containers exhaust memory.
- **Journal**: capped with `SystemMaxUse=1G` in `journald.conf.d/50-size.conf` (the default would be
  4 GiB). bootc shares `/var/log/journal` between deployments; arkdep keeps one per deployment.
- **Lid and suspend** (`etc/systemd/logind.conf`): the lid suspends only on battery
  (`HandleLidSwitchExternalPower=ignore`): logind counts as docked only while an external display is
  connected, so turning off the P14s' monitors on the dock (lid closed) suspended it.
  `IdleAction=ignore`: logind's idle suspend (it was `suspend` after 15 min) never saw a sway
  session as idle (no idle hint) but did act with no session at all, at the login prompt or over SSH
  (the T480 on its charger, reached by SSH, suspended). swayidle locks after 10 min and, on battery
  only (`systemd-ac-power || systemctl suspend`), suspends after 15 min.
- **Firewall** (`etc/nftables.conf`, `usr/bin/fw`): `fw` used to add elements to sets the ruleset
  did not define, ignore the failure and then dump `nft list ruleset` over `/etc/nftables.conf`
  (libvirt tables and counters included, `destroy table` gone): the port stayed closed and the file
  no longer matched the image (2026-10-13). Now the sets live in `nftables.conf`, which includes
  `fw.nft` with a wildcard (a missing directory is no error), `fw` only rewrites that file, and it
  restores the previous one when `nft -c` fails. The sets have `flags interval`: a port inside an
  open range is a conflict that `nft -c` catches; without that check the whole ruleset, and so the
  firewall, would fail to load at boot. Test changes without root in a network namespace: `unshare
  -rn nft -f <copy of nftables.conf>`.
- **Registry client**: the base layer's `policy.json` overrides `containers-common`'s. A
  `~/.config/containers/policy.json` would take precedence for rootless podman (none on the
  laptops, 2026-10-09).

Laptop module and hosts:

- **TLP precedence**: `/etc/tlp.conf` is read after `/etc/tlp.d/*.conf` and overrides it, so the
  laptop module's `tlp.conf` must not set host specific options (the host's `tlp.d/50-<host>.conf`).
  `CPU_SCALING_*_FREQ` values are in kHz.
- **Firmware**: never use the `linux-firmware` meta package; pick split packages per host. To find
  what a machine needs: `modinfo -F firmware` over `lsmod` and map files to packages with `pacman
  -Ql linux-firmware-*`.

Workstation module:

- **Userland boxes** (`userland-update`, `deploy-userland`): the boxes come from the userland image
  (`userland/`). `userland-update` pulls it, reads the manifest it carries
  (`/usr/share/userland/distrobox.ini`), pins its `image=` lines to the digest it pulled and runs
  `distrobox assemble create --replace --name userland`; it asks before replacing a running box
  (its apps close) unless `--yes`, copies the image's D-Bus services to
  `~/.local/share/dbus-1/services` (plain files: the dotfiles' former links there are replaced, not
  written through) and removes the previous image. It also removes the services there that start
  something in userland (`Exec=/usr/bin/distrobox enter userland ...`) and the image no longer
  ships, and syncs them on every run, not only when it replaces the box: gvfs moved to the host
  images (sway layer, below), and a box updated before the host image kept the old
  `org.gtk.vfs.Daemon.service`, which wins over the host's (`$XDG_DATA_HOME` comes first). Once
  userland is replaced it runs `userland-update-status refresh` (sway layer, when present), so
  the waybar notice goes whether the update ran from the module's click or from a terminal (it
  stayed until the hourly check when only the click refreshed it, 2026-10-16). `--dry-run` shows
  what would change; an older tag as argument goes back to it. `playground` keeps its image and its experiments until
  `userland-update --playground`, which moves it to userland's image and reinstalls the packages
  added in it (`pacman -Qqe` of the box minus `pacman -Qq` of the image, then `pacman -Syu
  --needed`). The lock is `flock -o` on a re-exec: a lock descriptor inherited by the boxes'
  conmon (distrobox starts them) stayed held for as long as the box ran (first version).
  `deploy-userland` (when the user manager starts: the first session after boot, SSH too) only
  runs it when there is no `userland` box: updates are the user's call. Before the image, the box
  was assembled from the dotfiles' `default.ini` and installed hundreds of packages on its first
  start; a session that ended meanwhile left it half set up (bootc T480 rehearsal, 2026-10-08),
  which a box from the image (nothing to install, `/.containersetupdone` in it) cannot be.

Sway layer (`layers/desktop/sway`):

- **Menus**: every system menu is a rofi script in `usr/bin` (e.g. `power-menu`, bound to
  `$mod+Shift+e` and the waybar power button), using the system theme (`/etc/rofi.rasi`). Do not add
  GTK menus (waybar `menu-file`) or swaynag dialogs. `keys-menu` (`$mod+F1`) lists the `bindsym`
  lines of the running sway config: when adding a binding with a new kind of command, add its
  Catalan description to `describe()` there (otherwise the raw command is shown).
- **Light/dark mode**: `darkman` (started by `sway-session.target`, location in
  `/etc/xdg/darkman/config.yaml`) runs `/usr/share/darkman/desktop-theme light|dark` at sunrise
  and sunset (`darkman toggle`: `$mod+Shift+t`, power menu). It sets gsettings `color-scheme`
  (apps through xdg-desktop-portal-gtk), `gtk-theme` (`adw-gtk3[-dark]`; icons stay Adwaita),
  the rofi theme (`~/.local/share/rofi/themes/current.rasi`), the mako mode
  `light` and the wallpaper folder (`pickwall`: `~/.local/share/wallpapers/{dia,nit}`). Waybar,
  foot and VS Code (no `window.autoDetectColorScheme` in the dotfiles) stay dark on purpose. New
  themed components belong in that hook.
- **sway autostart** (`etc/zsh/zlogin`): a login shell starts sway only when `$TTY` is `/dev/tty1`.
  It used `XDG_VTNR -eq 1`, which every process of the graphical session inherits: after an attach
  over SSH, tmux marks `DISPLAY` and `WAYLAND_DISPLAY` removed in that session
  (`update-environment`), so each new window or pane ran zlogin, tried a second sway and closed at
  once (2026-10-12). A `~/.config/zsh/.zlogin` turns it off.
- **Secret Service** (sway layer, since 2026-10-08): `gnome-keyring` (11 MB with gcr and gcr-4;
  `oo7` has fewer dependencies but takes 25 MB and is 0.6), started by
  `gnome-keyring-daemon.socket` (user preset) and unlocked at the tty login by `pam_gnome_keyring`
  in `etc/pam.d/login` (overrides util-linux's file: keep it in line with it) and kept in sync on a
  password change by `etc/pam.d/passwd` (shadow's). Brave and VS Code run in the userland box and
  reach it on the host's session bus, but on sway they do not detect it: the dotfiles set
  `--password-store=gnome-libsecret` (`brave-flags.conf`, `~/.vscode/argv.json`) once the images
  have the keyring. Check with `secret-tool store --label=t a b` and `secret-tool lookup a b`.
  gcr-4 also brings `gcr-ssh-agent`, which sets `SSH_AUTH_SOCK` for the systemd user manager: the
  user preset disables it (and openssh's `ssh-agent.socket`), SSH keys are gpg-agent's. The user
  preset has no `disable *`, so every packaged user unit with an `[Install]` section is enabled.
- **gvfs** (sway layer, since 2026-10-21; in the userland box before): the file dialog of Brave
  and the other box apps is xdg-desktop-portal-gtk's, on the host, and its GIO sees `smb://` only
  through the host's gvfs (a download could not be saved to a share). The portal returns a
  remote file as its FUSE path (`/run/user/<uid>/gvfs/smb-share:...`, GTK3's local-only chooser),
  which the boxes see because the host's gvfsd-fuse mounts it and `/run/user/<uid>` is `rslave` in
  them; a gvfsd started in a box (the old `org.gtk.vfs.Daemon.service`) mounted it in the box's
  namespace only. Thunar in the box keeps `gvfs` (GIO's client module) and talks to the host's
  daemon over the session bus. gvfs adds ~11 MB of packages (smbclient the most) and no user unit
  with an `[Install]` section (all D-Bus activated).
- **Podman storage** (`podman-cleanup.timer`, user, monthly, sway layer): removes images unused by
  any container for 30 days and old VS Code server versions in the dev containers' shared `vscode`
  volume (VS Code adds one per update and never removes them: 10 versions, 6 GB in 2026-10), and all
  but the highest version of each extension download in its `extensionsCache` (`sort -V`, `.sigzip`
  signatures go with their package; an age limit kept nearly everything: some extensions publish
  daily, 8 GB in a month). It never removes containers or volumes. After a VS Code update, windows
  of several dev containers restored at once race to install the new server into that shared volume:
  the losers fail (`mv -n ...` then `rmdir: ... Directory not empty`), "Reload Window" fixes them
  (the server is installed by then). Accepted (2026-10-08): `dev.containers.cacheVolume: false` (a
  server per container) or `window.restoreWindows: one` would avoid it at a permanent cost.
- **Slow shutdown with containers**: rootless containers started outside systemd (VS Code
  devcontainers, distrobox) kept their conmon scopes alive until the 90 s stop timeout.
  `podman-stop-all.service` (user, sway layer) runs `podman stop --all` when the session ends, and
  `user.conf.d/50-stop-timeout.conf` caps any user unit or scope at 15 s.
- **Waybar icons**: the font is JetBrainsMono Nerd Font, which lacks Font Awesome 5/6 codepoints
  (e.g. `U+F590`, `U+F769`): use Nerd Font glyphs (`md-*`) and check new ones with
  `fc-list ":charset=<hex>"`.
- **Waybar config**: module settings and the layout live in `/etc/xdg/waybar/bar.jsonc`;
  `config.jsonc` only lists the bars per output and includes it. The external monitors' bar
  overrides `modules-right` without `backlight` (keys in the including bar win), so add or remove
  right-side modules in both lists. Test a change with `waybar -c <copy>/config.jsonc` (rewrite the
  absolute include path to the copy).
