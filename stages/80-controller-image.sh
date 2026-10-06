#!/bin/bash
# The controller image: the ClusterHAT controller image plus everything
# the cluster needs - node root template, client VM image, QEMU and the
# lustre-cluster commands.

. "$(dirname "$(readlink -f "$0")")/../lib.sh"

krel=$(node_krel)
lver=$(cat "$PKGS/server/LUSTRE_VERSION")
img=$OUT/lustre-${lver#v}-${CTRL_IMAGE_URL##*/}
img=${img%.xz}
mnt=$WORK/mnt

[ -d "$NODEROOT/boot/firmware" ] || die "node root missing: run stage 60"
[ -s "$VMOUT/base.img" ] || die "client image missing: run stage 70"

mkdir -p "$OUT" "$mnt"
rm -f "$img" "$img.xz" "$img.sha256" "$img.xz.sha256"
log "unpacking controller image to $img"
xz -dc "$(fetch "$CTRL_IMAGE_URL")" > "$img"

# grow the root partition by what goes into it, plus QEMU and some slack
need_mb=$(( ($(du -sm "$NODEROOT" | cut -f1) + $(du -sm "$VMOUT" | cut -f1)) \
	    * 105 / 100 + 700 + IMAGE_SLACK_MB ))
log "growing the root filesystem by $need_mb MB"
truncate -s +${need_mb}M "$img"
echo ', +' | sfdisk -q -N 2 "$img"

loop=$(losetup -fP --show "$img")
LOOPS+=("$loop")
e2fsck -fy "${loop}p2" >/dev/null || [ $? -le 1 ]
resize2fs "${loop}p2" >/dev/null
track_mount "${loop}p2" "$mnt"
track_mount "${loop}p1" "$mnt/boot/firmware"

chroot_open "$mnt"
in_root "$mnt" apt-get update
in_root "$mnt" apt-get install -y --no-install-recommends \
	qemu-system-arm qemu-utils rsync openssh-client iperf3
in_root "$mnt" apt-get clean

state=$mnt/var/lib/lustre-clusterhat
mkdir -p "$state/vm"
log "copying node root template"
rsync -aHAX --numeric-ids "$NODEROOT/" "$state/node-rootfs/"
log "copying client VM image"
cp --sparse=always "$VMOUT"/base.img "$VMOUT"/vmlinuz "$VMOUT"/initrd.img "$state/vm/"

install -d "$mnt/opt/lustre-clusterhat"
install -m 755 "$TOP"/cluster/*.sh "$TOP/cluster/lustre-cluster" "$mnt/opt/lustre-clusterhat/"
ln -sf /opt/lustre-clusterhat/lustre-cluster "$mnt/usr/local/sbin/lustre-cluster"

install -m 644 "$TOP"/files/*.service "$mnt/etc/systemd/system/"
in_root "$mnt" systemctl enable lustre-clusterhat-init.service \
	lustre-clusterhat-fan.service

# let rpiboot, not usb-storage, have the Zeros' boot ROM: as a module
# option and on the kernel command line, whichever way the driver loads
install -m 644 "$TOP/files/usb-storage-rpiboot.conf" "$mnt/etc/modprobe.d/"
grep -q 'usb-storage.quirks=' "$mnt/boot/firmware/cmdline.txt" ||
	sed -i '1s/$/ usb-storage.quirks=0a5c:2764:i/' "$mnt/boot/firmware/cmdline.txt"

# headless access: sshd (there is no account until first boot creates
# one) and the serial console
in_root "$mnt" systemctl enable ssh.service
grep -q '^enable_uart=1' "$mnt/boot/firmware/config.txt" ||
	printf '\n[all]\nenable_uart=1\n' >> "$mnt/boot/firmware/config.txt"
if [ "$SERIAL_AUTOLOGIN" = yes ]; then
	install -D -m 644 "$TOP/files/serial-autologin.conf" \
		"$mnt/etc/systemd/system/serial-getty@.service.d/autologin.conf"
fi

cat > "$mnt/etc/lustre-clusterhat-release" <<E
LUSTRE=$lver
LUSTRE_REF=$LUSTRE_REF
E2FSPROGS=$E2FS_TAG
NODE_KERNEL=$krel
CLIENT_KERNEL=$(cat "$PKGS/client/KERNEL_RELEASE")
BASE_IMAGE=${CTRL_IMAGE_URL##*/}
BUILT=$(date -u +%Y-%m-%dT%H:%MZ)
E

chroot_restore "$mnt"
slim_root "$mnt"
df -h "$mnt" | tail -1
# hand freed blocks back so they compress to nothing
fstrim "$mnt" 2>/dev/null || true
cleanup

if [ "$COMPRESS" = yes ]; then
	log "compressing"
	xz -T0 -$XZ_LEVEL "$img"
	img=$img.xz
fi
(cd "$OUT" && sha256sum "${img##*/}" > "${img##*/}.sha256")
ls -lh "$img" "$img.sha256"
