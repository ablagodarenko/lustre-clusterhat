#!/bin/bash
#
# Deploy and control the Lustre servers on the ClusterHAT nodes.
# Runs on the controller, as root, and drives the nodes over ssh.
#
#   servers.sh format         DESTROYS the nodes' SD cards: partition them,
#                             set up DRBD within each pair, mkfs.lustre
#   servers.sh start          mount every target where it is active, or on
#                             its home node
#   servers.sh stop           unmount everything; a node that hangs in
#                             umount is power cycled ("stop poweroff":
#                             left off)
#   servers.sh failover N [hard]
#                             move the targets node N serves to its partner.
#                             If N does not release them in time (or with
#                             "hard") it is powered off first, then rejoins
#   servers.sh failback       move every target back to its home node
#   servers.sh status         where each target is, DRBD state, memory

set -e

. "$(dirname "$(readlink -f "$0")")/config.sh"

D=$(dirname "$(readlink -f "$0")")
cmd=$1 arg1=$2 arg2=$3

# fields of a targets() line
t_field() { targets | awk -v n="$1" -v f="$2" '$1 == n { print $f }'; }
t_home()  { t_field $1 2; }
t_dev()   { echo /dev/drbd$(t_field $1 4); }

# targets a node can serve: all those of its pair
pair_targets() {
	targets | awk -v n="$1" '$2 == n || $3 == n { print $1 }'
}

# common node setup: LNet on the internal network, few service threads
# (the nodes have about 460 MB of RAM), swap on the SD card
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
		mkdir -p $(targets | awk '{ printf "/mnt/%s ", $1 }')
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
		for p in \$(lsblk -lnpo NAME,TYPE,SIZE $SD_DEV | awk '\$2 == \"part\" && \$3 != \"1K\" { print \$1 }'); do
			dd if=/dev/zero of=\$p bs=1M count=8 status=none
		done
		mkfs.vfat -n USBBOOT $GUARD_PART >/dev/null
	"
}

# DRBD configuration of the pair a node belongs to
drbd_conf() {
	targets | awk -v n="$1" -v net="$NODE_NET" '$2 == n || $3 == n {
		printf "resource %s {\n\tnet { protocol C; }\n", $1
		# After its primary dies a mirror resyncs everything the
		# activity log covers: keep that small (about 1 GB) and let
		# the resync use the link, or the pair is without redundancy,
		# and unable to fail over again, for half an hour.
		printf "\tdisk { al-extents 257; resync-rate 15M; c-plan-ahead 0; }\n"
		printf "\tdevice /dev/drbd%s; disk %s; meta-disk internal;\n", $4, $5
		printf "\ton p%s { address %s.%s:%s; }\n", $2, net, $2, $6
		printf "\ton p%s { address %s.%s:%s; }\n}\n", $3, net, $3, $6
	}'
}

# (re)install the DRBD configuration and bring the devices up: a node
# loses the configuration when its root is redeployed, the data on the SD
# card is still there
drbd_up() {
	drbd_conf $1 | node_ssh $1 "cat > /etc/drbd.d/lustre.res"
	node_ssh $1 "
		modprobe drbd
		if drbdadm status >/dev/null 2>&1; then drbdadm adjust all; else drbdadm up all; fi
	"
}

# node a target is active on (DRBD primary), if any
t_where() {
	local n
	for n in $(t_home $1) $(partner $(t_home $1)); do
		node_ssh $n "drbdadm role $1 2>/dev/null" 2>/dev/null | grep -q '^Primary' &&
			{ echo $n; return; }
	done
	return 1
}

# targets active on a node
active_on() {
	local t
	for t in $(pair_targets $1); do
		[ "$(t_where $t)" = "$1" ] && echo $t
	done
	return 0
}

t_mount() {	# t_mount <node> <target...>, in the order given
	local n=$1 t; shift
	for t in "$@"; do
		echo "=== p$n: mount $t"
		node_ssh $n "
			set -e
			mountpoint -q /mnt/$t && exit 0
			drbdadm primary $t
			mount -t lustre $(t_dev $t) /mnt/$t
		" || { echo "p$n: could not mount $t"; return 1; }
	done
}

