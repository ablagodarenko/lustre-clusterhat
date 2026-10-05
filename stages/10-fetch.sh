#!/bin/bash
# Fetch the ClusterHAT images and the Lustre and e2fsprogs sources.

. "$(dirname "$(readlink -f "$0")")/../lib.sh"

fetch "$CTRL_IMAGE_URL" >/dev/null
fetch "$NODE_ROOT_URL" >/dev/null

mkdir -p "$SRC"

if [ ! -d "$SRC/lustre-release/.git" ]; then
	log "cloning $LUSTRE_GIT"
	git clone "$LUSTRE_GIT" "$SRC/lustre-release"
fi
git -C "$SRC/lustre-release" fetch origin
git -C "$SRC/lustre-release" checkout -q -f \
	"$(git -C "$SRC/lustre-release" rev-parse -q --verify "origin/$LUSTRE_REF" ||
	   echo "$LUSTRE_REF")"
git -C "$SRC/lustre-release" clean -q -fdx
log "lustre: $(git -C "$SRC/lustre-release" describe --tags)"

if [ ! -d "$SRC/e2fsprogs/.git" ]; then
	log "cloning $E2FS_GIT"
	git clone --branch "$E2FS_TAG" --depth 1 "$E2FS_GIT" "$SRC/e2fsprogs"
fi
git -C "$SRC/e2fsprogs" fetch -q --depth 1 origin tag "$E2FS_TAG"
git -C "$SRC/e2fsprogs" checkout -q -f "$E2FS_TAG"
git -C "$SRC/e2fsprogs" clean -q -fdx
log "e2fsprogs: $E2FS_TAG"
