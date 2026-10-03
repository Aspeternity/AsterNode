#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/stage_b_testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=0
source "$PROJECT_DIR/lib/node.sh"
state_init

spec="$root/spec.json"
stage_b_base_spec "$spec"

target_probe() {
  jq -n '{status:"suitable_measured",recommendation_eligible:false,recommendation_reason:"cross-sni risk",
    abuse_risk:{status:"high"},catalog_policy:{recommendable:true}}'
}
set +e
node_target_safety_preflight_spec "$spec" create >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'high-risk Target passed node safety preflight'

target_probe() {
  jq -n '{status:"suitable_measured",recommendation_eligible:true,recommendation_reason:"safe",
    abuse_risk:{status:"low"},catalog_policy:{recommendable:true}}'
}
node_target_safety_preflight_spec "$spec" create

pass 'Stage B node Target safety gate blocks high/unverified abuse risk before apply'