# Does a node hold a complete, current copy of every target of its pair?
# Only then may it take them over, and only then may its partner be fenced.
has_good_copies() {
	node_ssh $1 "
		for t in $(pair_targets $1 | tr '\n' ' '); do
			[ \"\$(drbdadm dstate \$t 2>/dev/null | cut -d/ -f1)\" = UpToDate ] || exit 1
		done
	" 2>/dev/null
}

# Wait for a node's copies to finish resyncing (after it was fenced, say)
wait_sync() {
	local n=$1 waited=0
	until has_good_copies $n; do
		node_ssh $n true 2>/dev/null || { echo "p$n is unreachable"; return 1; }
		[ $waited -lt $SYNC_TIMEOUT ] || { echo "p$n is still resyncing"; return 1; }
		[ $((waited % 60)) -ne 0 ] || echo "waiting for p$n to finish resyncing"
		sleep 10
		waited=$((waited + 10))
	done
}

# Unmount targets on a node and give up the DRBD primary role, last
# mounted first.  Fails if the node cannot be reached or does not finish
# in time, in which case the caller has to fence it.  The time limit is
# enforced here, on the controller: a stuck umount on the node sleeps
# uninterruptibly and cannot be timed out or killed there.
t_umount() {	# t_umount <node> <target...>
	local n=$1 t rev=; shift
	for t in "$@"; do rev="$t $rev"; done
	[ -n "$rev" ] || return 0
	timeout -k 5 $UMOUNT_TIMEOUT ssh $SSH_OPTS root@$NODE_NET.$n "
		for t in $rev; do
			if mountpoint -q /mnt/\$t; then umount /mnt/\$t || exit 1; fi
			drbdadm role \$t >/dev/null 2>&1 || continue
			drbdadm secondary \$t || exit 1
		done
	" </dev/null
}

# Power a node off so it cannot write to the mirrored devices any more
fence() {
	echo "=== p$1: fencing (power off)"
	clusterctrl off p$1
	sleep 5
}

# Power a fenced node back on and let it rejoin DRBD as secondary.  A Zero
# sometimes fails to show up on USB after a power cycle: try again.
unfence() {
	local try attempt
	echo "=== p$1: power on, rejoin DRBD"
	rpiboot_quirk
	for attempt in 1 2 3; do
		clusterctrl on p$1
		for try in $(seq 30); do
			if node_ssh $1 true 2>/dev/null; then
				node_common $1
				drbd_up $1
				return
			fi
			sleep 5
		done
		echo "p$1 did not come up, power cycling it again"
		clusterctrl off p$1
		sleep 5
	done
	echo "p$1 DID NOT COME BACK: its partner now runs without a mirror"
	return 1
}

# Move targets off a node to its partner.  Cleanly if the node lets go of
# them in time; otherwise, or with "hard", the node is fenced.  Nothing is
# touched unless the partner is up and holds complete copies.
#
# What happens after a fence depends on the goal:
#   failover  everything the node was serving goes to the partner
#   failback  the partner gets only what is at home there, and the node,
#             once it is back and resynced, mounts what is at home on it.
#             So one power cycle puts every target of the pair at home,
#             where moving them one way and then the other could bounce
#             between the two nodes for as long as unmounts keep hanging.
# Returns 0 after a clean move, 1 if the node had to be fenced, 2 if
# nothing could be done or a target could not be brought up.
evacuate() {	# evacuate <failover|failback> <node> <hard|soft> <target...>
	local goal=$1 from=$2 how=$3 to fenced= t list= mine= rc=0; shift 3
	to=$(partner $from)

	if ! node_ssh $to true 2>/dev/null; then
		echo "p$to is unreachable: not touching p$from"
		return 2
	fi
	if ! wait_sync $to; then
		echo "p$to has no complete copy: not touching p$from"
		return 2
	fi

	if [ $how = hard ] || ! t_umount $from "$@"; then
		fence $from
		fenced=yes
		# of what is not already running on the partner
		for t in $(pair_targets $from); do
			[ "$(t_where $t)" = "$to" ] && continue
			if [ $goal = failback ] && [ "$(t_home $t)" = "$from" ]; then
				mine="$mine $t"
			else
				list="$list $t"
			fi
		done
		set -- $list
	fi
	t_mount $to "$@" || rc=2
	if [ -n "$fenced" ]; then
		if unfence $from; then
			if [ -n "$mine" ]; then
				wait_sync $from && t_mount $from $mine || rc=2
			fi
		else
			# the node is gone: its own targets need a home too
			[ -z "$mine" ] || t_mount $to $mine || true
			rc=2
		fi
		[ $rc -ne 0 ] || rc=1
	fi
	return $rc
}

do_format() {
	local n t home dev kind idx mgsnodes= svc pair

	for n in $MDS_NODES; do mgsnodes="$mgsnodes --mgsnode=$(node_nid $n)"; done

	do_stop || true
	for n in $MDS_NODES; do
		echo "=== p$n: partition for MGT and two MDTs"
		node_ssh $n "drbdadm down all 2>/dev/null; true"
		partition $n ",64MiB,c" ",$SWAP_SIZE,82" ",$MGT_SIZE,83" ",,E" \
			",$MDT_SIZE,83" ",$MDT_SIZE,83"
	done
	for n in $OSS_NODES; do
		echo "=== p$n: partition for two OSTs"
		node_ssh $n "drbdadm down all 2>/dev/null; true"
		partition $n ",64MiB,c" ",$SWAP_SIZE,82" ",$OST_SIZE,83" ",$OST_SIZE,83"
	done
	for n in $MDS_NODES $OSS_NODES; do
		node_common $n
		drbd_conf $n | node_ssh $n "cat > /etc/drbd.d/lustre.res"
		node_ssh $n "drbdadm create-md --force all && modprobe drbd && drbdadm up all"
	done

	targets | while read t home pair minor part port kind idx; do
		echo "=== p$home: DRBD primary and mkfs $t"
		svc="--servicenode=$(node_nid $home) --servicenode=$(node_nid $pair)"
		case $kind in
		mgs) kind="--mgs" ;;
		mdt) kind="--mdt --fsname=$FSNAME --index=$idx $mgsnodes" ;;
		ost) kind="--ost --fsname=$FSNAME --index=$idx $mgsnodes" ;;
		esac
		# both halves are freshly created: skip the initial full resync
		node_ssh $home "
			set -e
			for try in \$(seq 30); do
				drbdadm cstate $t | grep -q Connected && break
				sleep 2
			done
			drbdadm -- --clear-bitmap new-current-uuid $t
			drbdadm primary $t
			mkfs.lustre --reformat $kind $svc --backfstype=ldiskfs /dev/drbd$minor
		" </dev/null
	done
}

