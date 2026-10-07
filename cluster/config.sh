# Settings for the lustre-cluster commands on the controller.
# Override any of them in /etc/lustre-clusterhat.conf.

[ ! -f /etc/lustre-clusterhat.conf ] || . /etc/lustre-clusterhat.conf

STATE=${STATE:-/var/lib/lustre-clusterhat}
# template root filesystem of the server nodes, copied to each node's
# NFS root by "lustre-cluster nodes deploy"
NODE_TEMPLATE=${NODE_TEMPLATE:-$STATE/node-rootfs}
NFSROOT=${NFSROOT:-/var/lib/clusterctrl/nfs}
NODES=${NODES:-"1 2 3 4"}
# address of node pN on the controller-internal network is NODE_NET.N
NODE_NET=${NODE_NET:-172.19.180}

# Where "lustre-cluster update" gets newer scripts from
UPDATE_REPO=${UPDATE_REPO:-https://github.com/ablagodarenko/lustre-clusterhat.git}
UPDATE_REF=${UPDATE_REF:-main}

# Client VMs: Debian arm64 guests under KVM on the controller
VMDIR=${VMDIR:-$STATE/vm}
NCLIENTS=${NCLIENTS:-8}
VM_MEM=${VM_MEM:-512}
VM_CPUS=${VM_CPUS:-1}
# clients sit on the same bridge as the nodes: client N is NODE_NET.(100+N)
VM_BRIDGE=${VM_BRIDGE:-brint}
VM_IPBASE=${VM_IPBASE:-100}

# Nodes and client VMs are re-imaged at will and only reachable on the
# controller-internal bridge, so their host keys are not tracked.  The
# key pair is created on the controller by "lustre-cluster init".
SSH_KEY=${SSH_KEY:-/root/.ssh/lustre-clusterhat}
SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# A Zero's boot ROM shows up with a mass-storage interface.  If the
# controller's usb-storage driver binds to it, rpiboot cannot talk to the
# ROM and the node never boots: tell usb-storage to ignore that device.
rpiboot_quirk() {
	local q=/sys/module/usb_storage/parameters/quirks
	[ -e $q ] && ! grep -q 0a5c:2764 $q &&
		echo 0a5c:2764:i > $q
	return 0
}

node_ssh() {
	local n=$1; shift
	ssh $SSH_OPTS root@$NODE_NET.$n "$@"
}

# Lustre layout.  Nothing is shared between the Zeros, so every target is a
# DRBD device mirrored between the SD cards of a pair of nodes, and either
# node of the pair can serve it.  Normally each node serves "its own"
# targets (active/active); on request, or when a node fails, its partner
# takes them over.
#
#   MDS pair:  MGS + MDT0000 at home on the first node, MDT0001 on the second
#   OSS pair:  OST0000 at home on the first node, OST0001 on the second
FSNAME=${FSNAME:-rpifs}
MDS_NODES=${MDS_NODES:-"1 2"}
OSS_NODES=${OSS_NODES:-"3 4"}
SD_DEV=${SD_DEV:-/dev/mmcblk0}
SWAP_SIZE=${SWAP_SIZE:-1GiB}
MGT_SIZE=${MGT_SIZE:-1GiB}
# each MDS node's card holds both MDTs, each OSS node's card both OSTs
MDT_SIZE=${MDT_SIZE:-8GiB}
OST_SIZE=${OST_SIZE:-50GiB}

# Partition 1 is a small empty FAT filesystem.  The Zero's boot ROM looks
# at the SD card first and only falls back to USB boot if it finds a FAT
# partition without boot files; with no FAT partition at all it hangs and
# the node never comes back after a power cycle.  The ROM is only trusted
# to read an MBR, hence the extended partition on the MDS cards.
GUARD_PART=${SD_DEV}p1
SWAP_PART=${SD_DEV}p2

# name  home-node  partner-node  drbd-minor  partition  drbd-port  kind  index
# Listed in the order targets have to be mounted.
targets() {
	set -- $MDS_NODES $OSS_NODES
	cat <<-E
	mgt  $1 $2 0 ${SD_DEV}p3 7788 mgs 0
	mdt0 $1 $2 1 ${SD_DEV}p5 7789 mdt 0
	mdt1 $2 $1 2 ${SD_DEV}p6 7790 mdt 1
	ost0 $3 $4 0 ${SD_DEV}p3 7791 ost 0
	ost1 $4 $3 1 ${SD_DEV}p4 7792 ost 1
	E
}

# the other node of the pair a node belongs to
partner() {
	set -- $1 $MDS_NODES $OSS_NODES
	case $1 in
	$2) echo $3 ;; $3) echo $2 ;; $4) echo $5 ;; $5) echo $4 ;;
	esac
}

# Disk I/O limit applied by "lustre-cluster throttle on": the band, in
# MB/s, is divided evenly between the OSTs.
THROTTLE_BAND=${THROTTLE_BAND:-20}

LNET_IF=${LNET_IF:-usb0.10}
CLIENT_MNT=${CLIENT_MNT:-/mnt/lustre}
# how long a node may take to unmount its targets before it gets fenced
UMOUNT_TIMEOUT=${UMOUNT_TIMEOUT:-120}
# how long to wait for a node's mirrors to finish resyncing before giving
# up on moving targets to it
SYNC_TIMEOUT=${SYNC_TIMEOUT:-1200}

node_nid() { echo "$NODE_NET.$1@tcp"; }

# "nid1:nid2" as used in a client mount source
mgs_nids() {
	local n out=
	for n in $MDS_NODES; do out=${out:+$out:}$(node_nid $n); done
	echo "$out"
}

vm_ip() { echo "$NODE_NET.$((VM_IPBASE + $1))"; }

vm_ssh() {
	local n=$1; shift
	ssh $SSH_OPTS root@$(vm_ip $n) "$@"
}
