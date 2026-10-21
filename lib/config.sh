# shellcheck shell=bash
# The build server's address, the one value the builds take from outside the repository: the
# overlays and the installers carry @SERVER@ in its place, replaced when an image or the ISO is
# built. Read from the environment (a local test run), else from the server's
# /etc/distro-builder/config (written by install), else from a host image's
# /usr/lib/distro-builder/config (also through /run/host from a distrobox: iso/test-vm). Sourced;
# the caller sets -euo pipefail. Sets SERVER, REGISTRY and REPO_URL.

if [[ -z ${SERVER:-} ]]; then
	for config in "${DISTRO_BUILDER_CONFIG:-/etc/distro-builder/config}" /usr/lib/distro-builder/config \
		/run/host/usr/lib/distro-builder/config; do
		# shellcheck disable=SC1090 # outside the repository
		[[ -r $config ]] && { . "$config"; break; }
	done
fi
# Also keeps sed's s|@SERVER@|...| safe
if [[ ! ${SERVER:-} =~ ^[A-Za-z0-9.:-]+$ ]]; then
	echo "No build server address: SERVER=<address> in /etc/distro-builder/config (install writes it) or in the environment" >&2
	exit 1
fi
REGISTRY=${REGISTRY:-$SERVER:5000}
REPO_URL=${REPO_URL:-http://$SERVER}
