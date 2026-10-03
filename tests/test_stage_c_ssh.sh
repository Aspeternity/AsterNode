#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT

export RM_ROOT="$root" RM_TEST_MODE=1
export RM_SYSTEMCTL_LOG="$root/systemctl.log"
export RM_SSH_TEST_MODE="service:ssh"
export RM_SSH_TEST_PORTS="22,2222"

mkdir -p "$root/etc/ssh/sshd_config.d" "$root/fakebin"
cat >"$root/etc/ssh/sshd_config" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
Match User backup
  PasswordAuthentication no
EOF
cat >"$root/etc/ssh/sshd_config.d/50-cloud-init.conf" <<'EOF'
PasswordAuthentication yes
EOF
export RM_SSH_EFFECTIVE_FILE="$root/sshd-effective.txt"
cat >"$RM_SSH_EFFECTIVE_FILE" <<'EOF'
port 22
pubkeyauthentication yes
passwordauthentication yes
kbdinteractiveauthentication yes
permitrootlogin yes
authenticationmethods any
authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2
authorizedkeyscommand none
authorizedprincipalscommand none
trustedusercakeys none
usepam yes
EOF

cat >"$root/fakebin/sshd" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  -T)
    cat "${RM_SSH_EFFECTIVE_FILE:?}"
    ;;
  -t)
    exit "${RM_SSH_TEST_SYNTAX_RC:-0}"
    ;;
  *)
    exit 10
    ;;
esac
EOF
chmod 0755 "$root/fakebin/sshd"
export PATH="$root/fakebin:$PATH"

source "$PROJECT_DIR/lib/ssh.sh"

state_init

status=$(ssh_detect_json root 127.0.0.1)
assert_json "$status" '
  .start_mode=="service:ssh" and
  .effective.ports==[22] and
  .automation_tightening_safe==true and
  (.automation_blockers|length)==0 and
  .startup.status=="ok" and
  .startup.safe_for_automatic_tightening==true and
  .config_trace.match_detected==true and
  .config_trace.cloud_init_present==true and
  (.config_trace.include_directives|length)>=1
'

export RM_SSH_TEST_EXECSTART='/usr/sbin/sshd -D -o PasswordAuthentication=yes'
blocked_status=$(ssh_detect_json root 127.0.0.1)
assert_json "$blocked_status" '
  .automation_tightening_safe==false and
  any(.automation_blockers[]; startswith("startup-config-overrides:"))
'
export RM_SSH_TEST_EXECSTART='/usr/sbin/sshd -D'

# A supported local AuthorizedKeys path is accepted, while an over-broad nested /home path is not.
assert_eq "$root/root/.ssh/authorized_keys" "$(ssh_authorized_keys_path root)"
set +e
tx_validate_destination "$(rm_path /home/alice/nested/.ssh/authorized_keys)" >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'transaction accepted an over-broad authorized_keys path'

# Generate an ephemeral test key. The private half must be rejected.
ssh-keygen -q -t ed25519 -N '' -f "$root/client" >/dev/null
added=$(ssh_add_public_key root "$root/client.pub")
assert_json "$added" '.status=="added" and .user=="root" and (.fingerprint|startswith("SHA256:"))'
assert_file_mode "$root/root/.ssh" 700
assert_file_mode "$root/root/.ssh/authorized_keys" 600

before_lines=$(grep -Evc '^[[:space:]]*(#|$)' "$root/root/.ssh/authorized_keys")
ssh_add_public_key root "$root/client.pub" >/dev/null
after_lines=$(grep -Evc '^[[:space:]]*(#|$)' "$root/root/.ssh/authorized_keys")
assert_eq "$before_lines" "$after_lines" 'duplicate key material was added twice'

set +e
ssh_validate_public_key_file "$root/client" >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'private key file was accepted'

inv=$(ssh_key_inventory_json root)
assert_json "$inv" '.user=="root" and (.keys|length)==1 and (.keys[0].fingerprint|startswith("SHA256:"))'
fp=$(jq -r '.keys[0].fingerprint' <<<"$inv")

verify_cmd=$(ssh_verification_command_json root 203.0.113.10 2222)
assert_json "$verify_cmd" '
  .port==2222 and
  (.command|contains("-S none")) and
  (.command|contains("ControlMaster=no")) and
  (.command|contains("PasswordAuthentication=no")) and
  (.command|contains("KbdInteractiveAuthentication=no"))
'

export RM_SSH_TEST_MANUAL_VERIFY=VERIFY
verified=$(ssh_mark_key_verified root "$fp")
assert_json "$verified" '.status=="manual_new_connection_verified"'
assert_eq "$fp" "$(jq -r .fingerprint <<<"$verified")" 'verified fingerprint mismatch'
jq -e --arg fp "$fp" '
  .ssh_verifications.root.key_login_manual==true and
  any(.ssh_verifications.root.verified_key_fingerprints[]; .==$fp)
