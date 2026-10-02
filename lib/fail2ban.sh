#!/usr/bin/env bash
# Fail2ban SSH jail adapter. It refuses to overwrite an existing administrator-managed [sshd] section.
# shellcheck source=lib/ssh.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ssh.sh"

RM_F2B_DROPIN="$(rm_path /etc/fail2ban/jail.d/relay-manager-ssh.local)"

f2b_existing_sshd_override() {
  local f
  for f in "$(rm_path /etc/fail2ban/jail.local)" "$(rm_path /etc/fail2ban/jail.d)"/*; do
    [[ -f $f ]] || continue
    [[ $f == "$RM_F2B_DROPIN" ]] && continue
    grep -Eq '^[[:space:]]*\[sshd\][[:space:]]*$' "$f" && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

f2b_backend_detect() {
  if [[ -e $(rm_path /var/log/auth.log) ]]; then printf 'auto\n';
  elif rm_have journalctl && [[ -d $(rm_path /run/systemd/journal) || -d $(rm_path /var/log/journal) ]]; then printf 'systemd\n';
  else printf 'unverified\n'; fi
}

f2b_status_json() {
  local installed=false active=false backend conflict=''
  rm_have fail2ban-client && installed=true
  [[ ${RM_TEST_MODE} == 1 && -n ${RM_F2B_TEST_INSTALLED:-} ]] && installed=true
  if [[ $installed == true && ${RM_TEST_MODE} != 1 ]] && systemctl is-active --quiet fail2ban 2>/dev/null; then active=true; fi
  backend=$(f2b_backend_detect); conflict=$(f2b_existing_sshd_override 2>/dev/null || true)
  jq -n --argjson installed "$installed" --argjson active "$active" --arg backend "$backend" --arg conflict "$conflict" '{installed:$installed,active:$active,backend_candidate:$backend,existing_sshd_override:(if $conflict=="" then null else $conflict end)}'
}

f2b_install_packages() {
  local assume_yes=${1:-false} pkg
  rm_require_root || return $?
  local pm; pm=$(system_pkg_manager_json); jq -e '.kind=="apt" and .locked==false' <<<"$pm" >/dev/null || { rm_error "包管理器不可用或被锁定: $(jq -c . <<<"$pm")"; return "$RM_RC_PRECONDITION"; }
  pkg='fail2ban'
  rm_info "计划安装: $pkg（不会运行 autoremove）"
  if [[ $assume_yes != true ]]; then rm_tty_available || return "$RM_RC_PRECONDITION"; rm_confirm '确认安装 Fail2ban?' || return "$RM_RC_CANCEL"; fi
  DEBIAN_FRONTEND=noninteractive apt-get update || return "$RM_RC_NETWORK"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends fail2ban || return "$RM_RC_PRECONDITION"
}

f2b_render_config() {
  local out=$1 backend ports action=''
  backend=$(f2b_backend_detect); [[ $backend != unverified ]] || { rm_error '无法确定 SSH 日志来源'; return "$RM_RC_PRECONDITION"; }
  ports=$(ssh_listen_ports | paste -sd, -); [[ -n $ports ]] || { ports=$(ssh_effective_text root 127.0.0.1 localhost | awk '$1=="port"{print $2}' | paste -sd, -); }
  [[ -n $ports ]] || return "$RM_RC_PRECONDITION"
  if rm_have ufw && fw_ufw_status_text 2>/dev/null | grep -qi '^Status: active'; then action='banaction = ufw'; fi
  cat >"$out" <<EOF2
# Managed by Relay Manager. Only the sshd jail is owned here.
[sshd]
enabled = true
port = $ports
backend = $backend
$action
maxretry = 5
findtime = 10m
bantime = 1h
EOF2
}

f2b_apply_ssh_jail() {
  rm_require_root || return $?
  rm_have fail2ban-client || { rm_error 'Fail2ban 未安装'; return "$RM_RC_PRECONDITION"; }
  local conflict; conflict=$(f2b_existing_sshd_override 2>/dev/null || true)
  [[ -z $conflict ]] || { rm_error "检测到已有 [sshd] 管理配置，拒绝自动覆盖: $conflict"; return "$RM_RC_PRECONDITION"; }
  local tmpdir cfg tx rc=0
  tmpdir=$(rm_safe_tmpdir); cfg="$tmpdir/relay-manager-ssh.local"; f2b_render_config "$cfg" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  # Validate a candidate by temporarily adding only our file is not possible without changing the config tree;
  # transaction + immediate fail2ban-client -t + rollback keeps the old state recoverable.
  tx=$(tx_begin fail2ban-ssh) || { rm -rf "$tmpdir"; return $?; }
  tx_record_service "$tx" fail2ban || true
  tx_stage_file "$tx" "$cfg" "$RM_F2B_DROPIN" 0644 root:root || { tx_rollback "$tx" 'f2b stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'f2b apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }
  if [[ ${RM_TEST_MODE} != 1 ]]; then
    if ! fail2ban-client -t >/dev/null 2>&1 || ! systemctl restart fail2ban || ! fail2ban-client status sshd >/dev/null 2>&1; then
      rc=$RM_RC_APPLY_ROLLED_BACK
      tx_rollback "$tx" 'fail2ban validation failed' || rc=$?
      systemctl restart fail2ban 2>/dev/null || true
      rm -rf "$tmpdir"; return "$rc"
    fi
  fi
  tx_commit "$tx"; state_add_owned_file /etc/fail2ban/jail.d/relay-manager-ssh.local "$(rm_sha256_file "$RM_F2B_DROPIN")"
  rm -rf "$tmpdir"
}

f2b_banned_json() {
  rm_have fail2ban-client || return "$RM_RC_PRECONDITION"
  local out; out=$(fail2ban-client get sshd banip 2>/dev/null || true)
  printf '%s\n' "$out" | tr ' ' '\n' | grep -E '^[0-9a-fA-F:.]+$' | jq -R -s 'split("\n")|map(select(length>0))|{jail:"sshd",banned:.}'
}

f2b_unban() {
  local ip=$1; rm_normalize_ip_or_cidr "$ip" >/dev/null || return "$RM_RC_PRECONDITION"; [[ $ip != */* ]] || return "$RM_RC_PRECONDITION"
  fail2ban-client set sshd unbanip "$ip"
}
