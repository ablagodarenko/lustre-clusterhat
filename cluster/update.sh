#!/bin/bash
#
# Update the lustre-cluster software on the controller from its git
# repository, without reflashing the controller.
#
#   update.sh [REF]     install the scripts from branch, tag or commit REF
#                       (default: $UPDATE_REF)
#   update.sh status    show what is installed and what the repository has
#   update.sh auto      install $UPDATE_REF only if it differs from what is
#                       installed; what lustre-clusterhat-update.timer runs
#                       after boot and once a day.  To stop that:
#                       systemctl disable --now lustre-clusterhat-update.timer
#
# This updates what the repository's cluster/ and files/ directories hold:
# the lustre-cluster commands, their systemd units, module options and
# manual pages.  It
# does not touch a running cluster, and it does not change Lustre itself,
# the kernels, the node root template or the client VM image: those are
# built into the image.  The controller needs to reach the repository.

set -e

. "$(dirname "$(readlink -f "$0")")/config.sh"

DEST=/opt/lustre-clusterhat
REPO_DIR=$STATE/repo
REV_FILE=$STATE/scripts-revision
COMMIT_FILE=$STATE/scripts-commit

installed() { cat "$REV_FILE" 2>/dev/null || echo "as shipped in the image"; }

fetch_repo() {
	[ -n "$UPDATE_REPO" ] ||
		{ echo "UPDATE_REPO is not set (see /etc/lustre-clusterhat.conf)"; exit 1; }
	command -v git >/dev/null || { echo "git is not installed: apt-get install git"; exit 1; }
	if [ ! -d "$REPO_DIR/.git" ]; then
		rm -rf "$REPO_DIR"
		git clone -q "$UPDATE_REPO" "$REPO_DIR"
	else
		git -C "$REPO_DIR" remote set-url origin "$UPDATE_REPO"
		git -C "$REPO_DIR" fetch -q --tags --prune origin
	fi
}

# commit a branch, tag or commit name stands for, preferring the remote's
resolve() {
	git -C "$REPO_DIR" rev-parse -q --verify "origin/$1^{commit}" ||
	git -C "$REPO_DIR" rev-parse -q --verify "$1^{commit}"
}

do_status() {
	local want
	echo "installed:  $(installed)"
	fetch_repo
	want=$(resolve "$UPDATE_REF") || { echo "no '$UPDATE_REF' in $UPDATE_REPO"; exit 1; }
	echo "repository: $(git -C "$REPO_DIR" log -1 --format='%h %ad %s' --date=short $want) ($UPDATE_REF)"
}

do_update() {
	local ref=${1:-$UPDATE_REF} want tmp f

	fetch_repo
	want=$(resolve "$ref") || { echo "no '$ref' in $UPDATE_REPO"; exit 1; }
	git -C "$REPO_DIR" checkout -q --detach "$want"
	[ -x "$REPO_DIR/cluster/lustre-cluster" ] ||
		{ echo "$ref has no cluster/ directory: not a lustre-clusterhat tree"; exit 1; }

	# nothing half-installed: check everything first, then swap the
	# directory in one move
	for f in "$REPO_DIR"/cluster/*.sh "$REPO_DIR/cluster/lustre-cluster"; do
		bash -n "$f" || { echo "syntax error in ${f##*/}: not installing"; exit 1; }
	done
	tmp=$(mktemp -d "$DEST.new.XXXXXX")
	install -m 755 "$REPO_DIR"/cluster/*.sh "$REPO_DIR/cluster/lustre-cluster" "$tmp/"
	chmod 755 "$tmp"
	rm -rf "$DEST.old"
	mv "$DEST" "$DEST.old"
	mv "$tmp" "$DEST"
	ln -sf "$DEST/lustre-cluster" /usr/local/sbin/lustre-cluster

	if ls "$REPO_DIR"/files/*.service >/dev/null 2>&1; then
		install -m 644 "$REPO_DIR"/files/*.service /etc/systemd/system/
		for f in "$REPO_DIR"/files/*.timer; do
			[ ! -e "$f" ] || install -m 644 "$f" /etc/systemd/system/
		done
		systemctl daemon-reload
	fi
	[ ! -e "$REPO_DIR/files/usb-storage-rpiboot.conf" ] ||
		install -m 644 "$REPO_DIR/files/usb-storage-rpiboot.conf" /etc/modprobe.d/
	for f in "$REPO_DIR"/man/*.[1-9]; do
		[ -e "$f" ] || continue
		install -D -m 644 "$f" "/usr/local/share/man/man${f##*.}/${f##*/}"
	done

	echo "was: $(installed)"
	git -C "$REPO_DIR" log -1 --format='%h %ad %s' --date=short "$want" > "$REV_FILE"
	echo "$want" > "$COMMIT_FILE"
	echo "now: $(installed)"
	echo "The previous scripts are in $DEST.old.  A running cluster is not"
	echo "affected until the next lustre-cluster command."
}

do_auto() {
	local want
	fetch_repo
	want=$(resolve "$UPDATE_REF") || { echo "no '$UPDATE_REF' in $UPDATE_REPO"; exit 1; }
	if [ "$(cat "$COMMIT_FILE" 2>/dev/null)" = "$want" ]; then
		echo "up to date: $(installed)"
	else
		do_update "$UPDATE_REF"
	fi
}

# all of the above is read before anything runs, so replacing this very
# file during an update cannot trip the shell up
case "$1" in
status) do_status; exit ;;
auto)   do_auto; exit ;;
-h|--help|help) sed -n '3,19p' "$0"; exit ;;
*)      do_update "$1"; exit ;;
esac
