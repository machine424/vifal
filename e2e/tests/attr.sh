# Stat attribute comparison between FUSE mount and container.

NAMESPACE="vifal-attr"
TEST_DIR=$(mktemp -d /tmp/vifal-attr-XXXXXX)
MOUNT="$TEST_DIR/mount"
LOGS="$TEST_DIR"

setup() {
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    mkdir -p "$MOUNT"
    kubectl create namespace "$NAMESPACE"
    kubectl run nginx --image="$IMAGE" -n "$NAMESPACE" --overrides="$FAST_TERM" --command -- sleep infinity
    kubectl wait --for=condition=Ready pod/nginx -n "$NAMESPACE" --timeout="${KUBECTL_TIMEOUT}s"
    "$VIFAL" $DEBUG --fsname "$VIFAL_SHELL_TEST" --attr-ttl "$CACHE_TTL" "$MOUNT" 2>"$LOGS/vifal.log" &
    NGINX_FS="$MOUNT/$NAMESPACE/nginx/nginx"
    wait_for_fuse_sync "$NGINX_FS"
}

teardown() {
    dump_vifal_logs "$?"
    "$VIFAL" unmount "$MOUNT" 2>/dev/null || true
    rm -rf "$TEST_DIR"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false
}

trap teardown EXIT
setup

STAT=$(resolve_gnu_stat)

# %X (atime) excluded: our find+stat updates it before we can compare.
FMT='%s %f %u %g %h %Y %Z %i %t %T'
[ "$UNAME_S" != "Darwin" ] && FMT="$FMT %b %o"

check() {
    local got want
    got=$(fuse $STAT -c "$FMT" "$NGINX_FS/$1")
    want=$(kexec stat -c "$FMT" "$1")
    [ "$got" = "$want" ] || { echo "MISMATCH $1: got=[$got] want=[$want]"; return 1; }
}

log_step "regular file attributes"
check /etc/hostname
check /etc/passwd

log_step "directory attributes"
check /etc

log_step "device file attributes"
check /dev/null
check /dev/zero
check /dev/random

log_step "mode 000 file preserves zero permission bits"
MODE000="$NGINX_FS/tmp/mode000"
kexec sh -c 'cp /etc/hostname /tmp/mode000 && chmod 000 /tmp/mode000'
wait_for_cache_ttl "test -f '$MODE000'"
got=$(fuse $STAT -c '%a' "$MODE000")
[ "$got" = "0" ] || { echo "FAIL: mode000 shows $got instead of 0"; exit 1; }

log_step "sparse file: metadata and content"
# Create a 1MB sparse file (all holes, 0 allocated blocks in the container),
# then write 5 bytes at the start so it has a data region followed by a hole.
SPARSE_CONTAINER="/tmp/sparse"
SPARSE_FUSE="$NGINX_FS$SPARSE_CONTAINER"
kexec sh -c "truncate -s 1048576 $SPARSE_CONTAINER && printf 'hello' | dd of=$SPARSE_CONTAINER bs=1 conv=notrunc status=none"
wait_for_cache_ttl "test -f '$SPARSE_FUSE'"
[ "$(fuse $STAT -c '%s' "$SPARSE_FUSE")" = "1048576" ]
container_blocks=$(kexec stat -c '%b' "$SPARSE_CONTAINER")
fuse_blocks=$(fuse $STAT -c '%b' "$SPARSE_FUSE")
if [ "$UNAME_S" = "Darwin" ]; then
    # macFUSE overrides st_blocks and st_blksize, ignoring the driver's values.
    # https://github.com/macfuse/macfuse/issues/1121
    [ "$fuse_blocks" = "2048" ] || { echo "FAIL: macFUSE blocks=$fuse_blocks want 2048"; exit 1; }
    # macFUSE hardcodes blksize to 1MB.
    MACFUSE_BLKSIZE=$((1024 * 1024))
    fuse_io=$(fuse $STAT -c '%o' "$NGINX_FS/etc/hostname")
    [ "$fuse_io" = "$MACFUSE_BLKSIZE" ] || { echo "FAIL: macFUSE blksize=$fuse_io want $MACFUSE_BLKSIZE"; exit 1; }
else
    [ "$fuse_blocks" = "$container_blocks" ] || { echo "FAIL: blocks mismatch: fuse=$fuse_blocks container=$container_blocks"; exit 1; }
fi
# Content reads must work regardless of the st_blocks metadata.
diff <(fuse dd if="$SPARSE_FUSE" bs=1 count=5 status=none) <(printf 'hello')
r=$(fuse dd if="$SPARSE_FUSE" bs=1 skip=5 count=5 status=none | wc -c | tr -d ' ')
[ "$r" = "5" ]
diff <(dd if="$SPARSE_FUSE" bs=1048576 2>/dev/null | md5sum) <(kexec cat "$SPARSE_CONTAINER" | md5sum)

log_step "file types"
[ "$(fuse $STAT -c '%F' "$NGINX_FS/etc/hostname")" = "regular file" ]
[ "$(fuse $STAT -c '%F' "$NGINX_FS/etc")" = "directory" ]
[ "$(fuse $STAT -c '%F' "$NGINX_FS/lib")" = "symbolic link" ]
