#!/usr/bin/env bash
# Fail2ban SSH jail adapter. Only AsterNode's own jail.d fragment is managed.
# shellcheck source=lib/ssh.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ssh.sh"

RM_F2B_DROPIN="$(rm_path /etc/fail2ban/jail.d/relay-manager-ssh.local)"
RM_F2B_MAXRETRY=5
RM_F2B_FINDTIME=10m
RM_F2B_BANTIME=1h
RM_F2B_MAXMATCHES=10

f2b_client() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    if [[ -n ${RM_F2B_LOG:-} ]]; then printf '%q ' "$@" >>"$RM_F2B_LOG"; printf '\n' >>"$RM_F2B_LOG"; fi
    case "${1:-}" in
      -t) return "${RM_F2B_TEST_CONFIG_RC:-0}" ;;
      status)
        if [[ ${2:-} == sshd ]]; then
          local test_status_fails
          test_status_fails=${RM_F2B_TEST_STATUS_FAILS:-0}
          if [[ $test_status_fails =~ ^[0-9]+$ ]] && ((test_status_fails > 0)); then
            RM_F2B_TEST_STATUS_FAILS=$((test_status_fails - 1))
            return 1
          fi
          printf 'Status for the jail: sshd\n'
          return "${RM_F2B_TEST_STATUS_RC:-0}"
        fi
        ;;
      get)
        if [[ ${2:-} == sshd && ${3:-} == banip ]]; then printf '%s\n' "${RM_F2B_TEST_BANNED:-}"; return 0; fi
        if [[ ${2:-} == dbpurgeage ]]; then printf '%s\n' "${RM_F2B_TEST_DBPURGEAGE:-86400}"; return 0; fi
        if [[ ${2:-} == dbmaxmatches ]]; then printf '%s\n' "${RM_F2B_TEST_DBMAXMATCHES:-10}"; return 0; fi
        if [[ ${2:-} == dbfile ]]; then printf '%s\n' "${RM_F2B_TEST_DBFILE:-/var/lib/fail2ban/fail2ban.sqlite3}"; return 0; fi
        ;;
      set) return 0 ;;
    esac
    return 0
  fi
  fail2ban-client "$@"
}

f2b_is_trusted_distro_sshd_default() {
  local f=$1 expected_path owner expected_md5 actual_md5
  expected_path=$(rm_path /etc/fail2ban/jail.d/defaults-debian.conf)
  [[ $f == "$expected_path" && -f $f && ! -L $f ]] || return 1
  rm_have dpkg-query && rm_have md5sum || return 1

  owner=$(dpkg-query -S /etc/fail2ban/jail.d/defaults-debian.conf 2>/dev/null | awk -F: 'NR==1 {gsub(/[[:space:]]+/, "", $1); print $1}')
  [[ $owner == fail2ban ]] || return 1

  expected_md5=$(dpkg-query -W -f='${Conffiles}\n' fail2ban 2>/dev/null | awk '$1=="/etc/fail2ban/jail.d/defaults-debian.conf" {print $2; exit}')
  [[ $expected_md5 =~ ^[0-9a-fA-F]{32}$ ]] || return 1
  actual_md5=$(md5sum "$f" 2>/dev/null | awk '{print $1}') || return 1
  [[ ${actual_md5,,} == ${expected_md5,,} ]]
}

