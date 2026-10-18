# Installer ISO (`iso/`)

- `sudo iso/build [output_dir]` builds `iso-builder` (from `arkdep-builder`, which already trusts
  the arkane key, plus `archiso`) and runs `mkarchiso` on Arch's `releng` profile with `arkdep`
  (from `[arkane]`) added and `iso/airootfs/` copied over. The ISO goes to `/mnt/repo/iso/`
  (`http://192.168.2.50/iso/`, with `sha256sums.txt` and its signature); older ISOs are deleted. Run through
  `build-iso.service` (pull + `flock /run/build-image.lock`). No timer: rebuild it when the
  installer changes or the live system gets too old.
- `/root/install` is `bootc/install` (copied in by `iso/build`'s `--build-context bootc=../bootc`,
  with the base layer's `/etc/containers` and `keys/distro-builder-sigstore.pub`: the ISO pulls
  signed images with no download from GitHub); `podman` is in `packages.x86_64`. Notes on it:
  `bootc/CLAUDE.md`. `iso/test-install` drives it over the serial console (the ISO's kernel booted
  with `-kernel` to add `console=ttyS0`; QEMU user networking, the installed system reached by
  SSH on port 2222 with a throwaway key put in its home). Its pitfalls: wait for the live shell's
  prompt before typing (`login` flushes earlier input); the installed system's end of boot comes
  from SSH (`systemctl is-system-running --wait`, `systemd-analyze`), not the serial console,
  where the serial getty writes terminal resets into the middle of the journal's lines (a
  "Startup finished" line came out cut); `deploy-userland` is masked in the test's home (it would
  pull the userland image).
- The ISO contains no image: `/root/install-arkdep` deploys the newest arkdep image of a recipe straight from
  the repository, so it needs the LAN (Wi-Fi through `iwctl` if there is no cable), not the
  internet. Steps: recipe (from the DMI model: `20Y1` p14s, `20L5`/`20L6` t480, otherwise a menu of
  the recipes in `/status/recipes.txt`), disk, password, then GPT with a 1G ESP (`EFI`) and btrfs `ROOT`,
  `/swap/swapfile` sized to RAM (hibernation `resume=` options), `ARKDEP_ROOT=/mnt arkdep init` +
  `arkdep deploy <recipe>`, systemd-boot, user `roger` and fstab in the new deployment.
- `iso/airootfs/root/arkdep.config` is the canonical `/arkdep/config` for new installs: keep it in
  sync with the laptops' `/arkdep/config` (`repo_url`, `deploy_keep`, `migrate_files`).
- `iso/airootfs/root/systemd-boot.template` is the canonical boot entry template
  (`/arkdep/templates/systemd-boot`: title, kernel options); `install-arkdep` only fills in
  `@ROOT_LABEL@` and `@RESUME@` (swap UUID and offset). Installed laptops keep their own copy in
  `/arkdep/templates/`: a change here only reaches new installs.
- `iso/test-vm iso|disk|clean` boots the published ISO or the installed disk in a throwaway
  QEMU/OVMF VM (VNC `localhost:5901`; on sway use `remote-viewer`, which can inhibit the
  compositor shortcuts, not TigerVNC).
- Group lines for the user are taken from the image's `/usr/lib/group`, so the GIDs always match
  the image (copying them from another system breaks dynamic GIDs such as `libvirt`).
