#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
root=$(new_test_root); trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
source "$PROJECT_DIR/lib/state.sh"

state_init
assert_file_mode "$RM_ETC_DIR" 700
assert_file_mode "$RM_VAR_DIR" 700
assert_file_mode "$RM_RUN_DIR" 700
assert_file_mode "$RM_STATE_FILE" 600
sha1=$(rm_sha256_file "$RM_STATE_FILE")
state_init
sha2=$(rm_sha256_file "$RM_STATE_FILE")
assert_eq "$sha1" "$sha2" 'state_init was not idempotent'
assert_true state_validate

state_record_source 203.0.113.9 edge-a up-a
state_record_source 203.0.113.9 edge-b up-b
assert_json "$(cat "$RM_STATE_FILE")" '.sources|length==1 and .[0].address=="203.0.113.9" and (. [0].upstream_ids|sort)==["up-a","up-b"]'
state_unlink_source_upstream 203.0.113.9 up-a
assert_json "$(cat "$RM_STATE_FILE")" '.sources|length==1 and .[0].upstream_ids==["up-b"]'
state_unlink_source_upstream 203.0.113.9 up-b
assert_json "$(cat "$RM_STATE_FILE")" '.sources|length==0'

before=$(rm_sha256_file "$RM_STATE_FILE")
set +e
state_update_filter '.nodes=[{node_id:"dup"},{node_id:"dup"}]' >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail 'duplicate stable IDs accepted'
after=$(rm_sha256_file "$RM_STATE_FILE")
assert_eq "$before" "$after" 'invalid state update changed state file'

pass 'state schema, permissions, idempotency, shared-source references'
