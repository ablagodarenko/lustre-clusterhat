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

# Lustre layout.  The MGT and MDT live on DRBD devices mirrored between the
# SD cards of the two MDS nodes, so either node can serve them (failover).
# Each OSS node serves one OST from its own SD card.
FSNAME=${FSNAME:-rpifs}
MDS_NODES=${MDS_NODES:-"1 2"}
OSS_NODES=${OSS_NODES:-"3 4"}
SD_DEV=${SD_DEV:-/dev/mmcblk0}
SWAP_SIZE=${SWAP_SIZE:-1GiB}
MGT_SIZE=${MGT_SIZE:-1GiB}
MDT_SIZE=${MDT_SIZE:-16GiB}

# Partition 1 is a small empty FAT filesystem.  The Zero's boot ROM looks
# at the SD card first and only falls back to USB boot if it finds a FAT
# partition without boot files; with no FAT partition at all it hangs and
# the node never comes back after a power cycle.
GUARD_PART=${SD_DEV}p1
SWAP_PART=${SD_DEV}p2
MGT_PART=${SD_DEV}p3
MDT_PART=${SD_DEV}p4
OST_PART=${SD_DEV}p3

LNET_IF=${LNET_IF:-usb0.10}
CLIENT_MNT=${CLIENT_MNT:-/mnt/lustre}
# how long an MDS node may take to unmount MGT and MDT before it gets fenced
UMOUNT_TIMEOUT=${UMOUNT_TIMEOUT:-120}

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
