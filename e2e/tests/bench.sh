# Read throughput benchmark using dd.
# Informational only, not a real test.

NAMESPACE="vifal-bench"
TEST_DIR=$(mktemp -d /tmp/vifal-bench-XXXXXX)
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

CONTAINER_PATH="/tmp/bench"

bench() {
    local size_mb="$1"
    local fuse_path="$NGINX_FS$CONTAINER_PATH"

    log_step "reading ${size_mb}MB file through FUSE"
    kexec sh -c "dd if=/dev/urandom of=$CONTAINER_PATH bs=1048576 count=$size_mb 2>/dev/null"
    wait_for_cache_ttl "test -e '$fuse_path'"
    dd if="$fuse_path" of=/dev/null bs=1048576 2>&1 | tail -1
}

bench 16
bench 64
bench 256
