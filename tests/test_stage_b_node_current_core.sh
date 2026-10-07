#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/stage_b_testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1 RM_SYSTEMCTL_LOG="$root/systemctl.log"

OLD_CORE=v26.2.6
DEFAULT_CORE=v26.3.27

# D-VPS-03 regression shape: a supported previous core is current while the
# compatibility matrix points new installs at a newer default core.
stage_b_fake_core "$root" "$OLD_CORE"
source "$PROJECT_DIR/lib/export.sh"

assert_eq "$DEFAULT_CORE" "$(xray_default_version)" 'test fixture no longer uses expected default core'
assert_eq "$root/usr/local/lib/relay-manager/core/$OLD_CORE" "$(readlink -f "$RM_CORE_CURRENT")"
[[ ! -x "$root/usr/local/lib/relay-manager/core/$DEFAULT_CORE/xray" ]] ||
  fail 'default core unexpectedly installed in previous-core fixture'

state_init
state_update_filter '.core_version=$v' --arg v "$OLD_CORE"

spec="$root/spec.json"
disabled_spec="$root/disabled-spec.json"
stage_b_base_spec "$spec"
jq '.node.enabled=false' "$spec" >"$disabled_spec"

created=$(node_create_or_replace_spec "$disabled_spec" create)
assert_json "$created" '.node_id=="node-stageb"'

# Bug21-A: node lifecycle must not claim a core switch that never happened.
assert_eq "$OLD_CORE" "$(jq -r '.core_version' "$RM_STATE_FILE")"   'disabled node create overwrote state.core_version with compatibility default'
assert_eq "$root/usr/local/lib/relay-manager/core/$OLD_CORE" "$(readlink -f "$RM_CORE_CURRENT")"   'disabled node create changed core/current'

# Bug21-B: enabling must validate the actual current managed core, not require
# the compatibility default to be installed.
: >"$RM_SYSTEMCTL_LOG"
node_set_enabled node-stageb true
assert_json "$(cat "$RM_STATE_FILE")"   '.core_version=="v26.2.6" and (.nodes[]|select(.node_id=="node-stageb")|.enabled)==true'
assert_eq "$root/usr/local/lib/relay-manager/core/$OLD_CORE" "$(readlink -f "$RM_CORE_CURRENT")"
grep -Fq 'restart relay-manager-xray.service' "$RM_SYSTEMCTL_LOG" ||
  fail 'current previous core could not start enabled node when default core was absent'

# Return to a stopped node, then create a second prepared core without changing
# the actual current symlink. A stale state version must never authorize an
# enabled-node mutation merely because that other version exists on disk.
node_set_enabled node-stageb false
stage_b_fake_core "$root" "$DEFAULT_CORE"
ln -sfn "$root/usr/local/lib/relay-manager/core/$OLD_CORE" "$RM_CORE_CURRENT"
state_update_filter '.core_version=$v' --arg v "$DEFAULT_CORE"

state_before=$(rm_sha256_file "$RM_STATE_FILE")
config_before=$(rm_sha256_file "$RM_XRAY_CONFIG")
: >"$RM_SYSTEMCTL_LOG"

rc=0
node_set_enabled node-stageb true >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'state/core-current mismatch did not fail closed'
assert_eq "$state_before" "$(rm_sha256_file "$RM_STATE_FILE")"   'state/core-current mismatch changed state'
assert_eq "$config_before" "$(rm_sha256_file "$RM_XRAY_CONFIG")"   'state/core-current mismatch changed rendered config'
assert_eq "$root/usr/local/lib/relay-manager/core/$OLD_CORE" "$(readlink -f "$RM_CORE_CURRENT")"   'state/core-current mismatch changed current core'
if grep -Eq '(^| )(enable|restart|start) relay-manager-xray\.service' "$RM_SYSTEMCTL_LOG"; then
  fail 'state/core-current mismatch changed Xray service state'
fi

pass 'Bug21 node lifecycle preserves and validates the actual current managed core'
