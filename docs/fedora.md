# Trial: the host images on fedora-bootc

The bootc images are built today on Arch (`bootc/`, structure from bootcrew), a platform bootc does
not support: `bootc` packaged here without SELinux, bootcrew's Arch image failing its CI since
2026-09-03, btrfs untested upstream, and workarounds of our own (the pacman database moved to
`/usr/lib/sysimage`, the bootc filesystem layout, dracut's bootc module, the overlays' modes). Fedora
is bootc's reference platform: official base images (`quay.io/fedora/fedora-bootc`), bootc from the
distribution, the ostree backend tested by upstream CI, greenboot (boot counting and automatic
rollback), SELinux. Since 2026-10-09 the hosts only carry the system (kernel, firmware, sway,
power, virtualization): the apps live in the userland box, which stays Arch. Plan: build a `t480`
image on Fedora with the same pipeline, install it on the T480 with `bootc/install` (root
reformatted, home kept), compare it with the Arch image for a few weeks. If it holds, the P14s
(reinstalled anyway to leave arkdep) and later the thin client (`layers.md`) follow.

The trial's recipes are also the first step of phase 2 of `layers.md`: layered Containerfiles with a
manifest next to each layer instead of arkdep's recipes. The package lists are in `fedora/`, one
directory per layer of `layers.md`: `base`, `modules/{laptop,workstation}`, `desktop/sway`,
`host/{t480,p14s}` (`packages.list`, and `remove.list` for what the base image has and a layer
takes out).

## Translation (2026-10-18, fedora-bootc:45)

Checked against `quay.io/fedora/fedora-bootc:45` (`45.20261018.0`, prerelease; `latest` is still
44) and its repositories (`fedora` and `updates-testing`, from which 16 of the packages come
before the release).

- Every package of the arkdep recipes (`depends/generic`, `depends/sway`, `t480`, `p14s`) and every
  command the overlays call has a Fedora package, except `zsh-completions` and the JetBrains Mono
  Nerd font (below). Versions close to Arch's: kernel 7.2.11 (`linux-cachyos` 7.2.9 here), systemd
  262, sway 1.12, mesa 26.2.5, pipewire 1.6.9, tlp 1.10.1.
- Resolved with `dnf` in the base image, for both hosts: the removals take 20 packages (NetworkManager,
  chrony, ~230 MB of firmware for absent hardware; dnf adds their dependents `dracut-network`,
  `clevis-dracut`, `kdump-utils` and `console-login-helper-messages-issuegen`), then the installs
  resolve without conflicts: 490 packages (391 MiB to download) with weak dependencies, 391
  (349 MiB) without. None brings NetworkManager, chrony, tuned or power-profiles-daemon back.
- fedora-bootc already has (not listed in `fedora/`): kernel, dracut, cpio, btrfs-progs,
  zlib-ng-compat, dbus-broker, iptables-nft, nftables, openssh-server and -clients, sudo,
  zram-generator, python3 (`bootc-update`), curl, file, gawk, procps-ng, kbd, vim-minimal, bluez,
  podman, systemd-resolved, systemd-timesyncd (in `systemd-udev`), microcode_ctl and the split
  linux-firmware packages (all of them, but not `iwlwifi-*`). 540 packages, 1.99 GB.

### Renamed

| Arch | Fedora |
|---|---|
| `linux-cachyos` | `kernel` (in the base image), or `kernel-cachyos` from COPR (below) |
| `vi` | `vim-minimal` (base image) |
| `git` | `git-core` |
| `wget` | `wget2-wget` |
| `openssh` | `openssh-server` + `openssh-clients` (base image) |
| `locale.gen` + `locale-gen` | `glibc-langpack-ca`, `-es`, `-en` |
| `mesa` | `mesa-dri-drivers` (VA-API drivers included) + `mesa-vulkan-drivers` |
| `vulkan-intel`, `vulkan-radeon` | `mesa-vulkan-drivers` |
| `pipewire-pulse` | `pipewire-pulseaudio`; `pactl` from `pulseaudio-utils` |
| `xorg-xwayland` | `xorg-x11-server-Xwayland` |
| `adw-gtk-theme` | `adw-gtk3-theme` |
| `gnome-keyring` (PAM module included) | `gnome-keyring` + `gnome-keyring-pam` |
| `sway` | `sway` + `sway-config-upstream` (the overlay brings `/etc/sway/config`) |
| `intel-ucode`, `amd-ucode` | `microcode_ctl` (base image), `amd-ucode-firmware` (base image) |
| `linux-firmware-intel`, `-amdgpu`, `-realtek` | `intel-gpu-firmware`, `amd-gpu-firmware`, `realtek-firmware` (base image) + `iwlwifi-mvm-firmware` (Wi-Fi of both laptops: not in the base image) |
| `intel-media-driver` | `libva-intel-media-driver` |

### Gone

- `arkdep`, `arkane-keyring`, `nss-altfiles` (arkdep only; Fedora's nsswitch has `altfiles`
  for its own reasons), `base` (a meta package), `arch-install-scripts` (no overlay uses it).
- `apparmor`: SELinux instead (below).
- `zsh-completions`: not packaged. The host's zsh keeps zsh's own completions; the box has the rest.
- `tlp-rdw` was never in the recipe and stays out: it works through NetworkManager's dispatcher.

### Not packaged

