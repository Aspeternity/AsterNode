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
Port 22
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
    managed="${RM_ROOT:?}/etc/ssh/sshd_config.d/00-relay-manager.conf"
    if [[ -f $managed ]]; then
      awk 'tolower($1)=="listenaddress"{print "listenaddress "$2}' "$managed"
    fi
    if [[ ${RM_SSH_TEST_LONG_EFFECTIVE:-0} == 1 ]]; then
      for ((i=0;i<10000;i++)); do
        printf 'unusedoption%s value\n' "$i"
      done
    fi
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

# External ListenAddress directives are ownership conflicts for automated port changes.
cat >"$root/etc/ssh/sshd_config.d/60-external-listen.conf" <<'EOF'
ListenAddress 127.0.0.1:22
EOF
listen_blocked=$(ssh_detect_json root 127.0.0.1)
assert_json "$listen_blocked" '
  .automation_tightening_safe==false and
  any(.automation_blockers[]; startswith("unmanaged-listenaddress:")) and
  (.config_trace.unmanaged_listen_addresses|length)==1
'
set +e
ssh_begin_port_migration 2222 >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'external ListenAddress did not block automated port migration'
rm -f "$root/etc/ssh/sshd_config.d/60-external-listen.conf"

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
# Real sshd -T emits much more output than this fixture. Keep writing after the
# matching pubkey line so the old grep -q pipeline would hit SIGPIPE under
# set -o pipefail; verification must still succeed.
export RM_SSH_TEST_LONG_EFFECTIVE=1
verified=$(ssh_mark_key_verified root "$fp")
unset RM_SSH_TEST_LONG_EFFECTIVE
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
grep -Fq 'ListenAddress 0.0.0.0:22' "$root/etc/ssh/sshd_config.d/00-relay-manager.conf" ||
  fail 'managed IPv4 listener for old port missing during migration'
grep -Fq 'ListenAddress [::]:2222' "$root/etc/ssh/sshd_config.d/00-relay-manager.conf" ||
  fail 'managed IPv6 listener for new port missing during migration'
runtime=$(ssh_runtime_ports_json root)
assert_json "$runtime" '.effective==[22,2222] and .actual==[22,2222]'

ssh_rollback_pending
[[ ! -e "$root/etc/ssh/sshd_config.d/00-relay-manager.conf" ]] ||
  fail 'pending SSH migration was not rolled back'

# Commit a dual-port migration, then prove remove-old-port cannot falsely pass
# while the runtime still exposes the old listener.
migration2=$(ssh_begin_port_migration 2222)
tx2=$(jq -r .transaction_id <<<"$migration2")
export RM_SSH_TEST_COMMIT=COMMIT
committed2=$(ssh_confirm_pending "$tx2")
unset RM_SSH_TEST_COMMIT
assert_json "$committed2" '.status=="committed_after_manual_verification"'
assert_json "$(cat "$RM_SSH_POLICY")" '.ports==[22,2222] and (.listen_families|sort)==["ipv4","ipv6"]'

set +e
ssh_begin_remove_old_port 2222 >/dev/null 2>&1
rc=$?
set -e
assert_eq 20 "$rc" 'remove-old-port did not roll back when the old runtime listener remained'
assert_json "$(cat "$RM_SSH_POLICY")" '.ports==[22,2222]' 

# When apply reaches the target listener set, confirm must still reject any
# extra old listener that appears before COMMIT.
export RM_SSH_TEST_PORTS=2222
remove_pending=$(ssh_begin_remove_old_port 2222)
remove_tx=$(jq -r .transaction_id <<<"$remove_pending")
assert_json "$remove_pending" '.status=="pending_manual_verification" and .change=="remove-old-port"'
assert_json "$(ssh_runtime_ports_json root)" '.effective==[2222] and .actual==[2222]'

