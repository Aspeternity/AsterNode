#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
source "$PROJECT_DIR/lib/target.sh"

assert_json "$(cat "$RM_TARGETS_FILE")" '
  (.candidates|length)>=2 and
  all(.candidates[]; (.target|type)=="string" and (.sni|type)=="string") and
  (any(.candidates[]; .sni=="www.microsoft.com")) and
  (all(.candidates[]; (.sni|ascii_downcase|contains("apple")|not)))
'

set +e
target_probe 'bad-target' 'www.example.com' >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'malformed Target was accepted'

set +e
target_probe '127.0.0.1:443' '127.0.0.1' >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'IP literal was accepted as REALITY SNI'

probe=$(target_probe '127.0.0.1:1' 'www.example.com')
assert_json "$probe" '
  .status=="failed" and
  .target=="127.0.0.1:1" and
  .checks.tcp==false and
  .checks.tls13==false and
  .checks.certificate_hostname==false and
  .probe_policy.handshake_attempts==2 and
  .probe_policy.tls_timeout_seconds==6 and
  (.risk_note|contains("不会因 Target 探测自动开放额外端口"))
'

mock_targets="$root/targets.json"
jq -n '{
  candidates:[
    {target:"127.0.0.1:1",sni:"www.example.com"},
    {target:"127.0.0.1:2",sni:"www.example.com"},
    {target:"127.0.0.1:3",sni:"www.example.com"}
  ],
  policy:"unit-test loopback candidates"
}' >"$mock_targets"
RM_TARGETS_FILE="$mock_targets"
candidates=$(target_probe_candidates)
assert_json "$candidates" '
  (.results|length)==3 and
  (.suitable|length)==0 and
  all(.results[]; .status=="failed") and
  .auto_selected==false and
  .probe_policy.max_parallel==2 and
  .probe_policy.handshake_attempts==2
'

pass 'Stage B Target candidate data, bounded retries and controlled parallel probing'
