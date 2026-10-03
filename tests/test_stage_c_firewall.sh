#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
export RM_UFW_LOG="$root/ufw.log"
export RM_UFW_STATUS_FILE="$root/ufw-status.txt"
export RM_UFW_ADDED_FILE="$root/ufw-added.txt"
export RM_UFW_RAW_FILE="$root/ufw-raw.txt"
export RM_UFW_FRAMEWORK_MODIFIED=false
export RM_SYSTEMCTL_LOG="$root/systemctl.log"

mkdir -p "$root/etc/default"
cat >"$root/etc/default/ufw" <<'EOF'
IPV6=yes
EOF
: >"$RM_UFW_ADDED_FILE"
: >"$RM_UFW_RAW_FILE"
: >"$RM_UFW_LOG"

source "$PROJECT_DIR/lib/firewall.sh"
state_init

cat >"$RM_UFW_STATUS_FILE" <<'EOF'
Status: inactive
EOF
enabled=$(fw_enable_safe 22)
assert_json "$enabled" '.status=="enabled" and .ssh_ports_preserved==[22] and .default_policy_preserved==true'
grep -Fq -- '--force enable' "$RM_UFW_LOG" || fail 'safe UFW enable was not requested'
assert_json "$(cat "$RM_STATE_FILE")" 'any(.owned_firewall_rules[]; .kind=="ssh-allow" and .port==22)'

cat >"$RM_UFW_STATUS_FILE" <<'EOF'
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere                   # relay-manager:ssh:22
22/tcp (v6)                ALLOW       Anywhere (v6)              # relay-manager:ssh:22
EOF

status=$(fw_status_json)
assert_json "$status" '
  .installed==true and .active==true and .default_incoming=="deny" and
  .ipv6_enabled==true and .complex_environment==false and
  .framework_integrity.status=="ok" and .isolation_verified==false
'

state_update_filter '.nodes=[{
  node_id:"node-fw",name:"fw",listen_address:"::",listen_port:443,
  enabled:true,autostart:true,access_mode:"whitelist"
}]'

: >"$RM_UFW_LOG"
deny_only=$(fw_apply_whitelist node-fw 443)
assert_json "$deny_only" '.status=="applied_unverified" and (.sources|length)==0 and (.note|contains("默认拒绝"))'
assert_json "$(cat "$RM_STATE_FILE")" '
  ([.owned_firewall_rules[]|select((.node_id//"")=="node-fw")]|length)==1 and
  any(.owned_firewall_rules[]; (.node_id//"")=="node-fw" and .kind=="deny")
'
grep -Fq 'deny to any port 443' "$RM_UFW_LOG" || fail 'empty whitelist did not install node-port deny'

before=$(wc -l <"$RM_UFW_LOG")
same=$(fw_apply_whitelist node-fw 443)
after=$(wc -l <"$RM_UFW_LOG")
assert_json "$same" '.status=="already_applied_unverified"'
assert_eq "$before" "$after" 'idempotent whitelist reapplied UFW commands'

: >"$RM_UFW_LOG"
applied=$(fw_apply_whitelist node-fw 443 198.51.100.9 2001:db8::20)
assert_json "$applied" '.status=="applied_unverified" and (.sources|length)==2'
assert_json "$(cat "$RM_STATE_FILE")" '
  ([.owned_firewall_rules[]|select((.node_id//"")=="node-fw")]|length)==3 and
  ([.owned_firewall_rules[]|select((.node_id//"")=="node-fw" and .kind=="allow")]|length)==2 and
  any(.owned_firewall_rules[]; (.node_id//"")=="node-fw" and .kind=="deny")
'
grep -Fq 'prepend allow from 198.51.100.9 to any port 443' "$RM_UFW_LOG" ||
  fail 'specific IPv4 allow was not prepended ahead of deny'
grep -Fq 'prepend allow from 2001:db8:0:0:0:0:0:20 to any port 443' "$RM_UFW_LOG" ||
  fail 'normalized IPv6 allow was not prepended'

export RM_UFW_TEST_VERIFY=VERIFY
verified=$(fw_mark_whitelist_verified node-fw)
assert_json "$verified" '.status=="verified_external_contrast"'
assert_json "$(cat "$RM_STATE_FILE")" '.firewall_verifications["node-fw"].verified==true'

cat >"$RM_UFW_STATUS_FILE" <<'EOF'
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
--                         ------      ----
443/tcp                    ALLOW       Anywhere
EOF
set +e
fw_apply_whitelist node-fw 443 198.51.100.9 >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'external port allow did not block whitelist automation'

cat >"$RM_UFW_STATUS_FILE" <<'EOF'
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere                   # relay-manager:ssh:22
EOF
export RM_UFW_FRAMEWORK_MODIFIED=true
complex=$(fw_status_json)
assert_json "$complex" '.complex_environment==true and .framework_integrity.status=="modified"'
set +e
fw_require_manageable >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'modified UFW framework files did not disable automation'
export RM_UFW_FRAMEWORK_MODIFIED=false

: >"$RM_UFW_LOG"
opened=$(fw_temp_open node-fw 10)
assert_json "$opened" '.status=="temporary_open_applied_unverified" and .node_id=="node-fw"'
grep -Fq 'prepend allow to any port 443' "$RM_UFW_LOG" ||
  fail 'temporary public allow was not inserted ahead of managed deny'
assert_json "$(cat "$RM_STATE_FILE")" 'any(.temporary_opens[]; .node_id=="node-fw")'

fw_expire_temp node-fw
assert_json "$(cat "$RM_STATE_FILE")" '([.temporary_opens[]|select(.node_id=="node-fw")]|length)==0'
grep -Fq -- '--force delete allow to any port 443' "$RM_UFW_LOG" ||
  fail 'temporary public allow was not removed at expiry'
[[ -f "$root/etc/systemd/system/relay-manager-temp-node-fw.timer" ]] ||
  fail 'expired timer unit should remain as an inert owned file'

pass 'Stage C UFW safe enable, whitelist ownership, conflict refusal and timed public access'
