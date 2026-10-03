#!/usr/bin/env bash
# OpenSSH inspection and protected migration. Authentication confirmation is deliberately manual
# unless reliable auth-log correlation is added and validated on a target distro.
# shellcheck source=lib/transaction.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/transaction.sh"
# shellcheck source=lib/firewall.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/firewall.sh"

RM_SSH_POLICY="$(rm_path /etc/relay-manager/ssh-policy.json)"
RM_SSH_DROPIN="$(rm_path /etc/ssh/sshd_config.d/00-relay-manager.conf)"
RM_SSH_SOCKET_DROPIN="$(rm_path /etc/systemd/system/ssh.socket.d/relay-manager.conf)"
RM_SSH_PROTECT_SERVICE="$(rm_path /etc/systemd/system/relay-manager-ssh-rollback.service)"
RM_SSH_PROTECT_TIMER="$(rm_path /etc/systemd/system/relay-manager-ssh-rollback.timer)"
RM_SSH_BOOT_GUARD_SERVICE="$(rm_path /etc/systemd/system/relay-manager-ssh-boot-guard.service)"
RM_SSH_SOCKET_GUARD_DROPIN="$(rm_path /etc/systemd/system/ssh.socket.d/relay-manager-guard.conf)"
RM_SSH_SERVICE_GUARD_DROPIN="$(rm_path /etc/systemd/system/ssh.service.d/relay-manager-guard.conf)"
RM_SSHD_SERVICE_GUARD_DROPIN="$(rm_path /etc/systemd/system/sshd.service.d/relay-manager-guard.conf)"

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

ssh_effective_value() {
  local text=$1 key=$2
  awk -v k="$key" '$1==k {$1=""; sub(/^ /,""); print; exit}' <<<"$text"
}

ssh_service_unit_name() {
  local mode
  mode=$(ssh_service_mode)
  case "$mode" in
    service:ssh) printf 'ssh.service\n' ;;
    service:sshd) printf 'sshd.service\n' ;;
    socket) printf 'ssh@.service\n' ;;
    *) return "$RM_RC_PRECONDITION" ;;
  esac
}

ssh_systemd_execstart_text() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    printf '%s\n' "${RM_SSH_TEST_EXECSTART:-/usr/sbin/sshd -D}"
    return 0
  fi
  local unit out=''
  unit=$(ssh_service_unit_name) || return $?
  out=$(systemctl show "$unit" -p ExecStart --value 2>/dev/null || true)
  if [[ -z $out && $unit == ssh@.service ]]; then
    out=$(systemctl show sshd@.service -p ExecStart --value 2>/dev/null || true)
  fi
  [[ -n $out ]] || return "$RM_RC_PRECONDITION"
  printf '%s\n' "$out"
}

