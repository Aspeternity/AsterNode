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
export RM_UFW_TEST_SSH_PORTS=22

mkdir -p "$root/etc/default"
cat >"$root/etc/default/ufw" <<'EOF'
IPV6=yes
EOF
: >"$RM_UFW_ADDED_FILE"
: >"$RM_UFW_RAW_FILE"
: >"$RM_UFW_LOG"

source "$PROJECT_DIR/lib/firewall.sh"
state_init

# Debian/Ubuntu UFW manages before/after framework rules through UCF rather
# than dpkg Conffiles. The package-facing /usr/share/ufw/*.rules entries are
# legitimate symlinks to canonical /usr/share/ufw/iptables/*.rules templates.
# Exercise that real layout directly.
mkdir -p "$root/etc/ufw" "$root/usr/share/ufw/iptables"
for base in before.rules after.rules before6.rules after6.rules; do
  printf 'official-%s-v1\n' "$base" >"$root/usr/share/ufw/iptables/$base"
  ln -s "iptables/$base" "$root/usr/share/ufw/$base"
  cp "$root/usr/share/ufw/iptables/$base" "$root/etc/ufw/$base"
  hash=$(md5sum "$root/usr/share/ufw/iptables/$base" | awk '{print $1}')
  printf '%s  /usr/share/ufw/%s\n' "$hash" "$base" >"$root/usr/share/ufw/$base.md5sum"
done

integrity=$(fw_framework_integrity_files_json)
assert_json "$integrity" '
  .status=="ok" and .modified==false and
  (.paths|length)==0 and (.unverified_paths|length)==0
'

# A locally retained older official UCF version must remain acceptable when
# its hash is present in the package history list.
printf 'official-before.rules-v0\n' >"$root/etc/ufw/before.rules"
old_hash=$(md5sum "$root/etc/ufw/before.rules" | awk '{print $1}')
printf '%s  /usr/share/ufw/before.rules\n' "$old_hash" >>"$root/usr/share/ufw/before.rules.md5sum"
integrity=$(fw_framework_integrity_files_json)
assert_json "$integrity" '.status=="ok" and .modified==false'

# Unknown local edits are not silently accepted.
printf 'local-admin-edit\n' >"$root/etc/ufw/after.rules"
integrity=$(fw_framework_integrity_files_json)
assert_json "$integrity" '
  .status=="modified" and .modified==true and
  any(.paths[]; .=="/etc/ufw/after.rules")
'

# Symlink substitution is treated as modification even when content matches.
cp "$root/usr/share/ufw/iptables/after.rules" "$root/etc/ufw/after.rules"
rm "$root/etc/ufw/after6.rules"
ln -s "$root/usr/share/ufw/iptables/after6.rules" "$root/etc/ufw/after6.rules"
integrity=$(fw_framework_integrity_files_json)
assert_json "$integrity" '
  .status=="modified" and
  any(.paths[]; .=="/etc/ufw/after6.rules")
'

# If neither the current package template nor UCF history can prove a file,
# classification must remain fail-closed as unverified.
rm "$root/etc/ufw/after6.rules"
cp "$root/usr/share/ufw/iptables/after6.rules" "$root/etc/ufw/after6.rules"
rm "$root/usr/share/ufw/iptables/before6.rules" "$root/usr/share/ufw/before6.rules.md5sum"
integrity=$(fw_framework_integrity_files_json)
assert_json "$integrity" '
  .status=="unverified" and .modified==null and
  any(.unverified_paths[]; .=="/etc/ufw/before6.rules")
'

# Restore the fixture used by the adapter tests below.
printf 'official-before6.rules-v1\n' >"$root/usr/share/ufw/iptables/before6.rules"
cp "$root/usr/share/ufw/iptables/before6.rules" "$root/etc/ufw/before6.rules"
hash=$(md5sum "$root/usr/share/ufw/iptables/before6.rules" | awk '{print $1}')
printf '%s  /usr/share/ufw/before6.rules\n' "$hash" >"$root/usr/share/ufw/before6.rules.md5sum"

