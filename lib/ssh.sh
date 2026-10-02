#!/usr/bin/env bash
# OpenSSH inspection and protected migration. Authentication confirmation is deliberately manual
# unless reliable auth-log correlation is added and validated on a target distro.
# shellcheck source=lib/transaction.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/transaction.sh"

RM_SSH_POLICY="$(rm_path /etc/relay-manager/ssh-policy.json)"
RM_SSH_DROPIN="$(rm_path /etc/ssh/sshd_config.d/00-relay-manager.conf)"
RM_SSH_SOCKET_DROPIN="$(rm_path /etc/systemd/system/ssh.socket.d/relay-manager.conf)"
RM_SSH_PROTECT_SERVICE="$(rm_path /etc/systemd/system/relay-manager-ssh-rollback.service)"
RM_SSH_PROTECT_TIMER="$(rm_path /etc/systemd/system/relay-manager-ssh-rollback.timer)"

ssh_sshd_bin() {
  if rm_have sshd; then command -v sshd; elif [[ -x /usr/sbin/sshd ]]; then printf '/usr/sbin/sshd\n'; else return "$RM_RC_PRECONDITION"; fi
}

ssh_service_mode() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then printf '%s\n' "${RM_SSH_TEST_MODE:-service}"; return 0; fi
  if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then printf 'socket\n';
  elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then printf 'service:ssh\n';
  elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then printf 'service:sshd\n';
  else printf 'unknown\n'; fi
}

ssh_effective_text() {
  local user=${1:-root} addr=${2:-127.0.0.1} host=${3:-localhost} bin
  bin=$(ssh_sshd_bin) || return $?
  "$bin" -T -C "user=$user,host=$host,addr=$addr" 2>/dev/null
}

ssh_listen_ports() {
  if [[ ${RM_TEST_MODE} == 1 && -n ${RM_SSH_TEST_PORTS:-} ]]; then tr ',' '\n' <<<"$RM_SSH_TEST_PORTS"; return 0; fi
  if rm_have ss; then
    ss -H -lntp 2>/dev/null | awk '$0 ~ /sshd/ {a=$4; sub(/^.*:/,"",a); if(a~/^[0-9]+$/) print a}' | sort -nu
  fi
}

ssh_detect_json() {
  local user=${1:-root} addr=${2:-127.0.0.1} mode effective=''
  mode=$(ssh_service_mode)
  if effective=$(ssh_effective_text "$user" "$addr" localhost 2>/dev/null); then :; else effective=''; fi
  local ports='[]' actual='[]'
  if [[ -n $effective ]]; then ports=$(awk '$1=="port"{print $2}' <<<"$effective" | jq -R -s 'split("\n")|map(select(length>0)|tonumber)|unique'); fi
  actual=$(ssh_listen_ports | jq -R -s 'split("\n")|map(select(length>0)|tonumber)|unique')
  jq -n --arg mode "$mode" --arg user "$user" --argjson effective_ports "$ports" --argjson actual_ports "$actual" \
    --arg pubkey "$(awk '$1=="pubkeyauthentication"{print $2;exit}' <<<"$effective")" \
    --arg pass "$(awk '$1=="passwordauthentication"{print $2;exit}' <<<"$effective")" \
    --arg kbd "$(awk '$1=="kbdinteractiveauthentication"{print $2;exit}' <<<"$effective")" \
    --arg root "$(awk '$1=="permitrootlogin"{print $2;exit}' <<<"$effective")" \
    --arg authm "$(awk '$1=="authenticationmethods"{print $2;exit}' <<<"$effective")" \
    --arg akf "$(awk '$1=="authorizedkeysfile"{$1="";sub(/^ /,"");print;exit}' <<<"$effective")" \
    --arg akc "$(awk '$1=="authorizedkeyscommand"{print $2;exit}' <<<"$effective")" \
    '{user:$user,start_mode:$mode,effective:{ports:$effective_ports,pubkey_authentication:$pubkey,password_authentication:$pass,kbd_interactive_authentication:$kbd,permit_root_login:$root,authentication_methods:$authm,authorized_keys_file:$akf,authorized_keys_command:$akc},actual_listen_ports:$actual_ports,auth_method_verified:false,note:"SSH_CONNECTION 只作线索；本结果不自动证明当前会话认证方式"}'
}

ssh_main_config_test() { local bin; bin=$(ssh_sshd_bin) || return $?; "$bin" -t; }

ssh_home_for_user() { getent passwd "$1" | awk -F: '{print $6}'; }
ssh_uid_gid_for_user() { getent passwd "$1" | awk -F: '{print $3":"$4}'; }

