# Compatibility with different container images and toolsets.

BUSYBOX_IMAGE="${E2E_BUSYBOX_IMAGE:-busybox:1.36}"
PAUSE_IMAGE="${E2E_PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"
NAMESPACE="vifal-compat"
TEST_DIR=$(mktemp -d /tmp/vifal-compat-XXXXXX)
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

log_step "busybox: basic operations"
kubectl run bb-test --image="$BUSYBOX_IMAGE" -n "$NAMESPACE" --overrides="$FAST_TERM" --command -- sleep infinity
kubectl wait --for=condition=Ready pod/bb-test -n "$NAMESPACE" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$MOUNT/$NAMESPACE/bb-test/bb-test"
BUSYBOX="$MOUNT/$NAMESPACE/bb-test/bb-test"
fuse ls "$BUSYBOX/" > /dev/null
fuse ls "$BUSYBOX/etc/" > /dev/null
diff <(fuse cat "$BUSYBOX/etc/hostname") <(kubectl exec bb-test -n "$NAMESPACE" -- cat /etc/hostname)

log_step "busybox: file creation"
kubectl exec bb-test -n "$NAMESPACE" -- sh -c "echo bb-data > /tmp/bb-file"
wait_for_cache_ttl "test -e '$BUSYBOX/tmp/bb-file'"
diff <(fuse cat "$BUSYBOX/tmp/bb-file") <(echo bb-data)

log_step "busybox: symlink"
kubectl exec bb-test -n "$NAMESPACE" -- sh -c "ln -sf /etc/hostname /tmp/bb-link"
wait_for_cache_ttl "test -L '$BUSYBOX/tmp/bb-link'"
fuse test -L "$BUSYBOX/tmp/bb-link"
diff <(fuse readlink "$BUSYBOX/tmp/bb-link") <(echo "$BUSYBOX/etc/hostname")
diff <(fuse cat "$BUSYBOX/tmp/bb-link") <(kubectl exec bb-test -n "$NAMESPACE" -- cat /etc/hostname)

log_step "missing dd: cat fails, ls works"
kubectl run no-dd --image="$IMAGE" -n "$NAMESPACE" --overrides="$FAST_TERM" --command -- sleep infinity
kubectl wait --for=condition=Ready pod/no-dd -n "$NAMESPACE" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$MOUNT/$NAMESPACE/no-dd/no-dd"
NO_DD="$MOUNT/$NAMESPACE/no-dd/no-dd"
kubectl exec no-dd -n "$NAMESPACE" -- sh -c "rm -f \$(which dd)"
wait_for_cache_ttl
must_fail cat "$NO_DD/etc/hostname"
fuse ls "$NO_DD/etc/" > /dev/null

log_step "missing find: ls fails, cat works"
kubectl run no-find --image="$IMAGE" -n "$NAMESPACE" --overrides="$FAST_TERM" --command -- sleep infinity
kubectl wait --for=condition=Ready pod/no-find -n "$NAMESPACE" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$MOUNT/$NAMESPACE/no-find/no-find"
NO_FIND="$MOUNT/$NAMESPACE/no-find/no-find"
fuse cat "$NO_FIND/etc/hostname" > /dev/null
kubectl exec no-find -n "$NAMESPACE" -- sh -c "rm -f \$(which find)"
wait_for_cache_ttl
must_fail ls "$NO_FIND/etc/"

log_step "missing stat: ls fails"
kubectl run no-stat --image="$IMAGE" -n "$NAMESPACE" --overrides="$FAST_TERM" --command -- sleep infinity
kubectl wait --for=condition=Ready pod/no-stat -n "$NAMESPACE" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$MOUNT/$NAMESPACE/no-stat/no-stat"
NO_STAT="$MOUNT/$NAMESPACE/no-stat/no-stat"
kubectl exec no-stat -n "$NAMESPACE" -- sh -c "rm -f \$(which stat)"
wait_for_cache_ttl
must_fail ls "$NO_STAT/etc/"

log_step "broken containers don't affect others"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(kexec cat /etc/hostname)
diff <(fuse ls "$NGINX_FS/etc/") <(kexec ls /etc/)
diff <(fuse cat "$BUSYBOX/etc/hostname") <(kubectl exec bb-test -n "$NAMESPACE" -- cat /etc/hostname)

# Pause image: no shell at all.
log_step "no-shell container: graceful degradation"
kubectl run notools --image="$PAUSE_IMAGE" -n "$NAMESPACE"
kubectl wait --for=condition=Ready pod/notools -n "$NAMESPACE" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$MOUNT/$NAMESPACE/notools"
diff <(fuse ls "$MOUNT/$NAMESPACE/notools/") <(echo "notools")
must_fail ls "$MOUNT/$NAMESPACE/notools/notools/"
must_fail cat "$MOUNT/$NAMESPACE/notools/notools/etc/hostname"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(kexec cat /etc/hostname)

log_step "remote stderr appears in logs"
# Locale-dependent: assumes English error messages from the container.
grep -q "Read.*no-dd.*stderr:.*dd: not found" "$LOGS/vifal.log"
grep -q "no-stat.*stderr:.*find:.*stat.*No such file" "$LOGS/vifal.log"

kubectl delete pod bb-test no-dd no-find no-stat notools -n "$NAMESPACE" --grace-period=1 --ignore-not-found
