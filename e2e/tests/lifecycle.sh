# Kubernetes object lifecycle: namespaces, pods, and containers appear and
# disappear from the FUSE tree in sync with the cluster.

NAMESPACE="vifal-lcbase"
LIFECYCLE_NS="vifal-lifecycle"
TEST_DIR=$(mktemp -d /tmp/vifal-lifecycle-XXXXXX)
MOUNT="$TEST_DIR/mount"
LOGS="$TEST_DIR"

setup() {
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    kubectl delete namespace "$LIFECYCLE_NS" --ignore-not-found
    mkdir -p "$MOUNT"
    kubectl create namespace "$NAMESPACE"
    kubectl run nginx --image="$IMAGE" -n "$NAMESPACE" --overrides="$FAST_TERM" --command -- sleep infinity
    kubectl run worker --image="$IMAGE" -n "$NAMESPACE" --overrides="$FAST_TERM" --command -- sleep infinity
    kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: multi
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: web
    image: $IMAGE
    command: ["sleep", "infinity"]
  - name: sidecar
    image: $IMAGE
    command: ["sleep", "infinity"]
EOF
    kubectl wait --for=condition=Ready pod/nginx pod/worker pod/multi -n "$NAMESPACE" --timeout="${KUBECTL_TIMEOUT}s"
    "$VIFAL" $DEBUG --fsname "$VIFAL_SHELL_TEST" --attr-ttl "$CACHE_TTL" "$MOUNT" 2>"$LOGS/vifal.log" &
    NGINX_FS="$MOUNT/$NAMESPACE/nginx/nginx"
    WORKER_FS="$MOUNT/$NAMESPACE/worker/worker"
    WEB_FS="$MOUNT/$NAMESPACE/multi/web"
    wait_for_fuse_sync "$NGINX_FS"
    wait_for_fuse_sync "$WORKER_FS"
    wait_for_fuse_sync "$WEB_FS"
}

teardown() {
    dump_vifal_logs "$?"
    "$VIFAL" unmount "$MOUNT" 2>/dev/null || true
    rm -rf "$TEST_DIR"
    local pids=()
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false &
    pids+=($!)
    kubectl delete namespace "$LIFECYCLE_NS" --ignore-not-found --wait=false &
    pids+=($!)
    for pid in "${pids[@]}"; do wait "$pid"; done
}

trap teardown EXIT
setup

STAT=$(resolve_gnu_stat)

log_step "namespace directory has K8s creation timestamp"
ns_ctime=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}')
ns_epoch=$(TZ=UTC date -d "$ns_ctime" +%s 2>/dev/null || TZ=UTC date -jf '%Y-%m-%dT%H:%M:%SZ' "$ns_ctime" +%s)
fuse_mtime=$(fuse $STAT -c '%Y' "$MOUNT/$NAMESPACE")
[ "$fuse_mtime" = "$ns_epoch" ]

