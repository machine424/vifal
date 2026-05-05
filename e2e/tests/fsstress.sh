# Filesystem stress: large directories and deep nesting.

NAMESPACE="vifal-fsstress"
TEST_DIR=$(mktemp -d /tmp/vifal-fsstress-XXXXXX)
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

log_step "large directory listing (/usr/bin)"
fuse_count=$(fuse ls "$NGINX_FS/usr/bin/" | line_count)
exec_count=$(kexec ls /usr/bin/ | line_count)
[ "$fuse_count" = "$exec_count" ]

log_step "every listed file in /etc has valid attributes"
for entry in "$NGINX_FS/etc/"*; do
    fuse test -e "$entry" || fuse test -L "$entry"
done

log_step "64 entries in one directory"
kexec sh -c "mkdir -p /tmp/bigdir && for i in \$(seq 1 64); do touch /tmp/bigdir/file-\$i; done"
wait_for_cache_ttl "test -d '$NGINX_FS/tmp/bigdir'"
fuse_count=$(fuse ls "$NGINX_FS/tmp/bigdir/" | line_count)
[ "$fuse_count" = "64" ]
diff <(fuse ls "$NGINX_FS/tmp/bigdir/" | sort) <(kexec ls /tmp/bigdir/ | sort)

log_step "20 levels of nested directories"
kexec sh -c "p=/tmp/deep; for i in \$(seq 1 20); do p=\$p/d\$i; done; mkdir -p \$p; echo ok > \$p/leaf"
deep_path="$NGINX_FS/tmp/deep"
for i in $(seq 1 20); do deep_path="$deep_path/d$i"; done
wait_for_cache_ttl "test -d '$NGINX_FS/tmp/deep'"
diff <(fuse cat "$deep_path/leaf") <(echo ok)
