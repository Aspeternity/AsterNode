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

state_add_owned_file /etc/systemd/system/example.service aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
state_add_owned_file /etc/systemd/system/example.service bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
assert_json "$(cat "$RM_STATE_FILE")" '
  ([.owned_files[]|select(.path=="/etc/systemd/system/example.service")]|length)==1 and
  ([.owned_files[]|select(.path=="/etc/systemd/system/example.service")][0].sha256
    =="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
'

state_update_filter '.temporary_opens=[{
  node_id:"legacy-temp",deadline_epoch:1,rule_args:["allow"],unit:"relay-manager-temp-legacy"
}]'
assert_true state_validate
state_update_filter '(.temporary_opens[0].phase)="ARMED"'
assert_true state_validate

before=$(rm_sha256_file "$RM_STATE_FILE")
set +e
state_update_filter '(.temporary_opens[0].phase)="INVALID"' >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail 'invalid temporary access phase accepted'
after=$(rm_sha256_file "$RM_STATE_FILE")
assert_eq "$before" "$after" 'invalid temporary access phase changed state file'

before=$(rm_sha256_file "$RM_STATE_FILE")
set +e
state_update_filter '(.temporary_opens[0].unit)="foreign.timer"' >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail 'foreign temporary access unit name accepted'
after=$(rm_sha256_file "$RM_STATE_FILE")
assert_eq "$before" "$after" 'invalid temporary access unit changed state file'
state_update_filter '.temporary_opens=[]'

before=$(rm_sha256_file "$RM_STATE_FILE")
set +e
state_update_filter '.nodes=[{node_id:"dup"},{node_id:"dup"}]' >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail 'duplicate stable IDs accepted'
after=$(rm_sha256_file "$RM_STATE_FILE")
assert_eq "$before" "$after" 'invalid state update changed state file'

before=$(rm_sha256_file "$RM_STATE_FILE")
set +e
state_update_filter '.nodes=[{node_id:"bad-bool",enabled:"false",autostart:true}]' >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail 'string boolean accepted in managed state'
after=$(rm_sha256_file "$RM_STATE_FILE")
assert_eq "$before" "$after" 'invalid boolean state update changed state file'

pass 'state schema, permissions, idempotency, latest ownership hash, temporary access validation, shared-source references and boolean typing'