log_step "pod directory has K8s creation timestamp"
pod_ctime=$(kubectl get pod nginx -n "$NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}')
pod_epoch=$(TZ=UTC date -d "$pod_ctime" +%s 2>/dev/null || TZ=UTC date -jf '%Y-%m-%dT%H:%M:%SZ' "$pod_ctime" +%s)
fuse_mtime=$(fuse $STAT -c '%Y' "$MOUNT/$NAMESPACE/nginx")
[ "$fuse_mtime" = "$pod_epoch" ]

log_step "namespace and pod directories have Nlink >= 2"
[ "$(fuse $STAT -c '%h' "$MOUNT/$NAMESPACE")" -ge 2 ]
[ "$(fuse $STAT -c '%h' "$MOUNT/$NAMESPACE/nginx")" -ge 2 ]

log_step "root directory has Nlink >= 2"
[ "$(fuse $STAT -c '%h' "$MOUNT")" -ge 2 ]

log_step "timestamps are not epoch zero"
[ "$(fuse $STAT -c '%Y' "$MOUNT")" -gt 0 ]
[ "$(fuse $STAT -c '%Y' "$MOUNT/$NAMESPACE")" -gt 0 ]
[ "$(fuse $STAT -c '%Y' "$MOUNT/$NAMESPACE/nginx")" -gt 0 ]

log_step "empty namespace appears"
kubectl create namespace "$LIFECYCLE_NS"
wait_for_fuse_sync "$MOUNT/$LIFECYCLE_NS"
[ -z "$(fuse ls -A "$MOUNT/$LIFECYCLE_NS/")" ]

log_step "pod appears and is accessible"
LC_POD="lc-pod"
LC_POD_FS="$MOUNT/$LIFECYCLE_NS/$LC_POD/$LC_POD"
kubectl run "$LC_POD" --image="$IMAGE" -n "$LIFECYCLE_NS" --overrides="$FAST_TERM" --command -- sleep infinity
kubectl wait --for=condition=Ready "pod/$LC_POD" -n "$LIFECYCLE_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$LC_POD_FS"
diff <(fuse ls "$MOUNT/$LIFECYCLE_NS/$LC_POD/") <(echo "$LC_POD")
diff <(fuse cat "$LC_POD_FS/etc/hostname") <(echo "$LC_POD")

log_step "deleted pod disappears"
fuse cat "$LC_POD_FS/etc/passwd" > /dev/null
kubectl delete pod "$LC_POD" -n "$LIFECYCLE_NS" --grace-period=1
wait_for_cache_ttl "! test -d '$MOUNT/$LIFECYCLE_NS/$LC_POD'"
fuse ls "$MOUNT/" | grep -qx "$LIFECYCLE_NS"
diff <(fuse ls -A "$MOUNT/$LIFECYCLE_NS/") <(echo -n)

log_step "multi-container pod"
kubectl apply -n "$LIFECYCLE_NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: multi
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: web
    image: $IMAGE
    command: ["sleep", "infinity"]
  - name: sidecar
    image: $IMAGE
    command: ["sleep", "infinity"]
EOF
kubectl wait --for=condition=Ready pod/multi -n "$LIFECYCLE_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$MOUNT/$LIFECYCLE_NS/multi/web"
diff <(fuse ls "$MOUNT/$LIFECYCLE_NS/multi/") <(printf 'sidecar\nweb\n')
diff <(fuse cat "$MOUNT/$LIFECYCLE_NS/multi/web/etc/hostname") <(echo multi)
diff <(fuse cat "$MOUNT/$LIFECYCLE_NS/multi/sidecar/etc/hostname") <(echo multi)
test "$(echo "$MOUNT/$LIFECYCLE_NS/mult"*)" = "$MOUNT/$LIFECYCLE_NS/multi"

log_step "delete and recreate pod"
kubectl delete pod multi -n "$LIFECYCLE_NS" --grace-period=1
wait_for_cache_ttl "! test -d '$MOUNT/$LIFECYCLE_NS/multi'"
REBORN="reborn"
REBORN_FS="$MOUNT/$LIFECYCLE_NS/$REBORN/$REBORN"
kubectl run "$REBORN" --image="$IMAGE" -n "$LIFECYCLE_NS" --overrides="$FAST_TERM" --command -- sleep infinity
kubectl wait --for=condition=Ready "pod/$REBORN" -n "$LIFECYCLE_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$REBORN_FS"
diff <(fuse cat "$REBORN_FS/etc/hostname") <(echo "$REBORN")

log_step "same-name recreate"
kubectl delete pod "$REBORN" -n "$LIFECYCLE_NS" --grace-period=1
wait_for_cache_ttl "! test -d '$MOUNT/$LIFECYCLE_NS/$REBORN'"
kubectl run "$REBORN" --image="$IMAGE" -n "$LIFECYCLE_NS" --overrides="$FAST_TERM" --command -- sleep infinity
kubectl wait --for=condition=Ready "pod/$REBORN" -n "$LIFECYCLE_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$REBORN_FS"
diff <(fuse cat "$REBORN_FS/etc/hostname") <(echo "$REBORN")
diff <(fuse cat "$REBORN_FS/etc/os-release") \
     <(kubectl exec "$REBORN" -n "$LIFECYCLE_NS" -c "$REBORN" -- cat /etc/os-release)

log_step "same-name pod recreate with different containers"
fuse test -d "$MOUNT/$LIFECYCLE_NS/$REBORN/$REBORN"
kubectl delete pod "$REBORN" -n "$LIFECYCLE_NS" --grace-period=1
wait_for_cache_ttl "! test -d '$MOUNT/$LIFECYCLE_NS/$REBORN'"
kubectl apply -n "$LIFECYCLE_NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $REBORN
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: alpha
    image: $IMAGE
    command: ["sleep", "infinity"]
  - name: beta
    image: $IMAGE
    command: ["sleep", "infinity"]
EOF
kubectl wait --for=condition=Ready "pod/$REBORN" -n "$LIFECYCLE_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$MOUNT/$LIFECYCLE_NS/$REBORN/alpha"
diff <(fuse ls "$MOUNT/$LIFECYCLE_NS/$REBORN/") <(printf 'alpha\nbeta\n')
diff <(fuse cat "$MOUNT/$LIFECYCLE_NS/$REBORN/alpha/etc/hostname") <(echo "$REBORN")
diff <(fuse cat "$MOUNT/$LIFECYCLE_NS/$REBORN/beta/etc/hostname") <(echo "$REBORN")
must_fail test -d "$MOUNT/$LIFECYCLE_NS/$REBORN/$REBORN"

log_step "delete namespace removes everything"
kubectl delete namespace "$LIFECYCLE_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_cache_ttl "! test -d '$MOUNT/$LIFECYCLE_NS'"

log_step "original namespace unaffected"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(kexec cat /etc/hostname)
diff <(fuse ls "$NGINX_FS/etc/") <(kexec ls /etc/)
diff <(fuse cat "$WORKER_FS/etc/hostname") <(echo worker)
diff <(fuse cat "$WEB_FS/etc/hostname") <(echo multi)
