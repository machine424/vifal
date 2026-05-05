# Edge cases: errors, path normalization, special files, and content staleness.

NAMESPACE="vifal-edge"
TEST_DIR=$(mktemp -d /tmp/vifal-edge-XXXXXX)
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

log_step "non-existent file"
must_fail cat "$NGINX_FS/this-does-not-exist"

log_step "non-existent namespace and pod"
must_fail ls "$MOUNT/no-such-namespace"
must_fail ls "$MOUNT/$NAMESPACE/no-such-pod"

log_step "cat a directory"
must_fail cat "$NGINX_FS/etc"

log_step "trailing slash on file"
must_fail ls "$NGINX_FS/etc/hostname/"

log_step "path traversal with .."
diff <(fuse cat "$NGINX_FS/etc/../etc/hostname") <(fuse cat "$NGINX_FS/etc/hostname")
diff <(fuse cat "$NGINX_FS/usr/../etc/hostname") <(fuse cat "$NGINX_FS/etc/hostname")

log_step "redundant slashes"
diff <(fuse cat "$NGINX_FS///etc///hostname") <(fuse cat "$NGINX_FS/etc/hostname")

log_step "deleted file: read fails, then disappears from listing"
VANISH="$NGINX_FS/tmp/vanish-test"
kexec sh -c "echo vanish > /tmp/vanish-test"
wait_for_cache_ttl "test -e '$VANISH'"
diff <(fuse cat "$VANISH") <(echo vanish)
kexec rm /tmp/vanish-test
must_fail cat "$VANISH"
wait_for_cache_ttl "! test -e '$VANISH'"

log_step "replaced file shows new content"
REPLACE="$NGINX_FS/tmp/replace-test"
kexec sh -c "echo version-1 > /tmp/replace-test"
wait_for_cache_ttl "test -e '$REPLACE'"
diff <(fuse cat "$REPLACE") <(echo "version-1")
kexec sh -c "echo version-2 > /tmp/replace-test"
wait_for_cache_ttl "test -e '$REPLACE'"
diff <(fuse cat "$REPLACE") <(echo "version-2")

log_step "symlink-swap update (configmap/secret pattern)"
# Kubelet updates configmaps by writing a new timestamped dir and atomically
# swapping a ..data symlink. Uses absolute targets like real kubelet:
#   /tmp/cm/key -> /tmp/cm/..data/key
#   /tmp/cm/..data -> /tmp/cm/..cm-v1    (then swapped to ..cm-v2)
CM_KEY="$NGINX_FS/tmp/cm/key"
kexec sh -c "mkdir -p /tmp/cm/..cm-v1 && echo val-1 > /tmp/cm/..cm-v1/key && ln -sfn /tmp/cm/..cm-v1 /tmp/cm/..data && ln -sf /tmp/cm/..data/key /tmp/cm/key"
wait_for_cache_ttl "test -e '$CM_KEY'"
diff <(fuse cat "$CM_KEY") <(echo "val-1")
kexec sh -c "mkdir -p /tmp/cm/..cm-v2 && echo val-2 > /tmp/cm/..cm-v2/key && ln -sfn /tmp/cm/..cm-v2 /tmp/cm/..data"
wait_for_cache_ttl "cat '$CM_KEY' 2>/dev/null | grep -q val-2"
diff <(fuse cat "$CM_KEY") <(echo "val-2")

log_step "many errors in a row"
must_fail cat "$NGINX_FS/aaa"
must_fail cat "$NGINX_FS/bbb"
must_fail cat "$NGINX_FS/ccc"
must_fail ls "$MOUNT/no-such-namespace-2"

log_step "stderr does not block result"
kexec sh -c "echo visible > /tmp/edge-stderr-test && echo warning >&2"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/edge-stderr-test'"
diff <(fuse cat "$NGINX_FS/tmp/edge-stderr-test") <(echo visible)

log_step "FIFO read: blocked on Linux, rejected on macOS (no writer)"
FIFO="$NGINX_FS/tmp/edge-fifo"
kexec mkfifo /tmp/edge-fifo
wait_for_cache_ttl "test -e '$FIFO'"
if [ "$UNAME_S" = "Darwin" ]; then
    # macFUSE returns EPERM for special file I/O.
    must_fail cat "$FIFO"