ssh_authorized_keys_path() {
  local user=$1 eff akf first home
  eff=$(ssh_effective_text "$user" 127.0.0.1 localhost) || return "$RM_RC_PRECONDITION"
  akf=$(awk '$1=="authorizedkeysfile"{$1="";sub(/^ /,"");print;exit}' <<<"$eff"); first=${akf%% *}; home=$(ssh_home_for_user "$user")
  [[ -n $home && -n $first ]] || return "$RM_RC_PRECONDITION"
  first=${first//%u/$user}; first=${first//%h/$home}
  if [[ $first == /* ]]; then printf '%s\n' "$(rm_path "$first")"; else printf '%s/%s\n' "$(rm_path "$home")" "$first"; fi
}

ssh_public_key_material() {
  local line=$1
  awk '{for(i=1;i<=NF;i++) if($i ~ /^(ssh-|ecdsa-|sk-)/ && (i+1)<=NF){print $(i+1); exit}}' <<<"$line"
}

ssh_validate_public_key_file() {
  local f=$1
  [[ -f $f ]] || return "$RM_RC_PRECONDITION"
  grep -q 'BEGIN .*PRIVATE KEY' "$f" && { rm_error '拒绝私钥，只接受客户端公钥。'; return "$RM_RC_PRECONDITION"; }
  local line material
  line=$(grep -Ev '^[[:space:]]*(#|$)' "$f" | head -n1); material=$(ssh_public_key_material "$line")
  [[ -n $material ]] || { rm_error '无法解析公钥格式'; return "$RM_RC_PRECONDITION"; }
  local tmp; tmp=$(mktemp); printf '%s\n' "$line" >"$tmp"
  ssh-keygen -lf "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; rm_error 'ssh-keygen 校验公钥失败'; return "$RM_RC_PRECONDITION"; }
  rm -f "$tmp"; printf '%s\n' "$line"
}

ssh_add_public_key() {
  local user=$1 keyfile=$2 line path dir owner material tmp tx
  rm_require_root || return $?; line=$(ssh_validate_public_key_file "$keyfile") || return $?
  path=$(ssh_authorized_keys_path "$user") || { rm_error '无法安全确定 AuthorizedKeysFile'; return "$RM_RC_PRECONDITION"; }
  owner=$(ssh_uid_gid_for_user "$user"); [[ -n $owner ]] || return "$RM_RC_PRECONDITION"; dir=$(dirname "$path")
  [[ -L $path || -L $dir ]] && { rm_error 'AuthorizedKeys 路径包含符号链接，拒绝自动修改'; return "$RM_RC_PRECONDITION"; }
  mkdir -p "$dir"; chmod 0700 "$dir"; [[ ${RM_TEST_MODE} == 1 ]] || chown "$owner" "$dir"
  tmp=$(rm_safe_tmpdir)/authorized_keys
  [[ -f $path ]] && cat "$path" >"$tmp" || : >"$tmp"
  material=$(ssh_public_key_material "$line")
  if awk -v m="$material" '{for(i=1;i<=NF;i++) if($i==m) found=1} END{exit found?0:1}' "$tmp"; then rm_info '相同密钥材料已存在，不重复添加。'; return 0; fi
  printf '%s\n' "$line" >>"$tmp"
  tx=$(tx_begin ssh-add-key) || return $?
  tx_stage_file "$tx" "$tmp" "$path" 0600 "$owner" || { tx_rollback "$tx" 'key stage failed' || true; return "$RM_RC_PRECONDITION"; }
  tx_apply "$tx" || { local rc=$?; tx_rollback "$tx" 'key apply failed' || true; return "$rc"; }
  tx_commit "$tx"
  ssh-keygen -lf "$path" | tail -n1
}

ssh_policy_load_or_init() {
  local out=$1 ports
  state_init_dirs
  if [[ -f $RM_SSH_POLICY ]]; then jq . "$RM_SSH_POLICY" >"$out"; return; fi
  ports=$(ssh_effective_text root 127.0.0.1 localhost | awk '$1=="port"{print $2}' | jq -R -s 'split("\n")|map(select(length>0)|tonumber)|unique')
  jq -n --argjson ports "$ports" '{ports:$ports,password_authentication:null,kbd_interactive_authentication:null,permit_root_login:null}' >"$out"
}

ssh_policy_render_dropin() {
  local policy=$1 out=$2
  {
    printf '# Managed by Relay Manager. Do not edit directly.\n'
    jq -r '.ports[]? | "Port \(.)"' "$policy"
    local v
    v=$(jq -r '.password_authentication//empty' "$policy"); [[ -n $v ]] && printf 'PasswordAuthentication %s\n' "$v"
    v=$(jq -r '.kbd_interactive_authentication//empty' "$policy"); [[ -n $v ]] && printf 'KbdInteractiveAuthentication %s\n' "$v"
    v=$(jq -r '.permit_root_login//empty' "$policy"); [[ -n $v ]] && printf 'PermitRootLogin %s\n' "$v"
  } >"$out"
}

ssh_socket_render_override() {
  local policy=$1 out=$2
  { printf '[Socket]\nListenStream=\n'; jq -r '.ports[]? | "ListenStream=\(.)"' "$policy"; } >"$out"
}

ssh_protection_setup() {
  local deadline=$1 tmpdir svc timer tx
  tmpdir=$(rm_safe_tmpdir); svc="$tmpdir/service"; timer="$tmpdir/timer"
  cat >"$svc" <<'EOS'
[Unit]
Description=Relay Manager SSH rollback protection
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/relay-manager ssh rollback-pending
EOS
  cat >"$timer" <<EOS
[Unit]
Description=Relay Manager SSH rollback deadline
[Timer]
OnCalendar=@$deadline
Persistent=true
AccuracySec=1s
Unit=relay-manager-ssh-rollback.service
[Install]
WantedBy=timers.target
EOS
  tx=$(tx_begin ssh-protection) || { rm -rf "$tmpdir"; return $?; }
  tx_stage_file "$tx" "$svc" "$RM_SSH_PROTECT_SERVICE" 0644 root:root || { tx_rollback "$tx" 'protect service stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  tx_stage_file "$tx" "$timer" "$RM_SSH_PROTECT_TIMER" 0644 root:root || { tx_rollback "$tx" 'protect timer stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  tx_apply "$tx" || { local rc=$?; tx_rollback "$tx" 'protect apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }
  if [[ ${RM_TEST_MODE} != 1 ]]; then
    systemctl daemon-reload && systemctl enable --now relay-manager-ssh-rollback.timer >/dev/null || { tx_rollback "$tx" 'protect timer activation failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl is-active --quiet relay-manager-ssh-rollback.timer || { tx_rollback "$tx" 'protect timer not active' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
  fi
  tx_commit "$tx"; rm -rf "$tmpdir"
}

ssh_protection_disable() {
  [[ ${RM_TEST_MODE} == 1 ]] && return 0
  systemctl disable --now relay-manager-ssh-rollback.timer >/dev/null 2>&1 || true
}

ssh_restart_mode() {
  local mode=$1
  if [[ ${RM_TEST_MODE} == 1 ]]; then rm_systemctl restart "$mode"; return 0; fi
  systemctl daemon-reload
  case "$mode" in socket) systemctl restart ssh.socket;; service:ssh) systemctl restart ssh.service;; service:sshd) systemctl restart sshd.service;; *) return "$RM_RC_PRECONDITION";; esac
}

ssh_pending_tx_id() {
  local f
  for f in "$RM_TX_DIR"/*/transaction.json; do [[ -f $f ]] || continue; jq -er 'select(.status=="APPLIED_PENDING" and (.type|startswith("ssh-change:")))|.transaction_id' "$f" 2>/dev/null && return 0; done
  return 1
}

ssh_apply_policy_protected() {
  local policy=$1 change=$2 deadline=${3:-$(( $(rm_epoch)+300 ))} mode tmpdir drop socket tx rc
  rm_require_root || return $?; rm_tty_available || { rm_error 'SSH 安全修改要求交互 TTY。'; return "$RM_RC_PRECONDITION"; }
  ssh_protection_setup "$deadline" || return $?
  mode=$(ssh_service_mode); [[ $mode != unknown ]] || { ssh_protection_disable; return "$RM_RC_PRECONDITION"; }
  tmpdir=$(rm_safe_tmpdir); drop="$tmpdir/ssh.conf"; socket="$tmpdir/socket.conf"
  ssh_policy_render_dropin "$policy" "$drop"; ssh_socket_render_override "$policy" "$socket"
  tx=$(tx_begin "ssh-change:$change" "$deadline") || { ssh_protection_disable; rm -rf "$tmpdir"; return $?; }
  tx_update "$tx" '.ssh={change:$change,ports:$ports}' --arg change "$change" --argjson ports "$(jq '.ports' "$policy")"
  tx_stage_file "$tx" "$policy" "$RM_SSH_POLICY" 0600 root:root || { tx_rollback "$tx" 'policy stage failed' || true; ssh_protection_disable; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  tx_stage_file "$tx" "$drop" "$RM_SSH_DROPIN" 0644 root:root || { tx_rollback "$tx" 'dropin stage failed' || true; ssh_protection_disable; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  if [[ $mode == socket ]]; then tx_stage_file "$tx" "$socket" "$RM_SSH_SOCKET_DROPIN" 0644 root:root || { tx_rollback "$tx" 'socket override stage failed' || true; ssh_protection_disable; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }; fi
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'SSH apply failed' || true; ssh_protection_disable; rm -rf "$tmpdir"; return "$rc"; }
  if ! ssh_main_config_test || ! ssh_restart_mode "$mode"; then rc=$RM_RC_APPLY_ROLLED_BACK; tx_rollback "$tx" 'SSHD syntax/restart failed' || rc=$?; ssh_restart_mode "$mode" || true; ssh_protection_disable; rm -rf "$tmpdir"; return "$rc"; fi
  rm -rf "$tmpdir"
  jq -n --arg tx "$tx" --arg change "$change" --argjson deadline "$deadline" '{status:"pending_manual_verification",transaction_id:$tx,change:$change,deadline_epoch:$deadline,note:"请保持当前会话，另开一个全新 SSH 连接验证后再执行 ssh confirm。"}'
}

ssh_begin_port_migration() {
  local newport=$1 tmp policy ports
  rm_valid_port "$newport" || return "$RM_RC_PRECONDITION"
  if rm_have ss && ss -H -lnt "sport = :$newport" 2>/dev/null | grep -q .; then rm_error '新 SSH 端口已被占用'; return "$RM_RC_PRECONDITION"; fi
  tmp=$(rm_safe_tmpdir); policy="$tmp/policy.json"; ssh_policy_load_or_init "$policy"
  ports=$(jq --argjson p "$newport" '.ports + [$p] | unique' "$policy"); jq --argjson ports "$ports" '.ports=$ports' "$policy" >"$tmp/p2"; mv "$tmp/p2" "$policy"
  local result; result=$(ssh_apply_policy_protected "$policy" port-migration) || { local rc=$?; rm -rf "$tmp"; return "$rc"; }; printf '%s\n' "$result"; rm -rf "$tmp"
}

ssh_begin_remove_old_port() {
  local keep=$1 tmp policy
  rm_valid_port "$keep" || return "$RM_RC_PRECONDITION"
  tmp=$(rm_safe_tmpdir); policy="$tmp/policy.json"; ssh_policy_load_or_init "$policy"
  jq --argjson p "$keep" '.ports=[$p]' "$policy" >"$tmp/p2"; mv "$tmp/p2" "$policy"
  local result; result=$(ssh_apply_policy_protected "$policy" remove-old-port) || { local rc=$?; rm -rf "$tmp"; return "$rc"; }; printf '%s\n' "$result"; rm -rf "$tmp"
}

ssh_mark_key_verified() {
  local user=$1 ans
  rm_tty_available || return "$RM_RC_PRECONDITION"
  ssh_effective_text "$user" 127.0.0.1 localhost | grep -q '^pubkeyauthentication yes' || { rm_error '有效配置未允许公钥认证'; return "$RM_RC_PRECONDITION"; }
  rm_read_tty ans '请确认：你刚刚使用该用户在“全新 SSH 连接”中成功完成公钥登录，且未回退到密码/键盘交互。输入 VERIFY 继续: '
  [[ $ans == VERIFY ]] || return "$RM_RC_CANCEL"
  state_init >/dev/null; state_update_filter '.ssh_verifications=((.ssh_verifications//{}) + {($user):{key_login_manual:true,verified_at:$now}})' --arg user "$user"
}

ssh_begin_disable_password() {
  local user=$1 tmp policy eff authm verified
  state_init >/dev/null; verified=$(jq -r --arg u "$user" '.ssh_verifications[$u].key_login_manual//false' "$RM_STATE_FILE"); [[ $verified == true ]] || { rm_error '先完成新连接公钥登录并执行 ssh mark-key-verified。'; return "$RM_RC_PRECONDITION"; }
  eff=$(ssh_effective_text "$user" 127.0.0.1 localhost); authm=$(awk '$1=="authenticationmethods"{print $2;exit}' <<<"$eff")
  [[ -z $authm || $authm == any ]] || { rm_error "检测到 AuthenticationMethods=$authm，可能存在 MFA；拒绝自动关闭密码。"; return "$RM_RC_PRECONDITION"; }
  tmp=$(rm_safe_tmpdir); policy="$tmp/policy.json"; ssh_policy_load_or_init "$policy"
  jq '.password_authentication="no"|.kbd_interactive_authentication="no"' "$policy" >"$tmp/p2"; mv "$tmp/p2" "$policy"
  local result; result=$(ssh_apply_policy_protected "$policy" disable-password) || { local rc=$?; rm -rf "$tmp"; return "$rc"; }; printf '%s\n' "$result"; rm -rf "$tmp"
}

ssh_record_sudo_verified() {
  local user=${1:?user required} actual=${SUDO_USER:-}
  [[ $user != root ]] || return "$RM_RC_PRECONDITION"
  [[ $actual == "$user" ]] || { rm_error '请以目标普通用户执行 sudo relay-manager ssh verify-sudo <user>，以证明实际提权链路。'; return "$RM_RC_PRECONDITION"; }
  state_init >/dev/null; state_update_filter '.ssh_verifications=((.ssh_verifications//{}) + {($user):((.ssh_verifications[$user]//{}) + {sudo_manual:true,sudo_verified_at:$now})})' --arg user "$user"
}

ssh_begin_root_policy() {
  local policy_name=$1 admin_user=${2:-} tmp policy keyok sudook
  [[ $policy_name == publickey-only || $policy_name == disable ]] || return "$RM_RC_PRECONDITION"
  state_init >/dev/null
  if [[ $policy_name == disable ]]; then
    [[ -n $admin_user && $admin_user != root ]] || return "$RM_RC_PRECONDITION"
    keyok=$(jq -r --arg u "$admin_user" '.ssh_verifications[$u].key_login_manual//false' "$RM_STATE_FILE"); sudook=$(jq -r --arg u "$admin_user" '.ssh_verifications[$u].sudo_manual//false' "$RM_STATE_FILE")
    [[ $keyok == true && $sudook == true ]] || { rm_error '禁用 Root 前必须验证非 Root 新连接和实际 sudo 提权。'; return "$RM_RC_PRECONDITION"; }
  fi
  tmp=$(rm_safe_tmpdir); policy="$tmp/policy.json"; ssh_policy_load_or_init "$policy"
  if [[ $policy_name == disable ]]; then jq '.permit_root_login="no"' "$policy" >"$tmp/p2"; else jq '.permit_root_login="prohibit-password"' "$policy" >"$tmp/p2"; fi; mv "$tmp/p2" "$policy"
  local result; result=$(ssh_apply_policy_protected "$policy" "root-$policy_name") || { local rc=$?; rm -rf "$tmp"; return "$rc"; }; printf '%s\n' "$result"; rm -rf "$tmp"
}

ssh_confirm_pending() {
  local tx=${1:-} f change ans eff ports p
  [[ -n $tx ]] || tx=$(ssh_pending_tx_id) || { rm_error '没有待确认 SSH 事务'; return "$RM_RC_PRECONDITION"; }
  f=$(tx_file "$tx"); [[ $(jq -r .status "$f") == APPLIED_PENDING ]] || return "$RM_RC_PRECONDITION"; change=$(jq -r '.ssh.change' "$f")
  ssh_main_config_test || return "$RM_RC_PRECONDITION"
  ports=$(jq -c '.ssh.ports' "$f")
  if [[ $change == port-migration || $change == remove-old-port ]]; then
    for p in $(jq -r '.[]' <<<"$ports"); do ssh_listen_ports | grep -qx "$p" || { rm_error "目标端口未监听: $p"; return "$RM_RC_PRECONDITION"; }; done
  fi
  eff=$(ssh_effective_text root 127.0.0.1 localhost || true)
  if [[ $change == disable-password ]]; then grep -q '^passwordauthentication no' <<<"$eff" && grep -q '^kbdinteractiveauthentication no' <<<"$eff" || return "$RM_RC_PRECONDITION"; fi
  if [[ $change == root-disable ]]; then grep -q '^permitrootlogin no' <<<"$eff" || return "$RM_RC_PRECONDITION"; fi
  rm_tty_available || return "$RM_RC_PRECONDITION"
  rm_read_tty ans '请确认：你已从另一个“全新 SSH 连接”按新策略成功登录，并保留当前旧会话作为兜底。输入 COMMIT 提交: '
  [[ $ans == COMMIT ]] || return "$RM_RC_CANCEL"
  tx_commit "$tx"; ssh_protection_disable
  jq -n --arg tx "$tx" '{status:"committed_after_manual_verification",transaction_id:$tx}'
}

ssh_rollback_pending() {
  local tx mode rc=0; tx=$(ssh_pending_tx_id) || { ssh_protection_disable; return 0; }
  mode=$(ssh_service_mode)
  tx_rollback "$tx" 'SSH 验证未确认或保护计时到期' || rc=$?
  ssh_restart_mode "$mode" || rc=$RM_RC_RECOVERY_INCOMPLETE
  ssh_protection_disable
  return "$rc"
}