' "$RM_STATE_FILE" >/dev/null || fail 'verified SSH key fingerprint was not persisted'

export RM_SSH_TEST_REMOVE_KEY=REMOVE
rc=0
ssh_remove_public_key root "$fp" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'last verified SSH key was removable'

ssh-keygen -q -t ed25519 -N '' -f "$root/client2" >/dev/null
ssh_add_public_key root "$root/client2.pub" >/dev/null
inv2=$(ssh_key_inventory_json root)
fp2=$(jq -r '.keys[]|select(.fingerprint!="'"$fp"'")|.fingerprint' <<<"$inv2" | head -n1)
[[ -n $fp2 ]] || fail 'second SSH key fingerprint missing'
ssh_mark_key_verified root "$fp2" >/dev/null
removed=$(ssh_remove_public_key root "$fp")
assert_json "$removed" '.status=="removed" and .removed_entries>=1'
inv_after_remove=$(ssh_key_inventory_json root)
assert_eq 1 "$(jq '.keys|length' <<<"$inv_after_remove")" 'key removal did not preserve exactly one remaining key'
assert_eq "$fp2" "$(jq -r '.keys[0].fingerprint' <<<"$inv_after_remove")" 'wrong key remained after fingerprint removal'

guide=$(ssh_recovery_guide_json)
assert_json "$guide" 'has("local_console_steps") and (.boundary|contains("云安全组"))'

# MFA/external authentication blockers must stop automatic tightening.
cat >"$RM_SSH_EFFECTIVE_FILE" <<'EOF'
port 22
pubkeyauthentication yes
passwordauthentication yes
kbdinteractiveauthentication yes
permitrootlogin yes
authenticationmethods publickey,password
authorizedkeysfile .ssh/authorized_keys
authorizedkeyscommand none
authorizedprincipalscommand none
trustedusercakeys none
usepam yes
EOF
set +e
ssh_begin_disable_password root >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'MFA AuthenticationMethods did not block password tightening'

# Restore a simple auth model and exercise protected port migration + rollback.
cat >"$RM_SSH_EFFECTIVE_FILE" <<'EOF'
port 22
pubkeyauthentication yes
passwordauthentication yes
kbdinteractiveauthentication yes
permitrootlogin yes
authenticationmethods any
authorizedkeysfile .ssh/authorized_keys
authorizedkeyscommand none
authorizedprincipalscommand none
trustedusercakeys none
usepam yes
EOF
: >"$RM_SYSTEMCTL_LOG"
migration=$(ssh_begin_port_migration 2222)
assert_json "$migration" '
  .status=="pending_manual_verification" and
  .change=="port-migration" and
  (.transaction_id|length)>0
'
grep -Fq 'start relay-manager-ssh-boot-guard.service' "$RM_SYSTEMCTL_LOG" ||
  fail 'SSH boot recovery guard was not started before migration'
grep -Fq 'start relay-manager-ssh-rollback.timer' "$RM_SYSTEMCTL_LOG" ||
  fail 'SSH rollback timer was not started'
[[ -f "$root/etc/systemd/system/relay-manager-ssh-boot-guard.service" ]] ||
  fail 'SSH boot recovery guard unit missing'
[[ -f "$root/etc/systemd/system/ssh.service.d/relay-manager-guard.conf" ]] ||
  fail 'SSH service guard drop-in missing'
[[ -f "$root/etc/ssh/sshd_config.d/00-relay-manager.conf" ]] ||
  fail 'SSH managed drop-in missing after migration apply'
grep -Fq 'Port 22' "$root/etc/ssh/sshd_config.d/00-relay-manager.conf" ||
  fail 'old SSH port was not preserved during migration'
grep -Fq 'Port 2222' "$root/etc/ssh/sshd_config.d/00-relay-manager.conf" ||
  fail 'new SSH port was not added during migration'

ssh_rollback_pending
[[ ! -e "$root/etc/ssh/sshd_config.d/00-relay-manager.conf" ]] ||
  fail 'pending SSH migration was not rolled back'

# Root publickey-only requires a verified root key and enters a separate protected transaction.
root_change=$(ssh_begin_root_policy publickey-only root)
assert_json "$root_change" '.status=="pending_manual_verification" and .change=="root-publickey-only"'
grep -Fq 'PermitRootLogin prohibit-password' "$root/etc/ssh/sshd_config.d/00-relay-manager.conf" ||
  fail 'root publickey-only policy not rendered'
ssh_rollback_pending

pass 'Stage C SSH detection, key safety, manual verification, protected migration and reboot guard'
