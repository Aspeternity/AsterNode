#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
root=$(new_test_root); trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
source "$PROJECT_DIR/lib/transaction.sh"
state_init
marker="$root/locked"
(
  export RM_ROOT="$root" RM_TEST_MODE=1
  source "$PROJECT_DIR/lib/transaction.sh"
  tx_lock_acquire
  : > "$marker"
  sleep 1
  tx_lock_release
) &
holder=$!
for _ in $(seq 1 50); do [[ -e $marker ]] && break; sleep 0.02; done
[[ -e $marker ]] || fail 'lock holder did not start'
start=$(date +%s%N)
id=$(tx_begin waits-for-lock)
end=$(date +%s%N)
wait "$holder"
elapsed_ms=$(( (end-start)/1000000 ))
(( elapsed_ms >= 700 )) || fail "transaction lock did not serialize writers (${elapsed_ms}ms)"
tx_rollback "$id" cleanup
pass "transaction flock serialization (${elapsed_ms}ms)"
