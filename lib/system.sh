#!/usr/bin/env bash
# Stage-A read-only system detection. ENV-01: no installation, service start, or configuration write.
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

_system_live_probe_allowed() {
  [[ -z ${RM_ROOT} || ${RM_TEST_USE_HOST_PROBES:-0} == 1 ]]
}

_system_os_release_value() {
  local file=$1 key=$2 line value
  line=$(grep -m1 -E "^${key}=" "$file" 2>/dev/null || true)
  [[ -n $line ]] || return 1
  value=${line#*=}
  if [[ $value == \"*\" && $value == *\" ]]; then
    value=${value:1:${#value}-2}
    value=${value//\\\"/\"}
    value=${value//\\\\/\\}
  elif [[ $value == \'*\' && $value == *\' ]]; then
    value=${value:1:${#value}-2}
  fi
  printf '%s\n' "$value"
}

system_os_json() {
  local file resolved id=unknown version=unknown pretty=unknown status=unverified reason='未找到 /etc/os-release'
  file=$(rm_path /etc/os-release)
  if [[ -r $file ]]; then
    if [[ -n $RM_ROOT && -L $file ]]; then
      resolved=$(readlink -f -- "$file" 2>/dev/null || true)
      if [[ -z $resolved || $resolved != "${RM_ROOT%/}"/* ]]; then
        reason='os-release 符号链接越出 RM_ROOT，未读取'
      else
        file=$resolved
      fi
    fi
    if [[ -r $file && ( -z $RM_ROOT || ! -L $(rm_path /etc/os-release) || $file == "${RM_ROOT%/}"/* ) ]]; then
      id=$(_system_os_release_value "$file" ID || printf unknown)
      version=$(_system_os_release_value "$file" VERSION_ID || printf unknown)
      pretty=$(_system_os_release_value "$file" PRETTY_NAME || printf unknown)
      status=ok; reason=''
    fi
  fi
  jq -n --arg id "$id" --arg version "$version" --arg pretty "$pretty" --arg status "$status" --arg reason "$reason" \
    '{status:$status,id:$id,version:$version,pretty:$pretty,reason:(if $reason=="" then null else $reason end)}'
}

system_arch_json() {
  local raw mapped supported=false status=ok reason=''
  raw=$(uname -m 2>/dev/null || printf unknown)
  case "$raw" in
    x86_64|amd64) mapped=amd64; supported=true ;;
    aarch64|arm64) mapped=arm64; supported=true ;;
    *) mapped=unsupported; status=unsupported; reason="首版只自动支持 x86_64 与 ARM64" ;;
  esac
  jq -n --arg raw "$raw" --arg mapped "$mapped" --argjson supported "$supported" --arg status "$status" --arg reason "$reason" \
    '{status:$status,raw:$raw,package_arch:$mapped,supported:$supported,reason:(if $reason=="" then null else $reason end)}'
}

system_systemd_json() {
  local running=false installed=false status=unverified reason='未检测到 systemd 运行环境'
  [[ -e $(rm_path /usr/lib/systemd/systemd) || -e $(rm_path /lib/systemd/systemd) ]] && installed=true
  if [[ -d $(rm_path /run/systemd/system) ]]; then
    installed=true; running=true; status=ok; reason=''
  elif [[ $installed == true ]]; then
    status=unverified; reason='检测到 systemd 文件，但当前不是 systemd 运行环境'
  fi
  jq -n --argjson installed "$installed" --argjson running "$running" --arg status "$status" --arg reason "$reason" \
    '{status:$status,installed:$installed,running:$running,reason:(if $reason=="" then null else $reason end)}'
}

system_support_json() {
  local os id version os_ok=false sd
  os=$(system_os_json); id=$(jq -r .id <<<"$os"); version=$(jq -r .version <<<"$os"); sd=$(system_systemd_json)
  case "$id:$version" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) os_ok=true ;;
  esac
  jq -n --argjson os "$os" --argjson arch "$(system_arch_json)" --argjson os_ok "$os_ok" --argjson sd "$sd" \
    '{os:$os,os_supported:$os_ok,arch:$arch,systemd:$sd.running,systemd_detail:$sd}'
}

system_cpu_count() {
  if rm_have nproc; then nproc; else getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'null\n'; fi
}

system_memory_json() {
  local mf total=null avail=null status=unverified reason='未读取 /proc/meminfo'
  mf=$(rm_path /proc/meminfo)
  if [[ -r $mf && ! -L $mf ]]; then
    total=$(awk '/^MemTotal:/ {printf "%.0f", $2*1024; exit}' "$mf")
    avail=$(awk '/^MemAvailable:/ {printf "%.0f", $2*1024; exit}' "$mf")
    if [[ -n $total ]]; then status=ok; reason=''; else total=null; fi
    [[ -n $avail ]] || avail=null
  fi
  jq -n --arg status "$status" --arg reason "$reason" --argjson total "${total:-null}" --argjson avail "${avail:-null}" \
    '{status:$status,total_bytes:$total,available_bytes:$avail,reason:(if $reason=="" then null else $reason end)}'
}

system_disk_json() {
  local target status=unverified reason='df 不可用或目标不可读'
  target=$(rm_path /)
  if rm_have df && df -PB1 "$target" >/dev/null 2>&1; then
    df -PB1 "$target" | awk 'NR==2 {printf "{\"status\":\"ok\",\"total_bytes\":%s,\"used_bytes\":%s,\"available_bytes\":%s,\"used_percent\":\"%s\",\"reason\":null}\n",$2,$3,$4,$5}'
  else
    jq -n --arg status "$status" --arg reason "$reason" '{status:$status,total_bytes:null,used_bytes:null,available_bytes:null,used_percent:null,reason:$reason}'
  fi
}

system_inode_json() {
  local target
  target=$(rm_path /)
  if rm_have df && df -Pi "$target" >/dev/null 2>&1; then
    df -Pi "$target" | awk 'NR==2 {printf "{\"status\":\"ok\",\"total\":%s,\"used\":%s,\"available\":%s,\"used_percent\":\"%s\",\"reason\":null}\n",$2,$3,$4,$5}'
  else
    jq -n '{status:"unverified",total:null,used:null,available:null,used_percent:null,reason:"df 不可用或 inode 信息不可读"}'
  fi
}

_system_proc_file_in_use() {
  local path=$1 proc_root fd target
  proc_root=$(rm_path /proc)
  [[ -d $proc_root ]] || return 2
  rm_have readlink || return 2

  # On the live host, another user's fd table may be hidden from an unprivileged probe.
  # Do not claim "clear" unless root can inspect it. RM_ROOT fixtures are safe to inspect.
  if [[ -z $RM_ROOT && ${EUID:-$(id -u)} -ne 0 ]]; then return 2; fi

  for fd in "$proc_root"/[0-9]*/fd/*; do
    [[ -L $fd ]] || continue
    target=$(readlink -f -- "$fd" 2>/dev/null || true)
    [[ $target == "$path" ]] && return 0
  done
  return 1
}

system_pkg_manager_json() {
  local kind=unknown status=unverified reason='未检测到支持的包管理器' locked_json=null lock_status=unverified
  local apt_present=false
  if [[ -n $RM_ROOT ]]; then
    [[ -x $(rm_path /usr/bin/apt-get) || -x $(rm_path /bin/apt-get) ]] && apt_present=true
  elif rm_have apt-get; then
    apt_present=true
  fi
  if [[ $apt_present == true ]]; then
    kind=apt; status=ok
    local lock p hit='' probe_mode=none probe_rc=0
    if rm_have fuser; then
      probe_mode=fuser
    elif [[ -d $(rm_path /proc) ]] && rm_have readlink &&
         { [[ -n $RM_ROOT ]] || [[ ${EUID:-$(id -u)} -eq 0 ]]; }; then
      probe_mode=proc
    fi

    if [[ $probe_mode == none ]]; then
      reason='缺少 fuser，且当前权限/环境无法安全检查 /proc 包管理占用'
      lock_status=unverified
      locked_json=null
    else
      for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
        p=$(rm_path "$lock")
        [[ -e $p ]] || continue
        probe_rc=1
        if [[ $probe_mode == fuser ]]; then
          fuser "$p" >/dev/null 2>&1 && probe_rc=0 || probe_rc=$?
        else
          _system_proc_file_in_use "$p" && probe_rc=0 || probe_rc=$?
        fi
        if ((probe_rc==0)); then hit=$lock; break; fi
        if ((probe_rc==2)); then probe_mode=none; break; fi
      done

      if [[ $probe_mode == none ]]; then
        reason='缺少 fuser，且 /proc 回退检查不可用'
        lock_status=unverified
        locked_json=null
      elif [[ -n $hit ]]; then
        locked_json=true
        lock_status=locked
        reason="检测到包管理锁文件正被占用: $hit"
      else
        locked_json=false
        lock_status=clear
        if [[ $probe_mode == fuser ]]; then
          reason='未发现包管理锁占用'
        else
          reason='未发现包管理锁占用（/proc 回退检查）'
        fi
      fi
    fi
  fi
  jq -n --arg kind "$kind" --arg status "$status" --arg lock_status "$lock_status" --arg reason "$reason" --argjson locked "$locked_json" \
    '{status:$status,kind:$kind,locked:$locked,lock_status:$lock_status,reason:$reason}'
}

_system_ip_addresses_json() {
  if ! _system_live_probe_allowed; then
    jq -n '{status:"unverified",reason:"RM_ROOT 隔离模式不读取宿主机网络",items:[]}'
    return
  fi
  if ! rm_have ip; then jq -n '{status:"unverified",reason:"缺少 ip 工具",items:[]}'; return; fi
  local raw
  if raw=$(ip -j addr show 2>/dev/null); then
    jq -n --argjson raw "$raw" '{status:"ok",reason:null,items:[$raw[] | {ifname:.ifname,addresses:[.addr_info[]? | select(.scope!="host") | {family:.family,address:.local,prefixlen:.prefixlen,scope:.scope}]}]}'
  else jq -n '{status:"unverified",reason:"ip addr 查询失败",items:[]}'; fi
}

_system_default_routes_json() {
  if ! _system_live_probe_allowed; then jq -n '{status:"unverified",reason:"RM_ROOT 隔离模式不读取宿主机路由",items:[]}'; return; fi
  if ! rm_have ip; then jq -n '{status:"unverified",reason:"缺少 ip 工具",items:[]}'; return; fi
  local r4='[]' r6='[]'
  r4=$(ip -j -4 route show default 2>/dev/null | jq '[.[] | {family:"inet",gateway:(.gateway//null),dev:(.dev//null),metric:(.metric//null),prefsrc:(.prefsrc//null)}]' 2>/dev/null || printf '[]')
  r6=$(ip -j -6 route show default 2>/dev/null | jq '[.[] | {family:"inet6",gateway:(.gateway//null),dev:(.dev//null),metric:(.metric//null),prefsrc:(.prefsrc//null)}]' 2>/dev/null || printf '[]')
  jq -n --argjson a "$r4" --argjson b "$r6" '{status:"ok",reason:null,items:($a+$b|unique_by([.family,.gateway,.dev,.metric]))}'
}

_system_listeners_json() {
  if ! _system_live_probe_allowed; then jq -n '{status:"unverified",reason:"RM_ROOT 隔离模式不读取宿主机监听",items:[]}'; return; fi
  if ! rm_have ss; then jq -n '{status:"unverified",reason:"缺少 ss 工具",items:[]}'; return; fi
  local data
  data=$(ss -H -lntup 2>/dev/null | awk '{proto=$1; state=$2; localaddr=$5; peer=$6; $1=$2=$3=$4=$5=$6=""; sub(/^[[:space:]]+/,"",$0); print proto"\t"state"\t"localaddr"\t"peer"\t"$0}' | \
    jq -R -s 'split("\n")|map(select(length>0)|split("\t")|{proto:.[0],state:.[1],local:.[2],peer:.[3],process:(.[4]//"")})' 2>/dev/null || printf '[]')
  jq -n --argjson items "$data" '{status:"ok",reason:null,items:$items}'
}

system_network_json() {
  local a r l
  a=$(_system_ip_addresses_json); r=$(_system_default_routes_json); l=$(_system_listeners_json)
  jq -n --argjson a "$a" --argjson r "$r" --argjson l "$l" \
    '{addresses:$a.items,address_status:$a.status,address_reason:$a.reason,default_routes:$r.items,route_status:$r.status,route_reason:$r.reason,listeners:$l.items,listener_status:$l.status,listener_reason:$l.reason}'
}

_system_command_path() {
  local cmd=$1
  if [[ -n $RM_ROOT ]]; then
    local p
    for p in /usr/sbin/$cmd /usr/bin/$cmd /sbin/$cmd /bin/$cmd; do [[ -x $(rm_path "$p") ]] && { printf '%s\n' "$(rm_path "$p")"; return 0; }; done
    return 1
  fi
  command -v "$cmd" 2>/dev/null
}

system_component_json() {
  local name=$1 command=$2 service=${3:-} installed=false active_json=null path='' status=ok reason=''
  if path=$(_system_command_path "$command"); then installed=true; else status=unverified; reason="未检测到 $command"; fi
  if [[ -n $service ]]; then
    if _system_live_probe_allowed && [[ -d /run/systemd/system ]] && rm_have systemctl; then
      if systemctl is-active --quiet "$service" 2>/dev/null; then active_json=true; else active_json=false; fi
    else
      active_json=null
      [[ -n $reason ]] && reason+='；'
      reason+='服务运行状态未检测'
    fi
  fi
  jq -n --arg name "$name" --argjson installed "$installed" --argjson active "$active_json" --arg path "$path" --arg status "$status" --arg reason "$reason" \
    '{name:$name,status:$status,installed:$installed,active:$active,path:(if $path=="" then null else $path end),reason:(if $reason=="" then null else $reason end)}'
}

system_managed_xray_json() {
  local base current resolved='' bin='' version='' installed=false active_json=null status=unverified reason='未检测到 AsterNode 受管 Xray'
  base=$(rm_path /usr/local/lib/relay-manager/core)
  current="$base/current"

  if [[ -L $current ]]; then
    resolved=$(readlink -f -- "$current" 2>/dev/null || true)
    if [[ -n $resolved && $resolved == "$base/"* && -d $resolved &&
          -x $resolved/xray && ! -L $resolved/xray ]]; then
      bin="$resolved/xray"
      version=${resolved##*/}
      installed=true
      status=ok
      reason=''
    else
      reason='受管 Xray current 链接无效或越出受管目录'
    fi
  elif [[ -e $current ]]; then
    reason='受管 Xray current 不是符号链接'
  fi

  if _system_live_probe_allowed && [[ -d /run/systemd/system ]] && rm_have systemctl; then
    if systemctl is-active --quiet relay-manager-xray.service 2>/dev/null; then active_json=true; else active_json=false; fi
  elif [[ $installed == true ]]; then
    active_json=null
    reason='服务运行状态未检测'
  fi

  jq -n --argjson installed "$installed" --argjson active "$active_json" --arg path "$bin" --arg version "$version" \
    --arg status "$status" --arg reason "$reason" \
    '{name:"xray",managed:true,source:"asternode-managed",status:$status,installed:$installed,active:$active,
      path:(if $path=="" then null else $path end),version:(if $version=="" then null else $version end),
      reason:(if $reason=="" then null else $reason end)}'
}

system_external_processes_json() {
  if ! _system_live_probe_allowed; then jq -n '[]'; return; fi
  if ! rm_have ps; then jq -n '[]'; return; fi
  ps -eo pid=,comm=,args= 2>/dev/null | awk '
    BEGIN{IGNORECASE=1}
    {
      pid=$1; comm=$2; $1=""; $2=""; sub(/^[[:space:]]+/,"",$0); args=$0;
      lc=tolower(comm); la=tolower(args);
      if (lc=="xray" || lc=="x-ui" || lc=="3x-ui" || lc=="nginx" || la ~ /(^|[[:space:]\/])(xray|x-ui|3x-ui|nginx)([[:space:]]|$)/)
        print pid"\t"comm"\t"args;
    }
  ' | jq -R -s 'split("\n")|map(select(length>0)|split("\t")|{pid:(.[0]|tonumber),command:.[1],args:(.[2]//"")})' 2>/dev/null || printf '[]\n'
}

system_firewall_json() {
  local ufw=false nft=false iptables=false firewalld=false container=false
  local ufw_trace=false nft_trace=false firewalld_trace=false container_trace=false
  _system_command_path ufw >/dev/null 2>&1 && ufw=true || true
  _system_command_path nft >/dev/null 2>&1 && nft=true || true
  _system_command_path iptables >/dev/null 2>&1 && iptables=true || true
  _system_command_path firewall-cmd >/dev/null 2>&1 && firewalld=true || true
  [[ -e $(rm_path /etc/ufw/ufw.conf) || -d $(rm_path /etc/ufw) ]] && ufw_trace=true
  [[ -e $(rm_path /etc/nftables.conf) || -d $(rm_path /etc/nftables.d) ]] && nft_trace=true
  [[ -d $(rm_path /etc/firewalld) ]] && firewalld_trace=true
  [[ -d $(rm_path /var/lib/docker) || -d $(rm_path /etc/docker) || -d $(rm_path /var/lib/containers) ]] && container_trace=true
  if _system_live_probe_allowed; then
    (rm_have docker || rm_have podman) && container=true || true
  fi
  [[ $container_trace == true ]] && container=true
  jq -n --argjson ufw "$ufw" --argjson nft "$nft" --argjson iptables "$iptables" --argjson firewalld "$firewalld" --argjson container "$container" \
    --argjson ufw_trace "$ufw_trace" --argjson nft_trace "$nft_trace" --argjson firewalld_trace "$firewalld_trace" --argjson container_trace "$container_trace" \
    '{ufw:{command:$ufw,trace:$ufw_trace},nftables:{command:$nft,trace:$nft_trace},iptables:{command:$iptables},firewalld:{command:$firewalld,trace:$firewalld_trace},container_network:{detected:$container,trace:$container_trace}}'
}

_system_sshd_path() {
  if [[ -n $RM_ROOT ]]; then
    _system_command_path sshd
  elif rm_have sshd; then command -v sshd
  elif [[ -x /usr/sbin/sshd ]]; then printf '/usr/sbin/sshd\n'
  else return 1
  fi
}

_system_sshd_effective() {
  local bin=$1 user=$2 addr=$3
  if ! _system_live_probe_allowed; then return 1; fi
  if rm_have timeout; then timeout 4 "$bin" -T -C "user=$user,host=localhost,addr=$addr" 2>/dev/null
  else "$bin" -T -C "user=$user,host=localhost,addr=$addr" 2>/dev/null
  fi
}

_system_ssh_key_presence_json() {
  local user=$1 effective=$2 authcmd akf home first path present=false count=0
  authcmd=$(awk '$1=="authorizedkeyscommand"{$1="";sub(/^ /,"");print;exit}' <<<"$effective")
  if [[ -n $authcmd && $authcmd != none ]]; then
    jq -n --arg reason "检测到 AuthorizedKeysCommand=$authcmd，不能用本地文件代表全部公钥入口" '{status:"unverified",present:null,count:null,path:null,reason:$reason}'
    return
  fi
  akf=$(awk '$1=="authorizedkeysfile"{$1="";sub(/^ /,"");print;exit}' <<<"$effective")
  [[ -n $akf ]] || { jq -n '{status:"unverified",present:null,count:null,path:null,reason:"有效配置未返回 AuthorizedKeysFile"}'; return; }
  first=${akf%% *}
  if ! home=$(getent passwd "$user" 2>/dev/null | awk -F: 'NR==1{print $6}'); then home=''; fi
  [[ -n $home ]] || { jq -n '{status:"unverified",present:null,count:null,path:null,reason:"无法确定目标用户主目录"}'; return; }
  first=${first//%u/$user}; first=${first//%h/$home}
  if [[ $first == /* ]]; then path=$first; else path="$home/$first"; fi
  if [[ -f $path && ! -L $path ]]; then
    count=$(grep -Evc '^[[:space:]]*(#|$)' "$path" 2>/dev/null || true)
    ((count>0)) && present=true
  fi
  jq -n --arg path "$path" --argjson present "$present" --argjson count "$count" '{status:"ok",present:$present,count:$count,path:$path,reason:null}'
}

system_ssh_json() {
  local user=${1:-root} addr=${2:-127.0.0.1} bin='' installed=false mode=unknown effective='' eff_status=unverified eff_reason='sshd 未安装或不可执行'
  local processes='[]' actual_ports='[]' key_presence
  if bin=$(_system_sshd_path); then installed=true; fi

  if _system_live_probe_allowed && rm_have ps; then
    processes=$(ps -eo pid=,args= 2>/dev/null | awk '/[s]shd([[:space:]]|$)/ {pid=$1; $1=""; sub(/^[[:space:]]+/,"",$0); print pid"\t"$0}' | jq -R -s 'split("\n")|map(select(length>0)|split("\t")|{pid:(.[0]|tonumber),args:(.[1]//"")})' 2>/dev/null || printf '[]')
  fi
  if _system_live_probe_allowed && rm_have ss; then
    actual_ports=$(ss -H -lntp 2>/dev/null | awk '$0 ~ /sshd/ {a=$4; sub(/^.*:/,"",a); if(a~/^[0-9]+$/) print a}' | sort -nu | jq -R -s 'split("\n")|map(select(length>0)|tonumber)|unique' 2>/dev/null || printf '[]')
  fi

  if _system_live_probe_allowed && [[ -d /run/systemd/system ]] && rm_have systemctl; then
    if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then mode=socket
    elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then mode=service:ssh
    elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then mode=service:sshd
    fi
  fi

  if [[ $installed == true ]]; then
    if effective=$(_system_sshd_effective "$bin" "$user" "$addr"); then eff_status=ok; eff_reason=''
    elif ! _system_live_probe_allowed; then eff_reason='RM_ROOT 隔离模式不执行宿主机 sshd'
    else eff_reason='sshd -T -C 有效配置检查失败'; fi
  fi

  local ports='[]' pubkey='' pass='' kbd='' root='' authm='' akf='' akc=''
  if [[ $eff_status == ok ]]; then
    ports=$(awk '$1=="port"{print $2}' <<<"$effective" | jq -R -s 'split("\n")|map(select(length>0)|tonumber)|unique')
    pubkey=$(awk '$1=="pubkeyauthentication"{print $2;exit}' <<<"$effective")
    pass=$(awk '$1=="passwordauthentication"{print $2;exit}' <<<"$effective")
    kbd=$(awk '$1=="kbdinteractiveauthentication"{print $2;exit}' <<<"$effective")
    root=$(awk '$1=="permitrootlogin"{print $2;exit}' <<<"$effective")
    authm=$(awk '$1=="authenticationmethods"{$1="";sub(/^ /,"");print;exit}' <<<"$effective")
    akf=$(awk '$1=="authorizedkeysfile"{$1="";sub(/^ /,"");print;exit}' <<<"$effective")
    akc=$(awk '$1=="authorizedkeyscommand"{$1="";sub(/^ /,"");print;exit}' <<<"$effective")
    key_presence=$(_system_ssh_key_presence_json "$user" "$effective")
  else
    key_presence=$(jq -n --arg reason "$eff_reason" '{status:"unverified",present:null,count:null,path:null,reason:$reason}')
  fi

  local login_verified=false verification_source=null statef
  statef=$(rm_path /etc/relay-manager/state.json)
  if [[ -f $statef ]] && jq -e --arg u "$user" '.ssh_verifications[$u].key_login_manual==true' "$statef" >/dev/null 2>&1; then
    login_verified=true; verification_source='relay-manager-manual-new-connection-confirmation'
  fi

  jq -n --argjson installed "$installed" --arg bin "$bin" --arg mode "$mode" --arg user "$user" --arg source_addr "$addr" \
    --arg status "$eff_status" --arg reason "$eff_reason" --argjson effective_ports "$ports" --argjson actual_ports "$actual_ports" --argjson processes "$processes" \
    --arg pubkey "$pubkey" --arg pass "$pass" --arg kbd "$kbd" --arg root "$root" --arg authm "$authm" --arg akf "$akf" --arg akc "$akc" --argjson key_presence "$key_presence" \
    --argjson verified "$login_verified" --arg verification_source "$verification_source" \
    '{installed:$installed,binary:(if $bin=="" then null else $bin end),start_mode:$mode,context:{user:$user,source_address:$source_addr,note:"此上下文结果不能代表其他用户或其他 Match 条件"},
      effective:{status:$status,reason:(if $reason=="" then null else $reason end),ports:$effective_ports,pubkey_authentication:(if $pubkey=="" then null else $pubkey end),password_authentication:(if $pass=="" then null else $pass end),kbd_interactive_authentication:(if $kbd=="" then null else $kbd end),permit_root_login:(if $root=="" then null else $root end),authentication_methods:(if $authm=="" then null else $authm end),authorized_keys_file:(if $akf=="" then null else $akf end),authorized_keys_command:(if $akc=="" then null else $akc end)},
      actual_listen_ports:$actual_ports,processes:$processes,public_key_presence:$key_presence,login_verified:$verified,verification_source:(if $verification_source=="" then null else $verification_source end)}'
}

system_conflicts_json() {
  local ext xray_external=false xray_count=0
  ext=$(system_external_processes_json)
  xray_count=$(jq '[.[]|select((.command|ascii_downcase)=="xray" or (.args|test("(^|[ /])xray([ ]|$)";"i")))]|length' <<<"$ext")
  if ((xray_count>0)); then
    if jq -e '.[]|select(((.command|ascii_downcase)=="xray" or (.args|test("(^|[ /])xray([ ]|$)";"i"))) and (.args|contains("/usr/local/lib/relay-manager/core/")|not))' <<<"$ext" >/dev/null; then xray_external=true; fi
  fi
  jq -n --argjson unmanaged_xray "$xray_external" --argjson xray_count "$xray_count" '{unmanaged_xray_detected:$unmanaged_xray,xray_process_count:$xray_count}'
}

system_probe_fast() {
  local ssh_user=${1:-root} ssh_addr=${2:-127.0.0.1}
  local support mem disk inode pkg net ext fw f2b xray managed_xray external_xray xui nginx ssh conflicts cpu
  support=$(system_support_json); mem=$(system_memory_json); disk=$(system_disk_json); inode=$(system_inode_json); pkg=$(system_pkg_manager_json)
  net=$(system_network_json); ext=$(system_external_processes_json); fw=$(system_firewall_json)
  f2b=$(system_component_json fail2ban fail2ban-client fail2ban)
  managed_xray=$(system_managed_xray_json)
  external_xray=$(system_component_json xray xray xray | jq '. + {managed:false,source:"external-path"}')
  if jq -e '.installed==true' <<<"$managed_xray" >/dev/null; then xray=$managed_xray; else xray=$external_xray; fi
  xui=$(system_component_json 3x-ui x-ui x-ui); nginx=$(system_component_json nginx nginx nginx)
  ssh=$(system_ssh_json "$ssh_user" "$ssh_addr"); conflicts=$(system_conflicts_json)
  cpu=$(system_cpu_count 2>/dev/null || printf null); [[ $cpu =~ ^[0-9]+$ ]] || cpu=null
  jq -n \
    --arg generated_at "$(rm_now)" --argjson support "$support" --argjson cpu "$cpu" \
    --argjson memory "$mem" --argjson disk "$disk" --argjson inode "$inode" --argjson package_manager "$pkg" \
    --argjson network "$net" --argjson external_processes "$ext" --argjson firewall "$fw" --argjson fail2ban "$f2b" \
    --argjson xray "$xray" --argjson managed_xray "$managed_xray" --argjson external_xray "$external_xray" \
    --argjson xui "$xui" --argjson nginx "$nginx" --argjson ssh "$ssh" --argjson conflicts "$conflicts" --argjson euid "$(id -u)" \
    '{generated_at:$generated_at,probe_mode:"read-only",support:$support,privilege:{euid:$euid,is_root:($euid==0)},cpu:{logical:$cpu},memory:$memory,disk:$disk,inode:$inode,package_manager:$package_manager,network:$network,ssh:$ssh,firewall:$firewall,
      components:{fail2ban:$fail2ban,xray:$xray,xray_managed:$managed_xray,xray_external:$external_xray,xui:$xui,nginx:$nginx},
      external_processes:$external_processes,conflicts:$conflicts}'
}

system_probe_public_address() {
  local family=${1:-auto} endpoint curl_family='' result source
  case "$family" in
    4) endpoint='https://api.ipify.org'; curl_family='-4' ;;
    6) endpoint='https://api6.ipify.org'; curl_family='-6' ;;
    auto) endpoint='https://api64.ipify.org' ;;
    *) return "$RM_RC_PRECONDITION" ;;
  esac
  source=$endpoint
  if ! _system_live_probe_allowed; then
    jq -n --arg source "$source" '{status:"unverified",source:$source,reason:"RM_ROOT 隔离模式不执行联网探测",address:null}'
    return 0
  fi
  if ! rm_have curl; then
    jq -n --arg source "$source" '{status:"unverified",source:$source,reason:"缺少 curl",address:null}'
    return 0
  fi
  if result=$(curl $curl_family -fsS --proto '=https' --tlsv1.2 --max-time 4 --connect-timeout 2 "$endpoint" 2>/dev/null); then
    result=${result//$'\r'/}; result=${result//$'\n'/}
    if rm_normalize_ip_or_cidr "$result" >/dev/null 2>&1 && [[ $result != */* ]]; then
      jq -n --arg source "$source" --arg addr "$result" '{status:"ok",source:$source,address:$addr,reason:null}'
    else
      jq -n --arg source "$source" '{status:"unverified",source:$source,reason:"返回值不是有效 IP",address:null}'
    fi
  else
    jq -n --arg source "$source" '{status:"unverified",source:$source,reason:"联网探测超时或不可达",address:null}'
  fi
}

system_port_owner() {
  local port=${1:?port required}
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  if ! _system_live_probe_allowed; then jq -n --argjson port "$port" '{port:$port,status:"unverified",reason:"RM_ROOT 隔离模式不读取宿主机监听"}'; return 0; fi
  if ! rm_have ss; then jq -n --argjson port "$port" '{port:$port,status:"unverified",reason:"缺少 ss"}'; return 0; fi
  local lines
  lines=$(ss -H -lntup "sport = :$port" 2>/dev/null || true)
  if [[ -z $lines ]]; then jq -n --argjson port "$port" '{port:$port,status:"free",detail:null}'
  else jq -n --argjson port "$port" --arg text "$lines" '{port:$port,status:"occupied",detail:$text}'; fi
}
