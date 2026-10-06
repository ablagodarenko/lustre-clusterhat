#!/bin/bash
#
# Lustre client VMs on the controller: Debian arm64 guests under KVM,
# attached to the bridge the server nodes are on.
#
#   clients.sh start [N..]  start client VMs (default: 1..$NCLIENTS)
#   clients.sh mount [N..]  mount the filesystem in the VMs
#   clients.sh umount [N..] unmount it
#   clients.sh stop [N..]   shut the VMs down
#   clients.sh status       list VMs and their Lustre mounts

set -e

. "$(dirname "$(readlink -f "$0")")/config.sh"

BASE=$VMDIR/base.img

all_clients() { seq 1 $NCLIENTS; }

vm_running() {
	[ -e "$VMDIR/client$1.pid" ] &&
		kill -0 "$(cat "$VMDIR/client$1.pid")" 2>/dev/null
}

do_start() {
	local n tap

	[ -e "$BASE" ] || { echo "no client image at $BASE"; exit 1; }
	modprobe -a tun vhost_net 2>/dev/null || true
	for n in "$@"; do
		vm_running $n && { echo "client$n already running"; continue; }
		tap=lc$n
		ip link del $tap 2>/dev/null || true
		ip tuntap add dev $tap mode tap
		ip link set $tap master $VM_BRIDGE up
		rm -f "$VMDIR/client$n.qcow2"
		qemu-img create -q -f qcow2 -b "$BASE" -F raw "$VMDIR/client$n.qcow2"
		: > "$VMDIR/client$n.log"	# console log, readable without sudo
		qemu-system-aarch64 -name client$n \
			-M virt -enable-kvm -cpu host -smp $VM_CPUS -m $VM_MEM \
			-kernel "$VMDIR/vmlinuz" -initrd "$VMDIR/initrd.img" \
			-append "root=/dev/vda rw console=ttyAMA0 net.ifnames=0 rpi.client=$n" \
			-drive if=virtio,format=qcow2,file="$VMDIR/client$n.qcow2" \
			-netdev tap,id=n0,ifname=$tap,script=no,downscript=no \
			-device virtio-net-pci,netdev=n0,romfile=,mac=$(printf '52:54:00:4c:55:%02x' $n) \
			-display none -serial file:"$VMDIR/client$n.log" \
			-daemonize -pidfile "$VMDIR/client$n.pid"
		echo "client$n started ($(vm_ip $n))"
	done
	ip link set $VM_BRIDGE up

	for n in "$@"; do
		for try in $(seq 30); do
			vm_ssh $n true 2>/dev/null && break
			sleep 5
		done
	done
}

do_mount() {
	local n
	for n in "$@"; do
		vm_ssh $n "
			modprobe lustre &&
			{ mountpoint -q $CLIENT_MNT ||
			  mount -t lustre $(mgs_nids):/$FSNAME $CLIENT_MNT; } &&
			echo \"\$(hostname): \$(df -h --output=size,used,target $CLIENT_MNT | tail -1)\"
		" || echo "client$n: mount failed"
	done
}

do_umount() {
	local n
	for n in "$@"; do
		vm_ssh $n "umount $CLIENT_MNT 2>/dev/null; true" || true
	done
}

do_stop() {
	local n
	for n in "$@"; do
		vm_running $n || continue
		vm_ssh $n "umount $CLIENT_MNT 2>/dev/null; poweroff" 2>/dev/null || true
	done
	for n in "$@"; do
		for try in $(seq 20); do vm_running $n || break; sleep 2; done
		vm_running $n && kill "$(cat "$VMDIR/client$n.pid")"
		ip link del lc$n 2>/dev/null || true
		rm -f "$VMDIR/client$n.pid"
	done
}

do_status() {
	local n
	for n in $(all_clients); do
		if vm_running $n; then
			echo "client$n $(vm_ip $n): $(vm_ssh $n \
				"mount -t lustre | awk '{print \$1 \" on \" \$3}'" 2>/dev/null ||
				echo 'no ssh')"
		else
			echo "client$n: stopped"
		fi
	done
}

cmd=$1; shift || true
case "$cmd" in
start)  do_start ${@:-$(all_clients)} ;;
mount)  do_mount ${@:-$(all_clients)}
        "$(dirname "$(readlink -f "$0")")/throttle.sh" reapply >/dev/null ;;
umount) do_umount ${@:-$(all_clients)} ;;
stop)   do_stop ${@:-$(all_clients)} ;;
status) do_status ;;
*)      sed -n '3,11p' "$0"; exit 1 ;;
esac
