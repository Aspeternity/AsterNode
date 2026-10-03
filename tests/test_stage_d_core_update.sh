#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/stage_b_testlib.sh"

root=$(new_test_root)
work=$(mktemp -d)
trap 'rm -rf "$root" "$work"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1 RM_SYSTEMCTL_LOG="$root/systemctl.log"
export RM_UPDATE_TEST_XRAY_ACTIVE=true RM_UPDATE_TEST_XRAY_ENABLED=true

stage_b_fake_core "$root" v26.3.27
source "$PROJECT_DIR/lib/update.sh"
state_init
state_update_filter '.core_version="v26.3.27"'

mkdir -p "$root/etc/relay-manager-xray"
printf '{"log":{"loglevel":"warning"}}\n' >"$root/etc/relay-manager-xray/config.json"
chmod 0640 "$root/etc/relay-manager-xray/config.json"

jq '
  .core.xray["v99.0.0"]=(.core.xray["v26.3.27"] | .release_url="https://example.invalid/v99" | .assets.amd64.url="https://example.invalid/v99.zip") |
  .core.xray["v98.0.0"]=(.core.xray["v99.0.0"]) |
  .core.xray["v97.0.0"]=(.core.xray["v99.0.0"])
' "$PROJECT_DIR/compat/compatibility.json" >"$work/compat.json"
RM_COMPAT_FILE="$work/compat.json"

make_fake_core() {
  local version=$1 behavior=${2:-good} dir="$root/usr/local/lib/relay-manager/core/$version"
  mkdir -p "$dir"
  cat >"$dir/xray" <<'XRAY'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  run)
    cfg=''
    while (($#)); do
      case "$1" in -config|-c) shift; cfg=${1:-};; esac
      shift || true
    done
    [[ -n $cfg && -f $cfg ]]
    jq -e . "$cfg" >/dev/null
    ;;
  *) exit 0 ;;
esac
XRAY
  if [[ $behavior == bad ]]; then
    cat >"$dir/xray" <<'XRAYBAD'
#!/usr/bin/env bash
exit 1
XRAYBAD
  fi
  chmod 0755 "$dir/xray"
}

xray_core_prepare() { make_fake_core "$1" good; }

result=$(update_core_to v99.0.0)
assert_json "$result" '.status=="updated" and .core_version=="v99.0.0" and .previous_core_version=="v26.3.27" and .line_end_to_end=="unverified"'
backup_id=$(jq -r .rollback_backup <<<"$result")
assert_eq "$root/usr/local/lib/relay-manager/core/v99.0.0" "$(readlink -f "$root/usr/local/lib/relay-manager/core/current")"
assert_eq v99.0.0 "$(jq -r .core_version "$RM_STATE_FILE")"
assert_json "$(cat "$root/var/lib/relay-manager/backups/$backup_id/manifest.json")" '.kind=="upgrade" and .core_version=="v26.3.27"'
grep -Fq "restart relay-manager-xray.service" "$RM_SYSTEMCTL_LOG" || fail 'active shared Xray service was not restarted'

rolled=$(update_core_rollback "$backup_id")
assert_json "$rolled" '.status=="rolled_back" and .from_core_version=="v99.0.0" and .core_version=="v26.3.27" and .line_end_to_end=="unverified"'
assert_eq "$root/usr/local/lib/relay-manager/core/v26.3.27" "$(readlink -f "$root/usr/local/lib/relay-manager/core/current")"
assert_eq v26.3.27 "$(jq -r .core_version "$RM_STATE_FILE")"

xray_core_prepare() { make_fake_core "$1" bad; }
before_link=$(readlink -f "$root/usr/local/lib/relay-manager/core/current")
rc=0
update_core_to v98.0.0 >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'invalid new core config did not stop update before switching'
assert_eq "$before_link" "$(readlink -f "$root/usr/local/lib/relay-manager/core/current")" 'invalid core changed current link'
assert_eq v26.3.27 "$(jq -r .core_version "$RM_STATE_FILE")" 'invalid core changed state'

xray_core_prepare() { make_fake_core "$1" good; }
original_apply=$(declare -f update_apply_xray_service_state)
update_apply_xray_service_state() {
  local now
  now=$(readlink -f "$RM_CORE_CURRENT" 2>/dev/null || true)
  if [[ $now == "$RM_CORE_BASE/v97.0.0" ]]; then return "$RM_RC_INTERNAL"; fi
  return 0
}
rc=0
update_core_to v97.0.0 >/dev/null 2>&1 || rc=$?
assert_eq 20 "$rc" 'service-start failure did not report successful rollback'
assert_eq "$root/usr/local/lib/relay-manager/core/v26.3.27" "$(readlink -f "$root/usr/local/lib/relay-manager/core/current")" 'service failure did not restore old core link'
assert_eq v26.3.27 "$(jq -r .core_version "$RM_STATE_FILE")" 'service failure did not restore old core state'
eval "$original_apply"

pass 'Stage D core update validates before switch, preserves service state and supports explicit rollback'
