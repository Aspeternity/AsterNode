#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1

source "$PROJECT_DIR/lib/transaction.sh"
state_init

capture_probe() {
  printf '%s\n' "$BASHPID" >"$root/capture.pid"
  printf 'payload\n'
  return "${RM_CAPTURE_TEST_RC:-0}"
}

outer_pid=$BASHPID
captured=''
rm_capture_output captured capture_probe
assert_eq payload "$captured" 'capture helper changed stdout semantics'
assert_eq "$outer_pid" "$(cat "$root/capture.pid")" 'mutating capture ran in a subshell'

set +e
RM_CAPTURE_TEST_RC=23 rm_capture_output captured capture_probe
rc=$?
set -e
assert_eq 23 "$rc" 'capture helper lost the wrapped command exit code'
assert_eq payload "$captured" 'capture helper lost stdout on failure'

tx=''
rm_capture_output tx tx_begin process-model
assert_eq "$outer_pid" "$(jq -r .creator_pid "$(tx_file "$tx")")" 'transaction creator_pid is not the real worker PID'
[[ $tx == *-"$outer_pid"-* ]] || fail 'transaction id does not contain the real worker PID'
tx_rollback "$tx" process-model-test

dangerous='tx_begin|ssh_apply_policy_protected|fw_ensure_ssh_port|node_create_or_replace_spec|backup_create|maintenance_prune_transactions|maintenance_prune_exports|maintenance_prune_evidence|maintenance_prune_manager_versions|maintenance_prune_core_versions'
if grep -REn "\$\(($dangerous)([[:space:]]|\))"   "$PROJECT_DIR/lib" "$PROJECT_DIR/relay-manager.sh"; then
  fail 'persistent mutator is still captured with command substitution'
fi

pass 'mutation output capture stays in manager process, preserves rc/stdout, and records real transaction PID'
