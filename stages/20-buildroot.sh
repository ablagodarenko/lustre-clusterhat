#!/bin/bash
# Build environment for everything that runs on the server nodes: the
# nodes' own root filesystem (Raspberry Pi OS arm64) plus compilers,
# the node kernel's headers and the matching kernel source.  Building in
# it keeps the build host untouched.

. "$(dirname "$(readlink -f "$0")")/../lib.sh"

if [ ! -e "$BUILDROOT/etc/os-release" ]; then
	log "unpacking node root into $BUILDROOT"
	mkdir -p "$BUILDROOT"
	tar -C "$BUILDROOT" --numeric-owner -xJf "$(fetch "$NODE_ROOT_URL")"
fi

chroot_open "$BUILDROOT"
in_root "$BUILDROOT" apt-get update

krel=$NODE_KREL
if [ -z "$krel" ]; then
	krel=$(in_root "$BUILDROOT" apt-cache depends linux-image-rpi-v8 |
	       sed -n 's/^ *Depends: linux-image-//p' | head -1)
fi
[ -n "$krel" ] || die "cannot work out the node kernel release"
echo "$krel" > "$WORK/node-krel"
kmm=$(echo "$krel" | cut -d. -f1-2)
log "node kernel: $krel"

in_root "$BUILDROOT" apt-get install -y --no-install-recommends \
	linux-headers-$krel linux-source-$kmm \
	build-essential libtool automake autoconf pkg-config flex bison bc \
	kmod git rsync ed quilt perl python3 python3-dev swig \
	debhelper dh-exec dpkg-dev fakeroot lsb-release module-assistant \
	libyaml-dev libnl-3-dev libnl-genl-3-dev libmount-dev libselinux1-dev \
	libreadline-dev libkeyutils-dev libssl-dev zlib1g-dev libelf-dev \
	libjson-c-dev libkrb5-dev \
	texinfo gettext libblkid-dev uuid-dev libudev-dev libfuse-dev \
	libattr1-dev libacl1-dev libarchive-dev

# ldiskfs is built from the kernel's ext4 sources, which the headers
# package does not carry
if [ ! -e "$BUILDROOT/usr/src/linux-source-$kmm/fs/ext4/super.c" ]; then
	in_root "$BUILDROOT" tar -C /usr/src -xJf /usr/src/linux-source-$kmm.tar.xz
fi
chroot_close "$BUILDROOT"
