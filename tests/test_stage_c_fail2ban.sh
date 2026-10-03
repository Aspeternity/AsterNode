#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
export RM_F2B_LOG="$root/f2b.log"
export RM_SYSTEMCTL_LOG="$root/systemctl.log"
export RM_SSH_TEST_MODE="service:ssh"
export RM_SSH_TEST_PORTS="22,2222"
export RM_F2B_TEST_INSTALLED=1 RM_F2B_TEST_ACTIVE=1
export RM_UFW_STATUS_FILE="$root/ufw-status.txt"
export RM_UFW_ADDED_FILE="$root/ufw-added.txt"
export RM_UFW_RAW_FILE="$root/ufw-raw.txt"
export RM_UFW_FRAMEWORK_MODIFIED=false

mkdir -p "$root/fakebin" "$root/etc/ssh/sshd_config.d" "$root/etc/fail2ban/jail.d"   "$root/etc/fail2ban/action.d" "$root/var/log" "$root/etc/default"
export RM_SSH_EFFECTIVE_FILE="$root/sshd-effective.txt"

cat >"$RM_SSH_EFFECTIVE_FILE" <<'EOF'
port 22
port 2222
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
cat >"$root/fakebin/sshd" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  -T) cat "${RM_SSH_EFFECTIVE_FILE:?}" ;;
  -t) exit 0 ;;
  *) exit 10 ;;
esac
EOF
chmod 0755 "$root/fakebin/sshd"
export PATH="$root/fakebin:$PATH"

cat >"$root/etc/default/ufw" <<'EOF'
IPV6=yes
EOF
cat >"$RM_UFW_STATUS_FILE" <<'EOF'
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)
EOF
: >"$RM_UFW_ADDED_FILE"
: >"$RM_UFW_RAW_FILE"
: >"$RM_F2B_LOG"
: >"$RM_SYSTEMCTL_LOG"
: >"$root/etc/fail2ban/action.d/ufw.conf"
: >"$root/var/log/auth.log"

source "$PROJECT_DIR/lib/fail2ban.sh"
state_init

backend=$(f2b_backend_json)
assert_json "$backend" '.status=="ok" and .backend=="polling" and .logpath=="/var/log/auth.log"'

recommend=$(f2b_recommendation_json root)
assert_json "$recommend" '.recommendation=="recommended"'

cfg="$root/rendered.local"
f2b_render_config "$cfg" 203.0.113.5 2001:db8::5
grep -Fq 'backend = polling' "$cfg" || fail 'file backend not rendered'
grep -Fq 'logpath = /var/log/auth.log' "$cfg" || fail 'file backend logpath missing'
grep -Fq 'port = 22,2222' "$cfg" || fail 'actual SSH ports not rendered'
grep -Fq 'banaction = ufw' "$cfg" || fail 'active UFW action not selected'
grep -Fq 'ignoreip = 127.0.0.1/8 ::1 203.0.113.5 2001:db8:0:0:0:0:0:5' "$cfg" ||
  fail 'explicit management ignore sources were not normalized'
if grep -Fq '198.51.100.9' "$cfg"; then
  fail 'an unrelated upstream whitelist leaked into Fail2ban ignoreip'
fi

cat >"$root/etc/fail2ban/jail.local" <<'EOF'
[sshd]
enabled = true
EOF
set +e
f2b_apply_ssh_jail >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'existing administrator-managed sshd jail was overwritten'
rm -f "$root/etc/fail2ban/jail.local"

applied=$(f2b_apply_ssh_jail 203.0.113.5)
assert_json "$applied" '.status=="applied" and .jail=="sshd" and .backend.backend=="polling"'
assert_file_mode "$root/etc/fail2ban/jail.d/relay-manager-ssh.local" 644
grep -Fq -- '-t' "$RM_F2B_LOG" || fail 'Fail2ban candidate config was not validated'
grep -Fq 'restart fail2ban' "$RM_SYSTEMCTL_LOG" || fail 'Fail2ban service was not restarted'
assert_json "$(cat "$RM_STATE_FILE")" '
  any(.owned_files[]; .path=="/etc/fail2ban/jail.d/relay-manager-ssh.local")
'

export RM_F2B_TEST_BANNED='198.51.100.2 2001:db8::2'
banned=$(f2b_banned_json)
assert_json "$banned" '.jail=="sshd" and (.banned|length)==2'
f2b_unban 198.51.100.2
grep -Fq 'set sshd unbanip 198.51.100.2' "$RM_F2B_LOG" || fail 'Fail2ban unban was not issued'

disabled=$(f2b_disable_managed)
assert_json "$disabled" '.status=="managed_sshd_jail_disabled" and .other_jails_untouched==true'
grep -Fq 'enabled = false' "$root/etc/fail2ban/jail.d/relay-manager-ssh.local" ||
  fail 'managed sshd jail was not disabled'

# Systemd backend must not carry a file logpath.
rm -f "$root/var/log/auth.log"
mkdir -p "$root/run/systemd/journal"
export RM_F2B_TEST_BACKEND=systemd RM_F2B_TEST_SYSTEMD_PY=1
syscfg="$root/systemd.local"
f2b_render_config "$syscfg"
grep -Fq 'backend = systemd' "$syscfg" || fail 'systemd backend not rendered'
if grep -Eq '^[[:space:]]*logpath[[:space:]]*=' "$syscfg"; then
  fail 'systemd backend incorrectly copied a logpath'
fi

export RM_F2B_TEST_SYSTEMD_PY=0
unverified=$(f2b_backend_json)
assert_json "$unverified" '.status=="unverified" and .backend=="systemd" and .dependency=="missing-python-systemd"'
set +e
f2b_render_config "$root/invalid.local" >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'missing systemd journal dependency did not block jail rendering'

pass 'Stage C Fail2ban backend selection, conflict refusal, UFW action, ignore scope and managed disable'
