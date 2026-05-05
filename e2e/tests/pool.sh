# Pool eviction and transparent recovery.

BUSYBOX_IMAGE="${E2E_BUSYBOX_IMAGE:-busybox:1.36}"
NAMESPACE="vifal-poolbase"
POOL_NS="vifal-pool"
TEST_DIR=$(mktemp -d /tmp/vifal-pool-XXXXXX)
MOUNT="$TEST_DIR/mount"
LOGS="$TEST_DIR"

setup() {
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    kubectl delete namespace "$POOL_NS" --ignore-not-found
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
    kubectl delete namespace "$POOL_NS" --ignore-not-found --wait=false &
    pids+=($!)
    for pid in "${pids[@]}"; do wait "$pid"; done
}

trap teardown EXIT
setup

POOL_PODS=17
POOL_CONTAINERS=4

kubectl create namespace "$POOL_NS"

for i in $(seq 1 $POOL_PODS); do
    cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: p$i
  namespace: $POOL_NS
spec:
  containers:
$(for j in $(seq 1 $POOL_CONTAINERS); do
    echo "  - name: c$j"
    echo "    image: $BUSYBOX_IMAGE"
    echo '    command: ["sleep", "infinity"]'
done)
EOF
done | kubectl apply -f -

log_step "waiting for $POOL_PODS pods"
kubectl wait --for=condition=Ready pod --all -n "$POOL_NS" --timeout="${KUBECTL_TIMEOUT}s"

log_step "waiting for FUSE to see all containers"
wait_for_fuse_sync "$MOUNT/$POOL_NS/p$POOL_PODS/c$POOL_CONTAINERS"

log_step "accessing all $((POOL_PODS * POOL_CONTAINERS)) containers"
for i in $(seq 1 $POOL_PODS); do
    for j in $(seq 1 $POOL_CONTAINERS); do
        diff <(fuse cat "$MOUNT/$POOL_NS/p$i/c$j/etc/hostname") \
             <(kubectl exec "p$i" -n "$POOL_NS" -c "c$j" -- cat /etc/hostname)
    done
done

log_step "main containers work after pool overflow"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(kexec cat /etc/hostname)
diff <(fuse cat "$WORKER_FS/etc/hostname") <(kexec_worker cat /etc/hostname)
diff <(fuse ls "$WEB_FS/etc/") <(kexec_web ls /etc/)

log_step "re-access evicted pool containers"
for i in $(seq 1 5); do
    for j in $(seq 1 $POOL_CONTAINERS); do
        diff <(fuse cat "$MOUNT/$POOL_NS/p$i/c$j/etc/hostname") \
             <(kubectl exec "p$i" -n "$POOL_NS" -c "c$j" -- cat /etc/hostname)
    done
done

log_step "listing on recreated connection"
fuse ls "$MOUNT/$POOL_NS/p1/c1/" > /dev/null
