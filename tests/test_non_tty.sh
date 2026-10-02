#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
root=$(new_test_root); trap 'rm -rf "$root"' EXIT
set +e
if command -v setsid >/dev/null 2>&1; then
  setsid -w env RM_ROOT="$root" RM_TEST_MODE=0 "$PROJECT_DIR/relay-manager.sh" quick-deploy </dev/null >/dev/null 2>&1
else
  env RM_ROOT="$root" RM_TEST_MODE=0 "$PROJECT_DIR/relay-manager.sh" quick-deploy </dev/null >/dev/null 2>&1
fi
rc=$?
set -e
assert_eq 10 "$rc" 'non-TTY mutation did not stop with precondition code'
[[ ! -e "$root/etc/relay-manager" ]] || fail 'non-TTY mutation created managed state'
pass 'UX-03 non-TTY mutation guard'
