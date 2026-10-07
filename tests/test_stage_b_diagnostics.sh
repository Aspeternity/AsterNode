#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/stage_b_testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
stage_b_fake_core "$root"
source "$PROJECT_DIR/diagnostics.sh"

state_init
state_update_filter '.core_version=$v' --arg v "$(xray_current_version)"
spec="$root/spec.json"
stage_b_base_spec "$spec"
node_create_or_replace_spec "$spec" create >/dev/null

d1=$(diag_d1)
assert_json "$d1" '
  any(.[]; .check=="state-schema" and .status=="normal") and
  any(.[]; .check=="xray-config" and .status=="normal")
'
d4=$(diag_d4)
assert_json "$d4" 'length==2 and all(.[]; .status=="unverified")'

export RM_UFW_STATUS_FILE="$root/ufw-status.txt"
export RM_UFW_FRAMEWORK_MODIFIED=false
mkdir -p "$root/etc/default"
cat >"$root/etc/default/ufw" <<'EOF'
IPV6=yes
EOF
cat >"$RM_UFW_STATUS_FILE" <<'EOF'
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
--                         ------      ----
443/tcp                    ALLOW       198.51.100.9               # relay-manager:node-stageb:allow:test
443/tcp                    DENY        Anywhere                   # relay-manager:node-stageb:deny
EOF
state_update_filter '
  .owned_firewall_rules=[
    {node_id:"node-stageb",comment:"relay-manager:node-stageb:allow:test",port:443,kind:"allow",source:"198.51.100.9",args:["allow"]},
    {node_id:"node-stageb",comment:"relay-manager:node-stageb:deny",port:443,kind:"deny",source:"any",args:["deny"]}
  ] |
  .firewall_verifications={"node-stageb":{verified:true,verified_at:"2026-10-03T16:08:41Z"}}
'
fw_item=$(diag_firewall_isolation_item)
assert_json "$fw_item" '.check=="firewall-isolation" and .status=="normal" and (.detail|contains("外部允许/拒绝对照验证"))'
state_update_filter '.firewall_verifications={}'
fw_item=$(diag_firewall_isolation_item)
assert_json "$fw_item" '.check=="firewall-isolation" and .status=="unverified"'

edir="$RM_VAR_DIR/evidence/d4"
mkdir -p "$edir"
chmod 0700 "$RM_VAR_DIR/evidence" "$edir" 2>/dev/null || true
fp=$(diag_connection_fingerprint node-stageb up-line-a)
jq -n --arg fp "$fp" '{
  result:"pass",node_id:"node-stageb",upstream_id:"up-line-a",
  exit_ip:"203.0.113.55",panel_version:"test-panel",line_core_version:"test-core",
  fingerprint:$fp,tested_at:"2026-10-02T00:00:00Z",method:"unit fixture"
}' >"$edir/up-line-a.json"
chmod 0600 "$edir/up-line-a.json"

d4=$(diag_d4)
assert_json "$d4" 'any(.[]; .upstream_id=="up-line-a" and .status=="normal")'

state_update_filter '(.upstreams[]|select(.upstream_id=="up-line-a")).uuid="cccccccc-cccc-4ccc-8ccc-cccccccccccc"'
d4=$(diag_d4)
assert_json "$d4" 'any(.[]; .upstream_id=="up-line-a" and .status=="unverified" and (.detail|contains("旧 D4 证据失效")))'

bundle="$root/diagnostic.json"
bundle_result=$(diag_export_bundle "$bundle" false)
assert_json "$bundle_result" '.status=="exported" and .credentials_redacted==true and .automatic_upload==false'
assert_file_mode "$bundle" 600
assert_json "$(cat "$bundle")" '
  .redaction.credentials==true and
  .network_probe.executed==false and
  (.state.upstreams|length)==2 and
  all(.state.upstreams[]; .credentials_redacted==true) and
  all(.state.nodes[]; .reality.credentials_present==true)
'
if grep -Fq 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' "$bundle" ||
   grep -Fq 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "$bundle" ||
   grep -Fq 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' "$bundle"; then
  fail 'diagnostic bundle leaked Stage B credentials'
fi

pass 'Stage B diagnostics keep D4 evidence stale-aware and export a credential-redacted bundle'
