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

probe=$(target_probe '127.0.0.1:1' 'www.example.com')
assert_json "$probe" '
  .status=="failed" and
  .target=="127.0.0.1:1" and
  .checks.tcp==false and
  .checks.tls13==false and
  .checks.certificate_hostname==false
'

pass 'Stage B Target candidate data and bounded failure probing'
