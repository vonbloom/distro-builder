# Installer ISO (`iso/`)

A live Arch ISO (Arch's `releng` profile) with podman and the bootc installer (`/root/install`,
from `bootc/install`), plus `arkdep` and its installer (`/root/install-arkdep`) until the P14s
leaves arkdep. Each installs the newest image straight from the build server (the registry, or
the arkdep repository). The ISO does not contain an image, so it stays small (~1.7 GB) and never
installs an outdated system; it does need the LAN (cable, or Wi-Fi joined from the installer).
Nothing is downloaded from the Arch mirrors or GitHub during the installation: the registry's
client config and the sigstore key are on the ISO.

## Building

```sh
sudo systemctl start --no-block build-iso   # on the build server, or Executa on the status page
journalctl -fu build-iso
```

`iso/build [output_dir]` builds `iso-builder` on top of `arkdep-builder` (which already trusts the
arkane signing key) with `archiso`, runs `mkarchiso` and moves the ISO to `/mnt/repo/iso/`
(default), replacing the previous one and writing `sha256sums.txt`. `build-iso.service` runs it
after pulling the checkout, one build at a time with the images. There is no timer: rebuild it
when the installer changes or when the live system is too old for new hardware.

## Installing a machine

bootc: `/root/install`, see [Installing a bootc image](../bootc/README.md#installing-a-bootc-image)
(a whole disk, or keeping a home partition). The rest of this section is the arkdep installer.

1. Download the ISO, `sha256sums.txt` and `sha256sums.txt.sig` from `http://192.168.2.50/iso/`,
   check them and write the ISO to a USB stick (the commands are in step 1 of [Installing a bootc
   image](../bootc/README.md#installing-a-bootc-image); `gpgv` cannot read the keyring from a pipe
   such as `<(gpg --dearmor ...)`). The installed system verifies every image with the same key.
2. Boot it in UEFI mode (Secure Boot off) and run `/root/install-arkdep`.
3. Answer the questions:
   - **Network**: if the server is not reachable, the Wi-Fi networks are listed; type the SSID and
     the passphrase. Networks joined here are copied to the installed system.
   - **Recipe**: detected from the machine model (`20Y1*` p14s, `20L5*`/`20L6*` t480); otherwise
     pick one from the recipes found in the repository.
   - **Disk**: the whole disk is wiped; type `yes` to confirm.
   - **Password**: the same for `root` and `roger`.
4. Reboot and remove the USB stick.

What the installer does:

| Step | Details |
|---|---|
| Partitions | GPT: 1 GiB ESP (FAT32, label `EFI`) + the rest btrfs (label `ROOT`) |
| Swap | subvolume `/swap` with a swap file the size of the RAM; `resume=` and `resume_offset=` on the kernel command line for hibernation |
| arkdep | `arkdep init` with `ARKDEP_ROOT=/mnt`, `/arkdep/config` from `iso/airootfs/root/arkdep.config` (with the chosen recipe as default), then `arkdep deploy <recipe>` |
| Boot | systemd-boot; entries from the template in `/arkdep/templates/systemd-boot` (kernel options in `install-arkdep`), only the microcode the image ships |
| User | `roger` (UID 1000, zsh) in `wheel input video render audio kvm libvirt`, with the group IDs read from the image; subuid/subgid `100000:65536` for rootless podman; home in the shared `/home` subvolume |
| Filesystem | btrfs with `compress=zstd:1` and `noatime`: in `rootflags=` of the boot template (btrfs takes compression from the first mount, the root) and in fstab |
| fstab | shared subvolumes `/home`, `/root`, `/arkdep`, `/var/lib/flatpak`, `/swap`, the ESP on `/boot` |

`iso/airootfs/root/arkdep.config` and `iso/airootfs/root/systemd-boot.template` are the reference
`/arkdep/config` and boot entry template (title, kernel options) for new installs; keep them in
line with the laptops (`/arkdep/config`, `/arkdep/templates/systemd-boot`).

## Testing in a VM

`iso/test-install [--checkout] [--host HOST] [ISO]` tests the bootc installer unattended (about 15
minutes, on any machine with KVM, QEMU, OVMF, bsdtar and ssh): it boots the ISO (the newest
published one by default) with a serial console, installs on an empty 50 GB disk with `--disk`,
boots the result and checks it over SSH (running without failed units, ext4 root with fs-verity,
`/var/home`, swap, hostname, user, `bootc status`, one boot entry, the root's fsck), then
reinstalls keeping the home and checks that a file left there survived. `--checkout` runs the
checkout's `bootc/install` instead of the ISO's: installer changes can be tested before building
an ISO. Serial logs and the disk stay in `~/.cache/iso-test/install` when it fails.

For a look by hand:

`iso/test-vm` boots the published ISO in a throwaway UEFI VM (KVM, OVMF, NVMe disk, NAT network
that reaches the LAN) on any machine with QEMU:

```sh
iso/test-vm iso      # download the newest ISO, check it and boot it with an empty disk
iso/test-vm disk     # boot the installed disk
iso/test-vm clean    # delete the VM files (~/.cache/iso-test)
```

The screen is on VNC `localhost:5901`. Use `remote-viewer vnc://localhost:5901` (package
`virt-viewer`): it is a native Wayland client, so it can take the compositor's shortcuts (Super+...)
while focused; Ctrl+Alt gives them back. Stop the VM with `poweroff` inside it. The VM model is not
a known laptop, so the installer shows the recipe menu.