- **JetBrains Mono Nerd Font** (`ttf-jetbrains-mono-nerd`; the waybar icons are Nerd glyphs, and
  foot, rofi and mako use it): Fedora has `jetbrains-mono-fonts-all` without the Nerd glyphs. The
  Containerfile installs a pinned release of ryanoasis/nerd-fonts with its sha256, rather than a
  COPR for one font.
- **CachyOS kernel**: the COPR `bieszczaders/kernel-cachyos` builds it for Fedora 44, 45 and rawhide
  (`7.2.11-cachyos1`, October 2026). An option, not the default (decisions below).

## Configuration that changes

The overlays are mostly configuration and carry over. What does not:

- **Network**: `remove.list` takes NetworkManager out; `systemd-networkd` (its own package on
  Fedora) and `iwd` with the overlays' `80-wifi`/`89-ethernet` as today; chrony out,
  `systemd-timesyncd` in.
- **Presets**: `81-custom.preset` cannot be copied. It ends with `disable *` and is read before
  Fedora's (`85-bootc.preset`, `86-bootc-standard.preset`, `90-default.preset`), so it would
  disable units the base image needs: `ostree-remount`, `authselect-apply-changes`,
  `selinux-autorelabel-mark`, `rpmdb-rebuild`, `bootloader-update`, `dbus-broker`. The Fedora
  preset lists our enables and disables only, and Fedora's presets do the rest. It disables
  `bootc-fetch-apply-updates.timer` (enabled by `85-bootc.preset`: it upgrades and reboots on its
  own; `bootc-update.timer` stages instead) and whatever the base enables that we do not want:
  `sssd`, `avahi-daemon`, `systemd-homed`, `systemd-oomd` (left out on purpose: `image/CLAUDE.md`,
  memory tuning), `kmsconvt@`, `irqbalance`.
- **nftables**: Fedora's `nftables.service` loads `/etc/sysconfig/nftables.conf`, not
  `/etc/nftables.conf`. Link the first to the second (`fw` and the `include` of `/etc/nftables.d`
  keep their paths) or a drop-in. `etc/iptables/iptables.rules` is unused (no `iptables.service`
  in the preset): left out.
- **AppArmor -> SELinux** (enforcing in the base image): the preset's `apparmor.service`, bootc's
  AppArmor tunables (`bootc/layers/base/overlay/etc/apparmor.d`) and `apparmor` in the `lsm=`
  kernel argument go. The base layer's `lsm=landlock,lockdown,yama,integrity,apparmor,bpf`
  (`usr/lib/bootc/kargs.d/10-base.toml`) would leave SELinux out: the Fedora image does not set
  `lsm=`. Files the overlays add get the policy's default labels at build time; to watch: podman
  volumes (`:Z`).
- **PAM and nsswitch**: authselect manages them (`/etc/pam.d/system-auth`, `nsswitch.conf` a link
  to `/etc/authselect/`). The overlays' `etc/pam.d/login`, `etc/pam.d/passwd` (Arch's files plus
  `pam_gnome_keyring`) and `etc/nsswitch.conf` must not be copied: they would break the logins.
  gnome-keyring at the tty login: the module added to Fedora's `login` and `passwd`, to be worked
  out with authselect.
- **sudo**: Fedora's sudoers has `%wheel ALL=(ALL) ALL`: `etc/sudoers.d/wheel` goes.
- **Locale**: the langpacks instead of `locale.gen` + `locale-gen`; `locale.conf` and
  `vconsole.conf` as they are.
- **dracut**: the base image's dracut configuration carries the bootc and ostree modules;
  `20-omit-unused.conf` (no crypt, LVM, RAID, TPM) must not omit one of them, to be checked
  against the base image's `dracut.conf.d`. `10-gpu.conf` as it is.
- **Package lists**: `bootc/build` writes the `.pkgs` file with `pacman -Q`, `arkdep-update-status`
  compares with `pacman -Q`: on Fedora `rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n'` (same "name
  version" lines, so `notify-image` and the status page stay). `userland-update`'s `pacman` runs in
  the box (Arch): unchanged. chunkah reads the rpm database as well as pacman's.
- **The registry's client config** (`policy.json`, `registries.conf.d`, `registries.d`, the
  sigstore key): the same files. The base image has no `/etc/containers/policy.json`, so ours
  applies as it is.

## Open decisions (for the Containerfile)

- **Kernel**: Fedora's (7.2.11, signed for Secure Boot, the tested path; the trial's default) or
  `kernel-cachyos` from COPR (a third-party repository in the image, off the tested path again).
- **Backend**: ostree (Fedora's default, with greenboot 0.16.4: health checks, boot counting,
  automatic rollback; soft reboots fall back to a normal reboot by themselves) or composefs as
  today (experimental on Fedora too). The trial's default is ostree + greenboot; `bootc/install`
  and `bootc/test` pass `--composefs-backend` today and get a parameter.
- **Root filesystem**: ext4 with verity (`bootc-composefs(7)`: CI covers ext4 and XFS, btrfs is
  untested) or XFS (Fedora's default; with the ostree backend fs-verity is optional).
- **Weak dependencies**: `install_weak_deps=False` saves ~100 packages; check that nothing needed
  comes only as a weak dependency.
- **Slimming the base image**: `sssd-*`, `clevis-*`, `toolbox`, `avahi` (`base/remove.list`).
- **Codecs**: Fedora's mesa has no H.264/HEVC in VA-API. It only matters for apps on the host:
  browsers and players run in the userland box, with Arch's mesa. No RPM Fusion.
