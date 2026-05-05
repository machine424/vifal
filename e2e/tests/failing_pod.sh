# Container failure and recovery.

BAD_IMAGE="nonexistent-image:99999"
NAMESPACE="vifal-failbase"
FAILING_NS="vifal-failing"
TEST_DIR=$(mktemp -d /tmp/vifal-failing-XXXXXX)
MOUNT="$TEST_DIR/mount"
LOGS="$TEST_DIR"

setup() {
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    kubectl delete namespace "$FAILING_NS" --ignore-not-found
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
    local pids=()
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false &
    pids+=($!)
    kubectl delete namespace "$FAILING_NS" --ignore-not-found --wait=false &
    pids+=($!)
    for pid in "${pids[@]}"; do wait "$pid"; done
}

trap teardown EXIT
setup

kubectl create namespace "$FAILING_NS"
FAILING_MOUNT="$MOUNT/$FAILING_NS"

log_step "bad image: appears in tree but reads fail"
kubectl run badimage --image="$BAD_IMAGE" -n "$FAILING_NS" --overrides="$FAST_TERM" --command -- sleep infinity
wait_for_fuse_sync "$FAILING_MOUNT/badimage/badimage"
BADIMAGE="$FAILING_MOUNT/badimage/badimage"
must_fail cat "$BADIMAGE/etc/hostname"
must_fail ls "$BADIMAGE/"

log_step "fix broken image and recover"
kubectl apply -n "$FAILING_NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: fixlater
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: fixlater
    image: $BAD_IMAGE
    command: ["sleep", "infinity"]
EOF
wait_for_fuse_sync "$FAILING_MOUNT/fixlater/fixlater"
must_fail cat "$FAILING_MOUNT/fixlater/fixlater/etc/hostname"
kubectl set image pod/fixlater fixlater="$IMAGE" -n "$FAILING_NS"
kubectl wait --for=condition=Ready pod/fixlater -n "$FAILING_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_cache_ttl "fuse cat '$FAILING_MOUNT/fixlater/fixlater/etc/hostname' 2>/dev/null | grep -q fixlater"
diff <(fuse cat "$FAILING_MOUNT/fixlater/fixlater/etc/hostname") <(echo fixlater)

CRASH_SLEEP=10
create_crasher() {
    kubectl delete pod crasher -n "$FAILING_NS" --ignore-not-found
    kubectl apply -n "$FAILING_NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: crasher
spec:
  terminationGracePeriodSeconds: 1
  restartPolicy: Always
  containers:
  - name: crasher
    image: $IMAGE
    command: ["sh", "-c", "sleep $CRASH_SLEEP; exit 1"]
EOF
    kubectl wait --for=condition=Ready pod/crasher -n "$FAILING_NS" --timeout="${KUBECTL_TIMEOUT}s"
    wait_for_fuse_sync "$FAILING_MOUNT/crasher/crasher"
}

log_step "crashing container: works, crashes, recovers"
create_crasher
CRASHER="$FAILING_MOUNT/crasher/crasher"
diff <(fuse cat "$CRASHER/etc/hostname") <(echo crasher)
sleep $((CRASH_SLEEP + 3))
kubectl wait --for=condition=Ready pod/crasher -n "$FAILING_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_cache_ttl "fuse cat '$CRASHER/etc/hostname' 2>/dev/null | grep -q crasher"
diff <(fuse cat "$CRASHER/etc/hostname") <(echo crasher)

log_step "survives 3 consecutive crash cycles"
for _ in 1 2 3; do
    kubectl wait --for=condition=Ready pod/crasher -n "$FAILING_NS" --timeout="${KUBECTL_TIMEOUT}s"
    wait_for_cache_ttl "fuse cat '$CRASHER/etc/hostname' 2>/dev/null | grep -q crasher"
    diff <(fuse cat "$CRASHER/etc/hostname") <(echo crasher)
    sleep $((CRASH_SLEEP + 3))
done

log_step "partial crash: stable survives, fragile recovers"
kubectl apply -n "$FAILING_NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: partial
spec:
  terminationGracePeriodSeconds: 1
  restartPolicy: Always
  containers:
  - name: stable
    image: $IMAGE
    command: ["sleep", "infinity"]
  - name: fragile
    image: $IMAGE
    command: ["sh", "-c", "sleep $CRASH_SLEEP; exit 1"]
EOF
kubectl wait --for=condition=Ready pod/partial -n "$FAILING_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$FAILING_MOUNT/partial/stable"
wait_for_fuse_sync "$FAILING_MOUNT/partial/fragile"
STABLE="$FAILING_MOUNT/partial/stable"
FRAGILE="$FAILING_MOUNT/partial/fragile"
diff <(fuse cat "$STABLE/etc/hostname") <(echo partial)
diff <(fuse cat "$FRAGILE/etc/hostname") <(echo partial)
sleep $((CRASH_SLEEP + 3))
diff <(fuse cat "$STABLE/etc/hostname") <(echo partial)
kubectl wait --for=condition=Ready pod/partial -n "$FAILING_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_cache_ttl "fuse cat '$FRAGILE/etc/hostname' 2>/dev/null | grep -q partial"
diff <(fuse cat "$FRAGILE/etc/hostname") <(echo partial)

log_step "10 parallel reads on restarting container"
create_crasher
pids=()
for _ in $(seq 10); do
    fuse cat "$CRASHER/etc/hostname" > /dev/null 2>&1 &
    pids+=($!)
done
failures=0
for p in "${pids[@]}"; do wait "$p" || failures=$((failures + 1)); done
[ "$failures" -lt 10 ]

log_step "other pods unaffected by failures"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(kexec cat /etc/hostname)
diff <(fuse ls "$NGINX_FS/etc/") <(kexec ls /etc/)
