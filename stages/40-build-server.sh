#!/bin/bash
# Lustre server packages (ldiskfs) for the node kernel.

. "$(dirname "$(readlink -f "$0")")/../lib.sh"

krel=$(node_krel)
kmm=$(echo "$krel" | cut -d. -f1-2)

rm -rf "$BUILDROOT/build/lustre"
mkdir -p "$BUILDROOT/build" "$PKGS/server"
git clone -q --local --no-hardlinks "$SRC/lustre-release" "$BUILDROOT/build/lustre"

chroot_open "$BUILDROOT"
in_root "$BUILDROOT" bash -ec "
	$DEB_NOCHECK
	cd /build/lustre
	git config --global --add safe.directory /build/lustre
	sh autogen.sh
	# the unpacked linux-source tree has the ext4 sources, the headers
	# package is the configured object tree
	./configure --enable-server --with-ldiskfs --without-zfs \
		--disable-gss --with-o2ib=no --disable-tests \
		--with-linux=/usr/src/linux-source-$kmm \
		--with-linux-obj=/usr/src/linux-headers-$krel
	make debs -j\$JOBS
"
chroot_close "$BUILDROOT"

# configure quietly drops ldiskfs if it has no patch series for the kernel
dpkg -c "$BUILDROOT"/build/lustre/debs/lustre-server-modules-*.deb |
	grep -q 'ldiskfs\.ko' || die "no ldiskfs module built for $krel"

rm -f "$PKGS"/server/*
cp "$BUILDROOT"/build/lustre/debs/*.deb "$PKGS/server/"
git -C "$SRC/lustre-release" describe --tags > "$PKGS/server/LUSTRE_VERSION"
ls -l "$PKGS/server"
