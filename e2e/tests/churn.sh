# Multi-namespace pod churn: consistency under rapid creation/deletion.

NAMESPACE="vifal-churnbase"
CHURN_NS="vifal-churn"
TEST_DIR=$(mktemp -d /tmp/vifal-churn-XXXXXX)
MOUNT="$TEST_DIR/mount"
LOGS="$TEST_DIR"

setup() {
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    for i in $(seq 1 5); do kubectl delete namespace "${CHURN_NS}-${i}" --ignore-not-found; done
    kubectl delete namespace "${CHURN_NS}-recreate" --ignore-not-found
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
    for n in "${CHURN_NAMESPACES[@]}"; do
        kubectl delete namespace "$n" --ignore-not-found --wait=false &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
}

trap teardown EXIT
setup

COUNT=5
DELETED="1 3 5"
KEPT="2 4"
ALL=$(seq 1 $COUNT)
CHURN_NAMESPACES=()

churn_ns()   { echo "${CHURN_NS}-${1}"; }
churn_pod()  { echo "$MOUNT/$(churn_ns "$1")/${2}/${2}"; }

create_pod() {
    kubectl run "$1" --image="$IMAGE" -n "$2" --overrides="$FAST_TERM" --command -- sleep infinity
}

bg_pids=()

log_step "create $COUNT namespaces with 1 pod each"
for i in $ALL; do
    CHURN_NAMESPACES+=("$(churn_ns "$i")")
    kubectl create namespace "$(churn_ns "$i")"
    create_pod "pod-${i}" "$(churn_ns "$i")"
done
for i in $ALL; do
    kubectl wait --for=condition=Ready "pod/pod-${i}" -n "$(churn_ns "$i")" --timeout="${KUBECTL_TIMEOUT}s"
    wait_for_fuse_sync "$(churn_pod "$i" "pod-${i}")"
done

log_step "each pod returns correct hostname"
for i in $ALL; do
    diff <(fuse cat "$(churn_pod "$i" "pod-${i}")/etc/hostname") <(echo "pod-${i}")
done

log_step "concurrent reads across all namespaces"
for i in $ALL; do
    for _ in $(seq 1 5); do
        fuse cat "$(churn_pod "$i" "pod-${i}")/etc/hostname" > /dev/null &
        bg_pids+=($!)
    done
done
reap

log_step "delete some namespaces, others survive"
for i in $DELETED; do
    kubectl delete namespace "$(churn_ns "$i")" --timeout="${KUBECTL_TIMEOUT}s"
    wait_for_cache_ttl "! test -d '$MOUNT/$(churn_ns "$i")'"
done
for i in $KEPT; do
    diff <(fuse cat "$(churn_pod "$i" "pod-${i}")/etc/hostname") <(echo "pod-${i}")
done

log_step "re-create deleted namespaces with new pods"
for i in $DELETED; do
    kubectl create namespace "$(churn_ns "$i")"
    create_pod "new-${i}" "$(churn_ns "$i")"
    kubectl wait --for=condition=Ready "pod/new-${i}" -n "$(churn_ns "$i")" --timeout="${KUBECTL_TIMEOUT}s"
    wait_for_fuse_sync "$(churn_pod "$i" "new-${i}")"
    diff <(fuse cat "$(churn_pod "$i" "new-${i}")/etc/hostname") <(echo "new-${i}")
    must_fail test -d "$MOUNT/$(churn_ns "$i")/pod-${i}"
done

log_step "same-name pod replacement"
for i in $KEPT; do
    kubectl delete pod "pod-${i}" -n "$(churn_ns "$i")" --grace-period=1
    wait_for_cache_ttl "! test -d '$(churn_pod "$i" "pod-${i}")'"
    create_pod "pod-${i}" "$(churn_ns "$i")"
    kubectl wait --for=condition=Ready "pod/pod-${i}" -n "$(churn_ns "$i")" --timeout="${KUBECTL_TIMEOUT}s"
    wait_for_fuse_sync "$(churn_pod "$i" "pod-${i}")"
    diff <(fuse cat "$(churn_pod "$i" "pod-${i}")/etc/hostname") <(echo "pod-${i}")
done

log_step "concurrent reads + ls during deletion"
delete_pids=()
for i in $ALL; do
    fuse ls "$MOUNT/$(churn_ns "$i")/" > /dev/null 2>&1 &
    bg_pids+=($!)
    kubectl delete namespace "$(churn_ns "$i")" --wait=false --ignore-not-found &
    delete_pids+=($!)
done
for pid in "${delete_pids[@]}"; do wait "$pid"; done
for pid in "${bg_pids[@]}"; do wait "$pid" || true; done
bg_pids=()

log_step "all churn namespaces eventually gone"
for i in $ALL; do
    kubectl wait --for=delete "namespace/$(churn_ns "$i")" --timeout="${KUBECTL_TIMEOUT}s" 2>/dev/null || true
    wait_for_cache_ttl "! test -d '$MOUNT/$(churn_ns "$i")'"
done
CHURN_NAMESPACES=()

log_step "namespace recreate: dir updates to new content"
RECREATE_NS="${CHURN_NS}-recreate"
CHURN_NAMESPACES+=("$RECREATE_NS")
kubectl create namespace "$RECREATE_NS"
create_pod alpha "$RECREATE_NS"
kubectl wait --for=condition=Ready pod/alpha -n "$RECREATE_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$MOUNT/$RECREATE_NS/alpha/alpha"
diff <(fuse cat "$MOUNT/$RECREATE_NS/alpha/alpha/etc/hostname") <(echo alpha)
diff <(fuse ls "$MOUNT/$RECREATE_NS/") <(echo alpha)

kubectl delete namespace "$RECREATE_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_cache_ttl "! test -d '$MOUNT/$RECREATE_NS'"

kubectl create namespace "$RECREATE_NS"
create_pod beta "$RECREATE_NS"
kubectl wait --for=condition=Ready pod/beta -n "$RECREATE_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$MOUNT/$RECREATE_NS/beta/beta"
diff <(fuse cat "$MOUNT/$RECREATE_NS/beta/beta/etc/hostname") <(echo beta)
must_fail test -d "$MOUNT/$RECREATE_NS/alpha"
diff <(fuse ls "$MOUNT/$RECREATE_NS/") <(echo beta)

log_step "namespace recreate: empty then populated"
kubectl delete namespace "$RECREATE_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_cache_ttl "! test -d '$MOUNT/$RECREATE_NS'"
kubectl create namespace "$RECREATE_NS"
wait_for_cache_ttl "test -d '$MOUNT/$RECREATE_NS'"
[ -z "$(fuse ls -A "$MOUNT/$RECREATE_NS/")" ]
create_pod gamma "$RECREATE_NS"
kubectl wait --for=condition=Ready pod/gamma -n "$RECREATE_NS" --timeout="${KUBECTL_TIMEOUT}s"
wait_for_fuse_sync "$MOUNT/$RECREATE_NS/gamma/gamma"
diff <(fuse cat "$MOUNT/$RECREATE_NS/gamma/gamma/etc/hostname") <(echo gamma)

log_step "original namespace unaffected by churn"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(kexec cat /etc/hostname)
diff <(fuse ls "$NGINX_FS/etc/") <(kexec ls /etc/)

log_step "no stale namespaces in root listing"
for i in $ALL; do
    must_fail test -d "$MOUNT/$(churn_ns "$i")"
done
