#!/bin/bash
#
# Limit the disk I/O of the OSTs, to see how Lustre behaves when the
# storage, not the network, is the bottleneck.  A band of B MB/s is divided
# evenly between the OSTs: each one may read B/N and write B/N MB/s.
#
#   throttle.sh on [B]    turn the limit on (default: $THROTTLE_BAND MB/s)
#   throttle.sh off       remove it
#   throttle.sh status    show what is in force on each OSS node
#
# The limit is Lustre's own: the TBF policy of the network request
# scheduler on the OSS I/O service, with one token bucket per operation
# (read, write) refilled at B/N requests a second.  Clients are told to
# send 1 MB bulk requests while it is on, so one request is one megabyte
# of streaming I/O.  Small requests cost a whole token each, so small-file
# I/O is limited harder than the figure suggests.  A node that serves both
# OSTs after a failover gets twice the rate.

set -e

. "$(dirname "$(readlink -f "$0")")/config.sh"

STATE_FILE=$STATE/throttle
RULE=lch_band

nost() { targets | awk '$7 == "ost"' | wc -l; }

# 1 MB (256 pages of 4 KiB) or the default 4 MB bulk requests
client_rpc_pages() {
	local n
	for n in $(seq 1 $NCLIENTS); do
		vm_ssh $n "lctl set_param -n osc.*.max_pages_per_rpc=$1" 2>/dev/null || true
	done
}

apply() {
	local band=$1 per n hosted rate

	per=$((band / $(nost)))
	[ $per -ge 1 ] || per=1
	for n in $OSS_NODES; do
		hosted=$(node_ssh $n "mount -t lustre | grep -c ' /mnt/ost'" 2>/dev/null) || continue
		[ "$hosted" -ge 1 ] 2>/dev/null || continue
		rate=$((per * hosted))
		node_ssh $n "
			set -e
			lctl get_param -n ost.OSS.ost_io.nrs_policies | grep -A1 'name: tbf' |
				grep -q started ||
				lctl set_param -n ost.OSS.ost_io.nrs_policies='tbf opcode'
			lctl set_param -n ost.OSS.ost_io.nrs_tbf_rule='change $RULE rate=$rate' 2>/dev/null ||
			lctl set_param -n ost.OSS.ost_io.nrs_tbf_rule='start $RULE opcode={ost_read ost_write} rate=$rate'
		"
		echo "p$n: $hosted OST(s), $rate MB/s read and $rate MB/s write"
	done
	client_rpc_pages 256
}

do_status() {
	local n
	[ -e "$STATE_FILE" ] && echo "throttle on: band $(cat "$STATE_FILE") MB/s over $(nost) OSTs" ||
		echo "throttle off"
	for n in $OSS_NODES; do
		echo "p$n: $(node_ssh $n "
			lctl get_param -n ost.OSS.ost_io.nrs_policies | awk '/name:/ { n = \$3 } /state: started/ { print n }' | tr '\n' ' '
			lctl get_param -n ost.OSS.ost_io.nrs_tbf_rule 2>/dev/null | grep -E '^$RULE ' | head -2 | tr '\n' ' '
		" 2>/dev/null || echo unreachable)"
	done
}

case "$1" in
on)
	band=${2:-$THROTTLE_BAND}
	[ "$band" -ge 1 ] 2>/dev/null || { echo "band must be a number of MB/s"; exit 1; }
	echo "$band" > "$STATE_FILE"
	apply "$band"
	;;
off)
	rm -f "$STATE_FILE"
	for n in $OSS_NODES; do
		node_ssh $n "lctl set_param -n ost.OSS.ost_io.nrs_policies=fifo" 2>/dev/null || true
	done
	client_rpc_pages 1024
	echo "throttle off"
	;;
reapply)
	# after targets or clients moved or started; a no-op when it is off
	[ ! -e "$STATE_FILE" ] || apply "$(cat "$STATE_FILE")"
	;;
status)
	do_status
	;;
*)
	sed -n '3,18p' "$0"; exit 1
	;;
esac
