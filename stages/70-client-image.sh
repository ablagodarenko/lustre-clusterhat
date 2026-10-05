#!/bin/bash
# Root image, kernel and initrd shared by the client VMs.

. "$(dirname "$(readlink -f "$0")")/../lib.sh"

krel=$(cat "$PKGS/client/KERNEL_RELEASE") || die "client packages missing"
R=$WORK/vm-rootfs

rm -rf "$R" "$VMOUT"
mkdir -p "$VMOUT"
debootstrap --variant=minbase \
	--include=systemd-sysv,udev,kmod,iproute2,iputils-ping,openssh-server,ca-certificates,procps,less,iperf3,libreadline8,libyaml-0-2,libnl-3-200,libnl-genl-3-200,libkeyutils1,libjson-c5,libmount1,libssl3,linux-image-$krel \
	"$DEBIAN_SUITE" "$R" "$DEBIAN_MIRROR"

chroot_open "$R"
chroot_bind "$R" "$PKGS" mnt/pkgs
in_root "$R" apt-get install -y --no-install-recommends \
	$(cd "$PKGS" && ls client/lustre-client-modules-${krel}_*.deb \
		client/lustre-client-utils_*.deb | sed 's|^|/mnt/pkgs/|')
in_root "$R" depmod -a $krel
in_root "$R" apt-get clean

# The image is shared: each VM takes its identity from "rpi.client=N" on
# the kernel command line.
cat > "$R/usr/local/sbin/rpi-client-id" <<E
#!/bin/sh
n=\$(sed -n 's/.*rpi\.client=\([0-9]*\).*/\1/p' /proc/cmdline)
[ -n "\$n" ] || exit 0
hostname client\$n
ip link set eth0 up
ip addr add $NODE_NET.\$(($VM_IPBASE + n))/24 dev eth0
E
chmod 755 "$R/usr/local/sbin/rpi-client-id"
cat > "$R/etc/systemd/system/rpi-client-id.service" <<E
[Unit]
Description=Per-VM hostname and address from the kernel command line
Before=network.target ssh.service
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rpi-client-id

[Install]
WantedBy=multi-user.target
E
in_root "$R" systemctl enable rpi-client-id.service

echo "options lnet networks=tcp(eth0)" > "$R/etc/modprobe.d/lustre.conf"
echo "/dev/vda / ext4 defaults 0 1" > "$R/etc/fstab"
mkdir -p "$R$CLIENT_MNT"

chroot_close "$R"
rmdir "$R/mnt/pkgs" 2>/dev/null || true

cp "$R/boot/vmlinuz-$krel" "$VMOUT/vmlinuz"
cp "$R/boot/initrd.img-$krel" "$VMOUT/initrd.img"
mke2fs -q -t ext4 -L rpiclient -d "$R" "$VMOUT/base.img" "$VM_DISK"
ls -l "$VMOUT"
