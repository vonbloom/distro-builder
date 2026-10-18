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

First server build (build-bootc@p14s, 2026-10-07, VM 202 with 6 cores): 18 min, I/O bound. Package
download and install take 1.6 min; committing the recipe layer (~3.5 GB, ~100k files) 5.6 min;
chunkah + `podman load` ~7 min (and the 6.9 GB memory peak of the 8 GB VM); the push 1 min (later
pushes only upload changed layers). The VM disk is a zvol on zeus' Kingston SA400 SATA SSDs.

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
      30 min later), and the whole log is `candidate.log` next to the `.pkgs` files. VM 202 got
      `cpu: host` (nested KVM; zeus has `kvm_intel nested=Y`) and `qemu-system-x86` + `ovmf`
      (homelab). Same change: no push without the signing key (it pushed unsigned with a warning,
      and the clients would have refused it without a word), no push with 20 % fewer packages than
      the previous image, the CachyOS key from `keys/` instead of the keyserver, `--pull=newer`
      for the base image, and the checkout's commit as `org.opencontainers.image.revision`.
      Catches what breaks the generic boot (initramfs and dracut modules, composefs setup, `/etc`
      merge of a fresh install, failing units, emergency mode), not hardware specific drivers
      (i915, Wi-Fi) or the desktop.
- [ ] **Upgrade test**: the T480 never installs from scratch, it upgrades, and the `/etc` 3-way
      merge (a file changed both in the image and locally) only happens on an upgrade. Install the
      previous `latest`, boot it, `bootc switch` to the candidate (the VM then needs a network to
      the registry: QEMU user networking reaches the build server's port 5000), reboot, same
      checks. About twice the test's time.
- [ ] The T480 is `degraded` (2026-10-18, `t480:2026-10-11`, up 6 days): `btrbk.service` fails
      (its `snapshot_dir /arkdep/snapshots` does not exist under bootc, bootc/README "Missing
      before real use") and `systemd-networkd-wait-online.service` timed out. Neither is part of
      the boot transaction, so the boot test does not see them. Fixed on 2026-10-18, to check on
      the T480 with the next image: btrbk is out of the bootc layers (the home backup replaces it);
      wait-online was started on 2026-10-17 by `archlinux-keyring-wkd-sync` (weekly) and timed out
      on the unplugged Ethernet port: `--any`, and the keyring sync masked (`bootc/CLAUDE.md`).
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
      laptops or yamaha moves to bootc (unattended updates of a server), and until the T480 shows
      how often consecutive images qualify, now that the initramfs no longer changes on every
      build (Arch updates its kernel, systemd, glibc, zstd or plymouth's libraries most weeks).
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
        --sign-passphrase-file ... oci:<dir> docker://192.168.2.50:5000/<recipe>:<date>` and the
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
      Prospect with a third kind of machine (yamaha: x86-64-v2, Cinnamon, appliance services),
      the split of `depends/generic` into base and modules, and a phase 1 in today's recipe
      format: `layers.md` (2026-10-09).
      Done in part (2026-10-18): the bootc images no longer replay the arkdep recipes
      (`build-recipe.sh`): `bootc/layers` has `base`, `modules/laptop`, `modules/workstation`,
      `desktop/sway` and `host/{t480,p14s}` (a `packages.list` and an `overlay/` each, a host's
      `layers.list`), applied in order by `bootc/apply-layers` in the one Containerfile, and
      `image/arkdep-build.d` is frozen for the P14s. Still to do: an image per layer in the
      registry (the base built once for every host, a host build reusing it), the audio modules and
      yamaha (`layers.md`).
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
- [ ] VM 202 memory 8 -> 12 GB (homelab `host_vars/zeus.yml`, `qm set 202 --memory 12288`). Less
      pressing since the skopeo push: a bootc build peaks at 3 GB.
- [ ] Optional: pacman package cache across builds (`RUN --mount=type=cache`), ~700 MB of
      downloads per build (40 s today).
- The rpool NVMe replacement (homelab TODO) speeds up every I/O bound phase.

## userland image

The userland distrobox built here as an image (`userland/`, 2026-10-09) instead of assembled and
upgraded in place on each machine from the dotfiles' `default.ini`. Done: the image, its manifest
(`/usr/share/userland/distrobox.ini`), the weekly build and the status page. Test builds on the
server (2026-10-09): 15 min, 1.63 GB compressed in 128 layers (the live userland's writable layer
was 8.9 GB, 3.7 GB of it package cache); a box created from it on the P14s started in 13 s
without installing anything, with zsh, `ca_ES.UTF-8`, the apps and the remote podman working.
Still to do, in order:

- [ ] **Pull from the registry on the laptops**: the registry's client config moved from
      `bootc/overlay` to the generic overlay (`registries.conf.d` with `192.168.2.50:5000` as
      insecure, `registries.d`, a `policy.json` that requires the signature for that registry and
      keeps Arch's default for the others), and the arkdep image gets the key from `keys/`
      (2026-10-09). To check once the P14s runs an image built with it: `podman pull
      192.168.2.50:5000/userland:latest` works, and an unsigned image there is refused.
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
        CentOS 10's 257 never gets the flag), not checked (logs need a login). Not yet reported
        on the PR.
      - Our `loader.conf` stays anyway (our settings, like the arkdep installer's): only its #2558
        comment goes. The `efibootmgr` step stays until bootc creates the entry in a way that works
        in a container: `efibootmgr --create` works in the same container once efivarfs is mounted
        there (checked; bootc mounts it itself).
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
        `org.opencontainers.image.version` label, then `version`), as we proposed. Not reviewed
        on 2026-10-16 (jeckersb requested); CI red in nearly every job, as for the other PRs of
        that day, so probably not this change. It does not touch the `created` lookups listed in
        the issue (`status.rs`, `aleph.rs`).
      - Once released: the label alone gives the version, so the annotation in `bootc/build` is
        no longer needed (harmless: chunkah writes it anyway) and the creation date fallback of
        `bootc-update` only matters for images without the label.
- [ ] AUR `bootc` without the `selinux` feature (reported in the AUR comments): `aur/local/bootc`
      while the AUR package links libselinux.

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