cat >"$RM_UFW_STATUS_FILE" <<'EOF'
Status: inactive
EOF

# Bug22 regression: real UFW writes human-readable rule/update messages to
# stdout. firewall enable is a JSON-returning CLI path, so those messages must
# be preserved on stderr without polluting its machine-readable stdout.
export RM_UFW_TEST_STDOUT=1
enable_stderr="$root/ufw-enable-stderr.txt"
enabled=$(fw_enable_safe --preserve-port 8443 2>"$enable_stderr")
unset RM_UFW_TEST_STDOUT
assert_json "$enabled" '.status=="enabled" and .ssh_ports_preserved==[22] and .business_ports_preserved==[8443] and .default_policy_preserved==true'
grep -Fq 'Rule added' "$enable_stderr" || fail 'UFW enable human output was not preserved on stderr'
if grep -Fq 'Rule added' <<<"$enabled"; then
  fail 'UFW human output polluted fw_enable_safe JSON stdout'
fi
grep -Fq -- '--force enable' "$RM_UFW_LOG" || fail 'safe UFW enable was not requested'
assert_json "$(cat "$RM_STATE_FILE")" '
  any(.owned_firewall_rules[]; .kind=="ssh-allow" and .port==22) and
  any(.owned_firewall_rules[]; .kind=="preserve-allow" and .port==8443)
'
grep -Fq 'allow to any port 8443' "$RM_UFW_LOG" || fail 'explicit business preserve port was not allowed'
if grep -Fq 'allow to any port 443' "$RM_UFW_LOG"; then
  fail 'unconfirmed business listener was opened automatically'
fi

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

# Real UFW writes human-readable "Rule added" lines to stdout. Helpers whose
# stdout is consumed as JSON must redirect that chatter away from stdout.
export RM_UFW_TEST_STDOUT=1
ensure_stderr="$root/ufw-ensure-stderr.txt"
ensure_json=$(fw_ensure_ssh_port 61235 2>"$ensure_stderr")
unset RM_UFW_TEST_STDOUT
assert_json "$ensure_json" '.status=="added" and .port==61235 and .added==true'
grep -Fq 'Rule added' "$ensure_stderr" || fail 'UFW human output was not preserved on stderr'
if grep -Fq 'Rule added' <<<"$ensure_json"; then
  fail 'UFW human output polluted fw_ensure_ssh_port JSON stdout'
fi
fw_release_ssh_port 61235 >/dev/null 2>&1

# The SSH migration transaction must persist firewall rollback intent before
# the live UFW add. This lets deadline recovery clean up after a SIGKILL at
# any point between the rule write and ownership-state persistence.
tx=''
rm_capture_output tx tx_begin ssh-firewall-intent
intent_json=''
rm_capture_output intent_json fw_ensure_ssh_port 61236 "$tx"
assert_json "$intent_json" '.status=="added" and .port==61236 and .added==true'
assert_json "$(cat "$(tx_file "$tx")")" '.status=="PREPARED" and .ssh.firewall_added_ports==[61236]'

# Simulate a crash after UFW contains the rule but before state.json contains
# its ownership record. Cleanup must reconstruct the deterministic rule.
state_update_filter '.owned_firewall_rules=[.owned_firewall_rules[]|select((.comment//"")!="relay-manager:ssh:61236")]'
: >"$RM_UFW_LOG"
fw_release_ssh_port 61236
grep -Fq -- '--force delete allow to any port 61236 proto tcp comment relay-manager:ssh:61236' "$RM_UFW_LOG" ||
  fail 'SSH firewall cleanup could not recover a rule missing from state ownership'
