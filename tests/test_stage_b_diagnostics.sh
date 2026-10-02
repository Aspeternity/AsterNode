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