export RM_SSH_TEST_PORTS=22,2222
export RM_SSH_TEST_COMMIT=COMMIT
set +e
ssh_confirm_pending "$remove_tx" >/dev/null 2>&1
rc=$?
set -e
unset RM_SSH_TEST_COMMIT
assert_eq 10 "$rc" 'SSH confirm accepted an extra old runtime listener'
ssh_rollback_pending
assert_json "$(cat "$RM_SSH_POLICY")" '.ports==[22,2222]'

# Full success path: apply and confirm with only the retained port listening.
# Seed the old SSH allow as AsterNode-owned so confirm must exercise the
# real firewall-release path and its human UFW output redirection.
old_fw_args=$(fw_rule_args_json allow any 22 'relay-manager:ssh:22')
fw_store_rule "$(jq -n --argjson a "$old_fw_args" '{
  comment:"relay-manager:ssh:22",
  port:22,
  kind:"ssh-allow",
  source:"any",
  args:$a
}')"

export RM_SSH_TEST_PORTS=2222
remove_pending=$(ssh_begin_remove_old_port 2222)
remove_tx=$(jq -r .transaction_id <<<"$remove_pending")
export RM_SSH_TEST_COMMIT=COMMIT
export RM_UFW_TEST_STDOUT=1
remove_stderr="$root/remove-confirm-stderr.txt"
remove_committed=$(ssh_confirm_pending "$remove_tx" 2>"$remove_stderr")
unset RM_UFW_TEST_STDOUT
unset RM_SSH_TEST_COMMIT
assert_json "$remove_committed" '.status=="committed_after_manual_verification"'
grep -Fq 'Rule deleted' "$remove_stderr" ||
  fail 'UFW delete chatter was not preserved on stderr during SSH confirm'
if grep -Fq 'Rule deleted' <<<"$remove_committed"; then
  fail 'UFW delete chatter polluted SSH confirm JSON stdout'
fi
assert_json "$(cat "$RM_SSH_POLICY")" '.ports==[2222]'
assert_json "$(ssh_runtime_ports_json root)" '.effective==[2222] and .actual==[2222]'

# Root publickey-only requires a verified root key and enters a separate protected transaction.
root_change=$(ssh_begin_root_policy publickey-only root)
assert_json "$root_change" '.status=="pending_manual_verification" and .change=="root-publickey-only"'
grep -Fq 'PermitRootLogin prohibit-password' "$root/etc/ssh/sshd_config.d/00-relay-manager.conf" ||
  fail 'root publickey-only policy not rendered'
ssh_rollback_pending

case_socket_mode_and_boot_guard() (
  set -Eeuo pipefail
  socket_root=$(new_test_root)
  trap 'rm -rf "$socket_root"' EXIT

  export RM_ROOT="$socket_root" RM_TEST_MODE=1
  export RM_SYSTEMCTL_LOG="$socket_root/systemctl.log"
  export RM_SSH_TEST_MODE=socket
  export RM_SSH_TEST_SOCKET_LISTEN="0.0.0.0:22 (Stream)
[::]:22 (Stream)"
  unset RM_SSH_TEST_PORTS

  mkdir -p "$socket_root/etc/ssh/sshd_config.d" "$socket_root/fakebin"
  cat >"$socket_root/etc/ssh/sshd_config" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
Port 22
EOF
  export RM_SSH_EFFECTIVE_FILE="$socket_root/sshd-effective.txt"
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

  cat >"$socket_root/fakebin/sshd" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  -T)
    cat "${RM_SSH_EFFECTIVE_FILE:?}"
    managed="${RM_ROOT:?}/etc/ssh/sshd_config.d/00-relay-manager.conf"
    if [[ -f $managed ]]; then
      awk 'tolower($1)=="listenaddress"{print "listenaddress "$2}' "$managed"
    fi
    ;;
  -t) exit 0 ;;
  *) exit 10 ;;
