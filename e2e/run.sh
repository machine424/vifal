#!/bin/bash
set -euo pipefail

DEBUG="${VIFAL_E2E_DEBUG:+--debug}"
[ -n "$DEBUG" ] && set -x

TESTS=()
for arg in "$@"; do
    TESTS+=("$arg")
done

START_TIME=$(date +%s)
DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR=$(mktemp -d /tmp/vifal-run-XXXXXX)
VIFAL="$RUN_DIR/bin"
IMAGE="${E2E_IMAGE:-nginx:1.27.4-bookworm}"
UNAME_S="$(uname -s)"
CACHE_TTL="${CACHE_TTL:-1s}"
CACHE_WAIT="${CACHE_WAIT:-2}"
FUSE_TIMEOUT="${FUSE_TIMEOUT:-3}"
POLLING_TIMEOUT=15
KUBECTL_TIMEOUT=90
FAST_TERM=$(printf '%s' '{"spec":{"terminationGracePeriodSeconds":1}}')

VIFAL_SHELL_TEST="${VIFAL_SHELL_TEST:-vifal-shell-test}"
VIFAL_LOG_PREFIX=" ${VIFAL_SHELL_TEST}: "

export CACHE_TTL CACHE_WAIT DEBUG DIR FAST_TERM FUSE_TIMEOUT IMAGE KUBECTL_TIMEOUT POLLING_TIMEOUT UNAME_S VIFAL VIFAL_SHELL_TEST VIFAL_LOG_PREFIX

# shellcheck source=./lib.sh
source "$DIR/lib.sh"

build_vifal() {
    make -s build BINARY="$VIFAL"
}

run_test_shell() {
    if [ -n "$DEBUG" ]; then
        bash -euxo pipefail -c "source '$1'"
        return
    fi
    bash -euo pipefail -c "source '$1'"
}

teardown() {
    rm -rf "$RUN_DIR"
}

trap 'exit 130' INT TERM
trap teardown EXIT

build_vifal

# Sanity-check must_fail().
rc=0; timeout 1 sleep 10 || rc=$?
[ "$rc" = 124 ] || { echo "timeout exit code is $rc, expected 124"; exit 1; }
must_fail true && { echo "must_fail accepted exit 0"; exit 1; }
must_fail timeout 1 sleep 10 && { echo "must_fail accepted exit 124 (timeout)"; exit 1; }
must_fail false || { echo "must_fail rejected a real failure"; exit 1; }

if [ ${#TESTS[@]} -gt 0 ]; then
    TEST_FILES=()
    for t in "${TESTS[@]}"; do
        TEST_FILES+=("$DIR/tests/${t%.sh}.sh")
    done
else
    TEST_FILES=("$DIR/tests/"*.sh)
fi
TOTAL=${#TEST_FILES[@]}
[ "$TOTAL" -gt 0 ] || { echo "no test files found"; exit 1; }

FAILURES=""
for test_file in "${TEST_FILES[@]}"; do
    name=$(basename "$test_file" .sh)
    log_step "--- Running $name ---"
    SECONDS=0
    if run_test_shell "$test_file"; then
        echo "--- Passed $name (${SECONDS}s)"
    else
        echo "--- Failed $name (${SECONDS}s), exit code: $?"
        FAILURES="$FAILURES $name"
    fi
done

ELAPSED=$(( $(date +%s) - START_TIME ))
if [ -n "$FAILURES" ]; then
    echo "FAILED (${ELAPSED}s):$FAILURES"
    exit 1
fi
echo "All $TOTAL tests passed (${ELAPSED}s)"
