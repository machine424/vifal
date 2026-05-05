# Directory listing, mount metadata, and read-only enforcement.

NAMESPACE="vifal-readdir"
TEST_DIR=$(mktemp -d /tmp/vifal-readdir-XXXXXX)
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
    wait_for_fuse_sync "$NGINX_FS"
    wait_for_fuse_sync "$MOUNT/$NAMESPACE/worker/worker"
    wait_for_fuse_sync "$MOUNT/$NAMESPACE/multi/web"
}

teardown() {
    dump_vifal_logs "$?"
    "$VIFAL" unmount "$MOUNT" 2>/dev/null || true
    rm -rf "$TEST_DIR"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false
}

trap teardown EXIT
setup

log_step "mount visible"
mount | grep -q "$(realpath "$MOUNT")"
fuse df "$MOUNT" > /dev/null
[ "$UNAME_S" = "Darwin" ] || findmnt "$MOUNT" > /dev/null

log_step "mount source equals fsname://context@server"
KUBE_CTX="$(kubectl config current-context)"
KUBE_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
EXPECTED="$VIFAL_SHELL_TEST://$KUBE_CTX@$KUBE_SERVER"
ACTUAL="$(mount | grep "$(realpath "$MOUNT") " | awk '{print $1}')"
[ "$ACTUAL" = "$EXPECTED" ]

log_step "df does not report 100% usage"
pct=$(fuse df "$MOUNT" | awk 'NR==2 {print $5}' | tr -d '%')
[ "$pct" -lt 100 ]

log_step "FUSE tree hierarchy"
fuse ls "$MOUNT" | grep -qx "$NAMESPACE"
diff <(fuse ls "$MOUNT/$NAMESPACE") <(printf 'multi\nnginx\nworker\n')
diff <(fuse ls "$MOUNT/$NAMESPACE/nginx") <(echo "nginx")
diff <(fuse ls "$MOUNT/$NAMESPACE/worker") <(echo "worker")
diff <(fuse ls "$MOUNT/$NAMESPACE/multi") <(printf 'sidecar\nweb\n')

log_step "listings match container"
for d in / /etc /usr /usr/share /etc/nginx /etc/nginx/conf.d; do
    diff <(fuse ls "$NGINX_FS$d/") <(kexec ls "$d/")
done

log_step "hidden files"
diff <(fuse ls -a "$NGINX_FS/etc/" | grep -v '^\.\.\?$') <(kexec ls -a /etc/ | grep -v '^\.\.\?$')

log_step "glob expansion"
test "$(echo "$MOUNT/$NAMESPACE/ngin"*)" = "$MOUNT/$NAMESPACE/nginx"
echo "$MOUNT/"*/ | grep -q "$NAMESPACE"
test "$(echo "$MOUNT/$NAMESPACE/nginx/ngin"*)" = "$MOUNT/$NAMESPACE/nginx/nginx"

log_step "writes are rejected"
must_fail touch "$NGINX_FS/tmp/fuse-write-test"
must_fail mkdir "$NGINX_FS/tmp/fuse-write-dir"

log_step "reads still work after write attempts"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(kexec cat /etc/hostname)
diff <(fuse ls "$NGINX_FS/etc/") <(kexec ls /etc/)

# macOS mount output doesn't include "ro" for FUSE mounts.
if [ "$UNAME_S" != "Darwin" ]; then
    log_step "mount is read-only"
    mount | grep "$(realpath "$MOUNT")" | grep -qw "ro"
fi
