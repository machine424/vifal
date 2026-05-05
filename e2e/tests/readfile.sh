# File reading: correctness across file types, sizes, and offsets.

NAMESPACE="vifal-readfile"
TEST_DIR=$(mktemp -d /tmp/vifal-readfile-XXXXXX)
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

log_step "content matches container"
for file in /etc/os-release /etc/hostname /etc/passwd /etc/nginx/nginx.conf /etc/nginx/conf.d/default.conf; do
    diff <(fuse cat "$NGINX_FS/$file") <(kexec cat "$file")
done

log_step "empty file"
kexec sh -c "> /tmp/rf-empty"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-empty'"
[ "$(file_size "$NGINX_FS/tmp/rf-empty")" = "0" ]

log_step "binary content (null bytes)"
kexec sh -c "dd if=/dev/urandom bs=1 count=64 2> /dev/null > /tmp/rf-bin"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-bin'"
diff <(fuse cat "$NGINX_FS/tmp/rf-bin" | xxd) <(kexec cat /tmp/rf-bin | xxd)

log_step "offset reads"
size=$(file_size "$NGINX_FS/etc/hostname")
diff <(fuse dd if="$NGINX_FS/etc/hostname" bs=1 count=1 2> /dev/null) \
     <(kexec dd if=/etc/hostname bs=1 count=1 2> /dev/null)
diff <(fuse dd if="$NGINX_FS/etc/hostname" bs=1 skip=$((size - 1)) count=1 2> /dev/null) \
     <(kexec dd if=/etc/hostname bs=1 skip=$((size - 1)) count=1 2> /dev/null)
diff <(fuse dd if="$NGINX_FS/etc/passwd" bs=1 skip=50 count=1 2> /dev/null) \
     <(kexec dd if=/etc/passwd bs=1 skip=50 count=1 2> /dev/null)
diff <(fuse head -c 100 "$NGINX_FS/etc/passwd") <(kexec head -c 100 /etc/passwd)
diff <(fuse tail -c 100 "$NGINX_FS/etc/passwd") <(kexec tail -c 100 /etc/passwd)

log_step "mid-file and unaligned ranges"
kexec sh -c "seq 1 1000 > /tmp/rf-seq"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-seq'"
diff <(fuse head -c 300 "$NGINX_FS/tmp/rf-seq" | tail -c 200) \
     <(kexec sh -c "head -c 300 /tmp/rf-seq | tail -c 200")
diff <(fuse head -c 110 "$NGINX_FS/tmp/rf-seq" | tail -c 73) \
     <(kexec sh -c "head -c 110 /tmp/rf-seq | tail -c 73")

log_step "reads at and past EOF"
[ -z "$(fuse tail -c +100000 "$NGINX_FS/tmp/rf-seq")" ]
diff <(fuse tail -c 10 "$NGINX_FS/tmp/rf-seq") \
     <(kexec tail -c 10 /tmp/rf-seq)

log_step "no content caching (DIRECT_IO)"
kexec sh -c "echo before > /tmp/rf-directio"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-directio'"
diff <(fuse cat "$NGINX_FS/tmp/rf-directio") <(echo before)
kexec sh -c "echo after > /tmp/rf-directio"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-directio'"
diff <(fuse cat "$NGINX_FS/tmp/rf-directio") <(echo after)

log_step "file grows in container"
kexec sh -c "echo line1 > /tmp/rf-grow"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-grow'"
diff <(fuse cat "$NGINX_FS/tmp/rf-grow") <(echo line1)
kexec sh -c "echo line2 >> /tmp/rf-grow"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-grow'"
diff <(fuse cat "$NGINX_FS/tmp/rf-grow") <(printf 'line1\nline2\n')

log_step "large file read (1MB)"
kexec sh -c "dd if=/dev/urandom of=/tmp/rf-large bs=1048576 count=1 2>/dev/null"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-large'"
[ "$(file_size "$NGINX_FS/tmp/rf-large")" = "1048576" ]
diff <(dd if="$NGINX_FS/tmp/rf-large" bs=1048576 2>/dev/null | md5sum) <(kexec cat /tmp/rf-large | md5sum)

log_step "read unreadable path"
must_fail cat "$NGINX_FS/proc/kcore"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(kexec cat /etc/hostname)

log_step "file without trailing newline"
kexec sh -c "printf 'no-newline-at-end' > /tmp/rf-nonl"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-nonl'"
diff <(fuse cat "$NGINX_FS/tmp/rf-nonl") <(kexec cat /tmp/rf-nonl)

log_step "file that looks like a hex marker"
kexec sh -c "printf '%0128x\\n' 0 > /tmp/rf-fakemarker"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-fakemarker'"
diff <(fuse cat "$NGINX_FS/tmp/rf-fakemarker") <(kexec cat /tmp/rf-fakemarker)

log_step "file with many empty lines"
kexec sh -c "printf '\\n\\n\\n\\n\\n' > /tmp/rf-blanks"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-blanks'"
diff <(fuse cat "$NGINX_FS/tmp/rf-blanks") <(kexec cat /tmp/rf-blanks)

log_step "blank lines between content"
kexec sh -c "printf 'first\\n\\n\\nmiddle\\n\\nlast\\n' > /tmp/rf-blankmix"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-blankmix'"
diff <(fuse cat "$NGINX_FS/tmp/rf-blankmix") <(kexec cat /tmp/rf-blankmix)

log_step "leading blank lines"
kexec sh -c "printf '\\n\\n\\ncontent\\n' > /tmp/rf-leadblanks"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-leadblanks'"
diff <(fuse cat "$NGINX_FS/tmp/rf-leadblanks") <(kexec cat /tmp/rf-leadblanks)

log_step "trailing blank lines"
kexec sh -c "printf 'content\\n\\n\\n' > /tmp/rf-trailblanks"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-trailblanks'"
diff <(fuse cat "$NGINX_FS/tmp/rf-trailblanks") <(kexec cat /tmp/rf-trailblanks)

log_step "single newline file"
kexec sh -c "printf '\\n' > /tmp/rf-onenl"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-onenl'"
diff <(fuse cat "$NGINX_FS/tmp/rf-onenl") <(kexec cat /tmp/rf-onenl)

log_step "whitespace-only file"
kexec sh -c "printf '   \\t\\t   ' > /tmp/rf-ws"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-ws'"
diff <(fuse cat "$NGINX_FS/tmp/rf-ws") <(kexec cat /tmp/rf-ws)

log_step "lines with trailing whitespace"
kexec sh -c "printf 'line1   \\nline2\\t\\nline3\\n' > /tmp/rf-trailws"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-trailws'"
diff <(fuse cat "$NGINX_FS/tmp/rf-trailws") <(kexec cat /tmp/rf-trailws)

log_step "CRLF line endings"
kexec sh -c "printf 'line1\\r\\nline2\\r\\nline3\\r\\n' > /tmp/rf-crlf"
wait_for_cache_ttl "test -e '$NGINX_FS/tmp/rf-crlf'"
diff <(fuse cat "$NGINX_FS/tmp/rf-crlf") <(kexec cat /tmp/rf-crlf)

log_step "post-edge-case health check"
diff <(fuse cat "$NGINX_FS/etc/hostname") <(kexec cat /etc/hostname)
