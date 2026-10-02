#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/stage_b_testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1 RM_SYSTEMCTL_LOG="$root/systemctl.log"
stage_b_fake_core "$root"
source "$PROJECT_DIR/lib/export.sh"

state_init
spec="$root/spec.json"
stage_b_base_spec "$spec"

created=$(node_create_or_replace_spec "$spec" create)
assert_json "$created" '.node_id=="node-stageb" and (.upstream_ids|sort)==["up-line-a","up-line-b"]'
assert_true state_validate
assert_json "$(cat "$RM_STATE_FILE")" '
  (.nodes|length)==1 and
  (.upstreams|length)==2 and
  (.sources|length)==1 and
  (.sources[0].upstream_ids|sort)==["up-line-a","up-line-b"]
'
assert_file_mode "$RM_XRAY_CONFIG" 640
assert_json "$(cat "$RM_XRAY_CONFIG")" '.inbounds|length==1 and .[0].settings.clients|length==2'

bad="$root/bad-replace.json"
jq '.upstreams[0].uuid="cccccccc-cccc-4ccc-8ccc-cccccccccccc"' "$spec" >"$bad"
set +e
node_create_or_replace_spec "$bad" upsert >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'direct UUID replacement bypassed rotation lifecycle'
assert_eq aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa "$(jq -r '.upstreams[]|select(.upstream_id=="up-line-a")|.uuid' "$RM_STATE_FILE")"

patch="$root/up-patch.json"
jq -n '{note:"new-egress",source_addresses:["198.51.100.10"],enabled:true}' >"$patch"
upstream_update_from_json up-line-a "$patch"
assert_eq 198.51.100.10 "$(jq -r '.upstreams[]|select(.upstream_id=="up-line-a")|.source_addresses[0]' "$RM_STATE_FILE")"
assert_json "$(cat "$RM_STATE_FILE")" '
  (.sources|length)==2 and
  ([.sources[]|select(.address=="198.51.100.10")][0].upstream_ids)==["up-line-a"] and
  ([.sources[]|select(.address=="198.51.100.9")][0].upstream_ids)==["up-line-b"]
'

upstream_set_enabled up-line-a false
set +e
upstream_set_enabled up-line-b false >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'enabled node was allowed to lose its last enabled credential'
assert_eq true "$(jq -r '.upstreams[]|select(.upstream_id=="up-line-b")|.enabled' "$RM_STATE_FILE")"

rot=$(upstream_rotation_prepare up-line-b 300)
assert_json "$rot" '.status=="parallel" and (.pending_uuid|type=="string")'
assert_json "$(cat "$RM_XRAY_CONFIG")" '.inbounds[0].settings.clients|length==2'
state_update_filter '(.upstreams[]|select(.upstream_id=="up-line-b")).rotation.deadline_epoch=0'
reconciled=$(upstream_rotation_reconcile_expired)
assert_json "$reconciled" '.expired_rotations==1 and .upstream_ids==["up-line-b"]'
assert_json "$(cat "$RM_STATE_FILE")" '(.upstreams[]|select(.upstream_id=="up-line-b")|has("pending_uuid")|not)'
assert_json "$(cat "$RM_XRAY_CONFIG")" '.inbounds[0].settings.clients|length==1'

before_key=$(jq -r '.nodes[]|select(.node_id=="node-stageb")|.reality.password' "$RM_STATE_FILE")
rotation=$(node_rotate_reality_keys node-stageb)
after_key=$(jq -r '.nodes[]|select(.node_id=="node-stageb")|.reality.password' "$RM_STATE_FILE")
assert_ne "$before_key" "$after_key" 'REALITY key rotation did not change public credential'
assert_json "$rotation" '.status=="rotated" and .exports_invalidated==true and .server_private_key_exposed==false'

node_delete node-stageb
assert_json "$(cat "$RM_STATE_FILE")" '.nodes|length==0 and .upstreams|length==0 and .sources|length==0'
assert_json "$(cat "$RM_XRAY_CONFIG")" '.inbounds|length==0'

pass 'Stage B node lifecycle, shared source references, guarded credentials and timed UUID rotation'
