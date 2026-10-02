#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
root=$(new_test_root); outside=$(new_test_root); trap 'rm -rf "$root" "$outside"' EXIT
mkdir -p "$root"; ln -s "$outside" "$root/etc"
export RM_ROOT="$root" RM_TEST_MODE=1
source "$PROJECT_DIR/lib/state.sh"
set +e
state_init >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail 'state_init followed attacker-controlled /etc symlink'
[[ ! -e "$outside/relay-manager" ]] || fail 'state_init wrote outside RM_ROOT through symlink'
pass 'SEC-01 symlink component rejection'
