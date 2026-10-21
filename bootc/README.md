# bootc images (`bootc/`)

[bootc](https://github.com/bootc-dev/bootc) images of the hosts, replacing arkdep (trial since
2026-10-07), based on the Arch image of [bootcrew/mono](https://github.com/bootcrew/mono). The T480
runs bootc (`t480`, built weekly) and the P14s stays on arkdep until it moves (`p14s` bootc image by
hand); `../install` sets the schedules. Implementation notes and pitfalls: `CLAUDE.md` in this
directory.

- `layers/`: what goes into the images, one directory per layer (`docs/layers.md`): `base` (boot,
  administration, the registry and bootc updates), `modules/laptop` (power, Wi-Fi, Bluetooth) and
  `modules/workstation` (the userland box), `desktop/sway`, and `host/<host>` (hardware, hostname).
  Each has a `packages.list` and an `overlay/` (files copied to `/`); a host's `layers.list` names
  the layers of its image in order. Taken from the arkdep recipes on 2026-10-18 (since then
  `image/arkdep-build.d` is frozen: fixes only, for the P14s).
- `Containerfile`: CachyOS v3 repositories (`layers/base/pacman.conf`) and `linux-cachyos`;
  `bootc` from the `[aur]` repository (`aur/local/bootc`: pinned version, no SELinux); composefs
  backend.
- `apply-layers`: installs each layer's packages and copies its overlay, then presets and
  locale-gen.
- `build`, `prune`: build, rechunk and push; retention in the registry.
- `install`: installs an image from the installer ISO (`/root/install`), on a whole disk or keeping a
  `/home` partition (see below).

## Building and updates

- `bootc/build <host>` builds `bootc/Containerfile` (which installs `bootc` from `[aur]` and
  applies the host's layers with `apply-layers`), splits the image into per-package layers
  with [chunkah](https://github.com/coreos/chunkah) and pushes it to the registry with skopeo
  (the compressed layers as chunkah writes them) as `<recipe>:candidate`. An image with more than
  20 % fewer packages than the previous one is not pushed (a stage of the recipe that installed
  nothing).
- `bootc/test` then tests the candidate in VMs (QEMU, KVM, UEFI), checked over SSH: installed
  new (pulled as the clients would, signature checked), then updated by `bootc-update` to the
  current `latest` made to fail its boots, which must bring the candidate back by itself (boot
  counting, below); and as an update: the current `latest` installed, given a machine's local
  state (a user, the hostname, an edited file, a port opened with `fw`, a file in `/var`),
  switched to the candidate with `bootc switch` and rebooted. Only when both pass (no failed unit,
  the local state kept, the old image as the rollback, the update counted and marked good), do
  `<recipe>:YYYY-MM-DD` and `<recipe>:latest`, the tag the bootc systems follow,
  name it, and the package list goes to `/mnt/repo/bootc/<recipe>/` for the notification. After a
  failed test `latest` stays where it was, the candidate stays in the registry for review, and the
  serial logs are `http://<server>/bootc/<recipe>/candidate.log` and `candidate-update.log`.
  The tests catch what breaks the boot or the update (initramfs, composefs, the `/etc` merge,
  failing units, emergency mode), not hardware drivers or the desktop.
- A failed build is retried once, half an hour later; only the second failure is notified.
- Each image is signed with the build server's sigstore key when pushed; the signature lives in
  the registry next to it (`sha256-<digest>.sig`), and the bootc systems refuse an unsigned image
  of `<server>:5000` (`/etc/containers/policy.json` and `registries.d/50-distro-builder.yaml`
  of the base layer, the same files as the arkdep recipes' generic overlay; public key
  `keys/distro-builder-sigstore.pub` copied to `/etc/pki/containers/distro-builder.pub`).
  The status page marks each image "signada" or "sense signar". A build without the signing key
  fails instead of pushing an image the clients would refuse.
- `bootc/prune <recipe>` keeps the newest 4 dated images (`KEEP`), with their signatures, deletes
  the signatures of images no tag names any more (a second build of the same day replaces the
  image of that date), and garbage-collects the registry (`--dry-run` shows what it would do). Both run under the same lock as the arkdep builds, one at a time.
- Scheduled weekly by `build-bootc@<recipe>.timer` for the recipes in `BOOTC_RECIPES` of
  `install` (default `t480`); run it now, for any recipe, with
  `sudo systemctl start build-bootc@p14s` and follow it with `journalctl -fu build-bootc@p14s`.
- On a bootc system `bootc-update.timer` (after boot and every 4 hours, skipped away from home)
  downloads and stages the newest image of its tag; it starts on the next boot. The waybar
  indicator (`arkdep-update-status`, same module as arkdep's) shows a staged image with its package
  changes; a click (or `sudo bootc-update`) looks for a newer one now.
- Boot counting: an update gets three tries. Its boot entry is renamed `...+3.conf` when bootc
  applies it at the shutdown (`bootc-boot-count`, in `bootc-finalize-staged.service`);
  systemd-boot takes a try at each boot of it, and `systemd-bless-boot` marks it good (drops the
  counter) once a boot ends without a failed unit (`systemd-boot-check-no-failures`). After three
  boots that do not (a hang or emergency mode needs the power button each time) systemd-boot boots
  the previous image again by itself. `bootc-update` does not stage the failed image again, and it
  and the waybar indicator (red) report it; the next build that passes its tests replaces it.
- The registry (`serve/distro-registry.container`, `registry:2`, storage in `/mnt/repo/registry`)
  serves plain HTTP on port 5000; the images list it as insecure in
  `/etc/containers/registries.conf.d/50-distro-builder.conf`. A bootc system follows a recipe with
  `bootc switch <server>:5000/<recipe>:latest` and updates with `bootc upgrade`.
- `bootc/install` installs an image from the installer ISO, on a whole disk or keeping a `/home`
  partition: see [below](#installing-a-bootc-image).

## Installing a bootc image

`bootc/install` (on the installer ISO as `/root/install`) installs a host's image from the
registry, in one of two ways:

- **A whole disk** (`--disk`, a new machine; everything on the disk is lost): GPT with a 1 GiB ESP,
  a swap partition the size of the RAM (hibernation), an ext4 root (`--root-size`, 64 GiB) and an
  ext4 home on the rest.
- **Keeping a home partition** (`--root`, `--esp`, `--home`, `--swap`: a reinstall): only the root
  partition is formatted; the ESP is reused (other loaders stay) and the home partition is mounted
  at `/var/home` untouched.

Either way the root is ext4 with fs-verity, systemd-boot comes first in the firmware boot order
with its menu hidden (below), the swap is enabled with `resume=`, and the user (UID 1000, the arkdep installer's
groups) gets the password asked; root stays locked (sudo). The host comes from the machine model
(`20Y1` p14s, `20L5`/`20L6` t480) or a menu of the registry's images, the hostname from the image
(`--hostname` to change it), and Wi-Fi networks joined in the live system are copied. Every
answer can be given as an option (`bootc/install` header); `iso/test-install` runs both ways
unattended in a VM (see [iso/README.md](../iso/README.md)).

Before, on the old system:

1. Back up what cannot be lost: the root partition is formatted (the home partition is not, but a
   wrong partition name would be).
2. Keeping the home: the user's directory on the home partition must belong to UID 1000 (`--uid`
   otherwise); note the partitions with `lsblk -f`.

Install:

1. Download the installer ISO, check its signature and write it to a USB stick (the whole device,
   e.g. `/dev/sda`, not a partition: `TRAN` says `usb`; everything on it is lost):

   ```sh
   curl -O http://<server>/iso/sha256sums.txt -O http://<server>/iso/sha256sums.txt.sig
   iso=$(awk '{ print $2 }' sha256sums.txt); curl -O "http://<server>/iso/$iso"
   gpg --dearmor < ~/Projectes/distro-builder/keys/distro-builder.asc > distro-builder.gpg
   gpgv --keyring ./distro-builder.gpg sha256sums.txt.sig sha256sums.txt && sha256sum -c sha256sums.txt
   lsblk -d -o NAME,SIZE,TRAN,MODEL
   sudo dd if="$iso" of=/dev/sdX bs=4M oflag=direct conv=fsync status=progress
   ```

2. Boot it in UEFI mode (ThinkPad: F12; Secure Boot off).
3. Network: a cable, or `iwctl station wlan0 connect <SSID>` (the installer offers it too).
4. Run the installer. It shows what it will format and asks to confirm, then the user's password
   twice:

   ```sh
   /root/install --disk /dev/nvme0n1                      # a whole disk
   /root/install --root /dev/nvme0n1p3 --esp /dev/nvme0n1p1 --home /dev/nvme0n1p4 \
       --swap /dev/nvme0n1p2                              # the T480: keep its home partition
   ```

   It stops before formatting anything if a partition or the user's directory is wrong, and can be
   run again after a failure.
5. Reboot and remove the USB stick.

First session:

1. Log in on tty1: sway starts.
2. If the home partition has an older `~/.dotfiles` checkout, update it (`git stash` local changes
   first) and restow: `cd ~/.dotfiles && git pull && ./install`. `deploy-userland` only clones the
   dotfiles when `~/.dotfiles` is missing.
3. `systemctl --user start deploy-userland` creates `playground` and `userland` and exports the
   apps. It runs by itself when the user manager starts (the first session after boot, SSH too),
   which on a home with older dotfiles happened before step 2. It takes minutes: do not log out or
   reboot until the "Sistema a punt" notification (an interrupted box is created again at the next
   login).
4. Check: `sudo bootc status` (the image and its tag), `systemctl --failed`.
5. A home from another system can hold user configs that win over the image's: move them aside
   (the T480's Artix home had `~/.config/rofi/config.rasi` with its own theme, GTK 3/4
   `settings.ini` and `gtk.css`, a full `~/.config/pipewire/pipewire.conf` and links to old
   dotfiles). Compare `ls ~/.config` with the P14s, which has none of them.

Afterwards, updates are staged by `bootc-update.timer` and shown by the waybar indicator (see
above), and start on the next boot. The boot menu lists each image as `Arch Linux (<recipe> <tag>)`
with the previous one as a fallback, which systemd-boot also boots by itself after three failed
boots of a new image (boot counting, above); `sudo bootc rollback` makes the previous one the
default. The menu is hidden (`timeout 0` in `loader.conf`, written by `install`; since 2026-10-19,
5 s less on every boot): hold Space while the machine starts, or choose *Reinicia al menú
d'arrencada* in the power menu (`$mod+Shift+e`, `systemctl reboot --boot-loader-menu=0`), which
shows it once with no timeout. A machine installed before then keeps its `timeout 5` until its
`loader.conf` is changed by hand:
`sudo unshare -m sh -c 'mount -o remount,rw /boot && sed -i "s/^timeout .*/timeout 0/" /boot/loader/loader.conf'`
(the ESP is mounted read-only; the remount only applies inside `unshare`).

## Building and testing on a workstation

```
podman build --no-hostname -f bootc/Containerfile --build-arg RECIPE=p14s -t localhost/p14s-bootc .
bcvk to-disk --composefs-backend --bootloader systemd --filesystem btrfs --format qcow2 \
    --disk-size 30G --target-transport containers-storage localhost/p14s-bootc disk.qcow2
```

`bcvk` (release binaries at github.com/bootc-dev/bcvk) installs the image to a disk image from an
ephemeral VM, rootless. Boot the disk with QEMU + OVMF like `iso/test-vm`.

## Results (VM, bootc 1.17.0, bcvk 0.21.0, 2026-10-07)

These tests compiled bootc in the Containerfile (since replaced by the `[aur]` package).

- The image matches the arkdep p14s image: same 520 packages and versions except the arkdep stack
  (bootc adds `composefs`, `ostree`, `skopeo`), same enabled system and user units. 4.1 GB.
- Install: ESP + btrfs root, systemd-boot, ~2 min. Boots to sway with waybar (autologin added by a
  test-only layer), no failed units, 11.5-13.6 s in the VM (initrd 6.7-7.2 s: the forced amdgpu
  load, see `docs/todo.md`).
- Updates from a registry (`bootc switch`/`upgrade`), image split per package with
  [chunkah](https://github.com/coreos/chunkah) (128 layers, 1.2 GB, it reads the pacman database
  at `/usr/lib/sysimage`): a full rebuild with the same package versions changed 12 layers, 208 MiB
  downloaded, 7 s to stage, +91 MiB on disk (composefs stores each file once). arkdep downloads the
  whole image (~900 MB) every time. Of the 208 MiB: 118 MiB are the bootc binaries rebuilt from
  source (not reproducible; `install-all` also ships the integration tests), 62 MiB the initramfs
  (regenerated every build), ~28 MiB generated files (pacman db, caches, certificates).
- `/etc` 3-way merge: a local edit to an image file and a new local file survive updates; an image
  change to a file the machine did not touch is applied; when both changed a file, the local copy
  wins and the image change is silently dropped. No `migrate_files` list needed.
- `/var` (journal, `/var/home`) is shared by all deployments. `bootc rollback` works (two
  deployments, each with its own `/etc`).
- `pacman` fails on the read-only `/usr`, as with arkdep; `bootc usroverlay` gives a writable
  `/usr` until the next reboot (try packages without rebuilding).
- Rootless podman and distrobox work as `roger`.

## T480 rehearsal (VM, bootc 1.17.0 -> 1.17.1, 2026-10-08)

A VM with the T480's layout (ESP, swap, ext4 root, ext4 `/home` with the user's files) booted from
the installer ISO (`cow_spacesize=2G`), `bootc/install` downloaded from GitHub:

- Install in ~1 min (pull from the registry included). Boots in 7-8 s, no failed units; sudo, iwd,
  the `/home` partition at `/var/home`, swap (priority 10, after zram), the firmware boot entry.
- `bootc upgrade` to the next build staged it in 8 s (changed layers only). After the reboot the
  install-time kernel arguments (`/home` and swap mounts, `resume=`, `rootflags`) were still there,
  and the `/etc` 3-way merge applied the image's corrected modes (`/etc/systemd` 775 -> 755,
  libvirt's `default.xml` 644 -> 600). The previous image stays as the rollback entry.
- `bootc status` showed no `version` on composefs (1.17.0 and 1.17.1) although the image had the
  label: the composefs backend reads only the manifest annotation, which `bootc/build` now sets too
  (bootc-dev/bootc#2227); `bootc-update` falls back to the image's creation date.
- The `userland` distrobox broke when its first setup was interrupted (see the dotfiles'
  pre-init hook): not bootc specific.

## Problems found

- bootcrew's Arch image has failed to build every day since 2026-09-03 (CI). Building bootc on
  Arch needs `--no-default-features` (the `selinux` feature links libselinux, only in the AUR).
- The recipe's `NoExtract usr/include/*` breaks compiling bootc: the builder stage uses plain Arch.
- podman bind mounts `/etc/resolv.conf` and `/etc/hostname` during builds: `--no-hostname`, and the
  overlay's `resolv.conf` link becomes a tmpfiles.d entry.
- `/usr/local` is a link to `/var/usrlocal`, which bootc never updates after the install: the
  scripts live in `/usr/bin` (the arkdep recipes have them in `/usr/local/bin`).
- Overlays extracted with `tar -xp` kept the checkout's UID 1000 and 775 modes, also on existing
  directories (`/usr`, `/etc/systemd`, `/etc/sudoers.d`): sudo ignored `sudoers.d` and iwd failed
  on D-Bus (the first registry image, `p14s:2026-10-07`). They are now extracted as root like
  arkdep-build's `cp -r`.
- bootc mounts the ESP read-only at `/boot`: `systemd-boot-random-seed.service` fails, masked.
- `bootc install` creates no firmware boot entry (only the `EFI/BOOT/BOOTX64.EFI` fallback):
  `install` adds or reorders it with `efibootmgr`. Reported: bootc-dev/bootc#2557 (`bootctl --root`
  skips EFI variables unless `--variables=yes`).
- No boot menu: `bootctl install` writes a `loader.conf` with every line commented out, so bootc's
  own `timeout 5` (only written when the file is missing) never lands; `install` writes its own
  (with the menu hidden since 2026-10-19, `timeout 0`).
  Reported: bootc-dev/bootc#2558. Every entry was titled "Arch Linux": the titles come from the
  image's os-release.
- `bootc status` shows no version on composefs for an image with only the
  `org.opencontainers.image.version` label: that backend reads the manifest annotation (the ostree
  one the label). `bootc/build` sets both; reported in bootc-dev/bootc#2227 (comment of
  2026-10-08).

## Missing before real use

- Done: the registry on the build server (`insecure` in `registries.conf.d`), retention
  (`prune`), `bootc` packaged once in `[aur]` instead of compiled in every build.
- Done (2026-10-08): image signing, sigstore (see the main README, Signatures).
- Machine-specific kernel arguments: `install` passes the `/home` mount, the swap partition and
  `resume=` with `--karg`, and they survive `bootc upgrade` (rehearsal). Hibernation: not tested.
- `arkdep-diff`. Done: `notify-image`, the status page, updates (`bootc-update.timer`) and the
  waybar indicator. btrbk is not in the bootc images (2026-10-18): its `snapshot_dir
  /arkdep/snapshots` does not exist there and the T480's home is ext4; a backup of the home to the
  server replaces its local snapshots of `~/.gnupg` (`docs/todo.md`).
- The root is ext4 with fs-verity since 2026-10-18 (the T480 reinstalled), a filesystem upstream's
  CI covers; btrfs, "expected to work but not tested", had worked here but hit a kernel fs-verity
  bug with compressed extents.
- Boot counting since 2026-10-19 (above): composefs bootc has none of its own
  (`bootc-boot-failure-detection(7)`: "likely to be added in the future"), so the base layer adds
  systemd-boot's counter to the entry of each update; arkdep's `p14s/update.sh` does the same with
  `+3`, but marks a boot good once `sysinit.target` is reached (no `check-no-failures`).
- No in-place migration from arkdep: `install` reinstalls the root partition and keeps a separate
  `/home` partition (the T480 layout); the P14s has `/home` inside its btrfs root.
