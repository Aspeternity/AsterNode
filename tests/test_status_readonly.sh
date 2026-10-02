#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
root=$(new_test_root); trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1 RM_TEST_USE_HOST_PROBES=0
source "$PROJECT_DIR/lib/transaction.sh"
state_init
# Create a completed transaction so status must traverse an existing transaction directory.
dest="$root/etc/relay-manager/status-demo.conf"; printf 'a\n' > "$dest"
src=$(mktemp); printf 'b\n' > "$src"; trap 'rm -rf "$root"; rm -f "$src"' EXIT
id=$(tx_begin status-demo); tx_stage_file "$id" "$src" "$dest"; tx_apply "$id"; tx_commit "$id"

before=$(snapshot_tree "$root")
out=$(env RM_ROOT="$root" RM_TEST_MODE=1 RM_TEST_USE_HOST_PROBES=0 "$PROJECT_DIR/relay-manager.sh" status)
after=$(snapshot_tree "$root")
assert_eq "$before" "$after" 'status command modified managed tree'
assert_json "$out" '.managed_state.schema_version==1 and (.transactions|length)==1 and .transactions[0].status=="COMMITTED"'
pass 'status path remains read-only with existing state/transactions'
