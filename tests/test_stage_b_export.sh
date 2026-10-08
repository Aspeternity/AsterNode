#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/stage_b_testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
stage_b_fake_core "$root"
source "$PROJECT_DIR/lib/export.sh"

state_init
state_update_filter '.core_version=$v' --arg v "$(xray_current_version)"
spec="$root/spec.json"
stage_b_base_spec "$spec" "2001:db8::10"
node_create_or_replace_spec "$spec" create >/dev/null

result=$(export_upstream up-line-a current false)
assert_json "$result" '.status=="exported" and .credentials_hidden==true'
dir="$RM_EXPORT_DIR/node-stageb/up-line-a/current"
for file in params.json outbound.json share.txt 3x-ui.json manifest.json; do
  [[ -f "$dir/$file" ]] || fail "missing export file: $file"
  assert_file_mode "$dir/$file" 600
done
assert_file_mode "$dir" 700

assert_json "$(cat "$dir/params.json")" '
  .profile=="xray-v26.3.27" and
  .address=="2001:db8::10" and
  .transport.xray_json=="raw" and
  .transport.share_uri=="tcp" and
  .server_private_key_exported==false
'
assert_json "$(cat "$dir/3x-ui.json")" '
  .panel=="3x-ui" and
  .fields.transport_for_xray_json=="raw" and
  .fields.transport_for_share_uri=="tcp" and
  .fields.password_or_public_key=="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" and
  .routing_guide.outbound_tag=="rm-out-up-line-a" and
  .routing_guide.merge_outbound_into=="outbounds[]" and
  .routing_guide.route_selected_traffic_with=="routing.rules[].outboundTag" and
  .routing_guide.overwrite_existing_config==false
'
assert_json "$(cat "$dir/manifest.json")" '
  .validation.xray_config_test=="pass" and
  .validation.line_end_to_end=="unverified" and
  .secret_policy.server_private_key_exported==false
'
uri=$(cat "$dir/share.txt")
[[ $uri == vless://aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa@\[2001:db8::10\]:443* ]] ||
  fail "IPv6 export URI malformed: $uri"
if grep -R -Fq 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "$dir"; then
  fail 'server REALITY private key leaked into export'
fi

upstream_rotation_prepare up-line-a 300 >/dev/null
pending=$(export_upstream up-line-a pending true)
assert_json "$pending" '.manifest.credential_mode=="pending" and .manifest.validation.xray_config_test=="pass"'
pending_dir="$RM_EXPORT_DIR/node-stageb/up-line-a/pending"
[[ -f "$pending_dir/share.txt" ]] || fail 'pending rotation export missing'
upstream_rotation_cancel up-line-a
[[ -f "$pending_dir/REVOKED" ]] || fail 'cancelled pending export was not revoked'
[[ ! -e "$pending_dir/share.txt" && ! -e "$pending_dir/params.json" ]] || fail 'revoked pending credentials remained on disk'

export_upstream up-line-a current false >/dev/null
upstream_delete up-line-a
[[ -f "$dir/REVOKED" ]] || fail 'deleted upstream export was not revoked'
[[ ! -e "$dir/outbound.json" && ! -e "$dir/share.txt" ]] || fail 'deleted upstream credentials remained on disk'

pass 'Stage B versioned export, Xray validation, IPv6 URI, 3x-ui mapping and revocation'
