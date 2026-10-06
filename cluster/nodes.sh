#!/bin/bash
#
# Server nodes (the Pi Zeros on the ClusterHAT).  They boot over USB from
# an NFS root on the controller; their SD cards only hold Lustre targets.
#
#   nodes.sh deploy [N..]  power the node(s) off, replace their NFS root
#                          with a copy of the template, power them on
#   nodes.sh on [N..]      power on, one at a time
#   nodes.sh off [N..]     power off
#   nodes.sh status        power state and reachability

set -e

. "$(dirname "$(readlink -f "$0")")/config.sh"

# Wait for a node to answer on ssh.  A Zero occasionally fails to show up
# on USB after a (re)boot and stays that way: power cycle it once before
# giving up.
wait_ssh() {
	local n=$1 try attempt
	for attempt in 1 2; do
		for try in $(seq 30); do
			node_ssh $n true 2>/dev/null && return 0
			sleep 10
		done
		[ $attempt = 1 ] || break
		echo "p$n did not come up, power cycling it"
		clusterctrl off p$n
		sleep 5
		power_on $n
	done
	echo "p$n did not come up"
	return 1
}

power_on() {
	local n
	rpiboot_quirk
	for n in "$@"; do
		clusterctrl on p$n
		# several Zeros starting together can brown out the
		# controller's USB bus
		sleep 30
	done
}

do_deploy() {
	local n root

	[ -e "$NODE_TEMPLATE/usr/share/clusterctrl/reconfig-usbboot" ] ||
		{ echo "no node template at $NODE_TEMPLATE"; exit 1; }
	[ -e "$SSH_KEY.pub" ] || { echo "run 'lustre-cluster init' first"; exit 1; }

	for n in "$@"; do
		root=$NFSROOT/p$n
		echo "=== p$n"
		clusterctrl off p$n
		sleep 3
		mkdir -p "$root"
		rsync -aHAX --delete --numeric-ids "$NODE_TEMPLATE/" "$root/"
		install -d -m 700 "$root/root/.ssh"
		install -m 600 "$SSH_KEY.pub" "$root/root/.ssh/authorized_keys"
		usbboot-init $n
	done
	power_on "$@"
	for n in "$@"; do
		wait_ssh $n && node_ssh $n 'echo "$(hostname): $(uname -rm)"'
	done
}

do_status() {
	local n
	for n in $NODES; do
		printf 'p%s: power %s, %s\n' $n \
			"$(clusterctrl status | sed -n "s/^p$n://p")" \
			"$(node_ssh $n 'uname -r; uptime -p' 2>/dev/null | tr '\n' ' ' ||
			   echo unreachable)"
	done
}

cmd=$1; shift || true
case "$cmd" in
deploy) do_deploy ${@:-$NODES} ;;
on)     power_on ${@:-$NODES}; for n in ${@:-$NODES}; do wait_ssh $n; done ;;
off)    for n in ${@:-$NODES}; do clusterctrl off p$n; done ;;
status) do_status ;;
*)      sed -n '3,11p' "$0"; exit 1 ;;
esac
