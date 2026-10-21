# shellcheck shell=bash
# Push an image built on the build server to the registry (bootc/build, userland/build): chunkah
# splits it into per-package layers, so an update downloads only the packages that changed, and
# skopeo pushes them as they are, signed with the server's sigstore key, under one tag; tag_image
# then points other tags (the date, latest) at it. Sourced; the caller sets -euo pipefail.

# REGISTRY, the name clients pull from: the signature names the image it signs (matchRepository
# in the clients' policy.json), so the push goes to the LAN address, not localhost
# shellcheck source=lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"
SIGSTORE_DIR=${SIGSTORE_DIR:-/etc/distro-builder/sigstore}  # private key and its passphrase, root only
# Pinned: an update of chunkah's gzip could change the bytes of unchanged layers, and every client
# would download the whole image again
CHUNKAH=${CHUNKAH:-quay.io/coreos/chunkah:v0.7.0}
SKOPEO=${SKOPEO:-quay.io/skopeo/stable:v1.22.3}

# push_image <local image> <repository> <version> <tag> [chunkah build option...]
# The version (the build date) goes to the org.opencontainers.image.version label and manifest
# annotation, the checkout's commit to org.opencontainers.image.revision; the image is pushed as
# <repository>:<tag>. Fails without the signing key: the clients refuse unsigned images of the
# registry and would stop updating without a word (ALLOW_UNSIGNED=1 for local test runs). Removes
# the local image afterwards: the registry holds it (a copy of several GB on the build server's disk
# otherwise)
push_image() {
	local image=$1 repository=$2 version=$3 tag=$4 revision
	shift 4

	local mounts=(-v /etc/containers/registries.d:/etc/containers/registries.d:ro)
	local sign=()
	if [[ -r $SIGSTORE_DIR/distro-builder.private ]]; then
		mounts+=(-v "$SIGSTORE_DIR:$SIGSTORE_DIR:ro")
		sign=(--sign-by-sigstore-private-key "$SIGSTORE_DIR/distro-builder.private"
			--sign-passphrase-file "$SIGSTORE_DIR/passphrase")
	elif [[ ${ALLOW_UNSIGNED:-0} == 1 ]]; then
		echo "No signing key ($SIGSTORE_DIR): the image is not signed (ALLOW_UNSIGNED=1)" >&2
	else
		echo "No signing key ($SIGSTORE_DIR): clients refuse unsigned images, not pushing" >&2
		return 1
	fi

	# The commit this checkout built, "-dirty" with local changes. As root in admin's checkout git
	# needs safe.directory; a copy without .git (test runs) has none
	revision=$(git -c safe.directory="$PWD" describe --always --dirty --abbrev=40 2>/dev/null) || revision=unknown

	# chunkah's output, an OCI directory layout (~1 GiB): /var/tmp, not the tmpfs /tmp. Global for
	# the EXIT trap
	PUSH_IMAGE_WORK=$(mktemp -d /var/tmp/push-image.XXXXXX)
	trap 'rm -rf -- "$PUSH_IMAGE_WORK"' EXIT
	local work=$PUSH_IMAGE_WORK
	mounts+=(-v "$work:/work")

	# One layer per group of packages instead of one per Containerfile step. chunkah reads the
	# pacman database (DBPath in the image's pacman.conf). The layers are gzip-compressed once, here,
	# and pushed as they are: no import into containers-storage and no recompression by podman push
	CHUNKAH_CONFIG_STR=$(podman inspect "$image")
	export CHUNKAH_CONFIG_STR
	podman run --rm --mount=type=image,src="$image",target=/chunkah -v "$work:/out" \
		-e CHUNKAH_CONFIG_STR "$CHUNKAH" build "$@" \
		--label org.opencontainers.image.version="$version" --annotation org.opencontainers.image.version="$version" \
		--label org.opencontainers.image.revision="$revision" \
		--compressed --max-layers 128 -o oci:/out/image

	# Signed with the build server's sigstore key: the signature goes to the registry next to the
	# image (sha256-<digest>.sig, /etc/containers/registries.d/50-distro-builder.yaml, mounted into
	# the skopeo container). It covers every tag tag_image points at the same manifest digest.
	# --preserve-digests: the manifest goes up byte for byte (chunkah's annotations, OCI format: the
	# composefs backend fails on Docker v2s2 manifests, bootc-dev/bootc#1703); skopeo fails instead
	# of rewriting it. Blobs already in the registry are skipped
	podman run --rm --network host "${mounts[@]}" "$SKOPEO" copy --preserve-digests \
		--dest-tls-verify=false --digestfile /work/digest "${sign[@]}" \
		oci:/work/image "docker://$REGISTRY/$repository:$tag"
	echo "Pushed $REGISTRY/$repository:$tag ($(<"$work/digest"))${sign:+, signed}, revision $revision"

	podman rmi "$image" >/dev/null
	podman image prune -f >/dev/null
}

# tag_image <repository> <tag> <new tag>...
# Point the new tags at the image of <tag>: its manifest copied byte for byte through the registry
# API, so the digest, and the signature that names it, are the same
tag_image() {
	local repository=$1 from=$2 manifest type
	shift 2
	local api=http://$REGISTRY/v2/$repository/manifests
	manifest=$(mktemp)
	type=$(curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json' -o "$manifest" \
		-w '%{content_type}' "$api/$from") || { rm -f "$manifest"; return 1; }
	for tag; do
		curl -fsS -X PUT -H "Content-Type: $type" --data-binary @"$manifest" -o /dev/null "$api/$tag" ||
			{ rm -f "$manifest"; return 1; }
		echo "Tagged $REGISTRY/$repository:$tag ($repository:$from)"
	done
	rm -f "$manifest"
}
