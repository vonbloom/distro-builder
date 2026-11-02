# userland image (`userland/`)

@README.md

- The boxes' first start must not install anything: `distrobox-init` runs its package setup
  (`pacman -Syy`, `pacman -Su`, its dependency list, locales) only when `/.containersetupdone` is
  missing, so the image creates it and has those packages (the list in `packages.list` is
  `setup_pacman` of distrobox 1.8.2.5; recheck it when distrobox changes it). The box then starts
  in seconds and never upgrades itself: updates are a new image.
- `glibc-locales` instead of `locale-gen`: distrobox-init generated the host's locale
  (`ca_ES.UTF-8`) in its setup, which the image skips; the package has every locale built.
- The Arch image skips man pages, locales and docs (`NoExtract` in `pacman.conf`): the Containerfile
  drops those lines before installing, as distrobox-init does. Packages of the base image keep
  what was skipped.
- What the dotfiles' `pre_init_distrobox_assemble.sh` and init hooks did at every start happens
  here once: the `[cachyos]` and `[aur]` repositories and keys, openssh's systemctl hook disabled
  (a `/dev/null` link in `/etc/pacman.d/hooks`; add new ones there), `fc-cache`, and podman as a
  remote client (`99-remote.conf`: a local podman in a box deletes the host's rootless
  `pause.pid`).
- `no-auto-check-trustdb` in the keyring's `gpg.conf`: once the trust database's next check date
  passes (set from the expiry dates in the keyring), gpg wants to update it, and pacman run as the
  user (`pacman -Q`, `-Si`, `-Sl`) cannot lock `trustdb.gpg` ("Fatal: can't create lock"). GPGME then
  returns no signature and the `[aur]` database, whose signature is required, reads as unsigned:
  "aur: missing required signature", and `-Si`/`-Sl` lose `[aur]` (2026-10-27, both boxes). Any gpg
  run as root in a box (`sudo pacman ...`) did the check and hid it until the next date. pacman-key
  still checks after every `--add`, `--lsign-key`, `--populate` and `--recv-keys`, so the image is
  built with a fresh trust database.
- `podman` in the boxes is `podman-remote` (`/usr/local/bin/podman`, first in PATH). The full
  binary, even with `remote = true`, checks the host's `pause.pid` before connecting, takes the
  host's `catatonit -P` for a stale process and deletes the file ("pause.pid file refers to PID
  ... which is not a pause process"); the host's podman then starts another pause process at each
  call (four after a few tests, 2026-10-09, podman 6.1.3; the old userland box did the same).
  `podman-remote` has no rootless setup and leaves it alone.
- The package cache is removed with `rm`: `pacman -Scc --noconfirm` answers no to removing it
  (seen in the first test build); the live userland had 3.7 GB of it.
- Files go in with `install -m 644` from a bind mount, not `COPY`: the checkout's modes (664, umask
  0002 on the build server) would end up in the image (the same trap as bootc/apply-layers).
- `distrobox.ini` carries `@SERVER@`; the Containerfile writes it to the image with the `SERVER`
  build argument in its place.
- `distrobox.ini`: values without spaces are sourced by `distrobox assemble` (`$(id -u)` in
  `additional_flags` works); `exported_bins_path` is left at its default (`$HOME/.local/bin`).
  Exports only happen when a box is created, which is fine: every update recreates it.
- `exported_apps` takes every desktop file the box sees whose `Exec` or `Name` has the word, `$HOME`
  included, except those already calling `distrobox-enter`: `brave` would match Origin's too, and a
  hand-made `~/.local/share/applications/brave-origin-<name>.desktop` with `--profile-directory`
  and `TryExec=brave-origin` (the host's launcher hides it; the export drops that line) comes out as
  a launcher for that profile. Launchers whose names tell what a profile is for stay out of the
  public dotfiles.
- Brave Origin keeps its data in `~/.config/BraveSoftware/Brave-Origin`, not Brave's `Brave-Browser`,
  and its launcher reads `brave-origin-flags.conf` (dotfiles). "Proceed with Origin for free on
  Linux" shows only once (`brave.origin.free_tier_accepted` in `Local State`): accept it before
  copying profiles from another machine, and keep that `Local State`. In a copied profile what the
  keyring encrypted (`v11`) does not survive (signed out of Google, 2026-11-02); `v10` has a fixed key.
- The push is `lib/push-image.sh` (chunkah, signature, skopeo), shared with bootc/build; prune is
  `bootc/prune userland` with `PKGS_DIR=/mnt/repo/userland`. The status page lists the registry's
  `userland` repository apart from the bootc ones (`serve/status-gen`, `USERLAND`).
- Test runs on the build server like the bootc ones: a copy of the checkout in `/var/tmp` (never
  edit `/home/admin/distro-builder`), `REPOSITORY=test/userland PKGS_DIR=/var/tmp/...`, under
  `/run/build-image.lock`, then delete the test manifests through the registry API.
