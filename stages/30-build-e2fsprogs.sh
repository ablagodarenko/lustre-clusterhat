#!/bin/bash
# Lustre-patched e2fsprogs: the servers need its mke2fs and e2fsck, and
# the Lustre server build needs its libext2fs.

. "$(dirname "$(readlink -f "$0")")/../lib.sh"

rm -rf "$BUILDROOT/build/e2fs"
mkdir -p "$BUILDROOT/build/e2fs" "$PKGS/e2fsprogs"
rsync -a --exclude .git "$SRC/e2fsprogs/" "$BUILDROOT/build/e2fs/e2fsprogs/"

# The Debian rules build out of tree, but ext2_types-wrapper.h is not a
# generated file and the install rule only looks in the build directory.
perl -pi -e 's{\$\(INSTALL_DATA\) \$\$i \$\(DESTDIR\)\$\(includedir\)/ext2fs/\$\$i}{\$(INSTALL_DATA) `test -f \$\$i || echo \$(srcdir)/`\$\$i \$(DESTDIR)\$(includedir)/ext2fs/\$\$i}' \
	"$BUILDROOT/build/e2fs/e2fsprogs/lib/ext2fs/Makefile.in"

chroot_open "$BUILDROOT"
in_root "$BUILDROOT" bash -ec '
	cd /build/e2fs/e2fsprogs
	DEB_BUILD_OPTIONS="nocheck parallel=$JOBS" dpkg-buildpackage -b -us -uc -d
	# The Lustre build links against the libraries.  e2fsprogs itself
	# has to come along: the stock one pins the stock library version.
	apt-get install -y --allow-downgrades $(ls ../*.deb | grep -E \
		"/(e2fsprogs|logsave|libcom-err2|comerr-dev|libext2fs2[a-z0-9]*|libext2fs-dev|libss2|ss-dev)_")
'
chroot_close "$BUILDROOT"

rm -f "$PKGS"/e2fsprogs/*
cp "$BUILDROOT"/build/e2fs/*.deb "$PKGS/e2fsprogs/"
ls -l "$PKGS/e2fsprogs"
