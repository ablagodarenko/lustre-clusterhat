#!/bin/bash
#
# Deploy and control the Lustre servers on the ClusterHAT nodes.
# Runs on the controller, as root, and drives the nodes over ssh.
#
#   servers.sh format    DESTROYS the nodes' SD cards: partition them, set
#                        up DRBD between the MDS nodes, mkfs.lustre
#   servers.sh start     mount MGT+MDT on the first MDS node (or on the
#                        node that is DRBD primary), then the OSTs
#   servers.sh stop      unmount everything
#   servers.sh failover [hard]
#                        move MGT+MDT to the other MDS node; if the active
#                        node does not release them in time (or with
#                        "hard") it is powered off first, then rejoined
#   servers.sh status    show DRBD roles and mounted targets

set -e

. "$(dirname "$(readlink -f "$0")")/config.sh"

cmd=$1
set -- $MDS_NODES; MDS1=$1; MDS2=$2
MGT_DEV=/dev/drbd0
MDT_DEV=/dev/drbd1

# common node setup: LNet on the internal network, few service threads
# (the nodes have about 420 MB of RAM), swap on the SD card
node_common() {
	local n=$1
	node_ssh $n "
		set -e
		cat > /etc/modprobe.d/lustre.conf <<-E
		options lnet networks=tcp($LNET_IF)
		options libcfs cpu_npartitions=1
		options mdt mds_num_threads=4
		options ost oss_num_threads=4
		options ptlrpc ldlm_num_threads=2
		E
		swapon --show=NAME --noheadings | grep -q $SWAP_PART ||
			{ mkswap -q $SWAP_PART; swapon $SWAP_PART; }
		mkdir -p /mnt/mgt /mnt/mdt /mnt/ost
	"
}

partition() {
	local n=$1; shift
	node_ssh $n "
		set -e
		swapoff -a
		for p in ${SD_DEV}p?; do [ -b \$p ] && wipefs -qa \$p; done
		wipefs -qa $SD_DEV
		printf '%s\n' 'label: dos' $* | sfdisk -q --wipe always $SD_DEV
		partprobe $SD_DEV 2>/dev/null || true
		sleep 2
		for p in ${SD_DEV}p?; do dd if=/dev/zero of=\$p bs=1M count=8 status=none; done
		mkfs.vfat -n USBBOOT $GUARD_PART >/dev/null
	"
}

drbd_conf() {
	cat <<-E
	resource mgt {
		net { protocol C; }
		device $MGT_DEV; disk $MGT_PART; meta-disk internal;
		on p$MDS1 { address $NODE_NET.$MDS1:7788; }
		on p$MDS2 { address $NODE_NET.$MDS2:7788; }
	}
	resource mdt {
		net { protocol C; }
		device $MDT_DEV; disk $MDT_PART; meta-disk internal;
		on p$MDS1 { address $NODE_NET.$MDS1:7789; }
		on p$MDS2 { address $NODE_NET.$MDS2:7789; }
	}
	E
}

# (re)install the DRBD configuration: a node loses it when its root is
# redeployed, the data on the SD card is still there
drbd_setup() {
	drbd_conf | node_ssh $1 "cat > /etc/drbd.d/lustre.res"
}

drbd_up() {
	drbd_setup $1
	node_ssh $1 "modprobe drbd && { drbdadm status >/dev/null 2>&1 || drbdadm up all; }"
}

# which MDS node holds the DRBD primary role, if any
mds_active() {
	local n
	for n in $MDS_NODES; do
		node_ssh $n "drbdadm role mdt 2>/dev/null" | grep -q '^Primary' &&
			{ echo $n; return; }
	done
	return 1
}

mds_mount() {
	node_ssh $1 "
		set -e
		modprobe drbd
		drbdadm status >/dev/null 2>&1 || drbdadm up all
		drbdadm primary all
		mount -t lustre $MGT_DEV /mnt/mgt
		mount -t lustre $MDT_DEV /mnt/mdt
	"
}

# Give up MGT+MDT on a node.  Fails if the node cannot be reached or does
# not finish in time, in which case the caller has to fence it.
mds_umount() {
	node_ssh $1 "
		for m in /mnt/mdt /mnt/mgt; do
			mountpoint -q \$m || continue
			timeout $UMOUNT_TIMEOUT umount \$m || exit 1
		done
		drbdadm status >/dev/null 2>&1 || exit 0
		drbdadm secondary all
	"
}

# Power a node off so it cannot write to the shared (DRBD) devices any more
fence() {
	echo "=== p$1: fencing (power off)"
	clusterctrl off p$1
	sleep 5
}

