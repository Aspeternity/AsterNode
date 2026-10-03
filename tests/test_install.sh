#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
root=$(new_test_root); trap 'rm -rf "$root"' EXIT

# The Stage-A source installer is exercised only inside RM_ROOT; it must be idempotent
# and must not create /etc/relay-manager state merely by showing post-install status.
env RM_ROOT="$root" RM_TEST_MODE=1 "$PROJECT_DIR/install.sh" --install-source >/dev/null
version=$(cat "$PROJECT_DIR/VERSION")
base="$root/usr/local/lib/relay-manager"
bin="$root/usr/local/bin/relay-manager"
[[ -x "$bin" ]] || fail 'installed relay-manager entry is not executable'
assert_eq "$base/versions/$version/relay-manager.sh" "$(readlink -f "$bin")"
[[ ! -e "$root/etc/relay-manager/state.json" ]] || fail 'installer status path created managed state'
count1=$(find "$base/versions" -mindepth 1 -maxdepth 1 -type d | wc -l)
sha1=$(sha256sum "$base/versions/$version/relay-manager.sh" | awk '{print $1}')

env RM_ROOT="$root" RM_TEST_MODE=1 "$PROJECT_DIR/install.sh" --install-source >/dev/null
count2=$(find "$base/versions" -mindepth 1 -maxdepth 1 -type d | wc -l)
sha2=$(sha256sum "$base/versions/$version/relay-manager.sh" | awk '{print $1}')
assert_eq "$count1" "$count2" 'reinstall created an extra version directory'
assert_eq "$sha1" "$sha2" 'reinstall rewrote the installed version unexpectedly'
[[ ! -e "$root/etc/relay-manager/state.json" ]] || fail 'reinstall created managed state'

grep -F 'tar fuser' "$PROJECT_DIR/install.sh" >/dev/null || fail 'installer does not require fuser'
grep -F 'fuser) pkg=psmisc' "$PROJECT_DIR/install.sh" >/dev/null || fail 'installer does not map fuser to psmisc'

pass 'Stage-A install entry idempotency, dependency coverage and read-only status'
