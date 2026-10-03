#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/stage_b_testlib.sh"

root=$(new_test_root)
work=$(mktemp -d)
trap 'rm -rf "$root" "$work"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1 RM_SYSTEMCTL_LOG="$root/systemctl.log"

mkdir -p "$root/etc"
printf '0123456789abcdef0123456789abcdef\n' >"$root/etc/machine-id"
stage_b_fake_core "$root" v26.3.27
source "$PROJECT_DIR/lib/backup.sh"
state_init
state_update_filter '.core_version="v26.3.27"'

list_before=$(backup_list)
assert_json "$list_before" 'length==0'
[[ ! -e $RM_BACKUP_DIR ]] || fail 'read-only backup list created the backup directory'

spec="$work/spec.json"
stage_b_base_spec "$spec"
node_create_or_replace_spec "$spec" create >/dev/null
state_update_filter '.owned_firewall_rules=[{id:"live-rule"}] | .ssh_verifications={admin:{verified:true}}'

backup_id=$(backup_create config)
backup_id_valid "$backup_id" || fail "generated backup id is invalid: $backup_id"
backup_verify "$backup_id"
assert_json "$(backup_verify_json "$backup_id")" '.status=="verified"'
manifest="$RM_BACKUP_DIR/$backup_id/manifest.json"
assert_json "$(cat "$manifest")" '
  .backup_format==1 and .kind=="config" and
  (.host_fingerprint|test("^[0-9a-f]{64}$")) and
  (.xray_service_state.active==false) and
  (.xray_service_state.enabled==false)
'
assert_file_mode "$RM_BACKUP_DIR/$backup_id" 700
assert_file_mode "$manifest" 600
assert_file_mode "$RM_BACKUP_DIR/$backup_id/files/etc/relay-manager/state.json" 600

saved_state="$work/saved-state.json"
cp "$RM_BACKUP_DIR/$backup_id/files/etc/relay-manager/state.json" "$saved_state"
printf ' ' >>"$RM_BACKUP_DIR/$backup_id/files/etc/relay-manager/state.json"
rc=0
backup_verify "$backup_id" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'tampered backup payload was not rejected'
cp "$saved_state" "$RM_BACKUP_DIR/$backup_id/files/etc/relay-manager/state.json"
chmod 0600 "$RM_BACKUP_DIR/$backup_id/files/etc/relay-manager/state.json"
backup_verify "$backup_id"

changed="$work/changed.json"
jq '.node.name="changed-node"' "$spec" >"$changed"
node_create_or_replace_spec "$changed" upsert >/dev/null
state_update_filter '.owned_firewall_rules=[{id:"current-security-rule"}] | .ssh_verifications={current:{verified:true}}'
: >"$RM_SYSTEMCTL_LOG"

restored=$(backup_restore_local "$backup_id")
assert_json "$restored" '.status=="restored" and .scope=="same_host_nodes" and .security_state=="preserved"'
assert_eq sg-node "$(jq -r '.nodes[0].name' "$RM_STATE_FILE")" 'same-host restore did not restore node data'
assert_eq current-security-rule "$(jq -r '.owned_firewall_rules[0].id' "$RM_STATE_FILE")" 'same-host restore overwrote current firewall ownership'
assert_json "$(cat "$RM_STATE_FILE")" '.ssh_verifications.current.verified==true'
if grep -Eq '(^| )(enable|disable|start|stop|restart) relay-manager-xray.service$' "$RM_SYSTEMCTL_LOG"; then
  fail 'same-host restore changed an inactive Xray service state'
fi

jq '.node.name="host-mismatch"' "$spec" >"$changed"
node_create_or_replace_spec "$changed" upsert >/dev/null
printf 'fedcba9876543210fedcba9876543210\n' >"$root/etc/machine-id"
rc=0
backup_restore_local "$backup_id" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'same-host restore accepted a different machine fingerprint'
assert_eq host-mismatch "$(jq -r '.nodes[0].name' "$RM_STATE_FILE")" 'rejected host-mismatch restore changed state'

state_update_filter '.nodes=[] | .upstreams=[] | .sources=[] | .config_revision+=1 |
  .owned_firewall_rules=[{id:"portable-current-rule"}] |
  .ssh_verifications={portable:{verified:true}}'
: >"$RM_SYSTEMCTL_LOG"
portable=$(backup_restore_nodes_only "$backup_id")
assert_json "$portable" '.status=="restored_for_review" and .scope=="portable_nodes" and .requires_review==true'
assert_json "$(cat "$RM_STATE_FILE")" '
  (.nodes|length)==1 and (.upstreams|length)==2 and
  ([.nodes[].enabled] | all(.==false)) and
  ([.nodes[].autostart] | all(.==false)) and
  ([.upstreams[].enabled] | all(.==false)) and
  ([.upstreams[] | (has("pending_uuid") or has("rotation"))] | any | not) and
  .owned_firewall_rules[0].id=="portable-current-rule" and
  .ssh_verifications.portable.verified==true
'
if grep -Eq '(^| )(enable|restart|start) relay-manager-xray.service$' "$RM_SYSTEMCTL_LOG"; then
  fail 'portable restore started the Xray service'
fi

rc=0
backup_restore_nodes_only "$backup_id" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'portable restore overwrote an existing node set'

rc=0
backup_verify '../escape' >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'backup id traversal was accepted'

listed=$(backup_list)
assert_json "$listed" 'length==1 and .[0].valid==true'
assert_eq "$backup_id" "$(jq -r '.[0].backup_id' <<<"$listed")" 'backup list returned the wrong id'

pass 'Stage D backups are integrity-checked, same-host safe, security-preserving and portable only in disabled review mode'
