# arkdep images and recipes (`image/`)

@README.md

New packages and configuration go to `bootc/layers`; a fix the P14s needs now goes to both. The
directory goes once the P14s runs bootc.

- `build-image@<recipe>.timer` has `Persistent=true`; the lock the builds share is
  `/run/build-image.lock`.

## Recipe layout (`image/arkdep-build.d/`)

- `p14s/` (Renoir) has its own `update.sh`; `t480/` is a Kaby Lake-R with UHD 620, Intel 8265
  Wi-Fi, 2 batteries and TB3.
- In a device recipe the GPU driver goes in `dracut.conf.d/10-gpu.conf`, TLP in
  `tlp.d/50-<device>.conf`, and it sets `/etc/hostname`.

How `arkdep-build` processes a recipe (relevant constraints):
- `pacman.conf` and `extensions/*` are only read from the device dir, never from `depends/*`,
  hence the symlinks to `common/`. `pacman.conf` is also copied into the image (`/etc/pacman.conf`).
- `pre_build.sh` installs the recipe `pacman.conf` and `mirrorlist` in the builder container;
  `pacstrap` copies that mirrorlist into the image.
- Bootstrap: device + depends `bootstrap.list` via `pacstrap`, then `post_bootstrap` overlays, then
  `pacman -S` of all `package.list` files in an `arch-chroot`.
- `post_install` overlays: the device overlay is copied first, then each `depends` overlay, so a
  depends overlay overwrites a device file with the same path. Use drop-in files instead.
- `post_install.sh` runs `systemctl preset-all` and `locale-gen`, before subvolumes become read-only.
- Extensions run in a subshell (`(source ...)`) and arkdep-build has no `set -e`: a failing
  extension does not stop the build. That is why `image/build` puts the build server's address in
  place of `@SERVER@` in a copy of `arkdep-build.d` (mounted instead of the checkout), not
  `post_install.sh`.

## Gotchas learned the hard way (images)

What the recipes share with the bootc layers has its notes in `bootc/CLAUDE.md`, "What the
layers hold": NoExtract, mirrors, dracut, memory, the journal, TLP, firmware, the lid, the
firewall, the registry's client, the userland boxes and the sway session. The files are the same
(here in `depends/generic` and `depends/sway`, the scripts in `/usr/local/bin`).

- **Builder image age**: the rebuild of `arkdep-builder` (`--pull=always --no-cache`; the age limit
  is `BUILDER_MAX_AGE_DAYS`) prints the arkdep version used (`Builder: arkdep <version>`). When
  debugging, read the code of that version, not upstream HEAD: a builder from 2026-02 had arkdep
  without the package.list fix below.
- **The required `package.list`**: without it, arkdep-build releases before 2026.06.10 silently
  skip the whole secondary stage, depends package lists included. Always check the `.pkgs` count
  of a new image (README, "Sanity check").
- **systemd presets**: first match wins and `81-custom.preset` ends with `disable *`; device presets
  must sort before it (e.g. `80-t480.preset`).
- **Split boot entries** (arkdep 2026.08.17, arkanelinux/arkdep#53): a deploy can write the
  entry's title and the rest into two files a second apart. The menu then shows the deployment
  by its file name plus a title-only entry; the deployment boots fine. Fix by hand on the ESP
  (`sudo sed -i '1i title ...' <entry>` and remove the title-only file) if it bothers. Fixed after
  2026.08.17 with a regression of its own (an empty time in the file name): see `docs/todo.md`,
  "arkdep upstream", before taking a new arkdep release.
- **Migrated files keep numeric GIDs** (`cp -p`): e.g. `wg0.key` is `root:systemd-network` (977, a
  dynamic sysusers GID). If an image changes that GID, networkd cannot read the key.
- **btrfs scrub**: `btrfs-scrub@-.timer` (monthly, from `btrfs-progs`, enabled in `81-custom.preset`)
  scrubs the whole filesystem; on a single device it detects corruption but can only repair
  metadata (DUP).
- **ESP and TRIM** (`81-custom.preset`, 2026-10-18; both were left out by `disable *` before):
  `systemd-boot-update.service` copies a newer systemd-boot from the image to the ESP at boot
  (`bootctl --graceful update`; neither arkdep nor bootc updates it after the install), and
  `fstrim.timer` trims weekly what is mounted without `discard` (ext4 `/home` on the T480; btrfs
  with `discard=async` needs it less, harmless).
- **wait-online**: `systemd-networkd-wait-online.service.d/any.conf` (`--any`, 2026-10-18): the
  default waits for every link, and the dock's unplugged port (`enp5s0`) and `wg0` stay
  "configuring" (2 min timeout, a failed unit; seen on the T480). Nothing at boot wants
  `network-online.target`; a backup unit will.
- **DHCP client identifier**: `ClientIdentifier=mac` in `80-wifi`/`89-ethernet` (2026-10-18):
  every deployment has its own `/etc/machine-id` (not in `migrate_files`), and the default DUID
  made from it gave the P14s a new address with each image. `etc/systemd/network` is in
  `migrate_files`, so the migrated copies win over the image's: an installed laptop needs the
  line added by hand (`sudo sed -i '/^\[DHCPv4\]/a ClientIdentifier=mac' ...`).
- **btrfs mount options**: compression (and other filesystem-wide options) is taken from the
  first mount only, the root from `rootflags=` in the boot template. `compress=` in fstab is
  ignored: until 2026-10-07 the laptop had `compress=zstd` in fstab and no compression at all.
  Both `iso/airootfs/root/systemd-boot.template` and fstab use `compress=zstd:1,noatime`;
  `noatime` is per mount point, so it does belong in fstab.

## Verifying changes without building

- Resolve every package of a recipe against fresh repo databases (use bash; zsh does not word-split):
  `unshare -r pacman -Sy --dbpath <tmp> --config image/arkdep-build.d/common/pacman.conf` (root in a
  user namespace, which `pacman -Sy` requires; the host's mirrorlists are the image's), then
  `pacman -Sp --dbpath <tmp> --config image/arkdep-build.d/common/pacman.conf <pkgs>`.
- The host's own sync databases come from the image build and are stale.
