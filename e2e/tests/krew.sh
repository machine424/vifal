# Test vifal as a kubectl plugin installed via krew: install, mount, read, unmount, uninstall.
# Skipped unless VIFAL_E2E_KREW=1 (set in CI after installing krew).

if [ "${VIFAL_E2E_KREW:-}" != "1" ]; then
    log_step "SKIP: VIFAL_E2E_KREW not set"
    return 0
fi

NAMESPACE="vifal-krew"
TEST_DIR=$(mktemp -d /tmp/vifal-krew-XXXXXX)
MOUNT="$TEST_DIR/mount"
LOGS="$TEST_DIR"

setup() {
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    mkdir -p "$MOUNT"
    kubectl create namespace "$NAMESPACE"
    kubectl run nginx --image="$IMAGE" -n "$NAMESPACE" --overrides="$FAST_TERM" --command -- sleep infinity
    kubectl wait --for=condition=Ready pod/nginx -n "$NAMESPACE" --timeout="${KUBECTL_TIMEOUT}s"
}

teardown() {
    dump_vifal_logs "$?"
    kubectl vifal unmount "$MOUNT" 2>/dev/null || true
    kubectl krew uninstall vifal 2>/dev/null || true
    rm -rf "$TEST_DIR"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false
}

trap teardown EXIT
setup

log_step "build and install via krew"
make -s release-archive VERSION=v0.0.0-ci GOOS=linux GOARCH=amd64
kubectl krew install --manifest="$DIR/krew-test-manifest.yaml" --archive=kubectl-vifal_v0.0.0-ci_linux_amd64.tar.gz
rm -f kubectl-vifal_v0.0.0-ci_linux_amd64.tar.gz kubectl-vifal

log_step "mount"
kubectl vifal --fsname "$VIFAL_SHELL_TEST" --attr-ttl "$CACHE_TTL" "$MOUNT" 2>"$LOGS/vifal.log" &
VIFAL_PID=$!
wait_for_fuse_sync "$MOUNT/$NAMESPACE/nginx/nginx"

log_step "read file"
diff <(fuse cat "$MOUNT/$NAMESPACE/nginx/nginx/etc/hostname") <(kubectl exec nginx -n "$NAMESPACE" -c nginx -- cat /etc/hostname)

log_step "unmount"
kubectl vifal unmount "$MOUNT"
wait_process_dead "$VIFAL_PID"
check_clean_unmount "$MOUNT"

log_step "krew uninstall"
kubectl krew uninstall vifal
