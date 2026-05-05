# Two independent vifal instances: custom fsname, same default fsname,
# cross-mount consistency, and interleaved concurrency.

NAMESPACE="vifal-dualmount"
TEST_DIR=$(mktemp -d /tmp/vifal-dualmount-XXXXXX)
MOUNT1="$TEST_DIR/mount1"
MOUNT2="$TEST_DIR/mount2"
LOGS="$TEST_DIR"

setup() {
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    mkdir -p "$MOUNT1"
    kubectl create namespace "$NAMESPACE"
    kubectl run nginx --image="$IMAGE" -n "$NAMESPACE" --overrides="$FAST_TERM" --command -- sleep infinity
    kubectl wait --for=condition=Ready pod/nginx -n "$NAMESPACE" --timeout="${KUBECTL_TIMEOUT}s"
    "$VIFAL" $DEBUG --fsname "$VIFAL_SHELL_TEST" --attr-ttl "$CACHE_TTL" "$MOUNT1" 2>"$LOGS/vifal.log" &
    NGINX_FS1="$MOUNT1/$NAMESPACE/nginx/nginx"
    wait_for_fuse_sync "$NGINX_FS1"
}

teardown() {
    dump_vifal_logs "$?"
    "$VIFAL" unmount "$MOUNT2" 2>/dev/null || true
    "$VIFAL" unmount "$MOUNT1" 2>/dev/null || true
    rm -rf "$TEST_DIR"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false
}

trap teardown EXIT
setup

NGINX_FS2="$MOUNT2/$NAMESPACE/nginx/nginx"
mkdir -p "$MOUNT2"
"$VIFAL" $DEBUG --attr-ttl "$CACHE_TTL" --fsname vifal-2 "$MOUNT2" 2>"$LOGS/dualmount.log" &
PID2=$!
wait_for_fuse_sync "$MOUNT2/$NAMESPACE/nginx/nginx"

log_step "custom fsname in mount table"
mount | grep "$MOUNT2" | grep -q vifal-2

bg_pids=()

log_step "cross-mount file consistency"
for f in /etc/hostname /etc/os-release /etc/passwd /etc/group; do
    diff <(fuse cat "$NGINX_FS1$f") <(fuse cat "$NGINX_FS2$f") &
    bg_pids+=($!)
done
reap

log_step "cross-mount listing consistency"
for d in / /etc /usr; do
    diff <(fuse ls "$NGINX_FS1$d/") <(fuse ls "$NGINX_FS2$d/") &
    bg_pids+=($!)
done
reap

log_step "interleaved reads (20 per mount)"
for _ in $(seq 20); do
    fuse cat "$NGINX_FS1/etc/passwd" > /dev/null &
    bg_pids+=($!)
    fuse cat "$NGINX_FS2/etc/passwd" > /dev/null &
    bg_pids+=($!)
done
reap

log_step "mount1 correct while mount2 under load"
for _ in $(seq 10); do
    fuse cat "$NGINX_FS2/etc/os-release" > /dev/null &
    bg_pids+=($!)
done
diff <(fuse cat "$NGINX_FS1/etc/passwd") <(kexec cat /etc/passwd)
reap

log_step "both mounts healthy"
diff <(fuse cat "$NGINX_FS1/etc/hostname") <(kexec cat /etc/hostname)
diff <(fuse cat "$NGINX_FS2/etc/hostname") <(kexec cat /etc/hostname)

"$VIFAL" unmount --rm "$MOUNT2"
wait_process_dead "$PID2"
must_fail test -d "$MOUNT2"

mkdir -p "$MOUNT2"
"$VIFAL" $DEBUG --fsname "$VIFAL_SHELL_TEST" --attr-ttl "$CACHE_TTL" "$MOUNT2" 2>"$LOGS/dualmount_samename.log" &
PID2=$!
wait_for_fuse_sync "$MOUNT2/$NAMESPACE/nginx/nginx"

log_step "same default fsname: both mounts have same source"
SRC1="$(mount | grep "$MOUNT1" | awk '{print $1}')"
SRC2="$(mount | grep "$MOUNT2" | awk '{print $1}')"
[ "$SRC1" = "$SRC2" ]

log_step "same default fsname: both return identical data"
diff <(fuse cat "$NGINX_FS1/etc/hostname") <(fuse cat "$NGINX_FS2/etc/hostname")
diff <(fuse cat "$NGINX_FS1/etc/passwd") <(fuse cat "$NGINX_FS2/etc/passwd")

log_step "same default fsname: mount matches kubectl"
diff <(fuse cat "$NGINX_FS2/etc/hostname") <(kexec cat /etc/hostname)

"$VIFAL" unmount --rm "$MOUNT2"
wait_process_dead "$PID2"
must_fail test -d "$MOUNT2"
