#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
source "$PROJECT_DIR/lib/target.sh"

mock_targets="$root/targets.json"
jq -n '{
  candidates:[
    {target:"safe-slow.example:443",sni:"safe-slow.example",recommendable:true,official_reference:true,risk_class:"standard"},
    {target:"safe-fast.example:443",sni:"safe-fast.example",recommendable:true,official_reference:false,risk_class:"standard"},
    {target:"cdn-fast.example:443",sni:"cdn-fast.example",recommendable:false,official_reference:false,risk_class:"shared-cdn-forwarding"}
  ],
  policy:"unit-test recommendation candidates"
}' >"$mock_targets"
RM_TARGETS_FILE="$mock_targets"

target_probe() {
  local target=$1 sni=$2 latency
  case "$target" in
    safe-slow.example:443) latency=40 ;;
    safe-fast.example:443) latency=20 ;;
    cdn-fast.example:443) latency=5 ;;
    *) latency=99 ;;
  esac
  jq -n --arg t "$target" --arg s "$sni" --argjson latency "$latency" '{
    status:"suitable_measured",target:$t,sni:$s,resolved_address:"192.0.2.1",latency_ms:$latency,
    checks:{dns:"ok",tcp:true,tls13:true,certificate_hostname:true,h2:true,repeated_handshake:true,http_status:"200",http_redirect:false,redirect:null},
    reason:null
  }'
}

candidates=$(target_probe_candidates)
assert_json "$candidates" '
  (.results|length)==3 and
  (.suitable|length)==3 and
  .results[2].candidate.recommendable==false and
  .recommended.target=="safe-fast.example:443" and
  .recommended.latency_ms==20 and
  .recommended.candidate.recommendable==true and
  .recommended.candidate.risk_class=="standard" and
  .auto_selected==false and
  .auto_applied==false and
  (.selection_basis|contains("不会自动写入节点配置"))
'

pass 'Stage B Target recommendation preserves explicit false and excludes caution candidates'
