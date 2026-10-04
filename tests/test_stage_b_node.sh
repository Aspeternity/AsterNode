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
assert_json "$(cat "$RM_XRAY_CONFIG")" '
  (.inbounds|length)==1 and
  (.inbounds[0].settings.clients|length)==2 and
  .inbounds[0].streamSettings.realitySettings.limitFallbackUpload.bytesPerSec>0 and
  .inbounds[0].streamSettings.realitySettings.limitFallbackDownload.bytesPerSec>0
'
assert_json "$(cat "$RM_STATE_FILE")" '
  .nodes[0].reality.fallback_limits.upload.bytes_per_sec>0 and
  .nodes[0].reality.fallback_limits.download.bytes_per_sec>0
'

add_upstream="$root/add-upstream.json"
jq -n '{
  name:"line-added",
  note:"existing-node upstream add regression",
  enabled:true,
  source_addresses:["198.51.100.10"]
}' >"$add_upstream"
added_upstream=$(upstream_add_from_json node-stageb "$add_upstream")
[[ $added_upstream =~ ^up-[A-Za-z0-9._-]{1,48}$ ]] ||
  fail "added upstream id format invalid: $added_upstream"
assert_json "$(cat "$RM_STATE_FILE")" --arg id "$added_upstream" '
  ([.upstreams[]|select(.upstream_id==$id)]|length)==1 and
  (.upstreams[]|select(.upstream_id==$id)|.node_id)=="node-stageb" and
  (.upstreams[]|select(.upstream_id==$id)|.source_addresses)==["198.51.100.10"] and
  (([.upstreams[].uuid]|length)==([.upstreams[].uuid]|unique|length))
'
assert_json "$(cat "$RM_XRAY_CONFIG")" '(.inbounds[0].settings.clients|length)==3'
upstream_delete "$added_upstream"
assert_json "$(cat "$RM_STATE_FILE")" --arg id "$added_upstream" '
  ([.upstreams[]|select(.upstream_id==$id)]|length)==0
'
assert_json "$(cat "$RM_XRAY_CONFIG")" '(.inbounds[0].settings.clients|length)==2'

valid_replace="$root/valid-replace.json"
jq '.node.name="sg-node-updated"' "$spec" >"$valid_replace"
valid_result=$(node_create_or_replace_spec "$valid_replace" upsert)
assert_json "$valid_result" '.node_id=="node-stageb"'
assert_eq sg-node-updated "$(jq -r '.nodes[]|select(.node_id=="node-stageb")|.name' "$RM_STATE_FILE")" \
  'valid node upsert was rejected by credential guard'

bad="$root/bad-replace.json"
jq '.upstreams[0].uuid="cccccccc-cccc-4ccc-8ccc-cccccccccccc"' "$spec" >"$bad"
set +e
node_create_or_replace_spec "$bad" upsert >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'direct UUID replacement bypassed rotation lifecycle'
assert_eq aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa "$(jq -r '.upstreams[]|select(.upstream_id=="up-line-a")|.uuid' "$RM_STATE_FILE")"

good_config="$root/good-config.json"
cp "$RM_XRAY_CONFIG" "$good_config"
state_before_drift=$(rm_sha256_file "$RM_STATE_FILE")
printf '%s\n' '{"external":"edit"}' >"$RM_XRAY_CONFIG"
drift_patch="$root/drift-patch.json"
jq -n '{note:"must-not-apply"}' >"$drift_patch"
set +e
upstream_update_from_json up-line-a "$drift_patch" >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'external Xray config drift was silently overwritten'
assert_eq '{"external":"edit"}' "$(cat "$RM_XRAY_CONFIG")" 'drift guard changed external config'
assert_eq "$state_before_drift" "$(rm_sha256_file "$RM_STATE_FILE")" 'drift guard changed managed state'
cp "$good_config" "$RM_XRAY_CONFIG"

patch="$root/up-patch.json"
jq -n '{note:"new-egress",enabled:true}' >"$patch"
config_before_metadata=$(rm_sha256_file "$RM_XRAY_CONFIG")
: >"$RM_SYSTEMCTL_LOG"
upstream_update_from_json up-line-a "$patch"
assert_eq "$config_before_metadata" "$(rm_sha256_file "$RM_XRAY_CONFIG")" 'metadata update rewrote Xray config'
if grep -Fq 'restart relay-manager-xray.service' "$RM_SYSTEMCTL_LOG"; then
  fail 'metadata update restarted Xray'
fi
assert_eq 198.51.100.9 "$(jq -r '.upstreams[]|select(.upstream_id=="up-line-a")|.source_addresses[0]' "$RM_STATE_FILE")"

unsafe_source_replace="$root/unsafe-source-replace.json"
jq -n '{source_addresses:["198.51.100.10"]}' >"$unsafe_source_replace"
set +e
upstream_update_from_json up-line-a "$unsafe_source_replace" >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'direct source-address replacement bypassed staged transition'
assert_eq 198.51.100.9 "$(jq -r '.upstreams[]|select(.upstream_id=="up-line-a")|.source_addresses[0]' "$RM_STATE_FILE")"

