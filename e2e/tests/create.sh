# Runtime file creation and special filenames.

NAMESPACE="vifal-create"
TEST_DIR=$(mktemp -d /tmp/vifal-create-XXXXXX)
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

log_step "file creation"
kexec sh -c "echo 'hello from fuse' > /tmp/fuse-created"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/fuse-created'"
diff <(fuse cat "$NGINX_FS/tmp/fuse-created") <(echo "hello from fuse")

log_step "UTF-8 content"
kexec sh -c "printf 'café الداخلة\n' > /tmp/fuse-utf8"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/fuse-utf8'"
diff <(fuse cat "$NGINX_FS/tmp/fuse-utf8") <(printf 'café الداخلة\n')

log_step "directory tree"
kexec sh -c "mkdir -p /tmp/fuse-dir/sub && touch /tmp/fuse-dir/a /tmp/fuse-dir/b /tmp/fuse-dir/sub/c"
wait_for_cache_ttl "test -d '$NGINX_FS/tmp/fuse-dir'"
diff <(fuse ls "$NGINX_FS/tmp/fuse-dir/") <(kexec ls /tmp/fuse-dir/)
diff <(fuse ls "$NGINX_FS/tmp/fuse-dir/sub/") <(kexec ls /tmp/fuse-dir/sub/)

log_step "names with spaces"
kexec sh -c "echo content > '/tmp/has spaces'"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/has spaces'"
diff <(fuse cat "$NGINX_FS/tmp/has spaces") <(echo content)

log_step "names with special characters"
kexec sh -c "echo ok > '/tmp/special-\$test'"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/special-\$test'"
diff <(fuse cat "$NGINX_FS/tmp/special-\$test") <(echo ok)

log_step "names with single quotes"
kexec sh -c "echo quoted > /tmp/it\\'s-a-test"
wait_for_cache_ttl "test -e \"$NGINX_FS/tmp/it's-a-test\""
diff <(fuse cat "$NGINX_FS/tmp/it's-a-test") <(echo quoted)

log_step "names with backticks and semicolons"
kexec sh -c "echo tricky > /tmp/back\\\`tick\\;semi"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/back\`tick;semi'"
diff <(fuse cat "$NGINX_FS/tmp/back\`tick;semi") <(echo tricky)

log_step "long filename (200 chars)"
LONG_NAME=$(printf 'x%.0s' $(seq 1 200))
kexec sh -c "echo longfile > /tmp/$LONG_NAME"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/$LONG_NAME'"
diff <(fuse cat "$NGINX_FS/tmp/$LONG_NAME") <(echo longfile)

log_step "unicode filename"
kexec sh -c "echo data > /tmp/café-طرفاية"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/café-طرفاية'"
diff <(fuse cat "$NGINX_FS/tmp/café-طرفاية") <(echo data)

log_step "hardlinks appear as regular files"
kexec sh -c "echo linkdata > /tmp/hl-orig && ln /tmp/hl-orig /tmp/hl-link"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/hl-link'"
fuse test -f "$NGINX_FS/tmp/hl-link"
diff <(fuse cat "$NGINX_FS/tmp/hl-link") <(echo linkdata)
diff <(fuse cat "$NGINX_FS/tmp/hl-link") <(fuse cat "$NGINX_FS/tmp/hl-orig")