tx_rollback "$tx" firewall-intent-test

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
old_only=$(fw_apply_whitelist node-fw 443 198.51.100.9)
assert_json "$old_only" '.status=="applied_unverified" and .sources==["198.51.100.9"]'
assert_json "$(cat "$RM_STATE_FILE")" '
  ([.owned_firewall_rules[]|select((.node_id//"")=="node-fw")]|length)==2 and
  any(.owned_firewall_rules[]; (.node_id//"")=="node-fw" and .kind=="allow" and .source=="198.51.100.9") and
  any(.owned_firewall_rules[]; (.node_id//"")=="node-fw" and .kind=="deny")
'
grep -Fq 'prepend allow from 198.51.100.9 to any port 443' "$RM_UFW_LOG" ||
  fail 'initial IPv4 allow was not prepended ahead of deny'
if grep -Fq -- '--force delete deny to any port 443' "$RM_UFW_LOG"; then
  fail 'initial source add deleted retained deny'
fi

: >"$RM_UFW_LOG"
transition=$(fw_apply_whitelist node-fw 443 198.51.100.9 2001:db8::20)
assert_json "$transition" '.status=="applied_unverified" and (.sources|length)==2'
assert_json "$(cat "$RM_STATE_FILE")" '
  ([.owned_firewall_rules[]|select((.node_id//"")=="node-fw")]|length)==3 and
  ([.owned_firewall_rules[]|select((.node_id//"")=="node-fw" and .kind=="allow")]|length)==2 and
  any(.owned_firewall_rules[]; (.node_id//"")=="node-fw" and .kind=="deny")
'
grep -Fq 'prepend allow from 2001:db8:0:0:0:0:0:20 to any port 443' "$RM_UFW_LOG" ||
  fail 'migration did not add the new source'
if grep -Fq 'prepend allow from 198.51.100.9 to any port 443' "$RM_UFW_LOG"; then
  fail 'migration re-added retained old source instead of keeping it'
fi
if grep -Fq -- '--force delete allow from 198.51.100.9 to any port 443' "$RM_UFW_LOG"; then
  fail 'OLD -> OLD+NEW migration deleted retained old source'
fi
if grep -Fq -- '--force delete deny to any port 443' "$RM_UFW_LOG"; then
  fail 'OLD -> OLD+NEW migration deleted retained deny'
fi

: >"$RM_UFW_LOG"
new_only=$(fw_apply_whitelist node-fw 443 2001:db8::20)
assert_json "$new_only" '.status=="applied_unverified" and (.sources|length)==1'
assert_json "$(cat "$RM_STATE_FILE")" '
  ([.owned_firewall_rules[]|select((.node_id//"")=="node-fw")]|length)==2 and
  ([.owned_firewall_rules[]|select((.node_id//"")=="node-fw" and .kind=="allow")]|length)==1 and
  any(.owned_firewall_rules[]; (.node_id//"")=="node-fw" and .kind=="allow" and .source=="2001:db8:0:0:0:0:0:20") and
  any(.owned_firewall_rules[]; (.node_id//"")=="node-fw" and .kind=="deny")
'
grep -Fq -- '--force delete allow from 198.51.100.9 to any port 443' "$RM_UFW_LOG" ||
  fail 'OLD+NEW -> NEW migration did not remove old source'
if grep -Fq 'prepend allow from 2001:db8:0:0:0:0:0:20 to any port 443' "$RM_UFW_LOG"; then
  fail 'OLD+NEW -> NEW migration re-added retained new source'
fi
if grep -Fq -- '--force delete deny to any port 443' "$RM_UFW_LOG"; then
  fail 'OLD+NEW -> NEW migration deleted retained deny'
fi

export RM_UFW_TEST_VERIFY=VERIFY
verified=$(fw_mark_whitelist_verified node-fw)
assert_json "$verified" '.status=="verified_external_contrast"'
assert_json "$(cat "$RM_STATE_FILE")" '.firewall_verifications["node-fw"].verified==true'
status=$(fw_status_json)
assert_json "$status" '
  .isolation_verified==true and .isolation.required_nodes==1 and
  any(.isolation.nodes[];
    .node_id=="node-fw" and .verified==true and
    .verification_recorded==true and .managed_rules_present==true and
    .temporary_public_open==false and .external_allow_conflict==false)
'

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

# Temporary public access is only allowed when a durable periodic
# reconciler is guaranteed to exist. Missing/disabled/inactive must fail
# before lock creation, transaction creation, state mutation, systemd calls
# or UFW writes.
temp_state_sha=$(rm_sha256_file "$RM_STATE_FILE")
temp_tx_count_before=$(find "$RM_TX_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

for maint_state in missing disabled inactive; do
  export RM_UFW_TEST_MAINT_TIMER_STATE="$maint_state"
  : >"$RM_UFW_LOG"
  : >"$RM_SYSTEMCTL_LOG"

  set +e
  fw_temp_open node-fw 10 >/dev/null 2>&1
  rc=$?
  set -e

  assert_eq 10 "$rc" "temporary access did not fail closed when maintenance timer was $maint_state"
  assert_eq "$temp_state_sha" "$(rm_sha256_file "$RM_STATE_FILE")"     "maintenance timer precondition changed state for $maint_state"

  temp_tx_count_after=$(find "$RM_TX_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$temp_tx_count_before" "$temp_tx_count_after"     "maintenance timer precondition created a transaction for $maint_state"

  [[ ! -s $RM_UFW_LOG ]] ||
    fail "maintenance timer precondition wrote UFW rules for $maint_state"
  [[ ! -s $RM_SYSTEMCTL_LOG ]] ||
    fail "maintenance timer precondition invoked systemd for $maint_state"
  [[ ! -e "$root/run/relay-manager/firewall-temp.lock" ]] ||
    fail "maintenance timer precondition created the temporary firewall lock for $maint_state"
done

export RM_UFW_TEST_MAINT_TIMER_STATE=ready
export RM_UFW_TEST_DENY_MARKER_STATE=present
export RM_UFW_TEST_TEMP_MARKER_STATE=absent
export RM_UFW_TEST_TEMP_SWAP_RESULT=applied
: >"$RM_UFW_LOG"
: >"$RM_SYSTEMCTL_LOG"
unset RM_UFW_TEST_MARKER_STATE
opened=''
rm_capture_output opened fw_temp_open node-fw 10
assert_json "$opened" '.status=="temporary_open_applied_unverified" and .node_id=="node-fw"'
status=$(fw_status_json)
assert_json "$status" '
  .isolation_verified==false and
  any(.isolation.nodes[];
    .node_id=="node-fw" and .verified==false and
    .verification_recorded==true and .temporary_public_open==true and
    .reason=="temporary-public-open")
'
grep -Fq 'allow to any port 443' "$RM_UFW_LOG" ||
  fail 'temporary public allow did not replace the managed deny'
if grep -Fq 'prepend allow to any port 443' "$RM_UFW_LOG"; then
  fail 'temporary public allow still used the UFW prepend path'
fi
[[ ${RM_UFW_TEST_TEMP_MARKER_STATE} == present && ${RM_UFW_TEST_DENY_MARKER_STATE} == absent ]] ||
  fail 'temporary public allow was not proven live after DENY replacement'
assert_json "$(cat "$RM_STATE_FILE")" '
  any(.temporary_opens[]; .node_id=="node-fw" and .phase=="APPLIED") and
  any(.owned_files[]; .path=="/etc/systemd/system/relay-manager-temp-node-fw.service") and
  any(.owned_files[]; .path=="/etc/systemd/system/relay-manager-temp-node-fw.timer") and
  (.owned_services|index("relay-manager-temp-node-fw.service"))!=null and
  (.owned_services|index("relay-manager-temp-node-fw.timer"))!=null
'

temp_tx_file=''
for f in "$RM_TX_DIR"/*/transaction.json; do
  [[ -f $f ]] || continue
  if jq -e '.type=="firewall-temp-open"' "$f" >/dev/null 2>&1; then
    temp_tx_file=$f
  fi
done
[[ -n $temp_tx_file ]] || fail 'temporary access transaction record missing'
assert_json "$(cat "$temp_tx_file")" '
  .status=="COMMITTED" and
  (.files|length)==3 and
  any(.files[]; .destination|endswith("/etc/relay-manager/state.json")) and
  any(.files[]; .destination|endswith("/etc/systemd/system/relay-manager-temp-node-fw.service")) and
  any(.files[]; .destination|endswith("/etc/systemd/system/relay-manager-temp-node-fw.timer"))
'

fw_expire_temp node-fw
assert_json "$(cat "$RM_STATE_FILE")" '([.temporary_opens[]|select(.node_id=="node-fw")]|length)==0'
status=$(fw_status_json)
assert_json "$status" '.isolation_verified==true'
grep -Fq 'deny to any port 443' "$RM_UFW_LOG" ||
  fail 'temporary public allow did not restore the managed deny at expiry'
[[ ${RM_UFW_TEST_TEMP_MARKER_STATE} == absent && ${RM_UFW_TEST_DENY_MARKER_STATE} == present ]] ||
  fail 'managed deny was not proven restored at expiry'
grep -Fq 'disable relay-manager-temp-node-fw.timer' "$RM_SYSTEMCTL_LOG" ||
  fail 'temporary access timer was not disabled at expiry'
[[ -f "$root/etc/systemd/system/relay-manager-temp-node-fw.timer" ]] ||
  fail 'expired timer unit should remain as an inert owned file'

# ARMED means UFW mutation never started. Expiry must not issue a delete.
armed_rule=$(fw_rule_args_json allow any 61237 'relay-manager:armed:temporary:1')
state_update_filter '.temporary_opens += [{
  node_id:"armed",deadline_epoch:1,rule_args:$rule,unit:"relay-manager-temp-armed",phase:"ARMED"
}]' --argjson rule "$armed_rule"
: >"$RM_UFW_LOG"
: >"$RM_SYSTEMCTL_LOG"
export RM_UFW_TEST_TEMP_MARKER_STATE=present
export RM_UFW_TEST_DENY_MARKER_STATE=present
fw_expire_temp armed
if grep -Fq -- '--force delete' "$RM_UFW_LOG"; then
  fail 'ARMED temporary access attempted to delete a rule that was never started'
fi
assert_json "$(cat "$RM_STATE_FILE")" '([.temporary_opens[]|select(.node_id=="armed")]|length)==0'

# APPLYING is uncertain: if the temporary marker is live, recovery must
# restore the deterministic managed DENY; unknown marker state preserves intent.
applying_absent_rule=$(fw_rule_args_json allow any 61238 'relay-manager:applying-absent:temporary:1')
state_update_filter '.temporary_opens += [{
  node_id:"applying-absent",deadline_epoch:1,rule_args:$rule,unit:"relay-manager-temp-applying-absent",phase:"APPLYING"
}]' --argjson rule "$applying_absent_rule"
: >"$RM_UFW_LOG"
export RM_UFW_TEST_TEMP_MARKER_STATE=absent
export RM_UFW_TEST_DENY_MARKER_STATE=present
fw_expire_temp applying-absent
if grep -Fq -- '--force delete' "$RM_UFW_LOG"; then
  fail 'APPLYING/absent temporary access issued an unnecessary delete'
fi
assert_json "$(cat "$RM_STATE_FILE")" '([.temporary_opens[]|select(.node_id=="applying-absent")]|length)==0'

applying_present_rule=$(fw_rule_args_json allow any 61239 'relay-manager:applying-present:temporary:1')
state_update_filter '.temporary_opens += [{
  node_id:"applying-present",deadline_epoch:1,rule_args:$rule,unit:"relay-manager-temp-applying-present",phase:"APPLYING"
}]' --argjson rule "$applying_present_rule"
: >"$RM_UFW_LOG"
export RM_UFW_TEST_TEMP_MARKER_STATE=present
export RM_UFW_TEST_DENY_MARKER_STATE=absent
fw_expire_temp applying-present
grep -Fq 'deny to any port 61239 proto tcp comment relay-manager:applying-present:deny' "$RM_UFW_LOG" ||
  fail 'APPLYING/present temporary access did not restore the managed deny'
assert_json "$(cat "$RM_STATE_FILE")" '([.temporary_opens[]|select(.node_id=="applying-present")]|length)==0'

unknown_rule=$(fw_rule_args_json allow any 61240 'relay-manager:unknown:temporary:1')
state_update_filter '.temporary_opens += [{
  node_id:"unknown",deadline_epoch:1,rule_args:$rule,unit:"relay-manager-temp-unknown",phase:"APPLYING"
}]' --argjson rule "$unknown_rule"
: >"$RM_SYSTEMCTL_LOG"
export RM_UFW_TEST_TEMP_MARKER_STATE=unknown
export RM_UFW_TEST_DENY_MARKER_STATE=present
set +e
fw_expire_temp unknown
rc=$?
set -e
assert_eq 21 "$rc" 'unknown UFW marker state did not require recovery'
assert_json "$(cat "$RM_STATE_FILE")" 'any(.temporary_opens[]; .node_id=="unknown" and .phase=="APPLYING")'
if grep -Fq 'disable relay-manager-temp-unknown.timer' "$RM_SYSTEMCTL_LOG"; then
  fail 'unknown UFW marker state disabled the recovery timer'
fi
export RM_UFW_TEST_TEMP_MARKER_STATE=absent
export RM_UFW_TEST_DENY_MARKER_STATE=present
fw_expire_temp unknown

# Regression: real UFW can return rc=0 while printing
# "Skipping inserting existing rule". A successful process exit without the
# temporary marker must never become APPLIED.
export RM_UFW_TEST_TEMP_SWAP_RESULT=skipped
export RM_UFW_TEST_TEMP_MARKER_STATE=absent
export RM_UFW_TEST_DENY_MARKER_STATE=present
: >"$RM_UFW_LOG"
set +e
fw_temp_open node-fw 10 >/dev/null 2>&1
rc=$?
set -e
assert_eq 20 "$rc" 'rc=0 UFW skip was incorrectly accepted as a live temporary allow'
assert_json "$(cat "$RM_STATE_FILE")" '([.temporary_opens[]|select(.node_id=="node-fw")]|length)==0'
[[ ${RM_UFW_TEST_TEMP_MARKER_STATE} == absent && ${RM_UFW_TEST_DENY_MARKER_STATE} == present ]] ||
  fail 'rc=0 UFW skip did not leave the managed deny fail-closed'
export RM_UFW_TEST_TEMP_SWAP_RESULT=applied

# If UFW add itself fails and cleanup cannot be proven, keep APPLYING + timer
# rather than claiming rollback success.
: >"$RM_UFW_LOG"
export RM_UFW_TEST_FAIL=1
export RM_UFW_TEST_FAIL_AFTER_SWAP=1
export RM_UFW_TEST_TEMP_MARKER_STATE=absent
export RM_UFW_TEST_DENY_MARKER_STATE=present
set +e
fw_temp_open node-fw 10 >/dev/null 2>&1
rc=$?
set -e
unset RM_UFW_TEST_FAIL RM_UFW_TEST_FAIL_AFTER_SWAP
assert_eq 21 "$rc" 'uncertain temporary UFW replacement failure did not require recovery'
assert_json "$(cat "$RM_STATE_FILE")" 'any(.temporary_opens[]; .node_id=="node-fw" and .phase=="APPLYING")'
export RM_UFW_TEST_TEMP_MARKER_STATE=absent
export RM_UFW_TEST_DENY_MARKER_STATE=present
fw_expire_temp node-fw
unset RM_UFW_TEST_MARKER_STATE RM_UFW_TEST_TEMP_MARKER_STATE RM_UFW_TEST_DENY_MARKER_STATE RM_UFW_TEST_TEMP_SWAP_RESULT

pass 'Stage C UFW UCF integrity, safe enable, whitelist ownership, conflict refusal and crash-safe timed public access'
