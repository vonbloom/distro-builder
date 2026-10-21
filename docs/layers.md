# Prospect: layered images for every machine (a thin client included)

Exploration (2026-10-09). It extends the "Layered images" item of `todo.md` (bootc builds) with
what a third kind of machine needs. The goal is bootc everywhere; arkdep goes once the P14s runs
bootc. Since 2026-10-18 the bootc images are built from these layers (`bootc/layers`, below in
Order); the thin client is not there yet.

## Why a thin client

The third kind of machine is a Fujitsu Futro S920 thin client with Arch installed by hand. It has
four jobs:

- a TV PC: Cinnamon (XFCE tried first, leftovers still installed), keyboard and mouse over
  Bluetooth;
- a squeezelite player (Lyrion);
- a Zigbee coordinator: a Sonoff Zigbee 3.0 USB Dongle Plus V2 shared over the network by ser2net;
- the QDevice of a Proxmox cluster (`corosync-qnetd`).

It is updated by hand (`pacman -Syu`), and one broken update takes all four down at once. A fixed
set of services with little local state, where a rollback matters: it fits an image.

Hardware (checked 2026-10-09):

- AMD GX-415GA (Jaguar, 4 cores at 1.5 GHz). **x86-64-v2 only** (no AVX2, BMI2, FMA): the
  CachyOS v3 repositories of the other recipes do not run there.
- 7.4 GiB RAM.
- Transcend 256 GB mSATA (1 GB ESP + ext4 root); the second SATA port is free.
- Radeon HD 8330E (Kabini) with HDMI audio, plus the FCH's HDA analog audio.
- Realtek RTL8111 1 GbE, the only PCIe link (no free slot shows up).
- Broadcom BCM2045 USB Bluetooth.
- UEFI, systemd-boot.

Today it runs `linux-rt`. Audio goes through PulseAudio in system mode (`squeezelite -o pulse`),
chosen so that the player does not depend on a user session; PipeWire is installed too.

## Layers

| Layer | Content | Images |
|---|---|---|
| base | What every machine needs to boot and be administered | `base-v3` (laptops), `base` (x86-64 generic: the thin client) |
| desktop | Session and graphical environment | `sway`, `cinnamon` |
| host | The hardware and the use of one machine | `p14s`, `t480`, `s920` |

Every machine is unique, so the third layer is the host itself. What repeats between hosts goes
into **modules**: a package list plus an overlay, applied inside the host layer. Modules are not
images of their own, so the chain stays linear (base -> desktop -> host).

Where today's `depends/generic` would go:

| Where | What |
|---|---|
| base | `base`, dracut, openssh, sudo, zsh, tmux, smartmontools, nvme-cli, fwupd, zram, nftables + `fw`, journald, locale, sysctl, the registry's client config + sigstore key |
| module `laptop` | tlp, iwd + `80-wifi.network`, brightnessctl, wireless-regdb, `sleep.conf` (hibernation), plymouth, bluez (ready, radio off at startup) |
| module `workstation` | distrobox + `userland-update`/`deploy-userland`, pass, stow. btrbk left on 2026-10-18; libvirt on 2026-10-20, with QEMU moved to the userland box (the test VMs) |
| gone with bootc | arkdep, arkane-keyring, nss-altfiles |

Example of why the split matters: in the base, `deploy-userland` would pull the 1.6 GB userland
image at the thin client's first login.

## Two CPU levels

The same base manifest, built twice. A build argument selects the repositories and the kernel:

- `base-v3`: CachyOS v3 + `linux-cachyos`, for the laptops.
- `base`: Arch only + `linux` (or `linux-rt`), for the thin client.

Each desktop or host declares its base.

- `bootc/Containerfile` copies `common/pacman.conf` today: it would read the recipe's.
- The kernel leaves `depends/generic/bootstrap.list` for the base flavour or the host.
- One more chain per week on the build server (8 GB of RAM, I/O bound builds: `todo.md`).
- Test the generic chain in a VM with an `x86-64-v2` CPU model, to catch any package built with
  v3 instructions. The `[aur]` packages are built for generic x86-64; corosync-qdevice and
  squeezelite already run on the thin client.

## Audio

Whether audio is a system service or part of the user session is a host decision, not a desktop
one. PipeWire, rtkit and wireplumber leave the `sway` layer for two modules:

- `audio-pipewire`: the laptops, as today.
- `audio-pulse-system`: the thin client.
  - `pulseaudio` with its system unit enabled.
  - The user in `pulse-access`, and a `client.conf` pointing at `/run/pulse/native`.
  - No `pipewire-pulse`; Cinnamon only needs `libpulse`.

