# Symlinks: verifies Readlink and symlink resolution through FUSE.
# Absolute targets are rewritten to point through the FUSE mount.

NAMESPACE="vifal-symlink"
TEST_DIR=$(mktemp -d /tmp/vifal-symlink-XXXXXX)
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

log_step "existing symlinks in / are followable"
# /lib, /sbin, etc. are typically relative symlinks in Debian-based images.
# Verify each one can be followed (ls succeeds through the symlink).
for entry in "$NGINX_FS/"*; do
    fuse test -L "$entry" || continue
    fuse ls "$entry/" > /dev/null
done

log_step "absolute symlink to file: readlink is rewritten"
SYM_ABS_FILE="$NGINX_FS/tmp/sym-abs-file"
kexec sh -c "ln -sf /etc/hostname /tmp/sym-abs-file"
wait_for_cache_ttl "test -L '$SYM_ABS_FILE'"
got=$(fuse readlink "$SYM_ABS_FILE")
[ "$got" = "$NGINX_FS/etc/hostname" ] || { echo "FAIL: readlink got [$got] want [$NGINX_FS/etc/hostname]"; exit 1; }

log_step "absolute symlink to file: cat returns target content"
diff <(fuse cat "$SYM_ABS_FILE") <(kexec cat /etc/hostname)
diff <(fuse cat "$SYM_ABS_FILE") <(fuse cat "$NGINX_FS/etc/hostname")

log_step "absolute symlink to directory: ls returns target listing"
SYM_ABS_DIR="$NGINX_FS/tmp/sym-abs-dir"
kexec sh -c "ln -sf /etc /tmp/sym-abs-dir"
wait_for_cache_ttl "test -L '$SYM_ABS_DIR'"
diff <(fuse ls "$SYM_ABS_DIR/") <(fuse ls "$NGINX_FS/etc/")

log_step "absolute symlink to directory: cat file through it"
diff <(fuse cat "$SYM_ABS_DIR/hostname") <(kexec cat /etc/hostname)

log_step "relative symlink to file: cat returns target content"
SYM_REL_FILE="$NGINX_FS/tmp/sym-rel-file"
kexec sh -c "ln -sf ../etc/hostname /tmp/sym-rel-file"
wait_for_cache_ttl "test -L '$SYM_REL_FILE'"
diff <(fuse readlink "$SYM_REL_FILE") <(echo "../etc/hostname")
diff <(fuse cat "$SYM_REL_FILE") <(kexec cat /etc/hostname)

log_step "relative symlink to directory: ls returns target listing"
SYM_REL_DIR="$NGINX_FS/tmp/sym-rel-dir"
kexec sh -c "ln -sf ../etc /tmp/sym-rel-dir"
wait_for_cache_ttl "test -L '$SYM_REL_DIR'"
diff <(fuse ls "$SYM_REL_DIR/") <(fuse ls "$NGINX_FS/etc/")

log_step "chained symlinks resolve end-to-end"
# a -> b -> /etc/hostname (absolute), follow both hops
SYM_CHAIN="$NGINX_FS/tmp/sym-chain-a"
kexec sh -c "ln -sf /etc/hostname /tmp/sym-chain-b && ln -sf /tmp/sym-chain-b /tmp/sym-chain-a"
wait_for_cache_ttl "test -L '$SYM_CHAIN'"
diff <(fuse cat "$SYM_CHAIN") <(kexec cat /etc/hostname)

log_step "dangling absolute symlink"
SYM_DANGLE="$NGINX_FS/tmp/sym-dangle"
kexec sh -c "ln -sf /nonexistent/target /tmp/sym-dangle"
wait_for_cache_ttl "test -L '$SYM_DANGLE'"
fuse test -L "$SYM_DANGLE"
diff <(fuse readlink "$SYM_DANGLE") <(echo "$NGINX_FS/nonexistent/target")
must_fail cat "$SYM_DANGLE"

log_step "dangling relative symlink"
SYM_DANGLE_REL="$NGINX_FS/tmp/sym-dangle-rel"
kexec sh -c "ln -sf ./no-such-file /tmp/sym-dangle-rel"
wait_for_cache_ttl "test -L '$SYM_DANGLE_REL'"
fuse test -L "$SYM_DANGLE_REL"
must_fail cat "$SYM_DANGLE_REL"

log_step "health check after symlink tests"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(kexec cat /etc/hostname)
