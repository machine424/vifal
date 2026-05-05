# Shared helpers for standalone e2e tests.

# Run a command inside the default nginx container.
kexec() { kubectl exec nginx -n "$NAMESPACE" -c nginx -- "$@"; }
kexec_web() { kubectl exec multi -n "$NAMESPACE" -c web -- "$@"; }
kexec_sidecar() { kubectl exec multi -n "$NAMESPACE" -c sidecar -- "$@"; }
kexec_worker() { kubectl exec worker -n "$NAMESPACE" -c worker -- "$@"; }

# Run a command to catch hangs in FUSE operations under test.
fuse() { timeout "$FUSE_TIMEOUT" "$@"; }

# Wait for FUSE directory/attribute cache to expire.
# With a condition: polls until it becomes true (or CACHE_WAIT timeout).
# Without arguments: blind sleep for CACHE_WAIT (use only when there is no observable condition).
wait_for_cache_ttl() {
    if [ $# -eq 0 ]; then
        sleep "$CACHE_WAIT"
        return
    fi
    timeout "$POLLING_TIMEOUT" bash -c "until $*; do sleep 0.2; done"
}

# Poll until a FUSE path appears (exists or is a symlink).
wait_for_fuse_sync() { timeout "$POLLING_TIMEOUT" bash -c "until [ -e '$1' ] || [ -L '$1' ]; do sleep 0.2; done"; }

# Poll until a process is no longer running.
wait_process_dead() { timeout "$POLLING_TIMEOUT" bash -c "while kill -0 $1 2> /dev/null; do sleep 0.5; done"; }

# Verify a FUSE operation fails without hanging. Exit 124 = timeout = hang, not a real failure.
must_fail() { local rc=0; timeout "$FUSE_TIMEOUT" "$@" 2> /dev/null || rc=$?; [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; }

# Verify a FUSE operation blocks (e.g. FIFO with no writer). Exit 124 = timeout = expected.
must_hang() { local rc=0; timeout "$FUSE_TIMEOUT" "$@" 2> /dev/null || rc=$?; [ "$rc" -eq 124 ]; }

# Return the byte size of a file via the FUSE mount.
file_size() { fuse wc -c "$1" | awk '{print $1}'; }

# Count lines from stdin.
line_count() { wc -l | awk '{print $1}'; }

# Wait for a mountpoint to disappear and verify the directory is empty.
check_clean_unmount() {
    timeout "$POLLING_TIMEOUT" bash -c "while mount | grep -q '$1'; do sleep 0.5; done"
    [ -d "$1" ]
    [ -z "$(ls -A "$1")" ]
}

# Print a timestamped test step label.
log_step() { echo "$(date -u '+%Y/%m/%d %H:%M:%S') $*"; }

# Dump vifal log lines (excluding go-fuse debug noise) on failure.
# Call at the start of teardown: dump_vifal_logs "$?"
dump_vifal_logs() {
    if [ "$1" -ne 0 ] && [ -f "$LOGS/vifal.log" ]; then
        echo "--- vifal logs ---" >&2
        grep "$VIFAL_LOG_PREFIX" "$LOGS/vifal.log" >&2 || true
        echo "--- end vifal logs ---" >&2
    fi
}

# Wait for all PIDs in bg_pids, return non-zero if any failed.
reap() {
    local rc=0
    for pid in "${bg_pids[@]}"; do wait "$pid" || rc=1; done
    bg_pids=()
    return $rc
}

# Resolve GNU stat (Linux: stat, macOS: gstat from coreutils).
resolve_gnu_stat() {
    if stat -c '%s' /dev/null > /dev/null 2>&1; then
        echo stat
    elif command -v gstat > /dev/null 2>&1; then
        echo gstat
    else
        echo "FAIL: requires GNU stat (stat -c) or gstat" >&2
        exit 1
    fi
}

export -f kexec kexec_web kexec_sidecar kexec_worker fuse must_fail must_hang wait_for_cache_ttl wait_for_fuse_sync wait_process_dead file_size line_count check_clean_unmount log_step dump_vifal_logs reap resolve_gnu_stat