The alternative that also avoids depending on the graphical session is PipeWire as the user's
service with linger: it starts at boot without a login and uses the laptops' stack, but stays tied
to a user account. PulseAudio is fine; upstream it is in maintenance mode.

## The thin client's host layer (`s920`)

- **Hardware:** `amd-ucode`; firmware for the Kabini GPU and the Realtek NIC; bluez.
- **squeezelite:** today's `squeezelite.conf`.
- **ser2net:** today's `ser2net.yaml`, and a stable device name for the dongle (it is
  `/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_*`).
- **corosync-qdevice:** `corosync-qnetd-certutil -i` at first boot when the NSS database is
  missing (homelab `docs/cluster.md`).
- **Session:** lightdm with autologin, then Cinnamon.
- **Firewall:** the thin client has none today. The image would open SSH, TCP 5403 (qnetd) and the
  ser2net port.
- **Updates:** `bootc-update.timer` stages the new image; the thin client also needs an automatic
  reboot at night. The laptops keep the reboot to the user. With an automatic reboot, the boot test
  before publishing `latest` (`todo.md`, bootc builds) becomes a prerequisite, and so does the
  boot counting of the base layer (since 2026-10-19, `bootc/CLAUDE.md`): after three failed boots
  systemd-boot goes back to the previous image. A kernel panic and emergency mode wait for a
  reset, though: the thin client needs `panic=` (a karg of its host layer) and a reboot out of
  emergency mode, or its services stay down until someone power cycles it.
- **State:** bootc keeps local changes to `/etc` across updates (3-way merge) and never touches
  `/var`. The qnetd NSS database, the Bluetooth pairings (`/var/lib/bluetooth`) and the network
  connections survive without anything like arkdep's `migrate_files`.

## Installing it

- **Back up first:** `ser2net.yaml`, `squeezelite.conf`, `/etc/corosync/qnetd`, the SSH host keys
  and the Cinnamon settings.
- **Installer:** `bootc/install --disk` (since 2026-10-18) partitions the mSATA like a laptop:
  ESP, swap, ext4 root, ext4 home; it needs no RAM for the image (podman's storage borrows the new
  home partition), which matters with 7.4 GiB. A smaller `--root-size` leaves more to the home.
- **Filesystem:** ext4 with fs-verity, the installer's since 2026-10-18 (compressed btrfs hit the
  7.2 fs-verity regression, `todo.md`, sealed images). Before that the options were ext4 or btrfs
  without compression.

## Order

Changed on 2026-10-18: the bootc side skipped phase 1 and went to the layers directly
(`bootc/layers`: `base`, `modules/laptop`, `modules/workstation`, `desktop/sway`, `host/<host>`,
applied in order by `bootc/apply-layers` in the one Containerfile, the same packages and files as
the recipes), and `image/arkdep-build.d` is frozen for the P14s. The thin client needs no arkdep
recipe: it becomes `bootc/layers/host/s920` plus `desktop/cinnamon` and the audio modules. Left
from phase 2: an image per layer in the registry. The original plan:

1. **Phase 1, in today's recipe format.** It works for both arkdep and bootc
   (`bootc/build-recipe.sh` replays the recipe), so the thin client does not have to wait for the
   P14s to move to bootc.
   - Split `depends/generic` into `depends/base`, `depends/laptop` and `depends/workstation`.
     `depends.list` already takes several entries: modules are depends entries.
   - Move the audio stack out of `sway`.
   - Check that the p14s and t480 `.pkgs` lists do not change.
   - Add `depends/cinnamon` and an `s920` recipe with its own `pacman.conf` (no v3) and kernel.
   - Build it with bootc, test it in an `x86-64-v2` VM, install it.
2. **Phase 2, once arkdep is gone.** Real layered Containerfiles (base -> desktop -> host, a
   manifest next to each, like `userland/`), and rebuild only what changed (`todo.md`).

## Open decisions

- **Kernel:** `linux-rt` or plain `linux`. With PulseAudio in system mode, plain `linux` should do.
- **Network:** NetworkManager (Cinnamon's applet) or systemd-networkd (the laptops' choice; one
  cable is enough).
- **Brave on the TV:** in the `s920` layer or as a Flatpak. The `userland` box is too heavy for
  this machine.
- **Filesystem:** decided on 2026-10-18: ext4 with fs-verity, as on the laptops (`bootc/install`).
- **Timing:** the thin client in phase 1 or after phase 2.
