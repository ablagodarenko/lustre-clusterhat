# Helpers shared by build.sh and the stages.

set -e
set -o pipefail

TOP=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
. "$TOP/config.sh"
[ ! -f "$TOP/config-local.sh" ] || . "$TOP/config-local.sh"
# runtime defaults (addresses, mount point): the images are built to match
. "$TOP/cluster/config.sh"

DL=$WORK/dl
SRC=$WORK/src
PKGS=$WORK/pkgs
BUILDROOT=$WORK/buildroot
CLIENTROOT=$WORK/clientroot
NODEROOT=$WORK/node-rootfs
VMOUT=$WORK/vm

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ "$(uname -m)" = aarch64 ] || die "must run on an aarch64 host"

# download $1 to $DL unless it is already there; print the local path
fetch() {
	local url=$1 dest=$DL/${1##*/}
	mkdir -p "$DL"
	if [ ! -s "$dest" ]; then
		log "fetching $url" >&2
		curl -fL --retry 3 -o "$dest.part" "$url" >&2
		mv "$dest.part" "$dest"
	fi
	echo "$dest"
}

# Everything mounted through these helpers is unmounted on exit, in
# reverse order, whatever way the stage ends.
MOUNTS=()
LOOPS=()

track_mount() {	# track_mount <mount args...> ; last arg is the mount point
	mount "$@"
	MOUNTS+=("${!#}")
}

cleanup() {
	local i
	set +e
	for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
		mountpoint -q "${MOUNTS[i]}" && umount "${MOUNTS[i]}"
	done
	for i in "${LOOPS[@]}"; do losetup -d "$i" 2>/dev/null; done
	MOUNTS=(); LOOPS=()
}
trap cleanup EXIT

# make a root filesystem tree usable as a chroot
chroot_open() {
	local root=$1 fs
	for fs in proc sys dev dev/pts; do
		mountpoint -q "$root/$fs" || track_mount --bind /$fs "$root/$fs"
	done
	# keep package scripts from starting services on the build host
	printf '#!/bin/sh\nexit 101\n' > "$root/usr/sbin/policy-rc.d"
	chmod 755 "$root/usr/sbin/policy-rc.d"
	# name resolution for apt inside the chroot: borrow the build host's
	# resolv.conf, and put the root's own back in chroot_close so the
	# host's does not end up in an image
	if [ ! -e "$root/etc/resolv.conf.lch-orig" ] && [ ! -L "$root/etc/resolv.conf.lch-orig" ]; then
		if [ -e "$root/etc/resolv.conf" ] || [ -L "$root/etc/resolv.conf" ]; then
			mv "$root/etc/resolv.conf" "$root/etc/resolv.conf.lch-orig"
		else
			: > "$root/etc/resolv.conf.lch-none"
		fi
	fi
	cp /etc/resolv.conf "$root/etc/resolv.conf"
}

# undo what chroot_open changed inside the root, leaving it mounted
chroot_restore() {
	local root=$1
	rm -f "$root/usr/sbin/policy-rc.d" "$root/etc/resolv.conf"
	if [ -e "$root/etc/resolv.conf.lch-orig" ] || [ -L "$root/etc/resolv.conf.lch-orig" ]; then
		mv "$root/etc/resolv.conf.lch-orig" "$root/etc/resolv.conf"
	fi
	rm -f "$root/etc/resolv.conf.lch-none"
}

chroot_close() {
	chroot_restore "$1"
	cleanup
}

# drop what only costs space in an image
slim_root() {
	rm -rf "$1"/var/lib/apt/lists/* "$1"/var/cache/apt/archives/*.deb \
		"$1"/var/log/apt/* "$1"/var/log/dpkg.log
}

# bind a host directory into an open chroot
chroot_bind() {	# chroot_bind <root> <host dir> <path inside>
	mkdir -p "$1/$3"
	track_mount --bind "$2" "$1/$3"
}

in_root() {	# in_root <root> <command...>
	local root=$1; shift
	chroot "$root" /usr/bin/env -i HOME=/root TERM=dumb LC_ALL=C \
		DEBIAN_FRONTEND=noninteractive JOBS="$JOBS" \
		PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

# kernel release of the server nodes, fixed by stage 20
node_krel() {
	cat "$WORK/node-krel" 2>/dev/null || die "node kernel not chosen yet: run stage 20"
}

# "make debs" in the Lustre tree insists on a linux-headers-<arch>
# metapackage that neither kernel used here provides
DEB_NOCHECK='mkdir -p /root/.config/dpkg &&
	echo no-check-builddeps > /root/.config/dpkg/buildpackage.conf'
