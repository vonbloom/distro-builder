# distro-builder

@README.md

The user speaks Catalan; code, comments and commit messages are in English (short, sentence-style
subjects).

## Working here

- The build server (README) is reached over SSH as `admin`; its address is in the user's global
  CLAUDE.md. Never build on the laptops.
- Run `ci/check` before giving the user a commit: it must pass. A shellcheck warning that is
  intended gets a `# shellcheck disable=SCxxxx # reason` directive.
- Each fact lives in one file: usage in the component's `README.md`, implementation notes and
  pitfalls in its `CLAUDE.md`, which imports the README. When behaviour changes, update the file of
  the component concerned.
- This repository is public: document only the project itself (what it builds, how and why), in
  files, comments and commit messages. Infrastructure details stay out: addresses, the other
  machines and their jobs, VM and container IDs, the file server and its paths, the cluster, work
  projects. They belong in the private homelab repo (`docs/`), which a document may point to.
  Docs and comments write the build server's address as `<server>`.

## System overview

- **Host OS**: arkdep deployments. Root is a read-only btrfs subvolume
  (`/arkdep/deployments/<image>/rootfs`), `/etc` and `/var` are separate subvolumes per deployment.
  `deploy_keep=2`. Packages are not installed on the host at runtime: change a recipe and rebuild.
- **Userland**: everything interactive (VS Code, Brave, neovim, compilers) lives in the `userland`
  distrobox (Arch), created from the userland image built here (`userland/`, with the box
  manifest inside) by `userland-update` (host image, generic overlay), which `deploy-userland`
  (user unit `deploy-userland.service`) runs at the first login when the box is missing. The user
  configuration is the dotfiles repo `vonbloom/dotfiles` (stow, `~/.dotfiles`), which defined the
  boxes until 2026-10-09 (`default.ini`).
- **Host config persistence**: `/arkdep/config` `migrate_files` copies listed paths from the running
  system into each new deployment (`cp -rp`, merged over the image). It includes
  `etc/passwd|shadow|group`, `etc/ssh`, `etc/systemd/network` (WireGuard `wg0`), `etc/nftables.d`
  (ports opened with `fw`), `var/lib/iwd`, etc.
  Local copies win over the image versions of the same files.
- **Users**: `arkdep-build` moves non-root accounts to `/usr/lib/{passwd,group,shadow}`, read through
  `nss-altfiles` (`altfiles` in `nsswitch.conf`). Do not remove either or system users disappear.

## Signatures

- Anything that deletes published files must delete their `.sig` too (`prune`, `aur/build` cleans
  orphan package signatures).
- `sign_stale` also re-signs a file newer than its signature: a second build of an image on the
  same day replaces `<recipe>-<date>.tar.zst` under the same name, and the kept signature made
  arkdep reject it ("BAD signature", p14s-2026-10-07).
- The installer gets `keys/distro-builder.asc` through `--build-context keys=../keys` (built into
  the ISO) and copies it to `/arkdep/keys/trusted-keys`.

## Other machines

- ThinkPad T480 (hardware info, tests of the `t480` recipe; its address is in the user's global
  CLAUDE.md): bootc `t480` image since 2026-10-08, reinstalled on 2026-10-18 (ext4 root,
  `bootc/install` keeping the home).