else
    # Linux FUSE routes the read through vifal, dd blocks on the FIFO.
    must_hang cat "$FIFO"
fi

log_step "device files: visible in listing but reading fails"
fuse ls "$NGINX_FS/dev/" | grep -q "null"
fuse ls "$NGINX_FS/dev/" | grep -q "zero"
must_fail cat "$NGINX_FS/dev/null"
must_fail cat "$NGINX_FS/dev/zero"

log_step "filename with arrow (ambiguous stat %N output)"
kexec sh -c 'echo arrow > "/tmp/edge -> arrow"'
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/edge -> arrow'"
diff <(fuse cat "$NGINX_FS/tmp/edge -> arrow") <(echo arrow)
fuse ls "$NGINX_FS/tmp/" | grep -q "edge -> arrow"

log_step "newline in filename is skipped but listing succeeds"
NLTEST="$NGINX_FS/opt/nltest"
kexec sh -c "$(printf 'mkdir -p /opt/nltest && echo ok > /opt/nltest/good && echo x > "/opt/nltest/bad\nname"')"
wait_for_cache_ttl "test -e '$NLTEST/good'"
fuse ls "$NLTEST/" | grep -q good
! fuse ls "$NLTEST/" | grep -q bad

log_step "read past EOF returns empty, not error"
EOF_FILE="$NGINX_FS/tmp/eof-test"
kexec sh -c "printf '12345' > /tmp/eof-test"
wait_for_cache_ttl "test -e '$EOF_FILE'"
r=$(fuse dd if="$EOF_FILE" bs=1 skip=5 count=1 2>/dev/null | wc -c | tr -d ' ')
[ "$r" = "0" ]
r=$(fuse dd if="$EOF_FILE" bs=1 skip=100 count=1 2>/dev/null | wc -c | tr -d ' ')
[ "$r" = "0" ]

log_step "delimiter byte in filename is skipped but listing succeeds"
kexec sh -c "$(printf 'echo data > /opt/nltest/clean && printf data > "/opt/nltest/d\x1dfile"')"
wait_for_cache_ttl "test -e '$NLTEST/clean'"
fuse ls "$NLTEST/" | grep -q clean
! fuse ls "$NLTEST/" | grep -qF $'\x1d'

log_step "procfs files with stat size 0 return real content"
content=$(fuse cat "$NGINX_FS/proc/version")
[ -n "$content" ]
kversion=$(kexec cat /proc/version)
[ "$content" = "$kversion" ]

log_step "procfs cpuinfo is readable and non-empty"
fuse cat "$NGINX_FS/proc/cpuinfo" | grep -qi "processor\|bogomips\|model"

log_step "procfs meminfo is readable and non-empty"
fuse cat "$NGINX_FS/proc/meminfo" | grep -qi "memtotal\|memfree"

log_step "file that grew since last stat returns new content"
GROW="$NGINX_FS/tmp/grow-test"
kexec sh -c "printf 'short' > /tmp/grow-test"
wait_for_cache_ttl "test -e '$GROW'"
diff <(fuse cat "$GROW") <(printf 'short')
kexec sh -c "printf 'short + now much longer content appended here' > /tmp/grow-test"
wait_for_cache_ttl "test -e '$GROW'"
diff <(fuse cat "$GROW") <(printf 'short + now much longer content appended here')

log_step "service account token is readable (same as kubectl exec)"
SA_DIR="$NGINX_FS/var/run/secrets/kubernetes.io/serviceaccount"
fuse test -d "$SA_DIR"
fuse cat "$SA_DIR/token" | grep -q .
[ "$(fuse cat "$SA_DIR/namespace")" = "$NAMESPACE" ]
diff <(fuse cat "$SA_DIR/ca.crt") <(kexec cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

log_step "FS healthy after all errors"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(kexec cat /etc/hostname)
diff <(fuse ls "$NGINX_FS/etc/") <(kexec ls /etc/)