do_start() {
	local n t where

	for n in $MDS_NODES $OSS_NODES; do
		node_common $n
		drbd_up $n
	done
	for t in $(targets | awk '{ print $1 }'); do
		if where=$(t_where $t); then
			t_mount $where $t
		else
			# at home if home has a good copy, else on the partner
			where=$(t_home $t)
			t_mount $where $t || t_mount $(partner $where) $t
		fi
	done
	"$D/throttle.sh" reapply
}

# stop [poweroff]: a node that hangs in umount is no use until it is
# power cycled; with "poweroff" it is just left off
do_stop() {
	local n
	for n in $OSS_NODES $MDS_NODES; do
		node_ssh $n true 2>/dev/null || continue
		t_umount $n $(node_ssh $n "ls /mnt" | grep -x -F "$(pair_targets $n)") &&
			continue
		echo "p$n: targets did not unmount in time"
		fence $n
		[ "$1" = poweroff ] || unfence $n || true
	done
}

do_failover() {
	local from=${1#p} how=${2:-soft} list rc

	[ -n "$(partner "$from")" ] || { echo "usage: $0 failover N [hard]"; exit 1; }
	if node_ssh $from true 2>/dev/null; then
		list=$(active_on $from)
	else
		how=hard
	fi
	[ $how = hard ] || [ -n "$list" ] || { echo "p$from serves nothing"; return; }
	echo "=== p$from -> p$(partner $from): ${list:-everything}"
	rc=0
	evacuate failover $from $how $list || rc=$?
	"$D/throttle.sh" reapply
	[ $rc -ne 2 ] || { echo "failover of p$from failed, see status"; exit 1; }
}

do_failback() {
	local n list t rc away=

	for n in $MDS_NODES $OSS_NODES; do
		list=
		for t in $(active_on $n); do
			[ "$(t_home $t)" = "$n" ] || list="$list $t"
		done
		[ -n "$list" ] || continue
		echo "=== p$n -> p$(partner $n):$list"
		rc=0
		evacuate failback $n soft $list || rc=$?
		[ $rc -ne 2 ] || away=yes
	done
	"$D/throttle.sh" reapply
	[ -z "$away" ] || { echo "failback incomplete, see status"; exit 1; }
}

do_status() {
	local n t where

	printf '%-6s %-6s %-6s %s\n' target home active state
	for t in $(targets | awk '{ print $1 }'); do
		if where=$(t_where $t); then
			printf '%-6s %-6s %-6s %s\n' $t p$(t_home $t) p$where \
				"$(node_ssh $where "mountpoint -q /mnt/$t && echo mounted || echo 'not mounted'; \
					drbdadm dstate $t; drbdadm cstate $t" | tr '\n' ' ')"
		else
			printf '%-6s %-6s %-6s\n' $t p$(t_home $t) -
		fi
	done
	for n in $MDS_NODES $OSS_NODES; do
		printf 'p%s: %s\n' $n "$(node_ssh $n "free -m | awk 'NR==2 { print \$3 \"/\" \$2 \" MB used\" }'" 2>/dev/null ||
			echo unreachable)"
	done
}

case "$cmd" in
format)   do_format ;;
start)    do_start ;;
stop)     do_stop "$arg1" ;;
failover) do_failover "$arg1" "$arg2" ;;
failback) do_failback ;;
status)   do_status ;;
*)        sed -n '3,20p' "$0"; exit 1 ;;
esac