esac
EOF
  chmod 0755 "$socket_root/fakebin/sshd"
  export PATH="$socket_root/fakebin:$PATH"

  source "$PROJECT_DIR/lib/ssh.sh"
  state_init
  : >"$RM_SYSTEMCTL_LOG"

  status=$(ssh_detect_json root 127.0.0.1)
  assert_json "$status" '
    .start_mode=="socket" and
    .effective.ports==[22] and
    .actual_listen_ports==[22] and
    .automation_tightening_safe==true and
    (.automation_blockers|length)==0 and
    .startup.status=="ok" and
    .startup.safe_for_automatic_tightening==true
  '
  assert_eq ssh.service "$(ssh_startup_service_unit_name)"     'Accept=no socket activation did not resolve the paired ssh.service'
  assert_json "$(ssh_listen_families_json)" 'sort==["ipv4","ipv6"]'

  # Ubuntu 24.04 uses ssh.socket Accept=no with ssh.service as the backing
  # daemon. Startup overrides on that service must still block automation.
  export RM_SSH_TEST_EXECSTART='/usr/sbin/sshd -D -p 2200'
  blocked=$(ssh_detect_json root 127.0.0.1)
  assert_json "$blocked" '
    .automation_tightening_safe==false and
    any(.automation_blockers[]; contains("startup-config-overrides:port-override(-p)"))
  '
  export RM_SSH_TEST_EXECSTART='/usr/sbin/sshd -D -o PasswordAuthentication=no'
  blocked=$(ssh_detect_json root 127.0.0.1)
  assert_json "$blocked" '
    .automation_tightening_safe==false and
    any(.automation_blockers[]; contains("startup-config-overrides:option-override(-o)"))
  '
  export RM_SSH_TEST_EXECSTART='/usr/sbin/sshd -D'

  # Accept=yes requires an instantiated/template backing service model that
  # is not safely resolved by the first release. Remain fail-closed.
  export RM_SSH_TEST_SOCKET_ACCEPT=yes
  blocked=$(ssh_detect_json root 127.0.0.1)
  assert_json "$blocked" '
    .startup.status=="unverified" and
    .automation_tightening_safe==false and
    any(.automation_blockers[]; .=="startup-arguments-unverified")
  '
  export RM_SSH_TEST_SOCKET_ACCEPT=no

  # An explicit Accept=no Service= is authoritative when present.
  export RM_SSH_TEST_SOCKET_SERVICE=custom-ssh.service
  assert_eq custom-ssh.service "$(ssh_startup_service_unit_name)"     'explicit socket Service= was not selected as the backing daemon'
  unset RM_SSH_TEST_SOCKET_SERVICE

  migration=$(ssh_begin_port_migration 2222)
  tx=$(jq -r .transaction_id <<<"$migration")
  assert_json "$migration" '
    .status=="pending_manual_verification" and
    .change=="port-migration" and
    (.transaction_id|length)>0
  '
  [[ -f "$RM_SSH_SOCKET_DROPIN" ]] || fail 'socket migration did not create ssh.socket override'
  grep -Fxq 'ListenStream=' "$RM_SSH_SOCKET_DROPIN" ||
    fail 'socket override did not reset inherited listeners'
  grep -Fxq 'ListenStream=0.0.0.0:22' "$RM_SSH_SOCKET_DROPIN" ||
    fail 'socket override did not preserve IPv4 old-port listener'
  grep -Fxq 'ListenStream=[::]:22' "$RM_SSH_SOCKET_DROPIN" ||
    fail 'socket override did not preserve IPv6 old-port listener'
  grep -Fxq 'ListenStream=0.0.0.0:2222' "$RM_SSH_SOCKET_DROPIN" ||
    fail 'socket override did not add IPv4 new-port listener'
  grep -Fxq 'ListenStream=[::]:2222' "$RM_SSH_SOCKET_DROPIN" ||
    fail 'socket override did not add IPv6 new-port listener'
  if grep -Eq '^ListenStream=(22|2222)$' "$RM_SSH_SOCKET_DROPIN"; then
    fail 'socket override regressed to family-ambiguous bare ports'
  fi
  grep -Fq 'restart socket' "$RM_SYSTEMCTL_LOG" ||
    fail 'socket migration did not restart ssh.socket mode'
  grep -Fq 'ExecStart=/usr/local/bin/relay-manager ssh rollback-pending --boot-guard'     "$RM_SSH_BOOT_GUARD_SERVICE" ||
    fail 'boot guard was not wired to boot-guard rollback context'
  if grep -Fq -- '--boot-guard' "$RM_SSH_PROTECT_SERVICE"; then
    fail 'deadline rollback service was incorrectly switched to boot-guard mode'
  fi
  assert_json "$(ssh_runtime_ports_json root)" '
    .effective==[22,2222] and
    .actual==[22,2222] and
    .actual_families==["ipv4","ipv6"]
  '

  : >"$RM_SYSTEMCTL_LOG"
  ssh_rollback_pending --boot-guard
  assert_eq ROLLED_BACK "$(jq -r .status "$(tx_file "$tx")")"
  [[ ! -e "$RM_SSH_SOCKET_DROPIN" ]] ||
    fail 'boot guard rollback did not restore the pre-migration socket configuration'
  grep -Fxq 'daemon-reload' "$RM_SYSTEMCTL_LOG" ||
    fail 'boot guard rollback did not daemon-reload restored systemd configuration'
  if grep -Eq '(^| )restart (socket|ssh\.socket)($| )' "$RM_SYSTEMCTL_LOG"; then
    fail 'boot guard synchronously restarted SSH and can deadlock boot ordering'
  fi
  if grep -Eq '(^| )(enable|disable|start|stop) ssh\.socket($| )' "$RM_SYSTEMCTL_LOG"; then
    fail 'boot guard transaction rollback restored ssh.socket service state inside the guard'
  fi
  assert_json "$(ssh_runtime_ports_json root)" '
    .effective==[22] and
    .actual==[22] and
    .actual_families==["ipv4","ipv6"]
  '

  # Ordinary/manual rollback keeps the existing behavior and explicitly
  # restarts the currently selected SSH mode after restoring files.
  : >"$RM_SYSTEMCTL_LOG"
  migration2=$(ssh_begin_port_migration 2222)
  ssh_rollback_pending
  grep -Fq 'restart socket' "$RM_SYSTEMCTL_LOG" ||
    fail 'ordinary socket rollback stopped restarting the active SSH mode'
  assert_json "$(ssh_runtime_ports_json root)" '
    .effective==[22] and
    .actual==[22] and
    .actual_families==["ipv4","ipv6"]
  '

  # Fault injection: both ports are present, but IPv4 is missing. The apply
  # path must rollback before returning pending_manual_verification.
  mkdir -p "$(dirname "$RM_SSH_POLICY")"
  cat >"$RM_SSH_POLICY" <<'EOF'
{
  "ports": [22],
  "listen_families": ["ipv4", "ipv6"],
  "password_authentication": null,
  "kbd_interactive_authentication": null,
  "permit_root_login": null
}
EOF
  export RM_SSH_TEST_SOCKET_RUNTIME_LISTEN="[::]:22 (Stream)
