# TODO

## Boot time (P14s)

Measured 2026-10-07: 31.6 s = 16.1 s firmware + 3.5 s loader + 0.9 s kernel + 7.5 s initrd +
3.6 s userspace. The firmware part cannot be helped; the initrd and loader parts can.

- [x] **amdgpu in the initramfs costs ~4 s: kept forced (decided 2026-10-08 after test boots).**
      `force_drivers+=" amdgpu "` (`p14s/.../10-gpu.conf`) makes `dracut-pre-udev` run `modprobe
      amdgpu` synchronously before udev starts: no other initrd work happens from 1.5 s until the
      driver starts probing at 5.5 s (same on every boot). It is there for Plymouth, which ignores
      simpledrm (the EFI framebuffer, built into linux-cachyos, up at 1.45 s) until `DeviceTimeout`
      (8 s) unless told to use it (`src/daemon/plymouthd-settings.c`, `plymouthd-policy.c`):
      `UseSimpledrm=1` or `UseSimpledrmNoLuks=1` (Fedora's default) in plymouthd.conf, or
      `plymouth.use-simpledrm` on the command line.
      - **Cause (2026-10-07, measured in a KVM VM booting the same vmlinuz + initramfs):** not the
        CPU speed. The VM, on a host CPU at full clock, takes the same 3.9 s, and the kernel's own
        initramfs unpack is as fast on the laptop (177 ms) as in the VM (212 ms), so the initrd
        already runs at full speed: loading `acpi-cpufreq` earlier would not help. With
        `initcall_debug` and a `function_graph` trace of `load_module`: decompression and
        signature check take ~0.14 s and `amdgpu_init` 1.5 ms. Almost all the rest is ftrace
        checking every traceable function of the module (`ftrace_module_enable` ->
        `test_for_valid_rec` -> `kallsyms_lookup`, ~0.2 ms each). Each lookup scans the module
        symbol table linearly, and amdgpu has 15,828 `__mcount_loc` entries and 75,071 symbols.
        Sorting the ORC unwind table (`unwind_module_init`) adds ~0.5 s. Wherever the module
        loads, this is paid.
      - **Test boots (2026-10-08, P14s docked, lid closed, two DisplayPort monitors on the dock;
        one-shot entries with test initramfs images, same deployment):**

        | | amdgpu forced | no amdgpu + `plymouth.use-simpledrm` | `add_drivers` (unforced) |
        |---|---|---|---|
        | initrd | 7.4 s | 1.7 s | 7.3 s |
        | Plymouth starts | 6.2 s | 1.9 s | 2.0 s, waits for amdgpu |
        | tty1 login | ~11.7 s | ~6.1 s | ~11.2 s |
        | amdgpu ready | 5.9 s | 12.4 s | 6.4 s |
        | initramfs | 57 MB | 22 MB | 57 MB |

        Without amdgpu the splash showed at once but deformed (the EFI mode on the dock's monitors
        has another aspect ratio), then tty1 stretched, until amdgpu, loaded by the real root in
        8 s instead of 4, took over at 12.4 s (the monitors blank and resync). A login before that
        would also start sway on simpledrm. Unforced, amdgpu still holds the initrd:
        `dracut-initqueue` waits for udev to settle before `/sysroot` is mounted. On the dock
        Plymouth is not seen with amdgpu either (forced or not): the monitors take seconds to
        resync after its modeset, by which time the splash is over. Undocked, the forced driver
        shows a clean splash from ~6 s.
      - The same trade-off applies to `i915` on the T480; not tested there.
      - Reproduce the load cost: `qemu-system-x86_64 -enable-kvm -cpu host -smp 16 -m 8G -display
        none -serial file:LOG -kernel /boot/arkdep/<deployment>/vmlinuz -initrd
        .../initramfs-linux.img -append 'console=ttyS0 root=LABEL=NONE ignore_loglevel
        systemd.log_target=kmsg initcall_debug'` and compare the timestamps of `dracut pre-udev
        hook` and `amdgpu: Virtual CRAT table`.
      - Test initramfs images without root (identical size to the image's own build):
        `unshare -r dracut --no-hostonly -c /dev/null --confdir <dir> --tmpdir ~/.cache/<dir>
        --kver $(uname -r) <out>` (chown errors and 600/700 modes are user namespace artifacts,
        harmless in an initramfs where everything runs as root; `--include` does not override
        files the plymouth module installs). Boot one with a copy of the deployment's entry and
        `bootctl set-oneshot <entry>.conf` (run sudo in a terminal).
- [x] **Unused dracut modules omitted** (`depends/generic/.../dracut.conf.d/20-omit-unused.conf`,
      2026-10-08): the initramfs, read by the firmware from the ESP (part of the 3.5 s loader
      time), went from 63 MB (110 MB unpacked) to 57 MB (88 MB) in a test build, mostly
      `hwdb.bin` (13 MB unpacked); booted fine in the test boots. To check on the next builds:
      the T480 and `iso/test-vm` (the previous deployment stays in the boot menu,
      `deploy_keep=2`). Most of the rest is amdgpu: its firmware for every AMD GPU (28 MB, already
      zstd-compressed; only `renoir_*` is used) and the module (6 MB).

## bootc builds

First server build (build-bootc@p14s, 2026-10-07, a VM with 6 cores): 18 min, I/O bound. Package
download and install take 1.6 min; committing the recipe layer (~3.5 GB, ~100k files) 5.6 min;
chunkah + `podman load` ~7 min (and the 6.9 GB memory peak of the 8 GB VM); the push 1 min (later
pushes only upload changed layers). The VM disk was on SATA SSDs then (NVMe since 2026-10-15).

Layer reuse (measured 2026-10-09 in the registry): the two t480 builds of 2026-10-08, 20 min
apart with recipe changes in between, share 104 of 128 layers: the update downloads 162 MiB of the
1035 MiB image. chunkah's layers are reproducible for unchanged packages (directory mtimes come
from the packages' build dates). 2026-10-07 -> 2026-10-08 shared none: the owner/mode fix of
`/usr`, `/usr/lib` and `/usr/share` (`build-recipe.sh`) changed those parent directories in every
layer, a one-off. Still to see on a regular weekly build: which layers change on every build
(VERSION_ID with the time in os-release, install dates in the pacman database, the initramfs?).
The initramfs (46 MB) did change on every build until 2026-10-18: it carried the Arch container
image's `VERSION_ID` (`initrd-release`); now only when a file it holds changes (bootc/CLAUDE.md).

- [x] **Boot test before publishing `latest`** (2026-10-18). The composefs backend sets up no
      boot counting (bootc docs, `bootc-boot-failure-detection.7.md`: "likely to be added in the
      future"), unlike arkdep's `+3` entries: an image that does not boot was only found when the
      T480, which stages updates every 4 h by itself, rebooted into it, and the user had to pick
      the previous entry by hand. Now `bootc/build` pushes `<recipe>:candidate` (signed),
      `bootc/test` pulls it with the clients' policy, installs it on a sparse raw file
      (`bootc install to-disk --via-loopback --generic-image`) and boots it in QEMU (KVM, OVMF, no
      network, the journal on the serial console) until "Startup finished" without a failed unit;
      only then do the dated tag and `latest` name it (`tag_image`). On failure `latest` stays,
      `notify-failure@` reports the matching lines and the tail of the serial log (after one retry
      30 min later), and the whole log is `candidate.log` next to the `.pkgs` files. The VM got
      `cpu: host` (nested KVM) and `qemu-system-x86` + `ovmf` (homelab). Same change: no push
      without the signing key (it pushed unsigned with a warning, and the clients would have
      refused it without a word), no push with 20 % fewer packages than
      the previous image, the CachyOS key from `keys/` instead of the keyserver, `--pull=newer`
      for the base image, and the checkout's commit as `org.opencontainers.image.revision`.
      Catches what breaks the generic boot (initramfs and dracut modules, composefs setup, `/etc`
      merge of a fresh install, failing units, emergency mode), not hardware specific drivers
      (i915, Wi-Fi) or the desktop.
- [x] **Update test** (2026-10-18): `bootc/test --from <repository>:latest <candidate>`, run by
      `bootc/build` after the install test, both required before `latest` moves. The current latest
      is installed, given a machine's state over SSH (a user, the hostname, an edit of
      `/etc/issue`, `fw allow`, a file in `/var`), `bootc switch`ed to the candidate inside the VM
      (pulled from the registry with the clients' policy) and rebooted; then the candidate's digest
      must be booted, latest the rollback, two boot entries, the state kept. Both tests now check
      the boot over SSH (`systemctl is-system-running`, root's throwaway key from `bootc install
      --root-ssh-authorized-keys`) and ignore the user managers' lines on the console (root's,
      started by the test's login). Validated with three builds to `test/t480` on the server: the
      first two failed on root's user manager (wireplumber "Dependency failed": pipewire's
      `ConditionUser=!root`), now filtered; `deploy-userland` got `ConditionUser=!@system` (it
      would provision root). The third passed both: install 13.2 s; update from the second build's
      image, boots 13.2 s then 12.1 s; the build 6 min 40 s in all. Test images deleted from the
      registry afterwards (`prune` keeps what latest names: the manifests by hand, then the
      garbage collection).
- [x] **Boot counting** (2026-10-19): an update's boot entry gets `+3` when bootc applies it at
      the shutdown (`bootc-boot-count`, an `ExecStop=` of `bootc-finalize-staged.service`),
      `systemd-bless-boot` marks it good after a boot without a failed unit
      (`systemd-boot-check-no-failures`), and after three boots that do not get there systemd-boot
      boots the previous image again; `bootc upgrade` does not stage the failed image again, and
      `bootc-update` and the waybar indicator report it (`bootc/CLAUDE.md`). `bootc/test
      --fallback latest <candidate>` tests it on every build: the candidate installed following
      latest, `bootc-update` staging latest with `systemd.unit=reboot.target` added to its entry,
      three boots that reboot at once, then the candidate again. The update test checks that the
      update was counted and marked good. Validated with four builds to `test/t480` on the server
      (the first one the latest of the others), which found three faults: the test VM's ESP was a
      read-write gpt-auto automount (`to-disk` writes no `systemd.mount-extra`), so it now gets the
      read-only mount of an installed machine; `systemd-bless-boot` then failed on it ("Read-only
      file system": a remount in `ExecStartPre=` does not reach `ExecStart=`), which would have made
      every good update fall back after three boots, and so would `systemd-boot-update` have failed
      with the next systemd-boot, both now remount in the command's own process; and the zram
      reset at the shutdown failed once ("Device or resource busy"), now ignored. The fourth build
      passed both tests in 8 min (the fallback adds ~70 s): its entry counted and marked good after
      the update, latest's entry `+0-3` after three boots, the candidate back, `bootc-update`
      reporting it and not staging it again (`bootc status`: `bootOrder: rollback`).
- [x] **Hidden boot menu** (2026-10-19): with boot counting the menu is no longer needed to go
      back, so `bootc/install` writes `timeout 0`, 5 s less on every boot (the T480's loader took
      12.1 s with the 5 s menu; the rest, to measure after the change, is mostly reading the 17 MB
      kernel and the 47 MB initramfs from the ESP). Holding Space at power-on shows it, and so does
      the power menu's *Reinicia al menú d'arrencada* (`systemctl reboot --boot-loader-menu=0`:
      logind sets `LoaderConfigTimeoutOneShot`, polkit `allow_active`; the T480's systemd-boot
      reports the feature). `iso/test-install` checks the line. `loader.conf` belongs to the
      machine: the T480 changed by hand (`bootc/README.md`).
- [x] The T480 is `degraded` (2026-10-18, `t480:2026-10-11`, up 6 days): `btrbk.service` fails
      (its `snapshot_dir /arkdep/snapshots` does not exist under bootc, bootc/README "Missing
      before real use") and `systemd-networkd-wait-online.service` timed out. Neither is part of
      the boot transaction, so the boot test does not see them. Fixed on 2026-10-18, to check on
      the T480 with the next image: btrbk is out of the bootc layers (the home backup replaces it);
      wait-online was started on 2026-10-17 by `archlinux-keyring-wkd-sync` (weekly) and timed out
      on the unplugged Ethernet port: `--any`, and the keyring sync masked (`bootc/CLAUDE.md`).
      Checked after the reinstall (`t480:2026-10-18`): `running`.
- [x] **bootc installer** (2026-10-18): `bootc/install` installs a whole disk (`--disk`: ESP, swap
      the size of the RAM, ext4 root with fs-verity, ext4 home) or keeps a home partition
      (`--root/--esp/--home/--swap`, the old way); every question is also an option. The ISO gets
      it as `/root/install` with podman, the base layer's registry config and the sigstore key
      (no `cow_spacesize=2G`, nothing from GitHub); the arkdep installer stays as
      `/root/install-arkdep`. The root is ext4 everywhere since then (`bootc/test` too, "FILE
      CORRUPTED" a failure again) and the initramfs checks it (`fscks` in `20-omit-unused.conf`).
      `iso/test-install --checkout` with the 2026-10-16 ISO and `t480:2026-10-18` (the first image
      from `bootc/layers`, boot test passed on the server with the ext4 root): both ways pass
      (install 67 s, boot 7.8-8.1 s, `ROOT: clean` from the initramfs' fsck, the home kept). The
      first ISO build failed on `etc/containers/policy.json` in `airootfs/` (containers-common
      ships it; `iso/CLAUDE.md`), now `distro-builder-policy.json`. `iso/test-install` with the
      `distro-installer-2026.10.18` ISO and its own installer passed too (install 62 / 49 s, boot
      8.2 / 7.7 s). The T480's first try failed: `bootc install` filled the live overlay's `/var/tmp`
      (256 MiB; the test had booted with `cow_spacesize=2G`), now bound to the storage. The T480
      was then reinstalled keeping its home (the ISO's installer, `/var/tmp` bound by hand):
      `running` with no failed unit, ext4 root with `verity=require` and `ROOT: clean` from the
      initramfs, swap and `resume=`, Wi-Fi from the live system, the userland box kept. Boot 28.9 s
      (firmware 7.0, loader 12.1 with the 5 s menu, kernel 1.3, initrd 2.9, userspace 5.5; 35.6 s
      before). Its address changed from .182 to .194: networkd's DHCP client identifier is a DUID
      from the machine-id, new with every install.
- [ ] **Fedora bootc trial** (`fedora.md`): the recipes translated on 2026-10-18 (`fedora/`, every
      package found or replaced, resolved with dnf). Next: the Containerfile (base, modules, sway,
      host from the lists, the overlays adapted as `fedora.md` lists), the open decisions there,
      a `t480` build through the same pipeline and boot test, a VM session with sway, then the
      T480 with `bootc/install`.
- [ ] **Soft reboot** (systemd `soft-reboot`, `bootc upgrade --soft-reboot`, composefs backend in
      bootc 1.17.1): userspace restarts into the new image on the running kernel, skipping
      firmware, loader, kernel and initrd (T480: 13.1 + 10.9 + 1.3 + 3.3 s of its 35.6 s boot);
      the session still closes. Only when the new image has the same boot digest (sha256 of
      `vmlinuz` + initramfs) and kernel command line. Waits until bootc is the default on the
      laptops or the thin client moves to bootc (unattended updates of a server), and until the
      T480 shows how often consecutive images qualify, now that the initramfs no longer changes
      on every build (Arch updates its kernel, systemd, glibc, zstd or plymouth's libraries most
      weeks).
      Then:
      - `bootc-update` stages with `bootc upgrade --soft-reboot=auto`: when the image qualifies,
        bootc mounts it at `/run/nextroot` (otherwise it stays staged for a normal reboot). It
        must happen when staging: in 1.17.1 `bootc upgrade --apply --soft-reboot` with that image
        already staged does a full reboot (`bootc_composefs/update.rs`).
      - `/run/bootc-update/staged` records it; the waybar indicator and the power menu offer
        `systemctl soft-reboot`.
      - Test on the T480: `systemctl soft-reboot` as the user (polkit), the `/etc` merge after
        it, and suspend or hibernation with `/run/nextroot` mounted.
      - arkdep (the P14s) has no support: a deployment mounted at `/run/nextroot` by hand, not
        while arkdep and bootc are compared.
- [ ] The CachyOS key from `keys/cachyos.asc` in the arkdep recipe
      (`common/extensions/pre_build.sh`) and the userland image too: both still fetch it from
      keyserver.ubuntu.com, and the arkdep recipe the keyring from a fixed URL.
- [x] **Push chunkah's output with skopeo** instead of `podman load` + `podman push` (2026-10-09).
      Test build of t480 to `test/t480`: 9 min 49 s instead of ~18, memory peak 3 GB instead of
      4.7-6.9 GB, 1.5 min of CPU instead of ~4.5 (no import, no recompression). After the recipe
      layer is committed: chunkah 15 s, skopeo pull 9 s (first run), push of all 128 layers to an
      empty repository 64 s. Tags, OCI manifest, the four annotations and the sigstore signature
      checked; the signature accepted by a copy of `:latest` with the T480's policy. The first
      real build re-uploads every layer to `t480` (chunkah's gzip bytes), and the T480 downloads
      the whole image (~1 GiB) once.
      - Today chunkah writes a gzip-compressed OCI archive (`--compressed` also gzips the whole
        archive around the already compressed layers) to stdout; `podman load` decompresses it
        and writes every layer uncompressed into containers-storage (~3.5 GB on the zvol of
        worn SATA SSDs); `podman push` then reads them back and compresses the layers it cannot
        match to registry blobs through its blob info cache.
      - Instead: `chunkah build ... --compressed -o oci:/out/<recipe>` (an OCI directory layout:
        layers gzip-compressed once, no outer archive) into a work directory on the server (the
        compressed image is ~1.0 GiB today), then
        `skopeo copy --preserve-digests --dest-tls-verify=false --sign-by-sigstore-private-key ...
        --sign-passphrase-file ... oci:<dir> docker://<server>:5000/<recipe>:<date>` and the
        same copy, unsigned, to `:latest` (blobs already there are skipped, the manifest digest
        stays the same, so the signature covers both tags as today). `--preserve-digests` makes
        skopeo fail rather than rewrite the manifest. skopeo reads `registries.d` for
        `use-sigstore-attachments` like podman: either Debian's `skopeo` package on the server
        (homelab `builders` play) or `quay.io/skopeo/stable` in a container with
        `/etc/containers/registries.d` and the key directory mounted.
      - Gains: ~1 GiB written once instead of the 3.5 GB import plus the re-read, no gzip of the
        archive and no recompression; less page cache charged to the unit (its 4.7-6.9 GB
        "memory peak" includes it). chunkah alone with `-o oci:` takes 26-29 s (2026-10-09,
        rechunking the published t480 image on the server), so nearly all of the ~7 min of
        "chunkah + `podman load`" is the import: most of it should go.
      - Upstream issues: every manifest annotation (`org.opencontainers.image.version` for
        bootc-dev/bootc#2227, `created`, `base.digest`, `base.name`) is written by chunkah itself
        (checked in its `oci:` output), and `--preserve-digests` copies the manifest unchanged,
        so the #2227 workaround keeps working. The same flag keeps the image OCI: the composefs
        backend fails on Docker v2s2 manifests (bootc-dev/bootc#1703, open); skopeo would fail
        instead of converting. #2557 and #2558 concern `bootc install`, not the push. The
        `podman inspect`/`podman rmi` of the built image stay.
      - One-off cost: the first image pushed this way has chunkah's gzip bytes instead of
        podman's (0 of 128 compressed layers matched the registry's in the test), so the T480
        downloads the whole image once (~1 GiB). Afterwards reuse depends on chunkah's gzip
        staying byte-identical for identical input: two runs on the same input gave the same
        manifest and all 128 layers byte for byte. Pin `CHUNKAH` to a version tag instead of
        `latest`, so that a compression library update does not trigger another full download
        unannounced.
- [ ] Layered images instead of one Containerfile per recipe: `base` (generic) -> desktop (`sway`,
      and `mango` to try mangowm, in cachyos-extra-v3) -> device (ucode, firmware, tlp.d, dracut
      GPU config, initramfs), published as `<device>-<desktop>`. Each extra combination only builds
      its device layer, and switching desktop on a laptop is a `bootc switch` (rollback included).
      Prospect with a third kind of machine (a thin client: x86-64-v2, Cinnamon, appliance
      services), the split of `depends/generic` into base and modules, and a phase 1 in today's
      recipe format: `layers.md` (2026-10-09).
      Done in part (2026-10-18): the bootc images no longer replay the arkdep recipes
      (`build-recipe.sh`): `bootc/layers` has `base`, `modules/laptop`, `modules/workstation`,
      `desktop/sway` and `host/{t480,p14s}` (a `packages.list` and an `overlay/` each, a host's
      `layers.list`), applied in order by `bootc/apply-layers` in the one Containerfile, and
      `image/arkdep-build.d` is frozen for the P14s. Still to do: an image per layer in the
      registry (the base built once for every host, a host build reusing it), the audio modules and
      the thin client (`layers.md`).
      - The userland image stays apart from these layers (decided 2026-10-09). The host image takes
        what needs root, hardware, the boot or the session (drivers, network, virtualization,
        the compositor, portals, the keyring) plus what the host's own shells and scripts use;
        the userland image takes the user's apps and tools, which change often. Apart, an app
        update is a box replaced in seconds, not a build of the system and a reboot; the `[aur]`
        packages' install scripts run as root in the box, not on the host; a broken userland
        still boots and rolls back alone; both laptops share it whatever the host runs (arkdep,
        bootc); and playground tries packages in the real environment. Moving a package is a
        line from one `packages.list` to the other. Duplicates are on purpose (zsh-completions,
        fzf, git, man-db...: the host's shells and the boxes' each need theirs).
      - Borderline: Thunar with gvfs and xfconf, the one app that needs the D-Bus services
        forwarded to the box (`userland/dbus-1/`). In the desktop layer that workaround would go.
- [ ] Rebuild only what changed: drop `--no-cache` and let podman reuse layers, with a fingerprint
      of the package versions available for each layer (`pacman -Sy` + `pacman -Sp`, ~20 s) as a
      `--build-arg` of its install step, so a new package version invalidates that layer and the
      ones above. Arch updates the base nearly every week; the gain is for changes in the desktop
      or device layers and for reruns in the same week. Nothing changed: no new tag, no notification.
- [ ] Optional: pacman package cache across builds (`RUN --mount=type=cache`), ~700 MB of
      downloads per build (40 s today).
- The server's disk is NVMe since 2026-10-15: measure the I/O bound phases again.

## userland image

The userland distrobox built here as an image (`userland/`, 2026-10-09) instead of assembled and
upgraded in place on each machine from the dotfiles' `default.ini`. Done: the image, its manifest
(`/usr/share/userland/distrobox.ini`), the weekly build and the status page. Test builds on the
server (2026-10-09): 15 min, 1.63 GB compressed in 128 layers (the live userland's writable layer
was 8.9 GB, 3.7 GB of it package cache); a box created from it on the P14s started in 13 s
without installing anything, with zsh, `ca_ES.UTF-8`, the apps and the remote podman working.
Still to do, in order:

- [ ] **Pull from the registry on the laptops**: the registry's client config moved from
      `bootc/overlay` to the generic overlay (`registries.conf.d` with `<server>:5000` as
      insecure, `registries.d`, a `policy.json` that requires the signature for that registry and
      keeps Arch's default for the others), and the arkdep image gets the key from `keys/`
      (2026-10-09). To check once the P14s runs an image built with it: `podman pull
      <server>:5000/userland:latest` works, and an unsigned image there is refused.
- [x] **`userland-update`** in the host images (generic overlay, 2026-10-09): pulls
      `userland:latest`, and if userland runs another image reads `distrobox.ini` and the D-Bus
      services from it, pins its `image=` lines to the pulled digest, `distrobox assemble create
      --replace` (asks first if userland runs: its apps close), installs the services, removes the
      previous image. `deploy-userland` runs it when there is no userland box. Dry run on the
      P14s from the checkout: pulled the real image in 38 s. The manifest gained the exports made
      by hand on the P14s (`gimp`, `magick`, `unzip`).
- [x] **Switch the laptops' boxes to the image**: the P14s on 2026-10-09 (`userland-update` from the
      checkout, 38 s with the image already pulled: both boxes, 14 exports, D-Bus services;
      zsh, locale, VS Code, Ansible, ssh and the remote podman work; the old userland's 8.9 GB
      writable layer gone); the T480 the same day (its t480-2026-10-09 image, script from the
      checkout: 126 s over Wi-Fi, then `--playground`). The dotfiles' `distrobox` package went the
      same day (unstowed on both laptops first: `default.ini`, the pre-init hook, the copy of the
      `[aur]` key, the D-Bus services).
- [x] **waybar notice** (2026-10-09): `custom/userland` (`userland-update-status`, sway layer)
      compares the registry's `userland:latest` digest with the image the box runs every hour (no
      staged pull: `userland-update` pulls on the click, 40 s on the LAN) and shows the package
      changes from the two images' lists. To check once the laptops run an image with it.

## bootc: sealed images (if bootc stays)

Read 2026-10-09: the bootc.dev series "Sealed images" (2026-05-04 to 05-07) and the bootc docs
(`bootc-composefs.7.md`, `building/bootc-sealed-images.7.md`). A sealed image is a chain from the
firmware to every file: Secure Boot (own keys) -> signed systemd-boot -> signed UKI (kernel,
initramfs and command line in one EFI binary) whose command line carries the composefs digest of
the whole root (`composefs.digest=v1-sha512-12:...`, computed at build time) -> the initramfs only
mounts a root with that digest, and fs-verity checks every file on read (a tampered file returns
EIO). Without Secure Boot "nothing validates that root digest itself": any root process can
replace the UKI, so a UKI alone adds little.

- [x] **Check what the T480 has now** (2026-10-09): fs-verity is enforced with the BLS entries
      (`findmnt /` shows `verity=require`, `composefs.digest=v1-sha512-12:...` on the command
      line, `fsverity=yes` in the kernel log). That is the integrity half; the digest there is
      written by the client, not authenticated.
- [ ] **btrfs compression + fs-verity: spurious `FILE CORRUPTED!`** on the T480 (kernel
      7.2.9-1-cachyos, both boots since the install). The kernel logs `fs-verity (nvme0n1p3,
      inode N): FILE CORRUPTED! pos=... level=-1` for objects of the composefs repository, mostly
      at 128 KiB offsets (btrfs compressed extents), yet every read succeeds: reading the whole
      root as roger gave no I/O error (20 messages on the way). Reproduced without root in
      `/var/tmp`: a 60 MB file of libraries, SHA-512 verity enabled, page cache dropped, read 3
      times: 10 messages and no read error when btrfs compressed it (`compress=zstd:1`), none
      with `chattr +m` (uncompressed). Without verity, 10 reads of a 200 MB compressed file after
      dropping the cache all gave the written bytes. So the stored data is intact and a readahead
      of compressed extents fails verification, then the synchronous retry passes. Fedora IoT hit
      the same message on btrfs with 6.16.8, where reads did fail (EIO, SIGBUS, broken login);
      fixed by "btrfs: fix incorrect readahead expansion length" (Oct 2025,
      https://discussion.fedoraproject.org/t/165159). A kernel where the retry fails too would
      break the T480 the same way (`bootc rollback` boots the previous deployment, whose objects
      are mostly the same files).
      - Narrowed down (2026-10-09): the P14s (another NVMe and CPU) gives the same 10 messages, so
        not the T480's hardware; so does Arch's own kernel in a VM (cloud image, virtio disk,
        btrfs `compress=zstd:1`): 7.2.2, 7.2.7 and 7.2.9-arch1 fail, 6.18.55-lts, 7.0.14 and
        7.1.11 do not. A regression of the 7.2 merge window, not CachyOS's. Reads with
        `POSIX_FADV_RANDOM` (no readahead) give none: readahead of compressed extents. VM and
        scripts kept in `~/.cache/verity-vm` (`vm-kernel.sh <arch version>` installs a kernel
        from the Arch archive, boots it and runs both tests). Reported to linux-btrfs on
        2026-10-09 (Cc fsverity and regressions, `#regzbot introduced: v7.1..v7.2.2`).
      - Fix (2026-10-10): Qu Wenruo's "btrfs: fix the fsverity callback where unexpected range is
        verified" (`fsverity_verify_folio()` -> `fsverity_verify_blocks()` on the range read).
        7.2 enabled large data folios, and `btrfs_verify_folio()` verified the whole folio when a
        read covered only part of it (a 128 KiB compressed extent), i.e. blocks not read yet; the
        bug is as old as btrfs fs-verity but needed block size < page size before. Tested in the
        VM on 7.2.9 (`build.sh`: Arch config reduced to the VM's modules, built in, booted with
        `test-kernel.sh <bzImage>`): vanilla 10 messages on the reproducers and 20/10/11/30 on
        `verity-tree.sh` (a copy of /usr, 34969 files with verity: cat, 4 parallel readers, mmap,
        diff), patched none; data identical in both. The counts are lower bounds:
        `fsverity_msg()` is rate limited (10 per 5 s), hence always "10". Tested-by sent the same
        day. v2 the same day: same code, the commit message fixed (reads never fail: the failed
        I/O has already filled the page cache, so the retry finds the blocks uptodate), with our
        Reported-by and Tested-by. Eric Biggers (fs-verity maintainer) gave his Reviewed-by and
        asked for `Cc: stable`, so 7.2.y should get it without us asking. A second, independent
        report the same day (composefs root on btrfs, arm64 and x86_64, Debian 7.2.8) tested v2
        too; Qu also sent an fstests case (generic/807: holes every 128 KiB split the reads).
        Next: the fix in mainline, then in a 7.2.y stable release, then in CachyOS's kernel;
        after that update, check the T480's log for `FILE CORRUPTED`.
      - Only if the fix stalls, avoid it on new installs: `bootc/install` mounts the root and
        sets `rootflags` with `compress=zstd:1`; `chattr +m` on `/sysroot/composefs` before the
        image is written, or no compression on the bootc root at all (costs disk: the objects
        are mostly binaries). Existing objects stay compressed (verity files cannot be rewritten
        in place).
- [ ] **Sealed images, together with LUKS + TPM2.** Sealing protects the system, not the data: a
      stolen laptop's `/var/home` is readable without disk encryption. The pair that pays off is
      a TPM2-bound LUKS key released only when our signed UKI boots (`systemd-cryptenroll`).
      - Build: two Containerfile stages, `bootc container split-kernel-and-rootfs` and
        `bootc container ukify --rootfs ... --kernel-dir ... -- --signtool sbsign
        --secureboot-private-key ... --secureboot-certificate ...`, the UKI copied to
        `/boot/EFI/Linux/`, systemd-boot signed with the same db key. The key reaches the build
        as a podman secret (never in a layer), lives in `/etc/distro-builder/` and in the homelab
        vault like the sigstore key. Tools available: `systemd-ukify` 262 and `sbsigntools`
        (Arch), and our bootc 1.17.1 has `split-kernel-and-rootfs`, `compute-composefs-digest`,
        `--allow-missing-verity` and the Secure Boot key enrolment.
      - Machines: own PK/KEK/db enrolled with the firmware in Setup Mode (systemd-boot
        `secure-boot-enroll` from `/usr/lib/bootc/install/secureboot-keys/<name>/`, or `sbctl`),
        keeping Microsoft's keys (Lenovo and fwupd firmware updates, option ROMs). The installer
        ISO is not signed: install with Secure Boot off, enable it afterwards. LUKS needs the
        dracut modules left out on 2026-10-08 back (`crypt`, `systemd-cryptsetup`, `dm`, and
        `systemd-pcrextend` for TPM policies), and bootc's install with LUKS + TPM has an open
        issue (bootc-dev/bootc#421).
      - Limits: the kernel command line is fixed in the image (machine specific arguments such
        as `resume=` go; systemd resumes from the `HibernateLocation` EFI variable instead), btrfs
        is "expected to work but not tested" upstream (their CI covers ext4 and XFS), keys must
        be rotated (db key valid 10 years in the examples). The P14s gains nothing while it runs
        arkdep: this is also an argument for bootc in the comparison.
      - Test in a VM first: OVMF with our keys enrolled (`virt-fw-vars --set-pk/--add-kek/--add-db`,
        as in the series), which the boot test above can reuse to check the seal on every build
        (`verity=require`, `mokutil --sb-state`) before touching the T480's firmware.

Upstream issues with a local workaround, to drop when they are fixed in a bootc release:

- [ ] Boot counting on composefs (none reported yet; `bootc-boot-failure-detection(7)`: "likely
      to be added in the future"): `bootc-boot-count` and the `bootc-finalize-staged.service`
      drop-in of the base layer, once bootc writes counted entries itself.

- [ ] bootc-dev/bootc#2557 (no firmware boot entry with `--bootloader systemd`): the
      `efibootmgr` step of `bootc/install`.
- [ ] bootc-dev/bootc#2558 (`timeout 5` never written): the `loader.conf` written by `bootc/install`.
      - Both fixed by bootc-dev/bootc#2569 (Johan-Liebert1, 2026-10-14): after `bootctl install`,
        the `timeout` lines of `loader.conf` are replaced by `timeout 5` (#2558), and `bootctl` gets
        `--variables=yes` unless `--generic-image` (systemd >= 258; the image has 262) (#2557).
        Approved by cgwalters the same day, not merged on 2026-10-15: review requested from
        jeckersb, CI red in three fedora-44 composefs + systemd-boot unsealed jobs. cgwalters would
        rather have the initial `loader.conf` come from the image or package than hardcoded and
        parsed by bootc, so the #2558 fix may change shape. `bootctl install` (262) cannot take
        `loader.conf` from `--root` (it only writes its commented template when the file is
        missing), so a file in the image needs bootc to copy it to the ESP. If bootc gets that, our
        `loader.conf` moves to the base layer (the Containerfile is already our own Arch base, the
        counterpart of fedora-bootc's config); if the timeout only moves to fedora-bootc, nothing
        changes for us.
      - Tested 2026-10-15 (PR head 5685e48, a `test/t480` image with it, `bootc/install` from the
        ISO in the T480-layout VM, ESP and firmware entries reset to the Artix state first):
        the #2557 commit breaks the install. `bootc install` aborts right after `bootctl` copied
        systemd-boot: "Failed to determine current boot order: Operation not supported". systemd
        treats a container as not booted with EFI (`bootctl status` in the image's container: "Not
        booted with EFI or running in a container", also with efivarfs mounted there), and an
        explicit `--variables=yes` fails instead of skipping; `bootc install` always runs in a
        container. It leaves the root formatted and the ESP with systemd-boot, the template
        `loader.conf` and no entry. With `--generic-image` (`--no-variables`) the #2558 commit
        works: `loader.conf` is `timeout 5` + `#console-mode keep` (no final newline) and the menu
        counts down from 5 s. The fedora-44 CI failures fit the same cause (systemd >= 258 there,
        CentOS 10's 257 never gets the flag), not checked (logs need a login). Reported on the PR
        the same day.
      - The PR thread: on 2026-10-16 cgwalters suggested mounting efivarfs read-write under
        `podman run` and turned the PR into a draft. Our answer (2026-10-17): it was mounted rw
        already; the check is systemd's container detection (`is_efi_boot()` is false when
        `detect_container() > 0`); `efibootmgr` could create the entry, best effort (bootcrew's
        Arch image has none); the timeout commit could land on its own. On 2026-10-19
        Johan-Liebert1 did not want bootc to manage the firmware entry itself (taken to the
        maintainers' Monday meeting). cgwalters proposed three ways out: `env container=""`, a
        `bootctl install --variables=always`, or bootctl taking writable efivarfs in the host PID
        namespace as "not a container". His agent (cgwalters-bot, cgwalters-forge/tracker#709)
        works on it. `container=""` does not help: systemd reads it only in PID 1 (`virt.c`, same
        as v262), and here the detection comes from podman's `/run/.containerenv`, a bind mount
        checked before the PID namespace. `systemd-detect-virt --container` in
        `podman run --pid=host` says `podman` with or without it. cgwalters' agent reached the
        same conclusions from the code (in his tracker, not on the PR; a VM run followed, below).
        Answered on 2026-10-20 (issuecomment-6290651271):
        - the `--variables=yes` idea was ours;
        - the `container=""` test;
        - bootupd needs shim, so #2512 doesn't cover shim-less images;
        - `--graceful` is no way out;
        - preferred fix: an explicit bootctl option (e.g. `--variables=always`) that bootc passes
          gated on the systemd version, since it serves every image;
        - meanwhile the old skip plus a warning;
        - we offered to test.

        Also noted on #2557 the same day that its suggestion fails from a container.
        The other two are systemd changes and need a systemd release, so the `efibootmgr` step
        stays for a while. `--graceful` is no way out for bootc. For `bootctl install` it only
        counts when the chroot detection forces it (`bootctl-install.c` L144-145), and bootc
        turns that off on purpose (`SYSTEMD_IN_CHROOT=0`, #2486: graceful let a failed install
        exit 0). Checked 2026-10-20 in the ISO VM, bootctl run as bootc runs it in the
        container: `--variables=yes --graceful` fails the same way, without `--variables` it
        skips them (rc 0). Best effort in bootc means not passing `--variables=yes` where it
        cannot work, as before the PR.
      - cgwalters' agent, run again in an OVMF VM on 2026-10-20
        (bootc-dev/cgwalters-devspace-sandbox#24, not on the PR), agrees with our answer and goes
        further. Tested with `to-disk` only:
        - systemd: `bootctl install` ignores the override of the container check that
          `--variables=yes` gives the other verbs since v260 (systemd@1fa1e88):
          `should_touch_install_variables()` never calls `set_efi_boot()`. Its patch fixes that
          through the existing `--variables=yes`, no new option, and then probes the ESP too.
          Better than our `--variables=always`.
        - A second blocker: with bootc's `SYSTEMD_RELAX_ESP_CHECKS=1`, and in any container,
          bootctl skips probing the ESP's device and writes an entry with an empty device path
          (`HD(0,GPT,00000000-...)`), which the firmware cannot load.
        - bootc: now, drop the `--variables=yes` commit and warn (its diff, tested); once a systemd
          release has the patch, `--variables=yes` from that version on and the relax only for
          `--generic-image`.
      - Our check of the `to-filesystem` case (2026-10-21, the ISO VM, a `test/t480` image with
        bootc 1.17.1 and systemd 262). A `bootctl` wrapper on the container's `PATH` stood in for
        the proposal: it adds `--variables=yes`, drops the relax and hides `/run/.containerenv`
        in a private mount namespace (what the systemd patch amounts to). `bootc/install` kept
        the home, without its `efibootmgr` step:
        - `bootc install to-filesystem` passes the strict ESP checks (ESP mounted at
          `/target/boot`), and bootctl creates `Linux Boot Manager` with
          `HD(1,GPT,<ESP PARTUUID>,...)`, first in BootOrder. Booted with the disk alone and that
          NVRAM, OVMF loads that entry and the system reaches the login prompt.
        - With the relax kept, the same call writes its entries with `HD(0,GPT,00000000-...)`,
          first in BootOrder: the second blocker holds on 262 too.
        - systemd 262 also creates `Fallback Linux Boot Manager` for
          `systemd-boot-fallbackx64.efi`, which is not on the ESP yet. By design: `bootctl update`
          copies the previous binary there. The firmware skips the missing file.
        - Not covered: osbuild (no udev database), the case the relax was added for.

        Not posted: it waits until the proposal reaches the PR or systemd.
      - bootupd, Fedora's way to the entry, is not one for us. bootc hands GRUB to bootupd,
        which runs `efibootmgr`, and the draft bootc-dev/bootc#2512 would hand it systemd-boot
        too (bootupd >= 0.3.0). But bootupd only installs systemd-boot behind shim and points the
        entry at `shimx64.efi`. Tested 2026-10-20 in the ISO VM (disk overlay and a copy of the
        EFI variables, nothing kept). Setup: bootupd 0.3.2 built here, the 2026-10-15
        `test/t480` image with systemd-boot copied to `/usr/lib/efi/systemd-boot/262/EFI/systemd`,
        `bootupctl backend install --bootloader systemd --component EFI --device /dev/nvme0n1` in
        `podman run --privileged --pid=host`. Without shim it fails with or without
        `--update-firmware` ("Failed to find shimx64.efi in the image": `src/bootupd.rs`
        L278-283 looks the vendor up from shim). With a dummy `shimx64.efi` it creates
        `Arch Linux` -> `\EFI\arch\shimx64.efi`, first in BootOrder, from the container. #2512
        keeps the bare `bootctl` for shim-less images, so the bootctl fix is the one that counts
        here. Arch does have shim: `shim` in `extra` (unsigned, in `/usr/share/shim`, to sign
        yourself) and Fedora's Microsoft-signed one in the AUR (`shim-signed`). It is only worth
        it if Secure Boot goes the shim + MOK way (systemd-boot as `grubx64.efi`, MOK enrolled on
        every machine, firmware keys untouched) instead of our own keys in the firmware (Sealed
        images): then bootupd would also bring the entry and the systemd-boot updates. An `arch-bootc` package with an `efibootmgr` step would not help either:
        `bootc install` runs nothing from the image afterwards (no hooks), so `bootc/install`
        would still have to call it.
      - Our `loader.conf` stays anyway: it carries our settings, like the arkdep installer's, and
        since 2026-10-19 `timeout 0` (the menu hidden, boot counting goes back by itself), so it
        overwrites bootc's `timeout 5`. Only its #2558 comment goes. The `efibootmgr` step stays
        until bootc creates the entry in a way that works in a container. Both `bootc/install`
        modes run `bootc install to-filesystem` in `podman run --pid=host`. `efibootmgr --create`
        works in the same container once efivarfs is mounted there (checked; bootc mounts it
        itself).
      - Next: the release that includes a working fix, `pkgver` of `aur/local/bootc`, a rebuilt
        image, then a rehearsal in the ISO VM. Test setup kept in `~/.cache/bootc-rehearsal`
        (`podman-scratch.qcow2` holds podman's storage on a second disk instead of a 12G tmpfs,
        so the VM needs 4 GiB). The test image: `aur/local/bootc`'s PKGBUILD with the commit's
        GitHub archive as source (`makepkg --nocheck` in `aur-builder`), `pacman -U` over the
        `[aur]` bootc in a copy of the Containerfile, `REPOSITORY=test/t480 bootc/build t480`
        from a copy of the checkout (~30 min on the server).
- [ ] bootc-dev/bootc#2227 (version read from labels on ostree, annotations on composefs): keep
      both in `bootc/build`; the creation date fallback of `bootc-update` once every image has the
      annotation.
      - Answered by bootc-dev/bootc#2570 (mvanhorn, 2026-10-15, "Closes #2227"): composefs status
        keeps the manifest annotation and falls back to `version_for_config()` (the
        `org.opencontainers.image.version` label, then `version`), as we proposed. Approved by
        cgwalters on 2026-10-16, not merged on 2026-10-19. CI was red in nearly every job, as
        for the other PRs of that day, so probably not because of this change. It does not touch the `created` lookups listed in
        the issue (`status.rs`, `aleph.rs`).
      - Once released: the label alone gives the version, so the annotation in `bootc/build` is
        no longer needed (harmless: chunkah writes it anyway) and the creation date fallback of
        `bootc-update` only matters for images without the label.
- [ ] AUR `bootc` without the `selinux` feature (reported in the AUR comments): `aur/local/bootc`
      while the AUR package links libselinux.
      - The maintainer (jjm) has answered no comment since 2025-11; nvchecker bumps the version
        (1.17.1 came after our comment, without the fix), so every release since 1.16.11 fails
        in a clean chroot.
      - Emailed the maintainer on 2026-10-20 (the comment's patch, offer to co-maintain). No answer
        by 2026-11-03: decide whether to file an orphan request and adopt it (`aur/local/bootc`
        would become the AUR package). Not out-of-date flags (new versions only) nor a duplicate
        package.
- [ ] ESP mounted read-only by bootc (`systemd.mount-extra=...:/boot:auto:ro`), which breaks
      systemd-boot's own units (none reported yet): `systemd-boot-random-seed` is masked, and
      `systemd-boot-update` and `systemd-bless-boot` remount it read-write in their own process
      (`bootc/CLAUDE.md`). Not ours alone: any composefs + systemd-boot system that uses them.

## bootcrew upstream

Nothing here depends on them (bootc is built in `[aur]`, the Containerfile is ours): reports for
other users of the Arch image.

- [ ] bootcrew/mono#24 (2026-10-17): their Arch image has failed to build since 2026-09-03. bootc
      links libselinux since bootc-dev/bootc@c3241ab77 (2026-09-02), and Arch's repositories don't
      have it. Checked by building `arch/Containerfile` here: it fails on `selinux/selinux.h`, and
      with `CARGO_OPTIONS='--no-default-features --features "install-to-disk pre-6.15"'` in
      `shared/build.sh` it builds and passes `bootc container lint`. `build.sh` is shared by every
      image, so the issue suggests the option for Arch only. Ubuntu has failed since the same day
      (not checked).
- [ ] Comment on bootcrew/mono#23 (2026-10-17, DNS, #22): `L` does not replace an existing
      `/etc/resolv.conf` either, `L+` does. On Arch the image has none, and systemd's own
      `systemd-resolve.conf` already has the link.
      - No answer to either on 2026-10-19.

## arkdep upstream

- [ ] arkanelinux/arkdep#53: `arkdep deploy` computes the boot entry's file name (with the time)
      for every template line, so an entry written across a second boundary is split in two: a
      title-only `<time>-<image>+3.conf` and the rest under the next second, shown by its file
      name (p14s-2026-10-08). No workaround in the images: merge them by hand or let the entry go
      with its deployment. Also reported there: the conflict check before writing never matches,
      and `arkdep cleanup` never removes the boot entry and kernel of an untracked deployment
      (`[[ -f ...*glob* ]]`); `remove_deployment` does.
      - Fixed upstream in ef6738e (2026-10-09, not released: `[arkane]` still has 2026.08.17), but
        the fix computes the time as `$($(date +%Y%m%d-%H%M%S))`: bash runs the time as a command
        ("command not found") and the variable is empty, so every entry would be named
        `-<image>+3.conf`. Reported:
        https://github.com/arkanelinux/arkdep/issues/53#issuecomment-6077770244, fixed in
        366d3af (2026-10-09, the single substitution we proposed). Neither is released yet. When
        the P14s image takes the next arkdep release, check that it includes 366d3af (`grep
        systemd_boot_entry_timestamp /usr/bin/arkdep`: one `$(`) and, after the first deploy with
        it, the entry's name on the ESP. The other two points are still open.

## Storage

- [x] **Compress the existing data: not done (decided 2026-10-09).** `compress=zstd:1`
      (2026-10-07, active on the P14s since the p14s-2026-10-07 deployment, 2026-10-08) only
      applies to new writes. `sudo compsize -x /home` on 2026-10-09: 76 GB on disk, of which 2.4 GB
      written since then is zstd (37 %) and 75 GB uncompressed, but 127 GB referenced: ~50 GB are
      extents shared between files (reflinks). `btrfs filesystem defragment -r -czstd /home` would
      unshare them (the disk usage could grow) and rewrite ~75 GB on the SSD, for a modest gain
      (container layers, ISOs, browser cache and downloads compress little), with `/home` 25 %
      full (356 GB free). Files rewritten from now on get compressed anyway. If one large,
      compressible directory without reflinks ever matters, defragment only that one.
- [x] Stopped podman containers kept by `podman-cleanup`: the dev containers stay (VS Code
      reopens them; 17.6 GB of writable layers on the P14s, 2026-10-09), and `playground` comes
      from the userland image now.

## Memory and scheduling

- [ ] **systemd-oomd**, left out of the cachyos-settings subset (see CLAUDE.md, Memory tuning):
      revisit only if the system ever thrashes. It would need the `userland` distrobox protected
      (`ManagedOOMPreference=avoid` on a dedicated slice, monitoring `user@1000.service` instead
      of `user-.slice`) and testing that it kills a dev container and not userland.
- [ ] **sched-ext** (`scx_lavd`, an interactivity and power aware scheduler for laptops) on top of
      the BORE scheduler of linux-cachyos: optional experiment (`scx-scheds`, `scx_loader`).