# Power a fenced node back on and let it rejoin DRBD as secondary
unfence() {
	local try
	echo "=== p$1: power on, rejoin DRBD"
	rpiboot_quirk
	clusterctrl on p$1
	for try in $(seq 60); do
		node_ssh $1 true 2>/dev/null && break
		sleep 5
	done
	node_common $1
	drbd_up $1
}

do_format() {
	local n i servicenodes= mgsnodes=

	for n in $MDS_NODES; do
		servicenodes="$servicenodes --servicenode=$(node_nid $n)"
		mgsnodes="$mgsnodes --mgsnode=$(node_nid $n)"
	done

	do_stop || true
	for n in $MDS_NODES; do
		echo "=== p$n: partition for MGT/MDT"
		node_ssh $n "drbdadm down all 2>/dev/null; true"
		partition $n ",64MiB,c" ",$SWAP_SIZE,82" ",$MGT_SIZE,83" ",$MDT_SIZE,83"
		node_common $n
		drbd_setup $n
		node_ssh $n "drbdadm create-md --force all && modprobe drbd && drbdadm up all"
	done
	for n in $OSS_NODES; do
		echo "=== p$n: partition for OST"
		partition $n ",64MiB,c" ",$SWAP_SIZE,82" ",,83"
		node_common $n
	done

	echo "=== p$MDS1: DRBD initial state"
	# both halves are freshly zeroed: skip the initial full resync
	node_ssh $MDS1 "
		set -e
		for r in mgt mdt; do
			for t in \$(seq 30); do
				drbdadm cstate \$r | grep -q Connected && break
				sleep 2
			done
			drbdadm -- --clear-bitmap new-current-uuid \$r
		done
		drbdadm primary all
	"

	echo "=== p$MDS1: mkfs MGT, MDT"
	node_ssh $MDS1 "
		set -e
		mkfs.lustre --reformat --mgs $servicenodes \
			--backfstype=ldiskfs $MGT_DEV
		mkfs.lustre --reformat --mdt --fsname=$FSNAME --index=0 \
			$mgsnodes $servicenodes --backfstype=ldiskfs $MDT_DEV
	"
	i=0
	for n in $OSS_NODES; do
		echo "=== p$n: mkfs OST$i"
		node_ssh $n "mkfs.lustre --reformat --ost --fsname=$FSNAME \
			--index=$i $mgsnodes --backfstype=ldiskfs $OST_PART"
		i=$((i + 1))
	done
}

do_start() {
	local n active

	for n in $MDS_NODES $OSS_NODES; do node_common $n; done
	for n in $MDS_NODES; do drbd_up $n; done
	active=$(mds_active) || active=$MDS1
	echo "=== p$active: mount MGT, MDT"
	mds_mount $active
	for n in $OSS_NODES; do
		echo "=== p$n: mount OST"
		node_ssh $n "mount -t lustre $OST_PART /mnt/ost"
	done
}

do_stop() {
	local n
	for n in $OSS_NODES; do node_ssh $n "umount /mnt/ost 2>/dev/null; true"; done
	for n in $MDS_NODES; do
		mds_umount $n || echo "p$n: MGT/MDT did not unmount cleanly"
	done
}

# failover [hard]: "hard" skips the clean unmount and powers the active
# node off, as if it had crashed
do_failover() {
	local from to n fenced=

	# the active node is the one that is not a healthy DRBD secondary
	if ! from=$(mds_active); then
		for n in $MDS_NODES; do
			node_ssh $n true 2>/dev/null || from=$n
		done
	fi
	[ -n "$from" ] || { echo "no active MDS node found"; exit 1; }
	[ "$from" = "$MDS1" ] && to=$MDS2 || to=$MDS1
	echo "=== MGT+MDT: p$from -> p$to"

	if [ "$1" = hard ] || ! mds_umount $from; then
		fence $from
		fenced=yes
	fi
	mds_mount $to
	[ -z "$fenced" ] || unfence $from
}

do_status() {
	local n
	for n in $MDS_NODES $OSS_NODES; do
		echo "=== p$n"
		node_ssh $n "
			drbdadm status 2>/dev/null | grep -E '^[a-z]|disk:|peer' | sed 's/^/  /'
			mount -t lustre | awk '{print \"  \" \$1 \" on \" \$3}'
			free -m | awk 'NR==2 {print \"  mem: \" \$3 \"/\" \$2 \" MB used\"}'
		" || echo "  unreachable"
	done
}

case "$cmd" in
format)   do_format ;;
start)    do_start ;;
stop)     do_stop ;;
failover) do_failover "$2" ;;
status)   do_status ;;
*)        sed -n '3,18p' "$0"; exit 1 ;;
esac
