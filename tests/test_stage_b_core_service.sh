#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/stage_b_testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1 RM_SYSTEMCTL_LOG="$root/systemctl.log"
stage_b_fake_core "$root"
source "$PROJECT_DIR/lib/core-xray.sh"

state_init
xray_service_install

for unit in relay-manager-xray.service relay-manager-maintenance.service relay-manager-maintenance.timer; do
  file="$root/etc/systemd/system/$unit"
  [[ -f $file ]] || fail "missing managed systemd unit: $unit"
  assert_file_mode "$file" 644
done

if grep -Fq 'firewall reconcile-expired' "$root/etc/systemd/system/relay-manager-xray.service"; then
  fail 'unprivileged Xray service still contains root-only firewall ExecStartPre'
fi
grep -Fq 'User=rm-xray' "$root/etc/systemd/system/relay-manager-xray.service" ||
  fail 'Xray service does not run as rm-xray'
grep -Fq 'NoNewPrivileges=true' "$root/etc/systemd/system/relay-manager-xray.service" ||
  fail 'Xray service hardening missing'
grep -Fq 'enable relay-manager-maintenance.timer' "$RM_SYSTEMCTL_LOG" ||
  fail 'maintenance timer was not enabled in test mode'
grep -Fq 'start relay-manager-maintenance.timer' "$RM_SYSTEMCTL_LOG" ||
  fail 'maintenance timer was not started in test mode'
assert_json "$(cat "$RM_STATE_FILE")" '
  any(.owned_services[]; .=="relay-manager-xray.service") and
  any(.owned_services[]; .=="relay-manager-maintenance.timer")
'

pass 'Stage B managed Xray service, unprivileged unit and maintenance timer installation'
