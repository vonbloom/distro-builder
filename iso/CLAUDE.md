# Installer ISO (`iso/`)

@README.md

- `iso/build` runs `mkarchiso` on the `releng` profile with `arkdep` (from `[arkane]`) added to its
  packages and `iso/airootfs/` copied over. `build-iso.service` takes
  `flock /run/build-image.lock`, like the image builds.
- The Containerfile puts the `SERVER` build argument in place of `@SERVER@` in everything under
  `airootfs/` once the files are copied in: `install-arkdep`, `arkdep.config`, `/root/install`
  and the registry's client config. `bootc/install` checks that its `REGISTRY` was replaced or
  given: a value starting with `@` is the placeholder.
- `/root/install` is `bootc/install`, copied in by `iso/build`'s `--build-context bootc=../bootc`
  with the base layer's `registries.conf.d` and `registries.d`, its `policy.json` as
  `/etc/containers/distro-builder-policy.json` (the installer's `podman pull --signature-policy`)
  and `keys/distro-builder-sigstore.pub`; `podman` is in `packages.x86_64`. mkarchiso copies
  `airootfs/` before installing the packages, so no file there may be one a package ships:
  `etc/containers/policy.json` failed the build (containers-common, "exists in filesystem",
  2026-10-18). Notes on it: `bootc/CLAUDE.md`.
- `iso/test-install` drives it over the serial console (the ISO's kernel booted with `-kernel` to
  add `console=ttyS0`; QEMU user networking, the installed system reached by SSH on port 2222 with
  a throwaway key put in its home). Its pitfalls: wait for the live shell's prompt before typing
  (`login` flushes earlier input); the installed system's end of boot comes from SSH
  (`systemctl is-system-running --wait`, `systemd-analyze`), not the serial console, where the
  serial getty writes terminal resets into the middle of the journal's lines (a "Startup finished"
  line came out cut); `deploy-userland` is masked in the test's home (it would pull the userland
  image).
- `install-arkdep` joins Wi-Fi through `iwctl`.
- Keeping `iso/airootfs/root/arkdep.config` in line with the laptops means `repo_url`,
  `deploy_keep` and `migrate_files`. Of `systemd-boot.template`, `install-arkdep` only fills in
  `@ROOT_LABEL@` and `@RESUME@` (swap UUID and offset).
- `iso/test-vm` on sway: `remote-viewer` can inhibit the compositor shortcuts, TigerVNC cannot.
- The user's group lines come from the image's `/usr/lib/group`: copying them from another system
  breaks dynamic GIDs such as `libvirt`.