f2b_existing_sshd_overrides_json() {
  local f items='[]'
  for f in "$(rm_path /etc/fail2ban/jail.local)" "$(rm_path /etc/fail2ban/jail.d)"/*; do
    [[ -f $f && ! -L $f ]] || continue
    [[ $f == "$RM_F2B_DROPIN" ]] && continue
    if grep -Eq '^[[:space:]]*\[sshd\][[:space:]]*$' "$f"; then
      f2b_is_trusted_distro_sshd_default "$f" && continue
      local logical=$f
      [[ -n $RM_ROOT ]] && logical=${f#"${RM_ROOT%/}"}
      items=$(jq -c --arg p "$logical" '.+[$p]' <<<"$items")
    fi
  done
  printf '%s\n' "$items"
}

f2b_existing_sshd_override() {
  f2b_existing_sshd_overrides_json | jq -r '.[0] // empty'
}

f2b_systemd_python_available() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then [[ ${RM_F2B_TEST_SYSTEMD_PY:-1} == 1 ]]; return; fi
  rm_have python3 || return 1
  python3 -c 'import systemd.journal' >/dev/null 2>&1
}

f2b_backend_json() {
  if [[ ${RM_TEST_MODE} == 1 && -n ${RM_F2B_TEST_BACKEND:-} ]]; then
    case "$RM_F2B_TEST_BACKEND" in
      systemd)
        jq -n --argjson dep "$(f2b_systemd_python_available && printf true || printf false)" '{status:(if $dep then "ok" else "unverified" end),backend:"systemd",logpath:null,journalmatch_source:"filter:sshd",dependency:(if $dep then "ok" else "missing-python-systemd" end)}'
        ;;
      polling)
        jq -n --arg p "${RM_F2B_TEST_LOGPATH:-/var/log/auth.log}" '{status:"ok",backend:"polling",logpath:$p,journalmatch_source:null,dependency:"ok"}'
        ;;
      *) jq -n '{status:"unverified",backend:null,logpath:null,journalmatch_source:null,dependency:"unknown"}' ;;
    esac
    return
  fi

  local auth secure
  auth=$(rm_path /var/log/auth.log); secure=$(rm_path /var/log/secure)
  if [[ -f $auth && ! -L $auth ]]; then
    jq -n '{status:"ok",backend:"polling",logpath:"/var/log/auth.log",journalmatch_source:null,dependency:"ok"}'
    return
  fi
  if [[ -f $secure && ! -L $secure ]]; then
    jq -n '{status:"ok",backend:"polling",logpath:"/var/log/secure",journalmatch_source:null,dependency:"ok"}'
    return
  fi
  if rm_have journalctl && { [[ -d $(rm_path /run/systemd/journal) ]] || [[ -d $(rm_path /var/log/journal) ]]; }; then
    if f2b_systemd_python_available; then
      jq -n '{status:"ok",backend:"systemd",logpath:null,journalmatch_source:"filter:sshd",dependency:"ok"}'
    else
      jq -n '{status:"unverified",backend:"systemd",logpath:null,journalmatch_source:"filter:sshd",dependency:"missing-python-systemd"}'
    fi
    return
  fi
  jq -n '{status:"unverified",backend:null,logpath:null,journalmatch_source:null,dependency:"no-supported-log-source"}'
}

f2b_managed_backend_json() {
  local backend='' logpath='' enabled='' dep=true
  if [[ -f $RM_F2B_DROPIN && ! -L $RM_F2B_DROPIN ]]; then
    backend=$(awk '
      BEGIN{sec=""}
      /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
      /^[[:space:]]*\[/ {
        sec=$0
        gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
        sec=tolower(sec)
        next
      }
      sec=="sshd" {
        line=$0
        sub(/[[:space:]]*[#;].*$/, "", line)
        n=index(line,"=")
        if(n>0){
          k=tolower(substr(line,1,n-1)); v=substr(line,n+1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          if(k=="backend"){print v; exit}
        }
      }' "$RM_F2B_DROPIN")
    logpath=$(awk '
      BEGIN{sec=""}
      /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
      /^[[:space:]]*\[/ {
        sec=$0
        gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
        sec=tolower(sec)
        next
      }
      sec=="sshd" {
        line=$0
        sub(/[[:space:]]*[#;].*$/, "", line)
        n=index(line,"=")
        if(n>0){
          k=tolower(substr(line,1,n-1)); v=substr(line,n+1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          if(k=="logpath"){print v; exit}
        }
      }' "$RM_F2B_DROPIN")
    enabled=$(awk '
      BEGIN{sec=""}
      /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
      /^[[:space:]]*\[/ {
        sec=$0
        gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
        sec=tolower(sec)
        next
      }
      sec=="sshd" {
        line=$0
        sub(/[[:space:]]*[#;].*$/, "", line)
        n=index(line,"=")
        if(n>0){
          k=tolower(substr(line,1,n-1)); v=tolower(substr(line,n+1))
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          if(k=="enabled"){print v; exit}
        }
      }' "$RM_F2B_DROPIN")
  fi

  if [[ -n $backend ]]; then
    case "$backend" in
      systemd)
        f2b_systemd_python_available || dep=false
        jq -n --argjson dep "$dep" --arg enabled "$enabled"           '{status:(if $dep then "ok" else "unverified" end),backend:"systemd",logpath:null,
            journalmatch_source:"filter:sshd",dependency:(if $dep then "ok" else "missing-python-systemd" end),
            configured:true,enabled:$enabled}'
        ;;
      polling|auto)
        if [[ -n $logpath ]]; then
          jq -n --arg backend "$backend" --arg logpath "$logpath" --arg enabled "$enabled"             '{status:"ok",backend:$backend,logpath:$logpath,journalmatch_source:null,dependency:"ok",configured:true,enabled:$enabled}'
        else
          jq -n --arg backend "$backend" --arg enabled "$enabled"             '{status:"unverified",backend:$backend,logpath:null,journalmatch_source:null,dependency:"missing-logpath",configured:true,enabled:$enabled}'
        fi
        ;;
      *)
        jq -n --arg backend "$backend" --arg enabled "$enabled"           '{status:"unverified",backend:$backend,logpath:null,journalmatch_source:null,dependency:"unsupported-configured-backend",configured:true,enabled:$enabled}'
        ;;
    esac
    return
  fi

  local detected
  detected=$(f2b_backend_json)
  jq -c '. + {configured:false}' <<<"$detected"
}

f2b_log_source_health_json() {
  local backend_json status backend logical real query_ok=false
  backend_json=$(f2b_managed_backend_json)
  status=$(jq -r .status <<<"$backend_json")
  backend=$(jq -r '.backend // empty' <<<"$backend_json")
  if [[ $status != ok ]]; then
    jq -n --argjson backend "$backend_json" '{status:"unverified",backend:$backend,detail:$backend,reason:"日志后端尚未达到可验证状态"}'
    return 0
  fi
  case "$backend" in
    polling|auto)
      logical=$(jq -r '.logpath // empty' <<<"$backend_json")
      real=$(rm_path "$logical")
      if [[ -f $real && ! -L $real && -r $real ]]; then
        jq -n --arg backend "$backend" --arg path "$logical" '{status:"ok",backend:$backend,logpath:$path,readable:true}'
      else
        jq -n --arg backend "$backend" --arg path "$logical" '{status:"abnormal",backend:$backend,logpath:$path,readable:false,reason:"SSH 日志文件不存在、不可读或为符号链接"}'
      fi
      ;;
    systemd)
      if ! f2b_systemd_python_available; then
        jq -n --arg backend "$backend" '{status:"unverified",backend:$backend,reason:"缺少 python-systemd journal 依赖"}'
        return 0
      fi
      if [[ ${RM_TEST_MODE} == 1 ]]; then
        [[ ${RM_F2B_TEST_JOURNAL_OK:-1} == 1 ]] && query_ok=true
      elif rm_have journalctl && journalctl --no-pager -n 1 -u ssh.service -u sshd.service >/dev/null 2>&1; then
        query_ok=true
      fi
      if [[ $query_ok == true ]]; then
        jq -n --arg backend "$backend" '{status:"ok",backend:$backend,journal_query:true,note:"journal 查询可用；是否存在近期认证事件不作为安装成功的必要条件"}'
      else
        jq -n --arg backend "$backend" '{status:"abnormal",backend:$backend,journal_query:false,reason:"无法查询 SSH systemd journal"}'
      fi
      ;;
    *)
      jq -n '{status:"unverified",backend:null,reason:"未知日志后端"}'
      ;;
  esac
}

f2b_growth_policy_json() {
  local purge='' maxmatches='' dbfile='' logrotate=false
  purge=$(f2b_client get dbpurgeage 2>/dev/null || true)
  maxmatches=$(f2b_client get dbmaxmatches 2>/dev/null || true)
  dbfile=$(f2b_client get dbfile 2>/dev/null || true)
  [[ -f $(rm_path /etc/logrotate.d/fail2ban) && ! -L $(rm_path /etc/logrotate.d/fail2ban) ]] && logrotate=true
  jq -n     --argjson managed_maxmatches "$RM_F2B_MAXMATCHES"     --arg managed_findtime "$RM_F2B_FINDTIME"     --arg managed_bantime "$RM_F2B_BANTIME"     --arg purge "$purge" --arg dbmax "$maxmatches" --arg dbfile "$dbfile" --argjson logrotate "$logrotate"     '{managed_jail:{maxmatches:$managed_maxmatches,findtime:$managed_findtime,bantime:$managed_bantime},
      observed_global_database:{dbpurgeage:(if $purge=="" then null else $purge end),dbmaxmatches:(if $dbmax=="" then null else $dbmax end),dbfile:(if $dbfile=="" then null else $dbfile end)},
      distro_logrotate_detected:$logrotate,
      modifies_global_database_policy:false,
      note:"AsterNode 只限制自有 SSH jail 的 maxmatches；Fail2ban 全局数据库保留和系统日志轮转仅检测/记录，不自动改写，以免影响其他 jail。"}'
}

f2b_runtime_health_json() {
  local installed=false service=false config=false jail=false source growth status
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    [[ ${RM_F2B_TEST_INSTALLED:-1} == 1 ]] && installed=true
    [[ ${RM_F2B_TEST_ACTIVE:-1} == 1 ]] && service=true
  else
    rm_have fail2ban-client && installed=true
    systemctl is-active --quiet fail2ban 2>/dev/null && service=true
  fi
  if [[ $installed == true ]] && f2b_client -t >/dev/null 2>&1; then config=true; fi
  if [[ $installed == true ]] && f2b_client status sshd >/dev/null 2>&1; then jail=true; fi
  source=$(f2b_log_source_health_json)
  growth=$(f2b_growth_policy_json)
  if [[ $installed == true && $service == true && $config == true && $jail == true && $(jq -r .status <<<"$source") == ok ]]; then
    status=normal
  elif [[ $(jq -r .status <<<"$source") == unverified ]]; then
    status=unverified
  else
    status=abnormal
  fi
  jq -n --arg status "$status" --argjson installed "$installed" --argjson service "$service"     --argjson config "$config" --argjson jail "$jail" --argjson source "$source" --argjson growth "$growth"     '{status:$status,installed:$installed,service_active:$service,config_valid:$config,sshd_jail_active:$jail,log_source:$source,growth_policy:$growth}'
}

f2b_recommendation_json() {
  local user=${1:-root} ssh verified=false pass kbd
  ssh=$(ssh_detect_json "$user" 127.0.0.1)
  pass=$(jq -r '.effective.password_authentication // ""' <<<"$ssh")
  kbd=$(jq -r '.effective.kbd_interactive_authentication // ""' <<<"$ssh")
  if [[ -f $RM_STATE_FILE ]] && jq -e --arg u "$user" '((.ssh_verifications[$u].verified_key_fingerprints//[])|length)>0' "$RM_STATE_FILE" >/dev/null 2>&1; then verified=true; fi
  if [[ $pass == yes || $kbd == yes ]]; then
    jq -n --arg user "$user" '{user:$user,recommendation:"recommended",reason:"公网 SSH 仍允许密码或键盘交互认证"}'
  elif [[ $pass == no && $kbd == no && $verified == true ]]; then
    jq -n --arg user "$user" '{user:$user,recommendation:"optional",reason:"已记录纯公钥入口；低资源机器可选择跳过"}'
  else
    jq -n --arg user "$user" '{user:$user,recommendation:"unverified",reason:"无法同时确认认证策略和已验证公钥入口"}'
  fi
}

f2b_status_json() {
  local installed=false active=false backend conflicts recommendation
  rm_have fail2ban-client && installed=true
  [[ ${RM_TEST_MODE} == 1 && ${RM_F2B_TEST_INSTALLED:-1} == 1 ]] && installed=true
  if [[ $installed == true ]]; then
    if [[ ${RM_TEST_MODE} == 1 ]]; then [[ ${RM_F2B_TEST_ACTIVE:-1} == 1 ]] && active=true
    elif systemctl is-active --quiet fail2ban 2>/dev/null; then active=true; fi
  fi
  backend=$(f2b_backend_json)
  conflicts=$(f2b_existing_sshd_overrides_json)
  recommendation=$(f2b_recommendation_json root)
  jq -n --argjson installed "$installed" --argjson active "$active" --argjson backend "$backend" \
    --argjson conflicts "$conflicts" --argjson recommendation "$recommendation" \
    '{installed:$installed,active:$active,backend:$backend,existing_sshd_overrides:$conflicts,
      recommendation:$recommendation,managed_fragment:"/etc/fail2ban/jail.d/relay-manager-ssh.local"}'
}

f2b_install_packages() {
  local assume_yes=${1:-false} pm backend packages=(fail2ban)
  rm_require_root || return $?
  pm=$(system_pkg_manager_json)
  jq -e '.kind=="apt" and .locked==false' <<<"$pm" >/dev/null || {
    rm_error "包管理器不可用或被锁定: $(jq -c . <<<"$pm")"
    return "$RM_RC_PRECONDITION"
  }
  backend=$(f2b_backend_json)
  if [[ $(jq -r '.backend // ""' <<<"$backend") == systemd && $(jq -r .dependency <<<"$backend") != ok ]]; then
    packages+=(python3-systemd)
  fi
  rm_info "计划安装: ${packages[*]}（不会运行 autoremove）"
  if [[ $assume_yes != true ]]; then
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_confirm '确认安装 Fail2ban 及所需日志后端依赖?' || return "$RM_RC_CANCEL"
  fi
  if [[ ${RM_TEST_MODE} == 1 ]]; then return 0; fi
  DEBIAN_FRONTEND=noninteractive apt-get update || return "$RM_RC_NETWORK"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}" || return "$RM_RC_PRECONDITION"
}

f2b_normalize_ignore_json() {
  local items='["127.0.0.1/8","::1"]' ip norm
  for ip in "$@"; do
    norm=$(rm_normalize_ip_or_cidr "$ip") || { rm_error "无效 Fail2ban 豁免来源: $ip"; return "$RM_RC_PRECONDITION"; }
    items=$(jq -c --arg n "$norm" '.+[$n]|unique' <<<"$items")
  done
  printf '%s\n' "$items"
}

f2b_banaction_line() {
  local action_file
  action_file=$(rm_path /etc/fail2ban/action.d/ufw.conf)
  if [[ -f $action_file ]]; then
    local fw; fw=$(fw_status_json)
    if jq -e '.installed==true and .active==true and .complex_environment==false' <<<"$fw" >/dev/null; then
      printf 'banaction = ufw\n'
    fi
  fi
}

f2b_render_config() {
  local out=$1; shift
  local backend_json backend logpath ports action ignore_json
  backend_json=$(f2b_backend_json)
  [[ $(jq -r .status <<<"$backend_json") == ok ]] || {
    rm_error "无法确定可用 Fail2ban SSH 日志后端: $(jq -c . <<<"$backend_json")"
    return "$RM_RC_PRECONDITION"
  }
  backend=$(jq -r .backend <<<"$backend_json")
  logpath=$(jq -r '.logpath // empty' <<<"$backend_json")
  ports=$(ssh_listen_ports | paste -sd, -)
  [[ -n $ports ]] || ports=$(ssh_effective_text root 127.0.0.1 localhost | awk '$1=="port"{print $2}' | paste -sd, -)
  [[ -n $ports ]] || { rm_error '无法确定 SSH 实际端口'; return "$RM_RC_PRECONDITION"; }
  ignore_json=$(f2b_normalize_ignore_json "$@") || return $?
  action=$(f2b_banaction_line || true)

  {
    printf '# Managed by AsterNode. Only this sshd jail fragment is owned here.\n'
    printf '[sshd]\n'
    printf 'enabled = true\n'
    printf 'port = %s\n' "$ports"
    printf 'backend = %s\n' "$backend"
    if [[ $backend == polling ]]; then printf 'logpath = %s\n' "$logpath"; fi
    [[ -n $action ]] && printf '%s\n' "$action"
    printf 'ignoreip = %s\n' "$(jq -r 'join(" ")' <<<"$ignore_json")"
    printf 'maxretry = %s\n' "$RM_F2B_MAXRETRY"
    printf 'findtime = %s\n' "$RM_F2B_FINDTIME"
    printf 'bantime = %s\n' "$RM_F2B_BANTIME"
    printf 'maxmatches = %s\n' "$RM_F2B_MAXMATCHES"
  } >"$out"
}

f2b_wait_sshd_ready() {
  local attempts=${RM_F2B_READY_ATTEMPTS:-10} delay=${RM_F2B_READY_DELAY:-1} i
  [[ $attempts =~ ^[1-9][0-9]*$ ]] || attempts=10

  for ((i=1; i<=attempts; i++)); do
    f2b_client status sshd >/dev/null 2>&1 && return 0
    ((i < attempts)) || break
    if [[ ${RM_TEST_MODE} != 1 ]]; then sleep "$delay"; fi
  done
  return 1
}

f2b_apply_ssh_jail() {
  rm_require_root || return $?
  if [[ ${RM_TEST_MODE} != 1 ]] && ! rm_have fail2ban-client; then
    rm_error 'Fail2ban 未安装'
    return "$RM_RC_PRECONDITION"
  fi
  local conflicts
  conflicts=$(f2b_existing_sshd_overrides_json)
  [[ $(jq 'length' <<<"$conflicts") == 0 ]] || {
    rm_error "检测到已有 [sshd] 管理配置，拒绝自动覆盖: $(jq -c . <<<"$conflicts")"
    return "$RM_RC_PRECONDITION"
  }

  local tmpdir cfg tx rc=0
  tmpdir=$(rm_safe_tmpdir); cfg="$tmpdir/relay-manager-ssh.local"
  f2b_render_config "$cfg" "$@" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }

  rm_capture_output tx tx_begin fail2ban-ssh || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  tx_record_service "$tx" fail2ban true || true
  tx_stage_file "$tx" "$cfg" "$RM_F2B_DROPIN" 0644 root:root || {
    tx_rollback "$tx" 'f2b stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION";
  }
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'f2b apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }

  if ! f2b_client -t >/dev/null 2>&1; then
    rc=$RM_RC_APPLY_ROLLED_BACK
    tx_rollback "$tx" 'fail2ban config validation failed' || rc=$?
    rm -rf "$tmpdir"; return "$rc"
  fi

  if [[ ${RM_TEST_MODE} == 1 ]]; then
    rm_systemctl restart fail2ban
  else
    systemctl restart fail2ban || {
      rc=$RM_RC_APPLY_ROLLED_BACK
      tx_rollback "$tx" 'fail2ban restart failed' || rc=$?
      systemctl restart fail2ban 2>/dev/null || true
      rm -rf "$tmpdir"; return "$rc"
    }
  fi
  if ! f2b_wait_sshd_ready; then
    rc=$RM_RC_APPLY_ROLLED_BACK
    tx_rollback "$tx" 'sshd jail not ready after restart' || rc=$?
    [[ ${RM_TEST_MODE} == 1 ]] && rm_systemctl restart fail2ban || systemctl restart fail2ban 2>/dev/null || true
    rm -rf "$tmpdir"; return "$rc"
  fi
  local source_health
  source_health=$(f2b_log_source_health_json)
  if [[ $(jq -r .status <<<"$source_health") != ok ]]; then
    rc=$RM_RC_APPLY_ROLLED_BACK
    tx_rollback "$tx" 'fail2ban SSH log source unavailable after restart' || rc=$?
    [[ ${RM_TEST_MODE} == 1 ]] && rm_systemctl restart fail2ban || systemctl restart fail2ban 2>/dev/null || true
    rm -rf "$tmpdir"; return "$rc"
  fi

  tx_commit "$tx" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  state_add_owned_file /etc/fail2ban/jail.d/relay-manager-ssh.local "$(rm_sha256_file "$RM_F2B_DROPIN")"
  local backend health; backend=$(f2b_backend_json); health=$(f2b_runtime_health_json)
  rm -rf "$tmpdir"
  jq -n --argjson backend "$backend" --argjson health "$health" '{status:"applied",jail:"sshd",backend:$backend,health:$health,
    note:"只管理 AsterNode 的 SSH jail 片段；未修改 jail.local、全局数据库保留或其他 jail。"}'
}

f2b_disable_managed() {
  rm_require_root || return $?
  [[ -f $RM_F2B_DROPIN && ! -L $RM_F2B_DROPIN ]] || {
    jq -n '{status:"already_disabled_or_absent"}'
    return 0
  }
  local tmpdir cfg tx rc=0
  tmpdir=$(rm_safe_tmpdir); cfg="$tmpdir/disabled.local"
  cat >"$cfg" <<'EOF'
# Managed by AsterNode. The managed sshd jail is intentionally disabled.
[sshd]
enabled = false
EOF
  rm_capture_output tx tx_begin fail2ban-disable || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  tx_record_service "$tx" fail2ban true || true
  tx_stage_file "$tx" "$cfg" "$RM_F2B_DROPIN" 0644 root:root || {
    tx_rollback "$tx" 'f2b disable stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION";
  }
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'f2b disable apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }
  f2b_client -t >/dev/null 2>&1 || { tx_rollback "$tx" 'disabled config invalid' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
  if [[ ${RM_TEST_MODE} == 1 ]]; then rm_systemctl restart fail2ban
  else systemctl restart fail2ban || { tx_rollback "$tx" 'fail2ban restart failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }; fi
  tx_commit "$tx" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  state_add_owned_file /etc/fail2ban/jail.d/relay-manager-ssh.local "$(rm_sha256_file "$RM_F2B_DROPIN")"
  rm -rf "$tmpdir"
  jq -n '{status:"managed_sshd_jail_disabled",other_jails_untouched:true}'
}

f2b_banned_json() {
  if [[ ${RM_TEST_MODE} != 1 ]] && ! rm_have fail2ban-client; then return "$RM_RC_PRECONDITION"; fi
  local out
  out=$(f2b_client get sshd banip 2>/dev/null || true)
  printf '%s\n' "$out" | tr ' ' '\n' | grep -E '^[0-9a-fA-F:.]+$' | jq -R -s 'split("\n")|map(select(length>0))|{jail:"sshd",banned:.}'
}

f2b_unban() {
  local ip=$1 norm
  norm=$(rm_normalize_ip_or_cidr "$ip") || return "$RM_RC_PRECONDITION"
  [[ $norm != */* ]] || { rm_error '解封只接受单个 IP，不接受 CIDR'; return "$RM_RC_PRECONDITION"; }
  f2b_client set sshd unbanip "$norm"
}
