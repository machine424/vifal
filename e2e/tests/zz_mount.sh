# Mount/unmount lifecycle.

NAMESPACE="vifal-mount"
TEST_DIR=$(mktemp -d /tmp/vifal-mount-XXXXXX)
MOUNT="$TEST_DIR/mount"
LOGS="$TEST_DIR"

setup() {
    "$VIFAL" unmount "$MOUNT" 2>/dev/null || true
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    mkdir -p "$MOUNT"
    kubectl create namespace "$NAMESPACE"
    kubectl run nginx --image="$IMAGE" -n "$NAMESPACE" --overrides="$FAST_TERM" --command -- sleep infinity
    kubectl wait --for=condition=Ready pod/nginx -n "$NAMESPACE" --timeout="${KUBECTL_TIMEOUT}s"
    "$VIFAL" --fsname "$VIFAL_SHELL_TEST" --attr-ttl "$CACHE_TTL" "$MOUNT" 2>"$LOGS/vifal.log" &
    VIFAL_PID=$!
    wait_for_fuse_sync "$MOUNT/$NAMESPACE/nginx/nginx"
}

teardown() {
    dump_vifal_logs "$?"
    "$VIFAL" unmount "$MOUNT" 2>/dev/null || true
    rm -rf "$TEST_DIR"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false
}

trap teardown EXIT
setup

remount() {
    mkdir -p "$MOUNT"
    "$VIFAL" --fsname "$VIFAL_SHELL_TEST" --attr-ttl "$CACHE_TTL" "$MOUNT" 2>"$LOGS/zz-${1}.log" &
    VIFAL_PID=$!
    wait_for_fuse_sync "$MOUNT/$NAMESPACE/nginx/nginx"
}

log_step "SIGTERM unmount"
kill -TERM "$VIFAL_PID"
wait_process_dead "$VIFAL_PID"
check_clean_unmount "$MOUNT"

remount sigint

log_step "double mount fails"
must_fail "$VIFAL" $DEBUG "$MOUNT"

log_step "SIGINT unmount"
kill -INT "$VIFAL_PID"
wait_process_dead "$VIFAL_PID"
check_clean_unmount "$MOUNT"

remount unmount
log_step "unmount subcommand"
"$VIFAL" unmount "$MOUNT"
wait_process_dead "$VIFAL_PID"
check_clean_unmount "$MOUNT"

remount rm
log_step "unmount --rm removes directory"
"$VIFAL" unmount --rm "$MOUNT"
wait_process_dead "$VIFAL_PID"
must_fail test -d "$MOUNT"

remount force
log_step "unmount --force"
"$VIFAL" unmount --force "$MOUNT"
wait_process_dead "$VIFAL_PID"
check_clean_unmount "$MOUNT"

remount force-rm
log_step "unmount --force --rm"
"$VIFAL" unmount --force --rm "$MOUNT"
wait_process_dead "$VIFAL_PID"
must_fail test -d "$MOUNT"

mkdir -p "$MOUNT"
log_step "--debug flag"
"$VIFAL" --debug --fsname "$VIFAL_SHELL_TEST" --attr-ttl "$CACHE_TTL" "$MOUNT" 2>"$LOGS/zz-debug.log" &
VIFAL_PID=$!
wait_for_fuse_sync "$MOUNT/$NAMESPACE/nginx/nginx"
diff <(fuse cat "$MOUNT/$NAMESPACE/nginx/nginx/etc/hostname") <(kexec cat /etc/hostname)
"$VIFAL" unmount "$MOUNT"
wait_process_dead "$VIFAL_PID"
check_clean_unmount "$MOUNT"

log_step "logs go to stderr, not stdout"
mkdir -p "$MOUNT"
"$VIFAL" $DEBUG --fsname "$VIFAL_SHELL_TEST" --attr-ttl "$CACHE_TTL" "$MOUNT" >"$LOGS/zz-stdout.log" 2>"$LOGS/zz-stderr.log" &
VIFAL_PID=$!
wait_for_fuse_sync "$MOUNT/$NAMESPACE/nginx/nginx"
fuse cat "$MOUNT/$NAMESPACE/nginx/nginx/etc/hostname" > /dev/null
"$VIFAL" unmount "$MOUNT"
wait_process_dead "$VIFAL_PID"
grep -q "mounted at" "$LOGS/zz-stderr.log"
[ ! -s "$LOGS/zz-stdout.log" ]
grep -q "$VIFAL_LOG_PREFIX" "$LOGS/zz-stderr.log"

log_step "--help exposes only expected flags"
help_flags() { "$@" 2>&1 | grep -o "^  *--[^ ]*" | sort | xargs; }
[ "$(help_flags "$VIFAL" --help)" = "--attr-ttl --cluster --context --debug --fsname --kubeconfig" ]
[ "$(help_flags "$VIFAL" unmount --help)" = "--force --rm" ]

log_step "CLI error handling"
mkdir -p "$MOUNT"
must_fail "$VIFAL" unmount "$MOUNT"
must_fail "$VIFAL"
must_fail "$VIFAL" unmount
"$VIFAL" unmount --rm "$MOUNT"
# macFUSE auto-creates nonexistent mountpoints, so this only applies to Linux.
if [ "$UNAME_S" != "Darwin" ]; then
    must_fail "$VIFAL" /tmp/no-such-dir-vifal
fi
mkdir -p "$MOUNT"
must_fail "$VIFAL" --kubeconfig /tmp/no-such-kubeconfig "$MOUNT"
must_fail "$VIFAL" --context no-such-context "$MOUNT"

log_step "mount/unmount 2 cycles"
for i in 1 2; do
    remount "cycle-$i"
    diff <(fuse cat "$MOUNT/$NAMESPACE/nginx/nginx/etc/hostname") <(kexec cat /etc/hostname)
    "$VIFAL" unmount "$MOUNT"
    wait_process_dead "$VIFAL_PID"
    check_clean_unmount "$MOUNT"
done

log_step "mount/unmount without --fsname (default)"
mkdir -p "$MOUNT"
"$VIFAL" $DEBUG --attr-ttl "$CACHE_TTL" "$MOUNT" 2>"$LOGS/zz-default.log" &
VIFAL_PID=$!
wait_for_fuse_sync "$MOUNT/$NAMESPACE/nginx/nginx"
diff <(fuse cat "$MOUNT/$NAMESPACE/nginx/nginx/etc/hostname") <(kexec cat /etc/hostname)
grep -q " vifal: " "$LOGS/zz-default.log"
"$VIFAL" unmount "$MOUNT"
wait_process_dead "$VIFAL_PID"
check_clean_unmount "$MOUNT"