source_new=$(upstream_source_add up-line-a 198.51.100.10)
assert_json "$source_new" '.status=="added" and .source.address=="198.51.100.10"'
assert_json "$(cat "$RM_STATE_FILE")" '
  ([.sources[]|select(.address=="198.51.100.9")][0].upstream_ids|sort)==["up-line-a","up-line-b"] and
  ([.sources[]|select(.address=="198.51.100.10")][0].upstream_ids)==["up-line-a"]
'
source_old_remove=$(upstream_source_remove up-line-a 198.51.100.9)
assert_json "$source_old_remove" '.status=="removed" and .remaining_sources==1'
assert_json "$(cat "$RM_STATE_FILE")" '
  ([.sources[]|select(.address=="198.51.100.9")][0].upstream_ids)==["up-line-b"] and
  ([.sources[]|select(.address=="198.51.100.10")][0].upstream_ids)==["up-line-a"]
'

ipv6_norm=$(rm_normalize_ip_or_cidr 2001:db8::20)
source_add=$(upstream_source_add up-line-a 2001:db8::20)
assert_json "$source_add" '.status=="added" and .source.family=="ipv6" and .source.scope=="single"'
jq -e --arg addr "$ipv6_norm" '
  any(.upstreams[]|select(.upstream_id=="up-line-a").source_addresses[]; .==$addr)
' "$RM_STATE_FILE" >/dev/null || fail 'normalized IPv6 source was not retained'
source_broad=$(upstream_source_add up-line-a 10.0.0.0/8)
assert_json "$source_broad" '.status=="added" and .source.scope=="broad" and (.source.warning|type=="string")'
source_remove=$(upstream_source_remove up-line-a 198.51.100.10)
assert_json "$source_remove" '.status=="removed" and .remaining_sources==2'
jq -e --arg addr "$ipv6_norm" '
  ([.sources[]|select(.address=="198.51.100.10")]|length)==0 and
  any(.sources[]; .address==$addr) and
  any(.sources[]; .address=="10.0.0.0/8")
' "$RM_STATE_FILE" >/dev/null || fail 'shared source reference rebuild did not preserve normalized addresses'

if grep -Fq 'restart relay-manager-xray.service' "$RM_SYSTEMCTL_LOG"; then
  fail 'source transition restarted Xray even though rendered config was unchanged'
fi
: >"$RM_SYSTEMCTL_LOG"
upstream_set_enabled up-line-a false
grep -Fq 'restart relay-manager-xray.service' "$RM_SYSTEMCTL_LOG" ||
  fail 'runtime-affecting upstream disable did not restart Xray'
assert_eq false "$(jq -r '.upstreams[]|select(.upstream_id=="up-line-a")|.enabled' "$RM_STATE_FILE")" 'explicit upstream disable was not preserved'
assert_json "$(cat "$RM_XRAY_CONFIG")" '
  (.inbounds[0].settings.clients|length)==1 and
  .inbounds[0].settings.clients[0].id=="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
'
set +e
upstream_set_enabled up-line-b false >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'enabled node was allowed to lose its last enabled credential'
assert_eq true "$(jq -r '.upstreams[]|select(.upstream_id=="up-line-b")|.enabled' "$RM_STATE_FILE")"

rot=$(upstream_rotation_prepare up-line-b 300)
assert_json "$rot" '.status=="parallel" and (.pending_uuid|type=="string")'
assert_json "$(cat "$RM_XRAY_CONFIG")" '(.inbounds[0].settings.clients|length)==2'
state_update_filter '(.upstreams[]|select(.upstream_id=="up-line-b")).rotation.deadline_epoch=0'
reconciled=$(upstream_rotation_reconcile_expired)
assert_json "$reconciled" '.expired_rotations==1 and .upstream_ids==["up-line-b"]'
assert_json "$(cat "$RM_STATE_FILE")" '(.upstreams[]|select(.upstream_id=="up-line-b")|has("pending_uuid")|not)'
assert_json "$(cat "$RM_XRAY_CONFIG")" '(.inbounds[0].settings.clients|length)==1'

export_upstream up-line-b current false >/dev/null
replace_spec="$root/replace.json"
jq '.node.sni="www.amazon.com" | .node.target="www.amazon.com:443"' "$spec" >"$replace_spec"
replace_result=$(node_create_or_replace_spec "$replace_spec" upsert)
assert_json "$replace_result" '.node_id=="node-stageb" and .exports_invalidated==true'
[[ -f "$RM_EXPORT_DIR/node-stageb/up-line-b/current/REVOKED" ]] ||
  fail 'node replace did not invalidate dependent upstream export'

before_key=$(jq -r '.nodes[]|select(.node_id=="node-stageb")|.reality.password' "$RM_STATE_FILE")
rotation=$(node_rotate_reality_keys node-stageb)
after_key=$(jq -r '.nodes[]|select(.node_id=="node-stageb")|.reality.password' "$RM_STATE_FILE")
assert_ne "$before_key" "$after_key" 'REALITY key rotation did not change public credential'
assert_json "$rotation" '.status=="rotated" and .exports_invalidated==true and .server_private_key_exposed==false'

node_delete node-stageb
assert_json "$(cat "$RM_STATE_FILE")" '(.nodes|length)==0 and (.upstreams|length)==0 and (.sources|length)==0'
assert_json "$(cat "$RM_XRAY_CONFIG")" '(.inbounds|length)==0'

pass 'Stage B node lifecycle, shared source references, guarded credentials and timed UUID rotation'
