# Multi-pod, multi-container, and concurrency.

NAMESPACE="vifal-multipod"
TEST_DIR=$(mktemp -d /tmp/vifal-multipod-XXXXXX)
MOUNT="$TEST_DIR/mount"
LOGS="$TEST_DIR"

setup() {
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
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
    SIDECAR_FS="$MOUNT/$NAMESPACE/multi/sidecar"
    wait_for_fuse_sync "$NGINX_FS"
    wait_for_fuse_sync "$WORKER_FS"
    wait_for_fuse_sync "$WEB_FS"
}

teardown() {
    dump_vifal_logs "$?"
    "$VIFAL" unmount "$MOUNT" 2>/dev/null || true
    rm -rf "$TEST_DIR"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false
}

trap teardown EXIT
setup

bg_pids=()

log_step "each pod has correct hostname"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(echo nginx)
diff <(fuse cat "$WORKER_FS/etc/hostname") <(echo worker)
diff <(fuse cat "$WEB_FS/etc/hostname") <(echo multi)
diff <(fuse cat "$SIDECAR_FS/etc/hostname") <(echo multi)

log_step "same image => same system files across pods"
diff <(fuse cat "$NGINX_FS/etc/os-release") <(fuse cat "$WORKER_FS/etc/os-release")
diff <(fuse cat "$NGINX_FS/etc/os-release") <(fuse cat "$WEB_FS/etc/os-release")

log_step "each pod has independent listing"
diff <(fuse ls "$NGINX_FS/etc/") <(kexec ls /etc/)
diff <(fuse ls "$WORKER_FS/etc/") <(kexec_worker ls /etc/)
diff <(fuse ls "$WEB_FS/etc/") <(kexec_web ls /etc/)

log_step "containers in same pod share hostname but not filesystem"
diff <(fuse cat "$WEB_FS/etc/hostname") <(fuse cat "$SIDECAR_FS/etc/hostname")
kexec_web sh -c "echo web-only > /tmp/web-marker"
wait_for_cache_ttl "test -e '$WEB_FS/tmp/web-marker'"
diff <(fuse cat "$WEB_FS/tmp/web-marker") <(echo web-only)
must_fail test -e "$SIDECAR_FS/tmp/web-marker"

log_step "parallel reads, different files"
for f in /etc/hostname /etc/os-release /etc/passwd /etc/group; do
    diff <(fuse cat "$NGINX_FS$f") <(kexec cat "$f") &
    bg_pids+=($!)
done
reap

log_step "10 concurrent reads"
for _ in $(seq 10); do
    fuse cat "$NGINX_FS/etc/hostname" > /dev/null &
    bg_pids+=($!)
done
reap

log_step "10 mixed cat and ls"
for _ in $(seq 5); do
    fuse cat "$NGINX_FS/etc/passwd" > /dev/null &
    bg_pids+=($!)
    fuse ls "$NGINX_FS/etc/" > /dev/null &
    bg_pids+=($!)
done
reap

log_step "16 reads across 4 containers"
for _ in $(seq 4); do
    fuse cat "$NGINX_FS/etc/passwd" > /dev/null &
    bg_pids+=($!)
    fuse cat "$WORKER_FS/etc/passwd" > /dev/null &
    bg_pids+=($!)
    fuse cat "$WEB_FS/etc/passwd" > /dev/null &
    bg_pids+=($!)
    fuse cat "$SIDECAR_FS/etc/passwd" > /dev/null &
    bg_pids+=($!)
done
reap

log_step "error in one container doesn't affect others"
must_fail cat "$NGINX_FS/no-such-file"
diff <(fuse cat "$WORKER_FS/etc/hostname") <(echo worker)
diff <(fuse cat "$WEB_FS/etc/hostname") <(echo multi)

log_step "all containers healthy after stress"
diff <(fuse ls "$NGINX_FS/etc/") <(kexec ls /etc/)
diff <(fuse ls "$WORKER_FS/etc/") <(kexec_worker ls /etc/)
diff <(fuse ls "$WEB_FS/etc/") <(kexec_web ls /etc/)
diff <(fuse ls "$SIDECAR_FS/etc/") <(kexec_sidecar ls /etc/)
