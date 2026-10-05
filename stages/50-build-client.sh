#!/bin/bash
# Lustre client packages for the Debian cloud kernel the client VMs run
# (the Raspberry Pi kernel has no virtio drivers, so the VMs cannot use
# it).  Built in a debootstrap chroot of the same Debian suite.

. "$(dirname "$(readlink -f "$0")")/../lib.sh"

if [ ! -e "$CLIENTROOT/etc/debian_version" ]; then
	debootstrap --variant=minbase \
		--include=ca-certificates,build-essential,libtool,automake,autoconf,pkg-config,flex,bison,bc,kmod,git,rsync,ed,quilt,python3,python3-dev,swig,debhelper,dh-exec,dpkg-dev,fakeroot,lsb-release,libyaml-dev,libnl-3-dev,libnl-genl-3-dev,libmount-dev,libselinux1-dev,libreadline-dev,libkeyutils-dev,libssl-dev,zlib1g-dev,libelf-dev,libjson-c-dev,libkrb5-dev,module-assistant,linux-headers-cloud-arm64 \
		"$DEBIAN_SUITE" "$CLIENTROOT" "$DEBIAN_MIRROR"
fi

rm -rf "$CLIENTROOT/build/lustre"
mkdir -p "$CLIENTROOT/build" "$PKGS/client"
git clone -q --local --no-hardlinks "$SRC/lustre-release" "$CLIENTROOT/build/lustre"

chroot_open "$CLIENTROOT"
in_root "$CLIENTROOT" bash -ec "
	$DEB_NOCHECK
	krel=\$(ls /lib/modules | grep cloud-arm64 | sort -V | tail -1)
	cd /build/lustre
	git config --global --add safe.directory /build/lustre
	sh autogen.sh
	./configure --disable-server --disable-gss --with-o2ib=no \
		--disable-tests \
		--with-linux=/usr/src/linux-headers-\${krel%-cloud-arm64}-common \
		--with-linux-obj=/usr/src/linux-headers-\$krel
	make debs -j\$JOBS
	echo \$krel > debs/KERNEL_RELEASE
"
chroot_close "$CLIENTROOT"

rm -f "$PKGS"/client/*
cp "$CLIENTROOT"/build/lustre/debs/*.deb \
	"$CLIENTROOT"/build/lustre/debs/KERNEL_RELEASE "$PKGS/client/"
ls -l "$PKGS/client"
