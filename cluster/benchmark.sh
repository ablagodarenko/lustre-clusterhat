#!/bin/bash
#
# Benchmarks for the ClusterHAT Lustre cluster.  Runs on the controller.
#
#   benchmark.sh disk   raw SD card throughput on every node: direct I/O
#                       on the swap partition, so no target is touched
#   benchmark.sh net    client VM <-> server node bandwidth: TCP (iperf3,
#                       if installed on both ends) and LNet selftest
#   benchmark.sh io     Lustre write and read throughput with 1, 2, ...
#                       $NCLIENTS clients, one file per client
#   benchmark.sh all    all of the above
#
# BENCH_MB sets the amount of data per node (disk) or per client (io).
# BENCH_UNSTABLE_CHECK=0|1 sets llite.*.unstable_stats on the clients for
# the io test.  With the default (1) a client counts pages the server has
# not committed yet against the kernel's dirty limit; on these small VMs
# that throttles each client to a few MB/s.

set -e

. "$(dirname "$(readlink -f "$0")")/config.sh"

BENCH_MB=${BENCH_MB:-256}
BENCH_DIR=$CLIENT_MNT/benchmark
LST_SECS=${LST_SECS:-20}
# Nodes to run LNet selftest against.  lnet_selftest needs a lot of memory
# for its bulk buffers: on a node that is serving targets the module can
# fail to load (and has been seen to oops in its error path), so by
# default only the standby MDS node, which is idle, is used.
LST_NODES=${LST_NODES:-${MDS_NODES%% *}}

mbps() { awk -v mb="$1" -v s="$2" 'BEGIN { printf "%.1f", mb / s }'; }
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'; }

# "... copied, 12.3 s, 20.8 MB/s" -> seconds
dd_secs() { sed -n 's/.* copied, \([0-9.]*\) s.*/\1/p'; }

do_disk() {
	local n w r
	printf '%-6s %-10s %12s %12s\n' node card write_MB/s read_MB/s
	for n in $MDS_NODES $OSS_NODES; do
		w=$(node_ssh $n "
			swapoff $SWAP_PART 2>/dev/null
			dd if=/dev/zero of=$SWAP_PART bs=1M count=$BENCH_MB \
				oflag=direct conv=fsync 2>&1" | dd_secs)
		r=$(node_ssh $n "
			dd if=$SWAP_PART of=/dev/null bs=1M count=$BENCH_MB \
				iflag=direct 2>&1" | dd_secs)
		printf '%-6s %-10s %12s %12s\n' p$n \
			"$(node_ssh $n "cat /sys/block/${SD_DEV##*/}/device/name")" \
			$(mbps $BENCH_MB $w) $(mbps $BENCH_MB $r)
		node_ssh $n "mkswap -q $SWAP_PART && swapon $SWAP_PART"
	done
}

# LNet selftest bulk test between one client and one server, run from
# the client.  $3 is "write" (client to server) or "read".
lst_brw() {
	local c=$1 n=$2 dir=$3
	vm_ssh $c "
		export LST_SESSION=\$\$
		lst new_session bench >/dev/null
		lst add_group c $(vm_ip $c)@tcp >/dev/null
		lst add_group s $(node_nid $n) >/dev/null
		lst add_batch b >/dev/null
		lst add_test --batch b --concurrency 4 --from c --to s \
			brw $dir size=1M >/dev/null
		lst run b >/dev/null
		lst stat --bw --mbs --delay $LST_SECS --count 1 s 2>&1
		lst end_session >/dev/null
	" | awk -v d=$dir '
		# the server receives on a write test and sends on a read test
		/\[R\]/ && d == "write" { print $3 }
		/\[W\]/ && d == "read"  { print $3 }' | tail -1
}

do_net() {
	local c=1 n tx rx lw lr

	for n in $LST_NODES; do
		node_ssh $n "modprobe lnet_selftest"
	done
	vm_ssh $c "modprobe lnet_selftest"

	printf '%-6s %14s %14s %14s %14s\n' node tcp_to_MB/s tcp_from_MB/s \
		lnet_to_MB/s lnet_from_MB/s
	for n in $MDS_NODES $OSS_NODES; do
		tx=-; rx=-
		if vm_ssh $c "command -v iperf3" >/dev/null &&
		   node_ssh $n "command -v iperf3" >/dev/null; then
			node_ssh $n "pkill iperf3; iperf3 -s -D -1"
			sleep 1
			tx=$(vm_ssh $c "iperf3 -c $NODE_NET.$n -t 10 -f M" |
			     awk '/receiver/ { print $(NF-2) }')
			node_ssh $n "pkill iperf3; iperf3 -s -D -1"
			sleep 1
			rx=$(vm_ssh $c "iperf3 -c $NODE_NET.$n -t 10 -f M -R" |
			     awk '/receiver/ { print $(NF-2) }')
		fi
		lw=-; lr=-
		case " $LST_NODES " in *" $n "*)
			lw=$(lst_brw $c $n write); lr=$(lst_brw $c $n read) ;;
		esac
		printf '%-6s %14s %14s %14s %14s\n' p$n $tx $rx $lw $lr
	done
}

drop_caches() {
	local n
	for n in "$@"; do vm_ssh $n "sync; echo 3 > /proc/sys/vm/drop_caches"; done
	for n in $OSS_NODES; do node_ssh $n "sync; echo 3 > /proc/sys/vm/drop_caches"; done
}

# run one dd per client at the same time, print the wall-clock seconds
parallel_dd() {
	local args=$1 t0 n; shift
	t0=$(now)
	for n in "$@"; do
		vm_ssh $n "dd ${args//%N/$n} bs=1M 2>/dev/null" &
	done
	wait
	elapsed $t0
}

do_io() {
	local count clients s w r

	if [ -n "$BENCH_UNSTABLE_CHECK" ]; then
		for count in $(seq 1 $NCLIENTS); do
			vm_ssh $count "lctl set_param -n \
				llite.*.unstable_stats=$BENCH_UNSTABLE_CHECK"
		done
	fi
	vm_ssh 1 "mkdir -p $BENCH_DIR"
	printf '%-8s %10s %14s %14s\n' clients MB_each write_MB/s read_MB/s
	for count in $(seq 1 $NCLIENTS); do
		clients=$(seq 1 $count)
		drop_caches $clients
		s=$(parallel_dd "if=/dev/zero of=$BENCH_DIR/f%N count=$BENCH_MB conv=fsync" $clients)
		w=$(mbps $((count * BENCH_MB)) $s)
		drop_caches $clients
		s=$(parallel_dd "if=$BENCH_DIR/f%N of=/dev/null" $clients)
		r=$(mbps $((count * BENCH_MB)) $s)
		printf '%-8s %10s %14s %14s\n' $count $BENCH_MB $w $r
		vm_ssh 1 "rm -f $BENCH_DIR/f*"
	done
	vm_ssh 1 "rmdir $BENCH_DIR"
}

case "$1" in
disk) do_disk ;;
net)  do_net ;;
io)   do_io ;;
all)  do_disk; echo; do_net; echo; do_io ;;
*)    sed -n '3,19p' "$0"; exit 1 ;;
esac
