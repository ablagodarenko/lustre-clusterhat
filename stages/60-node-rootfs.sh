#!/bin/bash
# Root filesystem template of the server nodes: the ClusterHAT usbboot
# root with the node kernel, e2fsprogs and Lustre server packages.

. "$(dirname "$(readlink -f "$0")")/../lib.sh"

krel=$(node_krel)
T=$NODEROOT

rm -rf "$T"
mkdir -p "$T"
log "unpacking node root into $T"
tar -C "$T" --numeric-owner -xJf "$(fetch "$NODE_ROOT_URL")"

chroot_open "$T"
chroot_bind "$T" "$PKGS" mnt/pkgs

in_root "$T" apt-get update
in_root "$T" apt-get install -y --no-install-recommends \
	linux-image-$krel drbd-utils kmod rsync dosfstools fdisk parted iperf3
# the node must keep booting the kernel Lustre was built for
in_root "$T" apt-mark hold linux-image-$krel linux-image-rpi-v8

debs=$(cd "$PKGS" && ls e2fsprogs/*.deb server/*.deb |
       grep -vE -- '-dbgsym_|-dev_|-udeb_|e2fsck-static|fuse2fs|fuseext2|lustre-source|lustre-tests|lustre-iokit|lustre-client|lustre-resource' |
       sed 's|^|/mnt/pkgs/|')
# no recommends: lustre-server-modules recommends "linux-image", which
# apt satisfies with an old, unrelated kernel package
in_root "$T" apt-get install -y --allow-downgrades --no-install-recommends $debs
in_root "$T" depmod -a $krel

# the nodes boot exactly one kernel: drop the others (the Pi 5 flavour,
# the image's original kernel) and all kernel headers
extra=$(in_root "$T" dpkg-query -W -f '${Package}\n' 'linux-image-*' \
		'linux-headers-*' 'raspberrypi-kernel*' 2>/dev/null |
	grep -v -x -e "linux-image-$krel" -e linux-image-rpi-v8 || true)
# a kernel package refuses to be removed, by default, when its version is
# the one the build host happens to be running
for pkg in $extra; do
	case $pkg in linux-image-[0-9]*)
		v=${pkg#linux-image-}
		echo "$pkg $pkg/prerm/removing-running-kernel-$v boolean false" |
			in_root "$T" debconf-set-selections ;;
	esac
done
[ -z "$extra" ] || in_root "$T" apt-get purge -y $extra
in_root "$T" apt-get clean

# the kernel postinst put the new kernel and initramfs in /boot/firmware,
# which rpiboot serves to the node: check it really is the one we want
zcat -f "$T/boot/firmware/kernel8.img" | strings | grep -c "Linux version $krel " >/dev/null ||
	die "node boot kernel is not $krel"

# sshd on; the controller's key is added by "lustre-cluster init"
ln -sf /lib/systemd/system/ssh.service \
	"$T/etc/systemd/system/multi-user.target.wants/ssh.service"

# The nodes have 512 MB of RAM and no display.  Without the KMS overlay
# (256 MB of CMA) and with the minimum GPU split the kernel gets about
# 200 MB more; with the defaults the MDS fails to start with -ENOMEM.
in_root "$T" systemctl disable --quiet ModemManager bluetooth hciuart \
	wpa_supplicant avahi-daemon triggerhappy 2>/dev/null || true
in_root "$T" systemctl mask --quiet ModemManager bluetooth wpa_supplicant \
	avahi-daemon avahi-daemon.socket triggerhappy 2>/dev/null || true
sed -i -e '/^arm_64bit=/d' -e '/^gpu_mem=/d' \
	-e 's/^dtoverlay=vc4-kms-v3d/#&/' "$T/boot/firmware/config.txt"
printf 'arm_64bit=1\ngpu_mem=16\n' >> "$T/boot/firmware/config.txt"
grep -q 'cma=' "$T/boot/firmware/cmdline.txt" ||
	sed -i '1s/$/ cma=16M/' "$T/boot/firmware/cmdline.txt"

chroot_close "$T"
rmdir "$T/mnt/pkgs" 2>/dev/null || true
slim_root "$T"
[ "$(ls "$T/lib/modules")" = "$krel" ] || die "unexpected kernels left: $(ls "$T/lib/modules" | tr '\n' ' ')"
du -sh "$T"
