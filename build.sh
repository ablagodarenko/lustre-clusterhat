#!/bin/bash
#
# Build a Raspberry Pi controller image for a Lustre cluster on a ClusterHAT.
#
#   build.sh            run every stage that has not completed yet
#   build.sh STAGE...   run the named stages (e.g. "40 80"), done or not
#   build.sh list       show the stages and which are done
#   build.sh deps       install the packages the build host needs
#   build.sh clean      remove the work directory
#
# Must run as root on an aarch64 Debian or Raspberry Pi OS host.

TOP=$(dirname "$(readlink -f "$0")")

case "$1" in
deps)
	exec apt-get install -y --no-install-recommends debootstrap git curl \
		xz-utils rsync fdisk e2fsprogs dosfstools ca-certificates perl
	;;
-h|--help|help)
	sed -n '3,11p' "$0"; exit 0
	;;
esac

. "$TOP/lib.sh"

stages=$(cd "$TOP/stages" && ls [0-9]*.sh)
mkdir -p "$WORK/done" "$WORK/log"

case "$1" in
list)
	for s in $stages; do
		printf '%-28s %s\n' "$s" "$([ -e "$WORK/done/$s" ] && echo done || echo -)"
	done
	exit 0
	;;
clean)
	cleanup
	grep -q " $WORK/" /proc/mounts && die "something is still mounted under $WORK"
	rm -rf "$WORK"
	exit 0
	;;
esac

run_stage() {
	local s=$1
	log "stage $s (log: $WORK/log/${s%.sh}.log)"
	if bash "$TOP/stages/$s" > "$WORK/log/${s%.sh}.log" 2>&1; then
		touch "$WORK/done/$s"
	else
		tail -n 25 "$WORK/log/${s%.sh}.log" >&2
		die "stage $s failed"
	fi
}

if [ $# -gt 0 ]; then
	for want in "$@"; do
		s=$(echo "$stages" | grep "^$want" | head -1)
		[ -n "$s" ] || die "no stage matches '$want'"
		rm -f "$WORK/done/$s"
		run_stage "$s"
	done
else
	for s in $stages; do
		[ -e "$WORK/done/$s" ] || run_stage "$s"
	done
	log "finished: $(ls "$OUT"/*.img* 2>/dev/null | tr '\n' ' ')"
fi