[::]:2222 (Stream)"
  set +e
  ssh_begin_port_migration 2222 >/dev/null 2>&1
  rc=$?
  set -e
  unset RM_SSH_TEST_SOCKET_RUNTIME_LISTEN
  assert_eq 20 "$rc" 'socket migration did not propagate apply-rollback after losing IPv4 listeners'
  if ssh_pending_tx_id >/dev/null 2>&1; then
    fail 'family-mismatch rollback left an APPLIED_PENDING SSH transaction'
  fi
  assert_json "$(cat "$RM_SSH_POLICY")" '
    .ports==[22] and
    (.listen_families|sort)==["ipv4","ipv6"]
  '
  [[ ! -e "$RM_SSH_SOCKET_DROPIN" ]] ||
    fail 'family-mismatch rollback left the managed socket override behind'
  assert_json "$(ssh_runtime_ports_json root)" '
    .effective==[22] and
    .actual==[22] and
    .actual_families==["ipv4","ipv6"]
  '
)

case_socket_mode_and_boot_guard

case_mid_apply_ssh_recovery() (
  set -Eeuo pipefail
  crash_root=$(new_test_root)
  trap 'rm -rf "$crash_root"' EXIT

  export RM_ROOT="$crash_root" RM_TEST_MODE=1
  export RM_SYSTEMCTL_LOG="$crash_root/systemctl.log"
  export RM_SSH_TEST_MODE="service:ssh"
  export RM_SSH_TEST_PORTS=22

  source "$PROJECT_DIR/lib/ssh.sh"
  state_init
  : >"$RM_SYSTEMCTL_LOG"

  mkdir -p "$(dirname "$RM_SSH_POLICY")" "$(dirname "$RM_SSH_DROPIN")" "$(dirname "$RM_SSH_SOCKET_DROPIN")"
  printf 'old-policy\n' >"$RM_SSH_POLICY"
  printf 'old-dropin\n' >"$RM_SSH_DROPIN"
  chmod 0600 "$RM_SSH_POLICY"
  chmod 0644 "$RM_SSH_DROPIN"

  prepare_mid_apply_ssh_tx() {
    local apply_count=$1 tag=$2 tmp tx i staged dest sha
    tmp=$(rm_safe_tmpdir)
    printf 'new-policy-%s\n' "$tag" >"$tmp/policy"
    printf 'new-dropin-%s\n' "$tag" >"$tmp/dropin"
    printf 'new-socket-%s\n' "$tag" >"$tmp/socket"

    tx=$(tx_begin "ssh-change:root-disable" "$(( $(rm_epoch)+300 ))")
    tx_update "$tx" '.ssh={change:"root-disable",ports:[22],listen_families:["ipv4","ipv6"],target_user:"root"}'
    tx_stage_file "$tx" "$tmp/policy" "$RM_SSH_POLICY" 0600 root:root
    tx_stage_file "$tx" "$tmp/dropin" "$RM_SSH_DROPIN" 0644 root:root
    tx_stage_file "$tx" "$tmp/socket" "$RM_SSH_SOCKET_DROPIN" 0644 root:root

    for ((i=0;i<apply_count;i++)); do
      staged=$(jq -r ".files[$i].staged" "$(tx_file "$tx")")
      dest=$(jq -r ".files[$i].destination" "$(tx_file "$tx")")
      cp -- "$staged" "$dest"
      sha=$(rm_sha256_file "$dest")
      tx_update "$tx" "(.files[$i].applied_sha256=\$sha|.files[$i].phase=\"APPLIED\")" --arg sha "$sha"
    done

    rm -rf "$tmp"
    RM_TEST_CRASH_TX=$tx
  }

  # Deterministic reproduction of Bug 11: the manager dies while the
  # transaction is still PREPARED after only the first file was applied.
  (
    prepare_mid_apply_ssh_tx 1 sigkill
    printf '%s\n' "$RM_TEST_CRASH_TX" >"$crash_root/crash-tx"
    : >"$crash_root/crash-ready"
    while :; do sleep 1; done
  ) &
  manager_pid=$!

  for _ in {1..200}; do
    [[ -f "$crash_root/crash-ready" ]] && break
    kill -0 "$manager_pid" 2>/dev/null || fail 'mid-apply crash harness exited before SIGKILL'
    sleep 0.01
  done
  [[ -f "$crash_root/crash-ready" ]] || fail 'mid-apply crash harness did not reach the deterministic crash point'
  tx=$(cat "$crash_root/crash-tx")
  assert_eq PREPARED "$(jq -r .status "$(tx_file "$tx")")" 'crash transaction did not remain PREPARED'
  assert_eq APPLIED "$(jq -r '.files[0].phase' "$(tx_file "$tx")")" 'first SSH file was not applied before crash'
  assert_eq STAGED "$(jq -r '.files[1].phase' "$(tx_file "$tx")")" 'second SSH file unexpectedly applied before crash'

  kill -KILL "$manager_pid"
  wait "$manager_pid" 2>/dev/null || true

  guide=$(ssh_recovery_guide_json)
  assert_json "$guide" --arg tx "$tx" '
    .pending==true and
    .transaction_id==$tx and
    .change=="root-disable"
  '

  # This is the command executed by the deadline rollback service.
  ssh_rollback_pending
  assert_eq ROLLED_BACK "$(jq -r .status "$(tx_file "$tx")")" 'deadline rollback missed PREPARED partial SSH apply'
  assert_eq old-policy "$(cat "$RM_SSH_POLICY")" 'deadline rollback did not restore the first applied SSH file'
  assert_eq old-dropin "$(cat "$RM_SSH_DROPIN")" 'deadline rollback changed an untouched SSH file'
  [[ ! -e "$RM_SSH_SOCKET_DROPIN" ]] || fail 'deadline rollback left a staged-only socket override behind'

  # Boot guard must also claim the same PREPARED mid-apply crash state.
  prepare_mid_apply_ssh_tx 1 boot-guard
  boot_tx=$RM_TEST_CRASH_TX
  ssh_rollback_pending --boot-guard
  assert_eq ROLLED_BACK "$(jq -r .status "$(tx_file "$boot_tx")")" 'boot guard missed PREPARED partial SSH apply'
  assert_eq old-policy "$(cat "$RM_SSH_POLICY")" 'boot guard did not restore PREPARED partial SSH apply'

  # If rollback itself is interrupted, a second recovery pass must be
  # idempotent. Simulate one file already restored while status persists as
  # ROLLING_BACK, then recover twice.
  prepare_mid_apply_ssh_tx 2 rolling-back
  rolling_tx=$RM_TEST_CRASH_TX
  rolling_file=$(tx_file "$rolling_tx")
  second_dest=$(jq -r '.files[1].destination' "$rolling_file")
  second_snap=$(jq -r '.files[1].snapshot' "$rolling_file")
  cp -- "$second_snap" "$second_dest"
  tx_update "$rolling_tx" '.status="ROLLING_BACK"|.failure_reason="simulated rollback interruption"'

  ssh_rollback_pending --boot-guard
  assert_eq ROLLED_BACK "$(jq -r .status "$rolling_file")" 'ROLLING_BACK recovery did not converge to ROLLED_BACK'
  assert_eq old-policy "$(cat "$RM_SSH_POLICY")" 'ROLLING_BACK recovery did not restore remaining applied file'
  assert_eq old-dropin "$(cat "$RM_SSH_DROPIN")" 'ROLLING_BACK recovery damaged an already-restored file'
  first_hash=$(rm_sha256_file "$RM_SSH_POLICY")
  second_hash=$(rm_sha256_file "$RM_SSH_DROPIN")

  ssh_rollback_pending --boot-guard
  assert_eq ROLLED_BACK "$(jq -r .status "$rolling_file")" 'second recovery changed terminal rollback state'
  assert_eq "$first_hash" "$(rm_sha256_file "$RM_SSH_POLICY")" 'second recovery was not idempotent for SSH policy'
  assert_eq "$second_hash" "$(rm_sha256_file "$RM_SSH_DROPIN")" 'second recovery was not idempotent for SSH drop-in'
)

case_mid_apply_ssh_recovery

pass 'Stage C SSH detection, key safety, exact listener ownership, protected migration, crash recovery and reboot guard'