ssh_default_sshd_opts_text() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    printf '%s\n' "${RM_SSH_TEST_SSHD_OPTS:-}"
    return 0
  fi
  local f raw=''
  f=$(rm_path /etc/default/ssh)
  [[ -f $f && ! -L $f ]] || { printf '\n'; return 0; }
  raw=$(sed -nE 's/^[[:space:]]*SSHD_OPTS[[:space:]]*=(.*)$/\1/p' "$f" | tail -n1)
  raw=${raw#"${raw%%[![:space:]]*}"}; raw=${raw%"${raw##*[![:space:]]}"}
  if [[ $raw == \"*\" && $raw == *\" ]]; then raw=${raw:1:${#raw}-2}; fi
  if [[ $raw == \'*\' && $raw == *\' ]]; then raw=${raw:1:${#raw}-2}; fi
  printf '%s\n' "$raw"
}

ssh_startup_args_json() {
  local exec='' opts='' combined overrides='[]' status=ok unresolved=false
  if ! exec=$(ssh_systemd_execstart_text); then status=unverified; fi
  opts=$(ssh_default_sshd_opts_text 2>/dev/null || true)
  combined="$exec $opts"
  if grep -Eq '\$\{?SSHD_OPTS\}?' <<<"$exec"; then
    local default_file
    default_file=$(rm_path /etc/default/ssh)
    if [[ ${RM_TEST_MODE} != 1 && ! -f $default_file ]]; then unresolved=true; status=unverified; fi
  fi
  if grep -Eq '(^|[[:space:];])-f([^[:space:];]*|[[:space:]]+[^[:space:];]+)' <<<"$combined"; then
    overrides=$(jq -c '.+["custom-config(-f)"]' <<<"$overrides")
  fi
  if grep -Eq '(^|[[:space:];])-p([=0-9]|[[:space:]])' <<<"$combined"; then
    overrides=$(jq -c '.+["port-override(-p)"]' <<<"$overrides")
  fi
  if grep -Eq '(^|[[:space:];])-o([^[:space:];]*|[[:space:]]+[^[:space:];]+)' <<<"$combined"; then
    overrides=$(jq -c '.+["option-override(-o)"]' <<<"$overrides")
  fi
  jq -n --arg status "$status" --arg exec "$exec" --arg opts "$opts"     --argjson unresolved "$unresolved" --argjson overrides "$overrides"     '{status:$status,execstart:$exec,sshd_opts:$opts,unresolved_environment:$unresolved,
      config_overrides:$overrides,safe_for_automatic_tightening:($status=="ok" and ($overrides|length)==0 and ($unresolved|not))}'
}

ssh_automation_blockers_json() {
  local user=${1:-root} addr=${2:-127.0.0.1} eff authcmd authmethods trusted principals akf blockers='[]' startup startup_status startup_overrides
  eff=$(ssh_effective_text "$user" "$addr" localhost) || {
    jq -n '["sshd-effective-config-unavailable"]'
    return 0
  }
  authcmd=$(ssh_effective_value "$eff" authorizedkeyscommand)
  authmethods=$(ssh_effective_value "$eff" authenticationmethods)
  trusted=$(ssh_effective_value "$eff" trustedusercakeys)
  principals=$(ssh_effective_value "$eff" authorizedprincipalscommand)
  akf=$(ssh_effective_value "$eff" authorizedkeysfile)
  [[ -n $authcmd && $authcmd != none ]] && blockers=$(jq -c --arg v "authorizedkeyscommand:$authcmd" '.+[$v]' <<<"$blockers")
  [[ -n $trusted && $trusted != none ]] && blockers=$(jq -c --arg v "trustedusercakeys:$trusted" '.+[$v]' <<<"$blockers")
  [[ -n $principals && $principals != none ]] && blockers=$(jq -c --arg v "authorizedprincipalscommand:$principals" '.+[$v]' <<<"$blockers")
  [[ -n $authmethods && $authmethods != any ]] && blockers=$(jq -c --arg v "authenticationmethods:$authmethods" '.+[$v]' <<<"$blockers")
  [[ -z $akf || $akf == none ]] && blockers=$(jq -c '.+["authorizedkeysfile:none-or-missing"]' <<<"$blockers")
  startup=$(ssh_startup_args_json)
  startup_status=$(jq -r .status <<<"$startup")
  startup_overrides=$(jq -r '.config_overrides|join(",")' <<<"$startup")
  [[ $startup_status == ok ]] || blockers=$(jq -c '.+["startup-arguments-unverified"]' <<<"$blockers")
  [[ -z $startup_overrides ]] || blockers=$(jq -c --arg v "startup-config-overrides:$startup_overrides" '.+[$v]' <<<"$blockers")
  [[ $(jq -r '.unresolved_environment' <<<"$startup") == false ]] || blockers=$(jq -c '.+["startup-environment-unresolved"]' <<<"$blockers")
  printf '%s\n' "$blockers"
}

ssh_config_trace_json() {
  local main dir f logical files='[]' include_directives='[]' match_files='[]' cloud=false
  main=$(rm_path /etc/ssh/sshd_config)
  dir=$(rm_path /etc/ssh/sshd_config.d)
  local -a candidates=()
  [[ -f $main && ! -L $main ]] && candidates+=("$main")
  if [[ -d $dir && ! -L $dir ]]; then
    while IFS= read -r f; do candidates+=("$f"); done < <(find "$dir" -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | sort)
  fi
  for f in "${candidates[@]}"; do
    logical=$f
    [[ -n $RM_ROOT ]] && logical=${f#"${RM_ROOT%/}"}
    files=$(jq -c --arg p "$logical" '.+[$p]|unique' <<<"$files")
    if grep -Eq '^[[:space:]]*Match([[:space:]]|$)' "$f"; then
      match_files=$(jq -c --arg p "$logical" '.+[$p]|unique' <<<"$match_files")
    fi
    while IFS= read -r inc; do
      [[ -n $inc ]] || continue
      include_directives=$(jq -c --arg p "$logical" --arg v "$inc" '.+[{file:$p,value:$v}]' <<<"$include_directives")
    done < <(awk 'tolower($1)=="include"{$1="";sub(/^[[:space:]]+/,"");print}' "$f")
  done
  [[ -f $(rm_path /etc/ssh/sshd_config.d/50-cloud-init.conf) ]] && cloud=true
  jq -n --argjson files "$files" --argjson includes "$include_directives" --argjson matches "$match_files" --argjson cloud "$cloud"     '{detected_files:$files,include_directives:$includes,match_files:$matches,match_detected:($matches|length>0),
      cloud_init_present:$cloud,effective_policy_source:"sshd -T -C"}'
}

ssh_detect_json() {
  local user=${1:-root} addr=${2:-127.0.0.1} mode effective=''
  mode=$(ssh_service_mode)
  if effective=$(ssh_effective_text "$user" "$addr" localhost 2>/dev/null); then :; else effective=''; fi
  local ports='[]' actual='[]' blockers='[]' trace startup
  if [[ -n $effective ]]; then ports=$(awk '$1=="port"{print $2}' <<<"$effective" | jq -R -s 'split("\n")|map(select(length>0)|tonumber)|unique'); fi
  actual=$(ssh_listen_ports | jq -R -s 'split("\n")|map(select(length>0)|tonumber)|unique')
  blockers=$(ssh_automation_blockers_json "$user" "$addr")
  trace=$(ssh_config_trace_json)
  startup=$(ssh_startup_args_json)
  jq -n --arg mode "$mode" --arg user "$user" --argjson effective_ports "$ports" --argjson actual_ports "$actual" \
    --arg pubkey "$(awk '$1=="pubkeyauthentication"{print $2;exit}' <<<"$effective")" \
    --arg pass "$(awk '$1=="passwordauthentication"{print $2;exit}' <<<"$effective")" \
    --arg kbd "$(awk '$1=="kbdinteractiveauthentication"{print $2;exit}' <<<"$effective")" \
    --arg root "$(awk '$1=="permitrootlogin"{print $2;exit}' <<<"$effective")" \
    --arg authm "$(ssh_effective_value "$effective" authenticationmethods)" \
    --arg akf "$(ssh_effective_value "$effective" authorizedkeysfile)" \
    --arg akc "$(ssh_effective_value "$effective" authorizedkeyscommand)" \
    --arg trusted "$(ssh_effective_value "$effective" trustedusercakeys)" \
    --arg principals "$(ssh_effective_value "$effective" authorizedprincipalscommand)" \
    --argjson blockers "$blockers" --argjson trace "$trace" --argjson startup "$startup" \
    '{user:$user,start_mode:$mode,effective:{ports:$effective_ports,pubkey_authentication:$pubkey,password_authentication:$pass,kbd_interactive_authentication:$kbd,permit_root_login:$root,authentication_methods:$authm,authorized_keys_file:$akf,authorized_keys_command:$akc,trusted_user_ca_keys:$trusted,authorized_principals_command:$principals},actual_listen_ports:$actual_ports,automation_tightening_safe:($blockers|length==0),automation_blockers:$blockers,config_trace:$trace,startup:$startup,auth_method_verified:false,note:"SSH_CONNECTION 只作线索；本结果不自动证明当前会话认证方式"}'
}

ssh_main_config_test() { local bin; bin=$(ssh_sshd_bin) || return $?; "$bin" -t; }

ssh_home_for_user() { getent passwd "$1" | awk -F: '{print $6}'; }
ssh_uid_gid_for_user() { getent passwd "$1" | awk -F: '{print $3":"$4}'; }

ssh_authorized_keys_path() {
  local user=$1 eff akf first home path
  eff=$(ssh_effective_text "$user" 127.0.0.1 localhost) || return "$RM_RC_PRECONDITION"
  akf=$(ssh_effective_value "$eff" authorizedkeysfile)
  first=${akf%% *}
  home=$(ssh_home_for_user "$user")
  [[ -n $home && -n $first && $first != none ]] || {
    rm_error '有效配置没有可安全管理的 AuthorizedKeysFile'
    return "$RM_RC_PRECONDITION"
  }
  first=${first//%%/%}; first=${first//%u/$user}; first=${first//%h/$home}
  [[ $first != *%* ]] || { rm_error 'AuthorizedKeysFile 含未支持的动态 token，拒绝自动修改'; return "$RM_RC_PRECONDITION"; }
  if [[ $first == /* ]]; then path=$first; else path="$home/$first"; fi
  case "$path" in
    /root/.ssh/authorized_keys) ;;
    /home/*/.ssh/authorized_keys) [[ $path =~ ^/home/[^/]+/\.ssh/authorized_keys$ ]] || return "$RM_RC_PRECONDITION" ;;
    /etc/ssh/authorized_keys/*) [[ $path =~ ^/etc/ssh/authorized_keys/[^/]+$ ]] || return "$RM_RC_PRECONDITION" ;;
    *) rm_error "首版不自动写入非标准 AuthorizedKeys 路径: $path"; return "$RM_RC_PRECONDITION" ;;
  esac
  printf '%s\n' "$(rm_path "$path")"
}

ssh_public_key_material() {
  local line=$1
  awk '{for(i=1;i<=NF;i++) if($i ~ /^(ssh-|ecdsa-|sk-)/ && (i+1)<=NF){print $(i+1); exit}}' <<<"$line"
}

ssh_public_key_type() {
  local line=$1
  awk '{for(i=1;i<=NF;i++) if($i ~ /^(ssh-|ecdsa-|sk-)/ && (i+1)<=NF){print $i; exit}}' <<<"$line"
}

ssh_key_fingerprint_from_line() {
  local line=$1 tmp out
  tmp=$(mktemp) || return "$RM_RC_INTERNAL"
  printf '%s\n' "$line" >"$tmp"
  out=$(ssh-keygen -lf "$tmp" 2>/dev/null) || { rm -f "$tmp"; return "$RM_RC_PRECONDITION"; }
  rm -f "$tmp"
  awk '{print $2; exit}' <<<"$out"
}

ssh_validate_public_key_file() {
  local f=$1
  [[ -f $f && ! -L $f ]] || return "$RM_RC_PRECONDITION"
  grep -q 'BEGIN .*PRIVATE KEY' "$f" && { rm_error '拒绝私钥，只接受客户端公钥。'; return "$RM_RC_PRECONDITION"; }
  local count line material tmp
  count=$(grep -Evc '^[[:space:]]*(#|$)' "$f" 2>/dev/null || true)
  [[ $count == 1 ]] || { rm_error '每次只接受一条客户端公钥。'; return "$RM_RC_PRECONDITION"; }
  line=$(grep -Ev '^[[:space:]]*(#|$)' "$f" | head -n1)
  material=$(ssh_public_key_material "$line")
  [[ -n $material ]] || { rm_error '无法解析公钥格式'; return "$RM_RC_PRECONDITION"; }
  tmp=$(mktemp); printf '%s\n' "$line" >"$tmp"
  ssh-keygen -lf "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; rm_error 'ssh-keygen 校验公钥失败'; return "$RM_RC_PRECONDITION"; }
  rm -f "$tmp"; printf '%s\n' "$line"
}

ssh_key_inventory_json() {
  local user=$1 path line fp bits kind items='[]' tmp
  path=$(ssh_authorized_keys_path "$user") || return $?
  [[ -f $path && ! -L $path ]] || { jq -n --arg user "$user" --arg path "$path" '{user:$user,path:$path,keys:[]}'; return 0; }
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line && ! $line =~ ^[[:space:]]*# ]] || continue
    [[ -n $(ssh_public_key_material "$line") ]] || continue
    fp=$(ssh_key_fingerprint_from_line "$line" 2>/dev/null || true)
    [[ -n $fp ]] || continue
    tmp=$(mktemp); printf '%s\n' "$line" >"$tmp"
    bits=$(ssh-keygen -lf "$tmp" 2>/dev/null | awk '{print $1;exit}')
    rm -f "$tmp"
    kind=$(ssh_public_key_type "$line")
    items=$(jq -c --arg fp "$fp" --arg kind "$kind" --argjson bits "${bits:-0}" '.+[{fingerprint:$fp,type:$kind,bits:$bits}]' <<<"$items")
  done <"$path"
  jq -n --arg user "$user" --arg path "$path" --argjson keys "$items" '{user:$user,path:$path,keys:$keys}'
}

ssh_verification_command_json() {
  local user=$1 host=$2 port=${3:-}
  [[ -n $user && -n $host ]] || return "$RM_RC_PRECONDITION"
  if [[ -z $port ]]; then
    port=$(ssh_listen_ports | head -n1)
    [[ -n $port ]] || port=22
  fi
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  jq -n --arg user "$user" --arg host "$host" --argjson port "$port" \
    '{user:$user,host:$host,port:$port,
      command:("ssh -S none -o ControlMaster=no -o ControlPath=none -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o NumberOfPasswordPrompts=0 -p "+($port|tostring)+" "+$user+"@"+$host),
      requirements:["必须新建连接","禁止连接复用","禁止密码回退","禁止键盘交互回退"],
      note:"命令仅用于人工验证方法；成功连接后仍需显式 mark-key-verified/confirm。"}'
}

ssh_add_public_key() {
  local user=$1 keyfile=$2 line path dir owner material tmp tx rc=0 created_dir=false fingerprint
  rm_require_root || return $?
  line=$(ssh_validate_public_key_file "$keyfile") || return $?
  path=$(ssh_authorized_keys_path "$user") || return $?
  owner=$(ssh_uid_gid_for_user "$user"); [[ -n $owner ]] || return "$RM_RC_PRECONDITION"
  dir=$(dirname "$path")
  [[ -L $path || -L $dir ]] && { rm_error 'AuthorizedKeys 路径包含符号链接，拒绝自动修改'; return "$RM_RC_PRECONDITION"; }
  if [[ -e $dir && ! -d $dir ]]; then rm_error '公钥目录路径异常'; return "$RM_RC_PRECONDITION"; fi
  if [[ ! -d $dir ]]; then
    rm_assert_no_symlink_components "$(dirname "$dir")" || return $?
    install -d -m 0700 "$dir" || return "$RM_RC_PRECONDITION"
    [[ ${RM_TEST_MODE} == 1 ]] || chown "$owner" "$dir" || { rmdir "$dir" 2>/dev/null || true; return "$RM_RC_PRECONDITION"; }
    created_dir=true
  fi

  tmp=$(rm_safe_tmpdir)/authorized_keys
  [[ -f $path ]] && cat "$path" >"$tmp" || : >"$tmp"
  material=$(ssh_public_key_material "$line")
  if awk -v m="$material" '{for(i=1;i<=NF;i++) if($i==m) found=1} END{exit found?0:1}' "$tmp"; then
    rm_info '相同密钥材料已存在，不重复添加。'
    $created_dir && rmdir "$dir" 2>/dev/null || true
    return 0
  fi
  printf '%s\n' "$line" >>"$tmp"
  tx=$(tx_begin ssh-add-key) || { $created_dir && rmdir "$dir" 2>/dev/null || true; return $?; }
  tx_stage_file "$tx" "$tmp" "$path" 0600 "$owner" || {
    tx_rollback "$tx" 'key stage failed' || true
    $created_dir && rmdir "$dir" 2>/dev/null || true
    return "$RM_RC_PRECONDITION"
  }
  tx_apply "$tx" || {
    rc=$?
    tx_rollback "$tx" 'key apply failed' || true
    $created_dir && rmdir "$dir" 2>/dev/null || true
    return "$rc"
  }
  tx_commit "$tx" || return $?
  fingerprint=$(ssh-keygen -lf "$keyfile" 2>/dev/null | awk '{print $2;exit}')
  jq -n --arg user "$user" --arg path "$path" --arg fp "$fingerprint" '{status:"added",user:$user,path:$path,fingerprint:$fp}'
}

ssh_remove_public_key() {
  local user=$1 fingerprint=$2 path owner inv verified='[]' verified_present=0 target_verified=false fp line tmp tx rc=0 removed=0 ans
  rm_require_root || return $?
  [[ -n $user && -n $fingerprint ]] || return "$RM_RC_PRECONDITION"
  path=$(ssh_authorized_keys_path "$user") || return $?
  [[ -f $path && ! -L $path ]] || { rm_error 'AuthorizedKeysFile 不存在或不是普通文件'; return "$RM_RC_PRECONDITION"; }
  owner=$(ssh_uid_gid_for_user "$user"); [[ -n $owner ]] || return "$RM_RC_PRECONDITION"
  inv=$(ssh_key_inventory_json "$user") || return $?
  jq -e --arg fp "$fingerprint" 'any(.keys[]?; .fingerprint==$fp)' <<<"$inv" >/dev/null || {
    rm_error '指定 fingerprint 不在当前 AuthorizedKeysFile 中'
    return "$RM_RC_PRECONDITION"
  }

  state_init >/dev/null || return $?
  verified=$(jq -c --arg u "$user" '.ssh_verifications[$u].verified_key_fingerprints // []' "$RM_STATE_FILE")
  jq -e --arg fp "$fingerprint" 'index($fp)!=null' <<<"$verified" >/dev/null && target_verified=true || true
  while IFS= read -r fp; do
    [[ -n $fp ]] || continue
    jq -e --arg fp "$fp" 'index($fp)!=null' <<<"$verified" >/dev/null 2>&1 && verified_present=$((verified_present+1)) || true
  done < <(jq -r '.keys[]?.fingerprint' <<<"$inv")
  if [[ $target_verified == true && $verified_present -le 1 ]]; then
    rm_error '拒绝删除最后一个当前仍存在的已验证 SSH 公钥入口。请先添加并验证另一把密钥。'
    return "$RM_RC_PRECONDITION"
  fi

  if [[ ${RM_TEST_MODE} == 1 && ${RM_SSH_TEST_REMOVE_KEY:-} == REMOVE ]]; then ans=REMOVE
  else
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_read_tty ans "将删除 $user 的 SSH 公钥 $fingerprint；输入 REMOVE 确认: "
  fi
  [[ $ans == REMOVE ]] || return "$RM_RC_CANCEL"

  tmp=$(rm_safe_tmpdir)/authorized_keys
  : >"$tmp"
  while IFS= read -r line || [[ -n $line ]]; do
    fp=''
    if [[ -n $(ssh_public_key_material "$line") ]]; then fp=$(ssh_key_fingerprint_from_line "$line" 2>/dev/null || true); fi
    if [[ -n $fp && $fp == "$fingerprint" ]]; then
      removed=$((removed+1))
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$path"
  ((removed>0)) || return "$RM_RC_PRECONDITION"

  tx=$(tx_begin ssh-remove-key) || return $?
  tx_stage_file "$tx" "$tmp" "$path" 0600 "$owner" || { tx_rollback "$tx" 'key removal stage failed' || true; return "$RM_RC_PRECONDITION"; }
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'key removal apply failed' || true; return "$rc"; }
  tx_commit "$tx" || return $?
  state_update_filter 'if .ssh_verifications[$user] then .ssh_verifications[$user].verified_key_fingerprints=[(.ssh_verifications[$user].verified_key_fingerprints//[])[]|select(.!=$fp)] else . end' --arg user "$user" --arg fp "$fingerprint"
  jq -n --arg user "$user" --arg path "$path" --arg fp "$fingerprint" --argjson removed "$removed"     '{status:"removed",user:$user,path:$path,fingerprint:$fp,removed_entries:$removed}'
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
  local deadline=$1 mode=$2 tmpdir svc timer guard guard_dropin guard_dest tx rc=0
  [[ $mode == socket || $mode == service:ssh || $mode == service:sshd ]] || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir); svc="$tmpdir/service"; timer="$tmpdir/timer"; guard="$tmpdir/guard"; guard_dropin="$tmpdir/guard-dropin"
  cat >"$svc" <<'EOS'
[Unit]
Description=AsterNode SSH rollback protection
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/relay-manager ssh rollback-pending
EOS
  cat >"$guard" <<'EOS'
[Unit]
Description=AsterNode SSH boot recovery guard
DefaultDependencies=no
After=local-fs.target
Before=ssh.service sshd.service ssh.socket
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/relay-manager ssh rollback-pending
EOS
  cat >"$timer" <<EOS
[Unit]
Description=AsterNode SSH rollback deadline
[Timer]
OnCalendar=@$deadline
Persistent=true
AccuracySec=1s
Unit=relay-manager-ssh-rollback.service
[Install]
WantedBy=timers.target
EOS
  cat >"$guard_dropin" <<'EOS'
[Unit]
Requires=relay-manager-ssh-boot-guard.service
After=relay-manager-ssh-boot-guard.service
EOS
  case "$mode" in
    socket) guard_dest=$RM_SSH_SOCKET_GUARD_DROPIN ;;
    service:ssh) guard_dest=$RM_SSH_SERVICE_GUARD_DROPIN ;;
    service:sshd) guard_dest=$RM_SSHD_SERVICE_GUARD_DROPIN ;;
  esac
  tx=$(tx_begin ssh-protection) || { rm -rf "$tmpdir"; return $?; }
  tx_stage_file "$tx" "$svc" "$RM_SSH_PROTECT_SERVICE" 0644 root:root || rc=$?
  ((rc==0)) && tx_stage_file "$tx" "$timer" "$RM_SSH_PROTECT_TIMER" 0644 root:root || rc=$?
  ((rc==0)) && tx_stage_file "$tx" "$guard" "$RM_SSH_BOOT_GUARD_SERVICE" 0644 root:root || rc=$?
  ((rc==0)) && tx_stage_file "$tx" "$guard_dropin" "$guard_dest" 0644 root:root || rc=$?
  if ((rc!=0)); then tx_rollback "$tx" 'protection stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; fi
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'protection apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    rm_systemctl daemon-reload
    rm_systemctl start relay-manager-ssh-boot-guard.service
    rm_systemctl enable relay-manager-ssh-rollback.timer
    rm_systemctl start relay-manager-ssh-rollback.timer
  else
    systemctl daemon-reload || { tx_rollback "$tx" 'protection daemon-reload failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl start relay-manager-ssh-boot-guard.service >/dev/null || { tx_rollback "$tx" 'boot guard activation failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl is-active --quiet relay-manager-ssh-boot-guard.service || { tx_rollback "$tx" 'boot guard inactive' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl enable --now relay-manager-ssh-rollback.timer >/dev/null || { tx_rollback "$tx" 'protect timer activation failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl is-active --quiet relay-manager-ssh-rollback.timer || { tx_rollback "$tx" 'protect timer not active' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
  fi
  tx_commit "$tx" || { rm -rf "$tmpdir"; return $?; }
  state_init >/dev/null
  state_add_owned_file /etc/systemd/system/relay-manager-ssh-rollback.service "$(rm_sha256_file "$RM_SSH_PROTECT_SERVICE")"
  state_add_owned_file /etc/systemd/system/relay-manager-ssh-rollback.timer "$(rm_sha256_file "$RM_SSH_PROTECT_TIMER")"
  state_add_owned_file /etc/systemd/system/relay-manager-ssh-boot-guard.service "$(rm_sha256_file "$RM_SSH_BOOT_GUARD_SERVICE")"
  state_add_owned_file "${guard_dest#"${RM_ROOT%/}"}" "$(rm_sha256_file "$guard_dest")" 2>/dev/null || true
  rm -rf "$tmpdir"
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

ssh_recovery_guide_json() {
  local tx=${1:-} f='' change='' target_user=root deadline=null mode unit
  if [[ -z $tx ]]; then tx=$(ssh_pending_tx_id 2>/dev/null || true); fi
  if [[ -n $tx && -f $(tx_file "$tx") ]]; then
    f=$(tx_file "$tx")
    change=$(jq -r '.ssh.change // ""' "$f")
    target_user=$(jq -r '.ssh.target_user // "root"' "$f")
    deadline=$(jq -r '.deadline_epoch // null' "$f")
  fi
  mode=$(ssh_service_mode)
  case "$mode" in socket) unit=ssh.socket;; service:ssh) unit=ssh.service;; service:sshd) unit=sshd.service;; *) unit=unknown;; esac
  jq -n --arg tx "$tx" --arg change "$change" --arg user "$target_user" --arg mode "$mode" --arg unit "$unit" --argjson deadline "$deadline"     '{pending:($tx!=""),transaction_id:(if $tx=="" then null else $tx end),change:(if $change=="" then null else $change end),
      target_user:$user,deadline_epoch:$deadline,start_mode:$mode,
      local_console_steps:[
        "保持现有 SSH 会话；若远程已不可达，使用 VPS/云厂商控制台登录。",
        "执行 relay-manager ssh rollback-pending 恢复最后已提交的本机 SSH 配置。",
        ("执行 sshd -t，并检查 systemctl status "+$unit+" 与 ss -lntp。"),
        "确认云安全组、防火墙/NAT 映射与目标 SSH 端口一致；本机回滚无法修复云侧阻断。"
      ],
      boundary:"AsterNode 只能恢复其管理的本机配置，不能承诺修复云安全组、供应商网络故障或损坏的系统。"}'
}

ssh_apply_policy_protected() {
  local policy=$1 change=$2 target_user=${3:-root} deadline=${4:-$(( $(rm_epoch)+300 ))} mode tmpdir drop socket tx rc service_unit
  rm_require_root || return $?
  if [[ ${RM_TEST_MODE} != 1 ]]; then rm_tty_available || { rm_error 'SSH 安全修改要求交互 TTY。'; return "$RM_RC_PRECONDITION"; }; fi
  ssh_main_config_test || { rm_error '现有 sshd 配置本身未通过语法检查，拒绝开始迁移。'; return "$RM_RC_PRECONDITION"; }
  mode=$(ssh_service_mode); [[ $mode != unknown ]] || return "$RM_RC_PRECONDITION"
  ssh_protection_setup "$deadline" "$mode" || return $?
  tmpdir=$(rm_safe_tmpdir); drop="$tmpdir/ssh.conf"; socket="$tmpdir/socket.conf"
  ssh_policy_render_dropin "$policy" "$drop"; ssh_socket_render_override "$policy" "$socket"
  tx=$(tx_begin "ssh-change:$change" "$deadline") || { ssh_protection_disable; rm -rf "$tmpdir"; return $?; }
  tx_update "$tx" '.ssh={change:$change,ports:$ports,target_user:$user}' --arg change "$change" --argjson ports "$(jq '.ports' "$policy")" --arg user "$target_user"
  case "$mode" in socket) service_unit=ssh.socket;; service:ssh) service_unit=ssh.service;; service:sshd) service_unit=sshd.service;; esac
  tx_record_service "$tx" "$service_unit" true || true
  tx_stage_file "$tx" "$policy" "$RM_SSH_POLICY" 0600 root:root || { tx_rollback "$tx" 'policy stage failed' || true; ssh_protection_disable; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  tx_stage_file "$tx" "$drop" "$RM_SSH_DROPIN" 0644 root:root || { tx_rollback "$tx" 'dropin stage failed' || true; ssh_protection_disable; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  if [[ $mode == socket ]]; then tx_stage_file "$tx" "$socket" "$RM_SSH_SOCKET_DROPIN" 0644 root:root || { tx_rollback "$tx" 'socket override stage failed' || true; ssh_protection_disable; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }; fi
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'SSH apply failed' || true; ssh_protection_disable; rm -rf "$tmpdir"; return "$rc"; }
  if ! ssh_main_config_test || ! ssh_restart_mode "$mode"; then rc=$RM_RC_APPLY_ROLLED_BACK; tx_rollback "$tx" 'SSHD syntax/restart failed' || rc=$?; ssh_restart_mode "$mode" || true; ssh_protection_disable; rm -rf "$tmpdir"; return "$rc"; fi
  rm -rf "$tmpdir"
  jq -n --arg tx "$tx" --arg change "$change" --argjson deadline "$deadline" '{status:"pending_manual_verification",transaction_id:$tx,change:$change,deadline_epoch:$deadline,recovery_command:"relay-manager ssh recovery-guide",note:"请保持当前会话，另开一个全新 SSH 连接验证后再执行 ssh confirm；本机回滚不能修复云安全组或 NAT 阻断。"}'
}

ssh_begin_port_migration() {
  local newport=$1 tmp policy ports fw_result='{}' fw_added=false result txid rc
  rm_valid_port "$newport" || return "$RM_RC_PRECONDITION"
  if [[ ${RM_TEST_MODE} != 1 ]] && rm_have ss && ss -H -lnt "sport = :$newport" 2>/dev/null | grep -q .; then
    rm_error '新 SSH 端口已被占用'
    return "$RM_RC_PRECONDITION"
  fi

  # If active, manageable UFW exists, open the new SSH port before changing listeners.
  fw_result=$(fw_ensure_ssh_port "$newport") || return $?
  fw_added=$(jq -r '.added // false' <<<"$fw_result")

  tmp=$(rm_safe_tmpdir); policy="$tmp/policy.json"; ssh_policy_load_or_init "$policy"
  ports=$(jq --argjson p "$newport" '.ports + [$p] | unique' "$policy")
  jq --argjson ports "$ports" '.ports=$ports' "$policy" >"$tmp/p2"; mv "$tmp/p2" "$policy"

  if ! result=$(ssh_apply_policy_protected "$policy" port-migration root); then
    rc=$?
    [[ $fw_added == true ]] && fw_release_ssh_port "$newport" || true
    rm -rf "$tmp"
    return "$rc"
  fi
  txid=$(jq -r .transaction_id <<<"$result")
  if [[ $fw_added == true ]]; then
    tx_update "$txid" '.ssh.firewall_added_ports=((.ssh.firewall_added_ports//[]) + [$p] | unique)' --argjson p "$newport"
  fi
  jq -n --argjson ssh "$result" --argjson firewall "$fw_result" '$ssh + {firewall:$firewall}'
  rm -rf "$tmp"
}

ssh_begin_remove_old_port() {
  local keep=$1 tmp policy current_ports remove_ports result txid
  rm_valid_port "$keep" || return "$RM_RC_PRECONDITION"
  tmp=$(rm_safe_tmpdir); policy="$tmp/policy.json"; ssh_policy_load_or_init "$policy"
  current_ports=$(jq -c '.ports' "$policy")
  jq -e --argjson p "$keep" 'index($p)!=null' <<<"$current_ports" >/dev/null || {
    rm_error '要保留的端口不在当前已提交 SSH 端口列表中'
    rm -rf "$tmp"
    return "$RM_RC_PRECONDITION"
  }
  remove_ports=$(jq -c --argjson p "$keep" '[.[]|select(.!=$p)]' <<<"$current_ports")
  jq --argjson p "$keep" '.ports=[$p]' "$policy" >"$tmp/p2"; mv "$tmp/p2" "$policy"
  result=$(ssh_apply_policy_protected "$policy" remove-old-port root) || { local rc=$?; rm -rf "$tmp"; return "$rc"; }
  txid=$(jq -r .transaction_id <<<"$result")
  tx_update "$txid" '.ssh.firewall_remove_after_confirm=$ports' --argjson ports "$remove_ports"
  printf '%s\n' "$result"
  rm -rf "$tmp"
}

ssh_mark_key_verified() {
  local user=$1 fingerprint=${2:-} ans inv
  ssh_effective_text "$user" 127.0.0.1 localhost | grep -q '^pubkeyauthentication yes' || { rm_error '有效配置未允许公钥认证'; return "$RM_RC_PRECONDITION"; }
  inv=$(ssh_key_inventory_json "$user") || return $?
  if [[ -z $fingerprint ]]; then
    [[ $(jq '.keys|length' <<<"$inv") == 1 ]] || { rm_error '存在多把公钥时必须明确提供已验证的 fingerprint。'; return "$RM_RC_PRECONDITION"; }
    fingerprint=$(jq -r '.keys[0].fingerprint' <<<"$inv")
  fi
  jq -e --arg fp "$fingerprint" 'any(.keys[]; .fingerprint==$fp)' <<<"$inv" >/dev/null || { rm_error '指定 fingerprint 不在当前 AuthorizedKeysFile 中'; return "$RM_RC_PRECONDITION"; }
  if [[ ${RM_TEST_MODE} == 1 && ${RM_SSH_TEST_MANUAL_VERIFY:-} == VERIFY ]]; then ans=VERIFY
  else
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_read_tty ans '请确认：你刚刚使用该用户在全新 SSH 连接中成功完成该公钥登录，且禁用了连接复用、密码和键盘交互回退。输入 VERIFY 继续: '
  fi
  [[ $ans == VERIFY ]] || return "$RM_RC_CANCEL"
  state_init >/dev/null
  state_update_filter '.ssh_verifications=((.ssh_verifications//{}) + {($user):((.ssh_verifications[$user]//{}) + {key_login_manual:true,verified_at:$now,verified_key_fingerprints:(((.ssh_verifications[$user].verified_key_fingerprints//[]) + [$fp])|unique)})})' --arg user "$user" --arg fp "$fingerprint"
  jq -n --arg user "$user" --arg fp "$fingerprint" '{status:"manual_new_connection_verified",user:$user,fingerprint:$fp}'
}

ssh_begin_disable_password() {
  local user=$1 tmp policy verified blockers
  state_init >/dev/null
  verified=$(jq -r --arg u "$user" '((.ssh_verifications[$u].verified_key_fingerprints//[])|length)>0' "$RM_STATE_FILE")
  [[ $verified == true ]] || { rm_error '先按生成的全新连接命令完成公钥登录并记录已验证 fingerprint。'; return "$RM_RC_PRECONDITION"; }
  blockers=$(ssh_automation_blockers_json "$user" 127.0.0.1)
  [[ $(jq 'length' <<<"$blockers") == 0 ]] || { rm_error "检测到外部认证/MFA/CA 配置，拒绝自动关闭密码: $(jq -c . <<<"$blockers")"; return "$RM_RC_PRECONDITION"; }
  tmp=$(rm_safe_tmpdir); policy="$tmp/policy.json"; ssh_policy_load_or_init "$policy"
  jq '.password_authentication="no"|.kbd_interactive_authentication="no"' "$policy" >"$tmp/p2"; mv "$tmp/p2" "$policy"
  local result; result=$(ssh_apply_policy_protected "$policy" disable-password "$user") || { local rc=$?; rm -rf "$tmp"; return "$rc"; }; printf '%s\n' "$result"; rm -rf "$tmp"
}

ssh_record_sudo_verified() {
  local user=${1:?user required} actual=${SUDO_USER:-}
  [[ $user != root ]] || return "$RM_RC_PRECONDITION"
  [[ $actual == "$user" ]] || { rm_error '请以目标普通用户执行 sudo relay-manager ssh verify-sudo <user>，以证明实际提权链路。'; return "$RM_RC_PRECONDITION"; }
  state_init >/dev/null; state_update_filter '.ssh_verifications=((.ssh_verifications//{}) + {($user):((.ssh_verifications[$user]//{}) + {sudo_manual:true,sudo_verified_at:$now})})' --arg user "$user"
}

ssh_begin_root_policy() {
  local policy_name=$1 admin_user=${2:-} tmp policy keyok sudook blockers
  [[ $policy_name == publickey-only || $policy_name == disable ]] || return "$RM_RC_PRECONDITION"
  state_init >/dev/null
  blockers=$(ssh_automation_blockers_json root 127.0.0.1)
  [[ $(jq 'length' <<<"$blockers") == 0 ]] || { rm_error "检测到 Root 外部认证/MFA/CA 配置，拒绝自动收紧: $(jq -c . <<<"$blockers")"; return "$RM_RC_PRECONDITION"; }
  if [[ $policy_name == publickey-only ]]; then
    keyok=$(jq -r '((.ssh_verifications.root.verified_key_fingerprints//[])|length)>0' "$RM_STATE_FILE")
    [[ $keyok == true ]] || { rm_error 'Root 改为仅公钥前必须先验证 Root 的全新公钥连接。'; return "$RM_RC_PRECONDITION"; }
  else
    [[ -n $admin_user && $admin_user != root ]] || return "$RM_RC_PRECONDITION"
    keyok=$(jq -r --arg u "$admin_user" '((.ssh_verifications[$u].verified_key_fingerprints//[])|length)>0' "$RM_STATE_FILE")
    sudook=$(jq -r --arg u "$admin_user" '.ssh_verifications[$u].sudo_manual//false' "$RM_STATE_FILE")
    [[ $keyok == true && $sudook == true ]] || { rm_error '禁用 Root 前必须验证非 Root 新连接和实际 sudo 提权。'; return "$RM_RC_PRECONDITION"; }
  fi
  tmp=$(rm_safe_tmpdir); policy="$tmp/policy.json"; ssh_policy_load_or_init "$policy"
  if [[ $policy_name == disable ]]; then jq '.permit_root_login="no"' "$policy" >"$tmp/p2"; else jq '.permit_root_login="prohibit-password"' "$policy" >"$tmp/p2"; fi; mv "$tmp/p2" "$policy"
  local result; result=$(ssh_apply_policy_protected "$policy" "root-$policy_name" root) || { local rc=$?; rm -rf "$tmp"; return "$rc"; }; printf '%s\n' "$result"; rm -rf "$tmp"
}

ssh_confirm_pending() {
  local tx=${1:-} f change ans eff ports p target_user
  [[ -n $tx ]] || tx=$(ssh_pending_tx_id) || { rm_error '没有待确认 SSH 事务'; return "$RM_RC_PRECONDITION"; }
  f=$(tx_file "$tx"); [[ $(jq -r .status "$f") == APPLIED_PENDING ]] || return "$RM_RC_PRECONDITION"
  change=$(jq -r '.ssh.change' "$f"); target_user=$(jq -r '.ssh.target_user // "root"' "$f")
  ssh_main_config_test || return "$RM_RC_PRECONDITION"
  ports=$(jq -c '.ssh.ports' "$f")
  if [[ $change == port-migration || $change == remove-old-port ]]; then
    for p in $(jq -r '.[]' <<<"$ports"); do ssh_listen_ports | grep -qx "$p" || { rm_error "目标端口未监听: $p"; return "$RM_RC_PRECONDITION"; }; done
  fi
  eff=$(ssh_effective_text "$target_user" 127.0.0.1 localhost || true)
  if [[ $change == disable-password ]]; then grep -q '^passwordauthentication no' <<<"$eff" && grep -q '^kbdinteractiveauthentication no' <<<"$eff" || return "$RM_RC_PRECONDITION"; fi
  if [[ $change == root-disable ]]; then grep -q '^permitrootlogin no' <<<"$eff" || return "$RM_RC_PRECONDITION"; fi
  if [[ ${RM_TEST_MODE} == 1 && ${RM_SSH_TEST_COMMIT:-} == COMMIT ]]; then ans=COMMIT
  else
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_read_tty ans '请确认：你已从另一个全新 SSH 连接按新策略成功登录，并保留当前旧会话作为兜底。输入 COMMIT 提交: '
  fi
  [[ $ans == COMMIT ]] || return "$RM_RC_CANCEL"
  tx_commit "$tx" || return $?
  local cleanup_rc=0 oldp
  while IFS= read -r oldp; do
    [[ -n $oldp ]] || continue
    fw_release_ssh_port "$oldp" || cleanup_rc=$RM_RC_RECOVERY_INCOMPLETE
  done < <(jq -r '.ssh.firewall_remove_after_confirm[]? // empty' "$f")
  ssh_protection_disable
  if ((cleanup_rc!=0)); then
    jq -n --arg tx "$tx" '{status:"committed_with_firewall_cleanup_warning",transaction_id:$tx}'
    return "$cleanup_rc"
  fi
  jq -n --arg tx "$tx" '{status:"committed_after_manual_verification",transaction_id:$tx}'
}

ssh_rollback_pending() {
  local tx mode rc=0 f p
  tx=$(ssh_pending_tx_id) || { ssh_protection_disable; return 0; }
  f=$(tx_file "$tx")
  mode=$(ssh_service_mode)
  tx_rollback "$tx" 'SSH 验证未确认或保护计时到期' || rc=$?
  ssh_restart_mode "$mode" || rc=$RM_RC_RECOVERY_INCOMPLETE
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    fw_release_ssh_port "$p" || rc=$RM_RC_RECOVERY_INCOMPLETE
  done < <(jq -r '.ssh.firewall_added_ports[]? // empty' "$f" 2>/dev/null || true)
  ssh_protection_disable
  return "$rc"
}
