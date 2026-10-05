#!/bin/bash
#
# One-time setup of a freshly flashed controller: create the SSH key the
# controller uses to reach nodes and client VMs and install its public
# half in the node template and the client image.  Runs on first boot
# (lustre-clusterhat-init.service); safe to run again.

set -e

. "$(dirname "$(readlink -f "$0")")/config.sh"

if [ ! -e "$SSH_KEY" ]; then
	install -d -m 700 "$(dirname "$SSH_KEY")"
	ssh-keygen -q -t ed25519 -N '' -C lustre-clusterhat -f "$SSH_KEY"
fi

install -d -m 700 "$NODE_TEMPLATE/root/.ssh"
install -m 600 "$SSH_KEY.pub" "$NODE_TEMPLATE/root/.ssh/authorized_keys"

# the client VMs share one read-only base image
if pgrep -f "qemu-system-aarch64 -name client" >/dev/null; then
	echo "client VMs are running: stop them before re-running init"
	exit 1
fi
mnt=$(mktemp -d)
mount -o loop "$VMDIR/base.img" "$mnt"
install -d -m 700 "$mnt/root/.ssh"
install -m 600 "$SSH_KEY.pub" "$mnt/root/.ssh/authorized_keys"
umount "$mnt"
rmdir "$mnt"

touch "$STATE/.initialized"
echo "initialized: next run 'lustre-cluster nodes deploy'"
