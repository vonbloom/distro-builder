# AUR repository (`aur/`)

@README.md

- `aur/build` signs after the container exits (packages and `aur.db`). The clients' setup is the
  dotfiles' `~/.dotfiles/distrobox/.config/distrobox/pre_init_distrobox_assemble.sh`.
- `build-aur.timer` adds up to 30 min of random delay to its 04:00 UTC and is `Persistent=true`.
  The unit takes `/run/build-image.lock` like the image builds: the bootc builds install bootc
  from `[aur]`, and the 8 GB VM cannot hold chunkah and a Rust compile at once (both started by
  hand on 2026-10-08: ~2 GB rustc next to `podman load`).
- `aur/build` runs `aur-build.sh` in the `aur-builder` image. `aur-build.sh` and `makepkg.conf` are
  mounted from the checkout (the copies baked into the image are only a fallback), so changes to
  them apply on the next run.

## aur-build.sh

- The `pacman -Syu` on every run is there because the old LXC builder built against stale
  libraries.
- `aur sync --no-view --noconfirm --auto-key-retrieve <list>`: builds new and outdated targets and
  their AUR dependencies, skips up-to-date ones.
- Then `aur build --syncdeps` in a copy of each `local/<pkgname>/` (mounted at `/local`); aur build
  skips a package whose file for that version is already in the repository. The directory name
  must be the package name (it counts as wanted in the cleanup below), and its AUR dependencies, if
  any, must be in `packages.list`.
- `aur/check-upstream` is the `ExecStartPost=-` of `build-aur.service`, with its state (one
  notification per version) in `/var/lib/distro-builder/upstream/<pkg>`. It watches upstream, not
  the AUR package: the AUR `bootc` is bumped by a bot and ignores its comments. `aur/bump-local`
  needs a single `source=()` and `sha256sums=()` line in the PKGBUILD.
- Cleanup: packages neither listed nor needed as AUR dependencies (`aur depends`) are
  `repo-remove`d and their files deleted; `paccache -rk2` keeps the two versions.
- `makepkg.conf` (`/etc/makepkg.conf.d/`) disables `-debug` packages.
- A failure in any step stops the run (the unit fails); packages built before it stay published.

## Gotchas

- `aur-repo-filter` reads `/dev/tty` unless `unbuffer` (package `expect`) is installed; without a
  terminal (systemd) the check for official packages providing an AUR target silently fails.
- `aur depends` default output is dependency pairs; use `--jsonl` + `aur format -f '%n\n'` for names.
- "Failed to connect to udev via varlink" / "command failed to execute correctly" while installing
  dependencies is the udev pacman hook inside the container: harmless.
