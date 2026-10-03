#!/usr/bin/env bash
# Conservative UFW adapter. It never resets UFW and never edits external rules.
# Stage C deliberately separates "rules written" from "isolation verified".
# shellcheck source=lib/transaction.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/transaction.sh"
# shellcheck source=lib/system.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/system.sh"

fw_ufw() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    if [[ -n ${RM_UFW_LOG:-} ]]; then
      printf '%q ' "$@" >>"$RM_UFW_LOG"
      printf '\n' >>"$RM_UFW_LOG"
    fi
    [[ ${RM_UFW_TEST_FAIL:-0} == 0 ]]
    return
  fi
  ufw "$@"
}

fw_ufw_status_text() {
  if [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_STATUS_FILE:-} && -f $RM_UFW_STATUS_FILE ]]; then
    cat "$RM_UFW_STATUS_FILE"
  else
    ufw status verbose 2>/dev/null
  fi
}

fw_ufw_added_text() {
  if [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_ADDED_FILE:-} && -f $RM_UFW_ADDED_FILE ]]; then
    cat "$RM_UFW_ADDED_FILE"
  else
    ufw show added 2>/dev/null
  fi
}

fw_ufw_raw_text() {
  if [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_RAW_FILE:-} && -f $RM_UFW_RAW_FILE ]]; then
    cat "$RM_UFW_RAW_FILE"
  else
    ufw show raw 2>/dev/null
  fi
}

fw_ipv6_enabled() {
  local f val
  f=$(rm_path /etc/default/ufw)
  [[ -r $f ]] || return 1
  val=$(awk -F= '$1=="IPV6"{gsub(/[[:space:]"]/,"",$2);print tolower($2);exit}' "$f")
  [[ $val == yes || $val == true || $val == 1 ]]
}

fw_framework_integrity_files_json() {
  if ! rm_have md5sum; then
    jq -n '{status:"unverified",modified:null,paths:[],unverified_paths:["md5sum"]}'
    return
  fi

  local logical path base template history actual template_hash known_hashes
  local modified='[]' unverified='[]'

  for logical in /etc/ufw/before.rules /etc/ufw/after.rules /etc/ufw/before6.rules /etc/ufw/after6.rules; do
    path=$(rm_path "$logical")
    base=${logical##*/}
    template=$(rm_path "/usr/share/ufw/$base")
    history=$(rm_path "/usr/share/ufw/$base.md5sum")

    if [[ ! -f $path || -L $path ]]; then
      modified=$(jq -c --arg p "$logical" '.+[$p]' <<<"$modified")
      continue
    fi

    actual=$(md5sum "$path" 2>/dev/null | awk '{print $1}') || actual=''
    if [[ ! $actual =~ ^[0-9a-fA-F]{32}$ ]]; then
      unverified=$(jq -c --arg p "$logical" '.+[$p]' <<<"$unverified")
      continue
    fi
    actual=${actual,,}

    known_hashes=''
    if [[ -f $template && ! -L $template ]]; then
      template_hash=$(md5sum "$template" 2>/dev/null | awk '{print $1}') || template_hash=''
      [[ $template_hash =~ ^[0-9a-fA-F]{32}$ ]] && known_hashes+="${template_hash,,}"
fw_complex_runtime_reason() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    printf '%s\n' "${RM_UFW_COMPLEX_REASON:-}"
    return
  fi
  local reason=''
  if systemctl is-active --quiet firewalld 2>/dev/null; then reason='firewalld 正在运行'; fi
  if systemctl is-active --quiet nftables 2>/dev/null; then reason="${reason:+$reason; }独立 nftables.service 正在运行"; fi
  if systemctl is-active --quiet docker 2>/dev/null || systemctl is-active --quiet podman 2>/dev/null; then
    reason="${reason:+$reason; }检测到容器网络服务"
  fi
  local raw
  raw=$(fw_ufw_raw_text || true)
  if grep -Eq '(^|[[:space:]])(DOCKER|CNI|CILIUM|LIBVIRT|KUBE-|PODMAN)' <<<"$raw"; then
    reason="${reason:+$reason; }底层防火墙存在容器/虚拟化链"
  fi
  printf '%s\n' "$reason"
}

fw_status_json() {
  local installed=false active=false default_in=unknown text reason='' integrity complex=false ipv6=false
  rm_have ufw && installed=true
  [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_STATUS_FILE:-} ]] && installed=true
  if [[ $installed == true ]]; then
    text=$(fw_ufw_status_text || true)
    grep -qi '^Status: active' <<<"$text" && active=true
    default_in=$(sed -nE 's/^Default: ([a-z]+) \(incoming\).*/\1/p' <<<"$text" | head -n1)
    [[ -n $default_in ]] || default_in=unknown
  fi
  fw_ipv6_enabled && ipv6=true || true
  integrity=$(fw_framework_integrity_json)
  reason=$(fw_complex_runtime_reason)
  if [[ -n $reason || $(jq -r '.modified==true' <<<"$integrity") == true ]]; then complex=true; fi
  if [[ $(jq -r .status <<<"$integrity") == unverified ]]; then
    reason="${reason:+$reason; }UFW before/after 规则完整性未能确认"
  fi
  jq -n --argjson installed "$installed" --argjson active "$active" --arg default "$default_in" \
    --argjson ipv6 "$ipv6" --argjson complex "$complex" --arg reason "$reason" --argjson integrity "$integrity" \
    '{installed:$installed,active:$active,default_incoming:$default,ipv6_enabled:$ipv6,
      framework_integrity:$integrity,complex_environment:$complex,
      reason:(if $reason=="" then null else $reason end),
      isolation_verified:false}'
}

fw_require_framework_safe() {
  local s; s=$(fw_status_json)
  jq -e '.installed==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 环境不能安全自动接管: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
}

fw_require_manageable() {
  local s; s=$(fw_status_json)
  jq -e '.installed==true and .active==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 未启用或环境存在冲突，自动写规则被禁用: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
}

fw_rule_args_json() {
  local action=$1 source=$2 port=$3 comment=$4
  [[ $action == allow || $action == deny || $action == limit ]] || return "$RM_RC_PRECONDITION"
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  if [[ $source == any ]]; then
    jq -n --arg a "$action" --arg p "$port" --arg c "$comment" '[$a,"to","any","port",$p,"proto","tcp","comment",$c]'
  else
    jq -n --arg a "$action" --arg s "$source" --arg p "$port" --arg c "$comment" '[$a,"from",$s,"to","any","port",$p,"proto","tcp","comment",$c]'
  fi
}

fw_exec_rule_json() {
  local json=$1 op=${2:-add} placement=${3:-append}
  local -a args=()
  mapfile -t args < <(jq -r '.[]' <<<"$json")
  case "$op:$placement" in
    add:append) fw_ufw "${args[@]}" ;;
    add:prepend) fw_ufw prepend "${args[@]}" ;;
    delete:*) fw_ufw --force delete "${args[@]}" ;;
    *) return "$RM_RC_PRECONDITION" ;;
  esac
}

fw_marker_present() {
  local marker=$1
  [[ ${RM_TEST_MODE} == 1 ]] && return 0
  fw_ufw_status_text | grep -Fq "# $marker"
}

fw_port_external_allow_conflict() {
  local port=$1 text
  text=$(fw_ufw_status_text || true)
  awk -v p="$port" 'BEGIN{IGNORECASE=1; bad=0}
    /ALLOW|LIMIT/ && $0 !~ /relay-manager:/ {
      to=$1
      if (to=="Anywhere" || to==p || to==p"/tcp" || to ~ ("^" p "/")) bad=1
    }
    END{exit bad?0:1}' <<<"$text"
}

fw_store_rule() {
  local rule=$1
  state_init >/dev/null
  state_update_filter '.owned_firewall_rules=((.owned_firewall_rules + [$rule])|unique_by(.comment))' --argjson rule "$rule"
}

fw_remove_owned_rule_from_state() {
  local comment=$1
  state_update_filter '.owned_firewall_rules=[.owned_firewall_rules[]|select((.comment//"")!=$comment)]' --arg comment "$comment"
}

fw_install_packages() {
  local assume_yes=${1:-false} pm
  rm_require_root || return $?
  pm=$(system_pkg_manager_json)
  jq -e '.kind=="apt" and .locked==false' <<<"$pm" >/dev/null || {
    rm_error "包管理器不可用或被锁定: $(jq -c . <<<"$pm")"
    return "$RM_RC_PRECONDITION"
  }
  rm_info '计划安装: ufw（不会 reset，不会修改默认策略）'
  if [[ $assume_yes != true ]]; then
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_confirm '确认安装 UFW?' || return "$RM_RC_CANCEL"
  fi
  DEBIAN_FRONTEND=noninteractive apt-get update || return "$RM_RC_NETWORK"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ufw || return "$RM_RC_PRECONDITION"
}

fw_detect_ssh_ports_json() {
  if [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_TEST_SSH_PORTS:-} ]]; then
    tr ',' '\n' <<<"$RM_UFW_TEST_SSH_PORTS" | jq -R -s 'split("\n")|map(select(length>0)|tonumber)|unique'
  else
    system_ssh_json root 127.0.0.1 | jq '(.actual_listen_ports + .effective.ports)|unique'
  fi
}

fw_enable_safe() {
  rm_require_root || return $?
  local s ssh_ports preserve_ports='[]' p rule comment added='[]' arg
  s=$(fw_status_json)
  jq -e '.installed==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 环境不能安全启用: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
  if jq -e '.active==true' <<<"$s" >/dev/null; then
    jq -n '{status:"already_active",default_policy_preserved:true}'
    return 0
  fi

  while (($#)); do
    arg=$1; shift
    case "$arg" in
      --preserve-port)
        (($#)) || { rm_error '--preserve-port 缺少端口'; return "$RM_RC_PRECONDITION"; }
        p=$1; shift
        rm_valid_port "$p" || return "$RM_RC_PRECONDITION"
        preserve_ports=$(jq -c --argjson p "$p" '.+[$p]|unique' <<<"$preserve_ports")
        ;;
      *)
        rm_error "未知 UFW enable 参数: $arg（业务入口请使用 --preserve-port PORT）"
        return "$RM_RC_PRECONDITION"
        ;;
    esac
  done

  ssh_ports=$(fw_detect_ssh_ports_json)
  [[ $(jq 'length' <<<"$ssh_ports") -gt 0 ]] || {
    rm_error '无法确定现有 SSH 监听端口，拒绝启用 UFW。'
    return "$RM_RC_PRECONDITION"
  }
  for p in $(jq -r '.[]' <<<"$ssh_ports"); do rm_valid_port "$p" || return "$RM_RC_PRECONDITION"; done
  preserve_ports=$(jq -c --argjson ssh "$ssh_ports" '[.[]|select(. as $p|($ssh|index($p)|not))]|unique' <<<"$preserve_ports")

  if [[ ${RM_TEST_MODE} != 1 ]]; then
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_info '启用前检测到的监听服务如下；不会自动开放扫描到的非 SSH 端口：'
    system_network_json | jq '.listeners' >&2
    rm_info "SSH 将保留: $(jq -r 'join(",")' <<<"$ssh_ports")"
    rm_info "显式保留的其他 TCP 端口: $(jq -r 'if length==0 then "无" else join(",") end' <<<"$preserve_ports")"
    rm_confirm '确认这些就是启用 UFW 后需要保留的本机入口？现有 UFW 默认策略保持不变。' || return "$RM_RC_CANCEL"
  fi

  state_init >/dev/null
  for p in $(jq -r '.[]' <<<"$ssh_ports"); do
    comment="relay-manager:ssh:$p"
    rule=$(fw_rule_args_json allow any "$p" "$comment")
    if ! fw_exec_rule_json "$rule" add append; then
      while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
      return "$RM_RC_APPLY_ROLLED_BACK"
    fi
    added=$(jq -c --argjson r "$(jq -n --arg c "$comment" --argjson p "$p" --argjson a "$rule" '{comment:$c,port:$p,kind:"ssh-allow",source:"any",args:$a}')" '.+[$r]' <<<"$added")
  done
  for p in $(jq -r '.[]' <<<"$preserve_ports"); do
    comment="relay-manager:preserve:$p"
    rule=$(fw_rule_args_json allow any "$p" "$comment")
    if ! fw_exec_rule_json "$rule" add append; then
      while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
      return "$RM_RC_APPLY_ROLLED_BACK"
    fi
    added=$(jq -c --argjson r "$(jq -n --arg c "$comment" --argjson p "$p" --argjson a "$rule" '{comment:$c,port:$p,kind:"preserve-allow",source:"any",args:$a}')" '.+[$r]' <<<"$added")
  done

  if ! fw_ufw --force enable; then
    while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi
  if [[ ${RM_TEST_MODE} != 1 ]] && ! fw_ufw_status_text | grep -qi '^Status: active'; then
    return "$RM_RC_RECOVERY_INCOMPLETE"
  fi
  state_update_filter '.owned_firewall_rules=((.owned_firewall_rules + $rules)|unique_by(.comment))' --argjson rules "$added"
  jq -n --argjson ssh "$ssh_ports" --argjson preserve "$preserve_ports"     '{status:"enabled",ssh_ports_preserved:$ssh,business_ports_preserved:$preserve,default_policy_preserved:true,
      note:"仅开放已确认 SSH 入口和显式 --preserve-port 业务入口；未自动开放其他监听端口。"}'
}

fw_ensure_ssh_port() {
  local port=$1 status comment rule existing
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  status=$(fw_status_json)
  if ! jq -e '.installed==true and .active==true' <<<"$status" >/dev/null; then
    jq -n --argjson p "$port" '{status:"not_locally_enforced",port:$p,added:false,note:"UFW 未启用；仍需确认云安全组/NAT。"}'
    return 0
  fi
  fw_require_manageable || return $?
  state_init >/dev/null
  comment="relay-manager:ssh:$port"
  existing=$(jq -c --arg c "$comment" '[.owned_firewall_rules[]|select((.comment//"")==$c)]' "$RM_STATE_FILE")
  if [[ $(jq 'length' <<<"$existing") -gt 0 ]] && fw_marker_present "$comment"; then
    jq -n --argjson p "$port" '{status:"already_present",port:$p,added:false}'
    return 0
  fi
  rule=$(fw_rule_args_json allow any "$port" "$comment")
  fw_exec_rule_json "$rule" add append || return "$RM_RC_APPLY_ROLLED_BACK"
  fw_marker_present "$comment" || {
    fw_exec_rule_json "$rule" delete || true
    rm_error 'UFW 写入后未能读回 SSH 规则'
    return "$RM_RC_APPLY_ROLLED_BACK"
  }
  fw_store_rule "$(jq -n --arg c "$comment" --argjson p "$port" --argjson a "$rule" '{comment:$c,port:$p,kind:"ssh-allow",source:"any",args:$a}')"
  jq -n --argjson p "$port" '{status:"added",port:$p,added:true}'
}

fw_release_ssh_port() {
  local port=$1 entry comment
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  state_init >/dev/null
  comment="relay-manager:ssh:$port"
  entry=$(jq -c --arg c "$comment" '.owned_firewall_rules[]?|select((.comment//"")==$c)' "$RM_STATE_FILE" | head -n1)
  [[ -n $entry ]] || return 0
  fw_exec_rule_json "$(jq -c .args <<<"$entry")" delete || return "$RM_RC_RECOVERY_INCOMPLETE"
  fw_remove_owned_rule_from_state "$comment"
}

fw_apply_whitelist() {
  local nid=$1 port=$2; shift 2
  local sources=("$@") node status ipv6_required=false
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  fw_require_manageable || return $?
  state_init >/dev/null
  node=$(state_get_node "$nid" 2>/dev/null || true)
  if [[ -n $node && $(jq -r '.listen_address' <<<"$node") == *:* ]]; then ipv6_required=true; fi
  status=$(fw_status_json)
  if [[ $ipv6_required == true ]] && ! jq -e '.ipv6_enabled==true' <<<"$status" >/dev/null; then
    rm_error '节点监听 IPv6，但 UFW IPv6 支持未启用；拒绝产生伪白名单。'
    return "$RM_RC_PRECONDITION"
  fi
  if fw_port_external_allow_conflict "$port"; then
    rm_error "端口 $port 存在非受管 ALLOW/LIMIT 规则，无法证明白名单隔离，拒绝自动接管。"
    return "$RM_RC_PRECONDITION"
  fi

  local normalized='[]' s n
  for s in "${sources[@]}"; do
    n=$(rm_normalize_ip_or_cidr "$s") || { rm_error "无效来源: $s"; return "$RM_RC_PRECONDITION"; }
    normalized=$(jq -c --arg n "$n" '.+[$n]|unique' <<<"$normalized")
  done

  local desired='[]' r comment hash old current_sem desired_sem applied='[]' failed=false
  while IFS= read -r s; do
    [[ -n $s ]] || continue
    hash=$(printf '%s' "$s" | sha256sum | cut -c1-8)
    comment="relay-manager:$nid:allow:$hash"
    r=$(fw_rule_args_json allow "$s" "$port" "$comment")
    desired=$(jq -c --arg nid "$nid" --arg c "$comment" --argjson p "$port" --arg source "$s" --argjson a "$r" '.+[{node_id:$nid,comment:$c,port:$p,kind:"allow",source:$source,args:$a}]' <<<"$desired")
  done < <(jq -r '.[]' <<<"$normalized")
  comment="relay-manager:$nid:deny"
  r=$(fw_rule_args_json deny any "$port" "$comment")
  desired=$(jq -c --arg nid "$nid" --arg c "$comment" --argjson p "$port" --argjson a "$r" '.+[{node_id:$nid,comment:$c,port:$p,kind:"deny",source:"any",args:$a}]' <<<"$desired")

  old=$(jq -c --arg nid "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$nid)]' "$RM_STATE_FILE")
  current_sem=$(jq -c '[.[]|{port,kind,source}]|sort_by([.port,.kind,.source])' <<<"$old")
  desired_sem=$(jq -c '[.[]|{port,kind,source}]|sort_by([.port,.kind,.source])' <<<"$desired")
  if [[ $current_sem == "$desired_sem" ]]; then
    local all_present=true marker
    while IFS= read -r marker; do fw_marker_present "$marker" || all_present=false; done < <(jq -r '.[].comment' <<<"$desired")
    if [[ $all_present == true ]]; then
      jq -n --arg nid "$nid" --argjson p "$port" --argjson sources "$normalized" '{status:"already_applied_unverified",node_id:$nid,port:$p,sources:$sources}'
      return 0
    fi
  fi

  # Specific allows are prepended so they remain before an older managed deny during updates.
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" add prepend; then failed=true; break; fi
    applied=$(jq -c --argjson r "$r" '.+[$r]' <<<"$applied")
  done < <(jq -c '.[]|select(.kind=="allow")' <<<"$desired")
  if [[ $failed == false ]]; then
    r=$(jq -c '.[]|select(.kind=="deny")' <<<"$desired")
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" add append; then failed=true
    else applied=$(jq -c --argjson r "$r" '.+[$r]' <<<"$applied"); fi
  fi
  if [[ $failed == true ]]; then
    while IFS= read -r r; do [[ -n $r ]] && fw_exec_rule_json "$(jq -c .args <<<"$r")" delete || true; done < <(jq -c '.[]' <<<"$applied" | tac)
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi

  if [[ ${RM_TEST_MODE} != 1 ]]; then
    while IFS= read -r comment; do
      if ! fw_marker_present "$comment"; then
        while IFS= read -r r; do [[ -n $r ]] && fw_exec_rule_json "$(jq -c .args <<<"$r")" delete || true; done < <(jq -c '.[]' <<<"$applied" | tac)
        rm_error "UFW 写入后未读回受管规则: $comment"
        return "$RM_RC_APPLY_ROLLED_BACK"
      fi
    done < <(jq -r '.[].comment' <<<"$desired")
  fi

  # Now remove the old generation. If an exact rule is duplicated, one copy remains.
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" delete; then
      rm_error '旧 UFW 受管规则未能完整清理；保留更严格的新规则并要求人工对账。'
      return "$RM_RC_RECOVERY_INCOMPLETE"
    fi
  done < <(jq -c '.[]' <<<"$old" | tac)

  state_update_filter '.owned_firewall_rules=([.owned_firewall_rules[]|select((.node_id//"")!=$nid)] + $rules)
    | .firewall_verifications=((.firewall_verifications//{})|del(.[$nid]))' --arg nid "$nid" --argjson rules "$desired"
  jq -n --arg nid "$nid" --argjson p "$port" --argjson sources "$normalized" \
    '{status:"applied_unverified",node_id:$nid,port:$p,sources:$sources,
      note:(if ($sources|length)==0 then "空白名单已实现为节点端口默认拒绝；仍需真实网络对照测试。" else "规则已写入；只有完成允许来源成功 + 非白名单来源失败的外部对照测试后才能标记白名单有效。" end)}'
}

fw_mark_whitelist_verified() {
  local nid=$1 ans rules
  state_init >/dev/null
  rules=$(jq -c --arg id "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$id)]' "$RM_STATE_FILE")
  [[ $(jq 'length' <<<"$rules") -gt 0 ]] || { rm_error '该节点没有受管 UFW 白名单规则'; return "$RM_RC_PRECONDITION"; }
  if [[ ${RM_TEST_MODE} == 1 && ${RM_UFW_TEST_VERIFY:-} == VERIFY ]]; then ans=VERIFY
  else
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_read_tty ans '请确认：已从允许来源建立新连接成功，并从至少一个非白名单来源验证新连接失败。输入 VERIFY: '
  fi
  [[ $ans == VERIFY ]] || return "$RM_RC_CANCEL"
  state_update_filter '.firewall_verifications=((.firewall_verifications//{}) + {($nid):{verified:true,verified_at:$now}})' --arg nid "$nid"
  jq -n --arg nid "$nid" '{status:"verified_external_contrast",node_id:$nid}'
}

fw_remove_node_rules() {
  local nid=$1 rules r failed=false
  state_init >/dev/null
  rules=$(jq -c --arg nid "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$nid)]' "$RM_STATE_FILE")
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" delete; then failed=true; fi
  done < <(jq -c '.[]' <<<"$rules" | tac)
  [[ $failed == false ]] || { rm_error '部分 UFW 受管规则删除失败，状态未清理'; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  state_update_filter '.owned_firewall_rules=[.owned_firewall_rules[]|select((.node_id//"")!=$nid)]
    | .firewall_verifications=((.firewall_verifications//{})|del(.[$nid]))' --arg nid "$nid"
}

fw_temp_unit_names() {
  local nid=$1 safe=${nid//[^A-Za-z0-9_.-]/_}
  printf 'relay-manager-temp-%s\n' "$safe"
}

fw_temp_open() {
  local nid=$1 minutes=${2:-10}
  [[ $minutes =~ ^[0-9]+$ ]] && ((minutes>=1 && minutes<=1440)) || return "$RM_RC_PRECONDITION"
  fw_require_manageable || return $?
  state_init >/dev/null
  if jq -e --arg id "$nid" '.temporary_opens[]?|select(.node_id==$id)' "$RM_STATE_FILE" >/dev/null; then
    rm_error '该节点已有临时公网开放，请先等待到期或手动 expire-temp。'
    return "$RM_RC_PRECONDITION"
  fi
  local node port now deadline unit comment rule service timer tmpdir tx rc=0
  node=$(state_get_node "$nid") || return "$RM_RC_PRECONDITION"
  port=$(jq -r .listen_port <<<"$node")
  now=$(rm_epoch); deadline=$((now+minutes*60)); unit=$(fw_temp_unit_names "$nid")
  comment="relay-manager:$nid:temporary:$deadline"
  rule=$(fw_rule_args_json allow any "$port" "$comment")
  tmpdir=$(rm_safe_tmpdir); service="$tmpdir/$unit.service"; timer="$tmpdir/$unit.timer"
  cat >"$service" <<EOS
[Unit]
Description=AsterNode temporary public access expiry for $nid
[Service]
Type=oneshot
ExecStart=/usr/local/bin/relay-manager firewall expire-temp $nid
EOS
  cat >"$timer" <<EOS
[Unit]
Description=AsterNode temporary public access timer for $nid
[Timer]
OnCalendar=@$deadline
Persistent=true
AccuracySec=1s
Unit=$unit.service
[Install]
WantedBy=timers.target
EOS
  tx=$(tx_begin firewall-temp-open "$deadline") || { rm -rf "$tmpdir"; return $?; }
  tx_stage_file "$tx" "$service" "$(rm_path /etc/systemd/system/$unit.service)" 0644 root:root || rc=$?
  ((rc==0)) && tx_stage_file "$tx" "$timer" "$(rm_path /etc/systemd/system/$unit.timer)" 0644 root:root || rc=$?
  if ((rc!=0)); then tx_rollback "$tx" 'timer stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; fi
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'timer apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }

  if [[ ${RM_TEST_MODE} == 1 ]]; then
    rm_systemctl daemon-reload
    rm_systemctl enable "$unit.timer"
    rm_systemctl start "$unit.timer"
  else
    systemctl daemon-reload || { tx_rollback "$tx" 'timer daemon-reload failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl enable --now "$unit.timer" >/dev/null || { tx_rollback "$tx" 'timer enable failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl is-active --quiet "$unit.timer" || { tx_rollback "$tx" 'timer inactive' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
  fi

  # Public allow must precede the managed node deny, otherwise UFW first-match semantics would keep it blocked.
  if ! fw_exec_rule_json "$rule" add prepend; then
    [[ ${RM_TEST_MODE} == 1 ]] && rm_systemctl disable "$unit.timer" || systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
    tx_rollback "$tx" 'temporary UFW rule failed' || true
    rm -rf "$tmpdir"
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi
  tx_commit "$tx" || { fw_exec_rule_json "$rule" delete || true; rm -rf "$tmpdir"; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  state_update_filter '.temporary_opens=([.temporary_opens[]|select(.node_id!=$nid)] + [{node_id:$nid,deadline_epoch:$deadline,rule_args:$rule,unit:$unit}])' \
    --arg nid "$nid" --argjson deadline "$deadline" --argjson rule "$rule" --arg unit "$unit"
  rm -rf "$tmpdir"
  jq -n --arg nid "$nid" --argjson deadline "$deadline" '{status:"temporary_open_applied_unverified",node_id:$nid,deadline_epoch:$deadline,note:"到期只删除本次临时放行；已有连接可能继续，不执行全局 conntrack 清理。"}'
}

fw_expire_temp() {
  local nid=$1 entry unit rule
  state_init >/dev/null
  entry=$(jq -c --arg id "$nid" '.temporary_opens[]|select(.node_id==$id)' "$RM_STATE_FILE" 2>/dev/null || true)
  [[ -n $entry ]] || return 0
  unit=$(jq -r .unit <<<"$entry"); rule=$(jq -c .rule_args <<<"$entry")
  fw_exec_rule_json "$rule" delete || { rm_error '临时开放规则删除失败'; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  if [[ ${RM_TEST_MODE} == 1 ]]; then rm_systemctl disable "$unit.timer" || true
  else systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true; fi
  # Unit files are intentionally kept as owned, inert files. Avoid non-transactional rm during expiry.
  state_update_filter '.temporary_opens=[.temporary_opens[]|select(.node_id!=$nid)]' --arg nid "$nid"
}

fw_reconcile_expired() {
  state_init >/dev/null
  local now nid deadline rc=0
  now=$(rm_epoch)
  while IFS=$'\t' read -r nid deadline; do
    [[ -n $nid ]] || continue
    if ((deadline<=now)); then fw_expire_temp "$nid" || rc=$?; fi
  done < <(jq -r '.temporary_opens[]|[.node_id,.deadline_epoch]|@tsv' "$RM_STATE_FILE")
  return "$rc"
}
\n'
    fi
    if [[ -f $history && ! -L $history ]]; then
      known_hashes+=$(awk '$1 ~ /^[0-9a-fA-F]{32}$/ {print tolower($1)}' "$history" 2>/dev/null || true)
      known_hashes+=
fw_complex_runtime_reason() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    printf '%s\n' "${RM_UFW_COMPLEX_REASON:-}"
    return
  fi
  local reason=''
  if systemctl is-active --quiet firewalld 2>/dev/null; then reason='firewalld 正在运行'; fi
  if systemctl is-active --quiet nftables 2>/dev/null; then reason="${reason:+$reason; }独立 nftables.service 正在运行"; fi
  if systemctl is-active --quiet docker 2>/dev/null || systemctl is-active --quiet podman 2>/dev/null; then
    reason="${reason:+$reason; }检测到容器网络服务"
  fi
  local raw
  raw=$(fw_ufw_raw_text || true)
  if grep -Eq '(^|[[:space:]])(DOCKER|CNI|CILIUM|LIBVIRT|KUBE-|PODMAN)' <<<"$raw"; then
    reason="${reason:+$reason; }底层防火墙存在容器/虚拟化链"
  fi
  printf '%s\n' "$reason"
}

fw_status_json() {
  local installed=false active=false default_in=unknown text reason='' integrity complex=false ipv6=false
  rm_have ufw && installed=true
  [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_STATUS_FILE:-} ]] && installed=true
  if [[ $installed == true ]]; then
    text=$(fw_ufw_status_text || true)
    grep -qi '^Status: active' <<<"$text" && active=true
    default_in=$(sed -nE 's/^Default: ([a-z]+) \(incoming\).*/\1/p' <<<"$text" | head -n1)
    [[ -n $default_in ]] || default_in=unknown
  fi
  fw_ipv6_enabled && ipv6=true || true
  integrity=$(fw_framework_integrity_json)
  reason=$(fw_complex_runtime_reason)
  if [[ -n $reason || $(jq -r '.modified==true' <<<"$integrity") == true ]]; then complex=true; fi
  if [[ $(jq -r .status <<<"$integrity") == unverified ]]; then
    reason="${reason:+$reason; }UFW before/after 规则完整性未能确认"
  fi
  jq -n --argjson installed "$installed" --argjson active "$active" --arg default "$default_in" \
    --argjson ipv6 "$ipv6" --argjson complex "$complex" --arg reason "$reason" --argjson integrity "$integrity" \
    '{installed:$installed,active:$active,default_incoming:$default,ipv6_enabled:$ipv6,
      framework_integrity:$integrity,complex_environment:$complex,
      reason:(if $reason=="" then null else $reason end),
      isolation_verified:false}'
}

fw_require_framework_safe() {
  local s; s=$(fw_status_json)
  jq -e '.installed==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 环境不能安全自动接管: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
}

fw_require_manageable() {
  local s; s=$(fw_status_json)
  jq -e '.installed==true and .active==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 未启用或环境存在冲突，自动写规则被禁用: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
}

fw_rule_args_json() {
  local action=$1 source=$2 port=$3 comment=$4
  [[ $action == allow || $action == deny || $action == limit ]] || return "$RM_RC_PRECONDITION"
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  if [[ $source == any ]]; then
    jq -n --arg a "$action" --arg p "$port" --arg c "$comment" '[$a,"to","any","port",$p,"proto","tcp","comment",$c]'
  else
    jq -n --arg a "$action" --arg s "$source" --arg p "$port" --arg c "$comment" '[$a,"from",$s,"to","any","port",$p,"proto","tcp","comment",$c]'
  fi
}

fw_exec_rule_json() {
  local json=$1 op=${2:-add} placement=${3:-append}
  local -a args=()
  mapfile -t args < <(jq -r '.[]' <<<"$json")
  case "$op:$placement" in
    add:append) fw_ufw "${args[@]}" ;;
    add:prepend) fw_ufw prepend "${args[@]}" ;;
    delete:*) fw_ufw --force delete "${args[@]}" ;;
    *) return "$RM_RC_PRECONDITION" ;;
  esac
}

fw_marker_present() {
  local marker=$1
  [[ ${RM_TEST_MODE} == 1 ]] && return 0
  fw_ufw_status_text | grep -Fq "# $marker"
}

fw_port_external_allow_conflict() {
  local port=$1 text
  text=$(fw_ufw_status_text || true)
  awk -v p="$port" 'BEGIN{IGNORECASE=1; bad=0}
    /ALLOW|LIMIT/ && $0 !~ /relay-manager:/ {
      to=$1
      if (to=="Anywhere" || to==p || to==p"/tcp" || to ~ ("^" p "/")) bad=1
    }
    END{exit bad?0:1}' <<<"$text"
}

fw_store_rule() {
  local rule=$1
  state_init >/dev/null
  state_update_filter '.owned_firewall_rules=((.owned_firewall_rules + [$rule])|unique_by(.comment))' --argjson rule "$rule"
}

fw_remove_owned_rule_from_state() {
  local comment=$1
  state_update_filter '.owned_firewall_rules=[.owned_firewall_rules[]|select((.comment//"")!=$comment)]' --arg comment "$comment"
}

fw_install_packages() {
  local assume_yes=${1:-false} pm
  rm_require_root || return $?
  pm=$(system_pkg_manager_json)
  jq -e '.kind=="apt" and .locked==false' <<<"$pm" >/dev/null || {
    rm_error "包管理器不可用或被锁定: $(jq -c . <<<"$pm")"
    return "$RM_RC_PRECONDITION"
  }
  rm_info '计划安装: ufw（不会 reset，不会修改默认策略）'
  if [[ $assume_yes != true ]]; then
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_confirm '确认安装 UFW?' || return "$RM_RC_CANCEL"
  fi
  DEBIAN_FRONTEND=noninteractive apt-get update || return "$RM_RC_NETWORK"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ufw || return "$RM_RC_PRECONDITION"
}

fw_detect_ssh_ports_json() {
  if [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_TEST_SSH_PORTS:-} ]]; then
    tr ',' '\n' <<<"$RM_UFW_TEST_SSH_PORTS" | jq -R -s 'split("\n")|map(select(length>0)|tonumber)|unique'
  else
    system_ssh_json root 127.0.0.1 | jq '(.actual_listen_ports + .effective.ports)|unique'
  fi
}

fw_enable_safe() {
  rm_require_root || return $?
  local s ssh_ports preserve_ports='[]' p rule comment added='[]' arg
  s=$(fw_status_json)
  jq -e '.installed==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 环境不能安全启用: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
  if jq -e '.active==true' <<<"$s" >/dev/null; then
    jq -n '{status:"already_active",default_policy_preserved:true}'
    return 0
  fi

  while (($#)); do
    arg=$1; shift
    case "$arg" in
      --preserve-port)
        (($#)) || { rm_error '--preserve-port 缺少端口'; return "$RM_RC_PRECONDITION"; }
        p=$1; shift
        rm_valid_port "$p" || return "$RM_RC_PRECONDITION"
        preserve_ports=$(jq -c --argjson p "$p" '.+[$p]|unique' <<<"$preserve_ports")
        ;;
      *)
        rm_error "未知 UFW enable 参数: $arg（业务入口请使用 --preserve-port PORT）"
        return "$RM_RC_PRECONDITION"
        ;;
    esac
  done

  ssh_ports=$(fw_detect_ssh_ports_json)
  [[ $(jq 'length' <<<"$ssh_ports") -gt 0 ]] || {
    rm_error '无法确定现有 SSH 监听端口，拒绝启用 UFW。'
    return "$RM_RC_PRECONDITION"
  }
  for p in $(jq -r '.[]' <<<"$ssh_ports"); do rm_valid_port "$p" || return "$RM_RC_PRECONDITION"; done
  preserve_ports=$(jq -c --argjson ssh "$ssh_ports" '[.[]|select(. as $p|($ssh|index($p)|not))]|unique' <<<"$preserve_ports")

  if [[ ${RM_TEST_MODE} != 1 ]]; then
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_info '启用前检测到的监听服务如下；不会自动开放扫描到的非 SSH 端口：'
    system_network_json | jq '.listeners' >&2
    rm_info "SSH 将保留: $(jq -r 'join(",")' <<<"$ssh_ports")"
    rm_info "显式保留的其他 TCP 端口: $(jq -r 'if length==0 then "无" else join(",") end' <<<"$preserve_ports")"
    rm_confirm '确认这些就是启用 UFW 后需要保留的本机入口？现有 UFW 默认策略保持不变。' || return "$RM_RC_CANCEL"
  fi

  state_init >/dev/null
  for p in $(jq -r '.[]' <<<"$ssh_ports"); do
    comment="relay-manager:ssh:$p"
    rule=$(fw_rule_args_json allow any "$p" "$comment")
    if ! fw_exec_rule_json "$rule" add append; then
      while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
      return "$RM_RC_APPLY_ROLLED_BACK"
    fi
    added=$(jq -c --argjson r "$(jq -n --arg c "$comment" --argjson p "$p" --argjson a "$rule" '{comment:$c,port:$p,kind:"ssh-allow",source:"any",args:$a}')" '.+[$r]' <<<"$added")
  done
  for p in $(jq -r '.[]' <<<"$preserve_ports"); do
    comment="relay-manager:preserve:$p"
    rule=$(fw_rule_args_json allow any "$p" "$comment")
    if ! fw_exec_rule_json "$rule" add append; then
      while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
      return "$RM_RC_APPLY_ROLLED_BACK"
    fi
    added=$(jq -c --argjson r "$(jq -n --arg c "$comment" --argjson p "$p" --argjson a "$rule" '{comment:$c,port:$p,kind:"preserve-allow",source:"any",args:$a}')" '.+[$r]' <<<"$added")
  done

  if ! fw_ufw --force enable; then
    while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi
  if [[ ${RM_TEST_MODE} != 1 ]] && ! fw_ufw_status_text | grep -qi '^Status: active'; then
    return "$RM_RC_RECOVERY_INCOMPLETE"
  fi
  state_update_filter '.owned_firewall_rules=((.owned_firewall_rules + $rules)|unique_by(.comment))' --argjson rules "$added"
  jq -n --argjson ssh "$ssh_ports" --argjson preserve "$preserve_ports"     '{status:"enabled",ssh_ports_preserved:$ssh,business_ports_preserved:$preserve,default_policy_preserved:true,
      note:"仅开放已确认 SSH 入口和显式 --preserve-port 业务入口；未自动开放其他监听端口。"}'
}

fw_ensure_ssh_port() {
  local port=$1 status comment rule existing
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  status=$(fw_status_json)
  if ! jq -e '.installed==true and .active==true' <<<"$status" >/dev/null; then
    jq -n --argjson p "$port" '{status:"not_locally_enforced",port:$p,added:false,note:"UFW 未启用；仍需确认云安全组/NAT。"}'
    return 0
  fi
  fw_require_manageable || return $?
  state_init >/dev/null
  comment="relay-manager:ssh:$port"
  existing=$(jq -c --arg c "$comment" '[.owned_firewall_rules[]|select((.comment//"")==$c)]' "$RM_STATE_FILE")
  if [[ $(jq 'length' <<<"$existing") -gt 0 ]] && fw_marker_present "$comment"; then
    jq -n --argjson p "$port" '{status:"already_present",port:$p,added:false}'
    return 0
  fi
  rule=$(fw_rule_args_json allow any "$port" "$comment")
  fw_exec_rule_json "$rule" add append || return "$RM_RC_APPLY_ROLLED_BACK"
  fw_marker_present "$comment" || {
    fw_exec_rule_json "$rule" delete || true
    rm_error 'UFW 写入后未能读回 SSH 规则'
    return "$RM_RC_APPLY_ROLLED_BACK"
  }
  fw_store_rule "$(jq -n --arg c "$comment" --argjson p "$port" --argjson a "$rule" '{comment:$c,port:$p,kind:"ssh-allow",source:"any",args:$a}')"
  jq -n --argjson p "$port" '{status:"added",port:$p,added:true}'
}

fw_release_ssh_port() {
  local port=$1 entry comment
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  state_init >/dev/null
  comment="relay-manager:ssh:$port"
  entry=$(jq -c --arg c "$comment" '.owned_firewall_rules[]?|select((.comment//"")==$c)' "$RM_STATE_FILE" | head -n1)
  [[ -n $entry ]] || return 0
  fw_exec_rule_json "$(jq -c .args <<<"$entry")" delete || return "$RM_RC_RECOVERY_INCOMPLETE"
  fw_remove_owned_rule_from_state "$comment"
}

fw_apply_whitelist() {
  local nid=$1 port=$2; shift 2
  local sources=("$@") node status ipv6_required=false
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  fw_require_manageable || return $?
  state_init >/dev/null
  node=$(state_get_node "$nid" 2>/dev/null || true)
  if [[ -n $node && $(jq -r '.listen_address' <<<"$node") == *:* ]]; then ipv6_required=true; fi
  status=$(fw_status_json)
  if [[ $ipv6_required == true ]] && ! jq -e '.ipv6_enabled==true' <<<"$status" >/dev/null; then
    rm_error '节点监听 IPv6，但 UFW IPv6 支持未启用；拒绝产生伪白名单。'
    return "$RM_RC_PRECONDITION"
  fi
  if fw_port_external_allow_conflict "$port"; then
    rm_error "端口 $port 存在非受管 ALLOW/LIMIT 规则，无法证明白名单隔离，拒绝自动接管。"
    return "$RM_RC_PRECONDITION"
  fi

  local normalized='[]' s n
  for s in "${sources[@]}"; do
    n=$(rm_normalize_ip_or_cidr "$s") || { rm_error "无效来源: $s"; return "$RM_RC_PRECONDITION"; }
    normalized=$(jq -c --arg n "$n" '.+[$n]|unique' <<<"$normalized")
  done

  local desired='[]' r comment hash old current_sem desired_sem applied='[]' failed=false
  while IFS= read -r s; do
    [[ -n $s ]] || continue
    hash=$(printf '%s' "$s" | sha256sum | cut -c1-8)
    comment="relay-manager:$nid:allow:$hash"
    r=$(fw_rule_args_json allow "$s" "$port" "$comment")
    desired=$(jq -c --arg nid "$nid" --arg c "$comment" --argjson p "$port" --arg source "$s" --argjson a "$r" '.+[{node_id:$nid,comment:$c,port:$p,kind:"allow",source:$source,args:$a}]' <<<"$desired")
  done < <(jq -r '.[]' <<<"$normalized")
  comment="relay-manager:$nid:deny"
  r=$(fw_rule_args_json deny any "$port" "$comment")
  desired=$(jq -c --arg nid "$nid" --arg c "$comment" --argjson p "$port" --argjson a "$r" '.+[{node_id:$nid,comment:$c,port:$p,kind:"deny",source:"any",args:$a}]' <<<"$desired")

  old=$(jq -c --arg nid "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$nid)]' "$RM_STATE_FILE")
  current_sem=$(jq -c '[.[]|{port,kind,source}]|sort_by([.port,.kind,.source])' <<<"$old")
  desired_sem=$(jq -c '[.[]|{port,kind,source}]|sort_by([.port,.kind,.source])' <<<"$desired")
  if [[ $current_sem == "$desired_sem" ]]; then
    local all_present=true marker
    while IFS= read -r marker; do fw_marker_present "$marker" || all_present=false; done < <(jq -r '.[].comment' <<<"$desired")
    if [[ $all_present == true ]]; then
      jq -n --arg nid "$nid" --argjson p "$port" --argjson sources "$normalized" '{status:"already_applied_unverified",node_id:$nid,port:$p,sources:$sources}'
      return 0
    fi
  fi

  # Specific allows are prepended so they remain before an older managed deny during updates.
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" add prepend; then failed=true; break; fi
    applied=$(jq -c --argjson r "$r" '.+[$r]' <<<"$applied")
  done < <(jq -c '.[]|select(.kind=="allow")' <<<"$desired")
  if [[ $failed == false ]]; then
    r=$(jq -c '.[]|select(.kind=="deny")' <<<"$desired")
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" add append; then failed=true
    else applied=$(jq -c --argjson r "$r" '.+[$r]' <<<"$applied"); fi
  fi
  if [[ $failed == true ]]; then
    while IFS= read -r r; do [[ -n $r ]] && fw_exec_rule_json "$(jq -c .args <<<"$r")" delete || true; done < <(jq -c '.[]' <<<"$applied" | tac)
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi

  if [[ ${RM_TEST_MODE} != 1 ]]; then
    while IFS= read -r comment; do
      if ! fw_marker_present "$comment"; then
        while IFS= read -r r; do [[ -n $r ]] && fw_exec_rule_json "$(jq -c .args <<<"$r")" delete || true; done < <(jq -c '.[]' <<<"$applied" | tac)
        rm_error "UFW 写入后未读回受管规则: $comment"
        return "$RM_RC_APPLY_ROLLED_BACK"
      fi
    done < <(jq -r '.[].comment' <<<"$desired")
  fi

  # Now remove the old generation. If an exact rule is duplicated, one copy remains.
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" delete; then
      rm_error '旧 UFW 受管规则未能完整清理；保留更严格的新规则并要求人工对账。'
      return "$RM_RC_RECOVERY_INCOMPLETE"
    fi
  done < <(jq -c '.[]' <<<"$old" | tac)

  state_update_filter '.owned_firewall_rules=([.owned_firewall_rules[]|select((.node_id//"")!=$nid)] + $rules)
    | .firewall_verifications=((.firewall_verifications//{})|del(.[$nid]))' --arg nid "$nid" --argjson rules "$desired"
  jq -n --arg nid "$nid" --argjson p "$port" --argjson sources "$normalized" \
    '{status:"applied_unverified",node_id:$nid,port:$p,sources:$sources,
      note:(if ($sources|length)==0 then "空白名单已实现为节点端口默认拒绝；仍需真实网络对照测试。" else "规则已写入；只有完成允许来源成功 + 非白名单来源失败的外部对照测试后才能标记白名单有效。" end)}'
}

fw_mark_whitelist_verified() {
  local nid=$1 ans rules
  state_init >/dev/null
  rules=$(jq -c --arg id "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$id)]' "$RM_STATE_FILE")
  [[ $(jq 'length' <<<"$rules") -gt 0 ]] || { rm_error '该节点没有受管 UFW 白名单规则'; return "$RM_RC_PRECONDITION"; }
  if [[ ${RM_TEST_MODE} == 1 && ${RM_UFW_TEST_VERIFY:-} == VERIFY ]]; then ans=VERIFY
  else
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_read_tty ans '请确认：已从允许来源建立新连接成功，并从至少一个非白名单来源验证新连接失败。输入 VERIFY: '
  fi
  [[ $ans == VERIFY ]] || return "$RM_RC_CANCEL"
  state_update_filter '.firewall_verifications=((.firewall_verifications//{}) + {($nid):{verified:true,verified_at:$now}})' --arg nid "$nid"
  jq -n --arg nid "$nid" '{status:"verified_external_contrast",node_id:$nid}'
}

fw_remove_node_rules() {
  local nid=$1 rules r failed=false
  state_init >/dev/null
  rules=$(jq -c --arg nid "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$nid)]' "$RM_STATE_FILE")
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" delete; then failed=true; fi
  done < <(jq -c '.[]' <<<"$rules" | tac)
  [[ $failed == false ]] || { rm_error '部分 UFW 受管规则删除失败，状态未清理'; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  state_update_filter '.owned_firewall_rules=[.owned_firewall_rules[]|select((.node_id//"")!=$nid)]
    | .firewall_verifications=((.firewall_verifications//{})|del(.[$nid]))' --arg nid "$nid"
}

fw_temp_unit_names() {
  local nid=$1 safe=${nid//[^A-Za-z0-9_.-]/_}
  printf 'relay-manager-temp-%s\n' "$safe"
}

fw_temp_open() {
  local nid=$1 minutes=${2:-10}
  [[ $minutes =~ ^[0-9]+$ ]] && ((minutes>=1 && minutes<=1440)) || return "$RM_RC_PRECONDITION"
  fw_require_manageable || return $?
  state_init >/dev/null
  if jq -e --arg id "$nid" '.temporary_opens[]?|select(.node_id==$id)' "$RM_STATE_FILE" >/dev/null; then
    rm_error '该节点已有临时公网开放，请先等待到期或手动 expire-temp。'
    return "$RM_RC_PRECONDITION"
  fi
  local node port now deadline unit comment rule service timer tmpdir tx rc=0
  node=$(state_get_node "$nid") || return "$RM_RC_PRECONDITION"
  port=$(jq -r .listen_port <<<"$node")
  now=$(rm_epoch); deadline=$((now+minutes*60)); unit=$(fw_temp_unit_names "$nid")
  comment="relay-manager:$nid:temporary:$deadline"
  rule=$(fw_rule_args_json allow any "$port" "$comment")
  tmpdir=$(rm_safe_tmpdir); service="$tmpdir/$unit.service"; timer="$tmpdir/$unit.timer"
  cat >"$service" <<EOS
[Unit]
Description=AsterNode temporary public access expiry for $nid
[Service]
Type=oneshot
ExecStart=/usr/local/bin/relay-manager firewall expire-temp $nid
EOS
  cat >"$timer" <<EOS
[Unit]
Description=AsterNode temporary public access timer for $nid
[Timer]
OnCalendar=@$deadline
Persistent=true
AccuracySec=1s
Unit=$unit.service
[Install]
WantedBy=timers.target
EOS
  tx=$(tx_begin firewall-temp-open "$deadline") || { rm -rf "$tmpdir"; return $?; }
  tx_stage_file "$tx" "$service" "$(rm_path /etc/systemd/system/$unit.service)" 0644 root:root || rc=$?
  ((rc==0)) && tx_stage_file "$tx" "$timer" "$(rm_path /etc/systemd/system/$unit.timer)" 0644 root:root || rc=$?
  if ((rc!=0)); then tx_rollback "$tx" 'timer stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; fi
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'timer apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }

  if [[ ${RM_TEST_MODE} == 1 ]]; then
    rm_systemctl daemon-reload
    rm_systemctl enable "$unit.timer"
    rm_systemctl start "$unit.timer"
  else
    systemctl daemon-reload || { tx_rollback "$tx" 'timer daemon-reload failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl enable --now "$unit.timer" >/dev/null || { tx_rollback "$tx" 'timer enable failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl is-active --quiet "$unit.timer" || { tx_rollback "$tx" 'timer inactive' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
  fi

  # Public allow must precede the managed node deny, otherwise UFW first-match semantics would keep it blocked.
  if ! fw_exec_rule_json "$rule" add prepend; then
    [[ ${RM_TEST_MODE} == 1 ]] && rm_systemctl disable "$unit.timer" || systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
    tx_rollback "$tx" 'temporary UFW rule failed' || true
    rm -rf "$tmpdir"
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi
  tx_commit "$tx" || { fw_exec_rule_json "$rule" delete || true; rm -rf "$tmpdir"; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  state_update_filter '.temporary_opens=([.temporary_opens[]|select(.node_id!=$nid)] + [{node_id:$nid,deadline_epoch:$deadline,rule_args:$rule,unit:$unit}])' \
    --arg nid "$nid" --argjson deadline "$deadline" --argjson rule "$rule" --arg unit "$unit"
  rm -rf "$tmpdir"
  jq -n --arg nid "$nid" --argjson deadline "$deadline" '{status:"temporary_open_applied_unverified",node_id:$nid,deadline_epoch:$deadline,note:"到期只删除本次临时放行；已有连接可能继续，不执行全局 conntrack 清理。"}'
}

fw_expire_temp() {
  local nid=$1 entry unit rule
  state_init >/dev/null
  entry=$(jq -c --arg id "$nid" '.temporary_opens[]|select(.node_id==$id)' "$RM_STATE_FILE" 2>/dev/null || true)
  [[ -n $entry ]] || return 0
  unit=$(jq -r .unit <<<"$entry"); rule=$(jq -c .rule_args <<<"$entry")
  fw_exec_rule_json "$rule" delete || { rm_error '临时开放规则删除失败'; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  if [[ ${RM_TEST_MODE} == 1 ]]; then rm_systemctl disable "$unit.timer" || true
  else systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true; fi
  # Unit files are intentionally kept as owned, inert files. Avoid non-transactional rm during expiry.
  state_update_filter '.temporary_opens=[.temporary_opens[]|select(.node_id!=$nid)]' --arg nid "$nid"
}

fw_reconcile_expired() {
  state_init >/dev/null
  local now nid deadline rc=0
  now=$(rm_epoch)
  while IFS=$'\t' read -r nid deadline; do
    [[ -n $nid ]] || continue
    if ((deadline<=now)); then fw_expire_temp "$nid" || rc=$?; fi
  done < <(jq -r '.temporary_opens[]|[.node_id,.deadline_epoch]|@tsv' "$RM_STATE_FILE")
  return "$rc"
}
\n'
    fi

    if [[ -z ${known_hashes//
fw_complex_runtime_reason() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    printf '%s\n' "${RM_UFW_COMPLEX_REASON:-}"
    return
  fi
  local reason=''
  if systemctl is-active --quiet firewalld 2>/dev/null; then reason='firewalld 正在运行'; fi
  if systemctl is-active --quiet nftables 2>/dev/null; then reason="${reason:+$reason; }独立 nftables.service 正在运行"; fi
  if systemctl is-active --quiet docker 2>/dev/null || systemctl is-active --quiet podman 2>/dev/null; then
    reason="${reason:+$reason; }检测到容器网络服务"
  fi
  local raw
  raw=$(fw_ufw_raw_text || true)
  if grep -Eq '(^|[[:space:]])(DOCKER|CNI|CILIUM|LIBVIRT|KUBE-|PODMAN)' <<<"$raw"; then
    reason="${reason:+$reason; }底层防火墙存在容器/虚拟化链"
  fi
  printf '%s\n' "$reason"
}

fw_status_json() {
  local installed=false active=false default_in=unknown text reason='' integrity complex=false ipv6=false
  rm_have ufw && installed=true
  [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_STATUS_FILE:-} ]] && installed=true
  if [[ $installed == true ]]; then
    text=$(fw_ufw_status_text || true)
    grep -qi '^Status: active' <<<"$text" && active=true
    default_in=$(sed -nE 's/^Default: ([a-z]+) \(incoming\).*/\1/p' <<<"$text" | head -n1)
    [[ -n $default_in ]] || default_in=unknown
  fi
  fw_ipv6_enabled && ipv6=true || true
  integrity=$(fw_framework_integrity_json)
  reason=$(fw_complex_runtime_reason)
  if [[ -n $reason || $(jq -r '.modified==true' <<<"$integrity") == true ]]; then complex=true; fi
  if [[ $(jq -r .status <<<"$integrity") == unverified ]]; then
    reason="${reason:+$reason; }UFW before/after 规则完整性未能确认"
  fi
  jq -n --argjson installed "$installed" --argjson active "$active" --arg default "$default_in" \
    --argjson ipv6 "$ipv6" --argjson complex "$complex" --arg reason "$reason" --argjson integrity "$integrity" \
    '{installed:$installed,active:$active,default_incoming:$default,ipv6_enabled:$ipv6,
      framework_integrity:$integrity,complex_environment:$complex,
      reason:(if $reason=="" then null else $reason end),
      isolation_verified:false}'
}

fw_require_framework_safe() {
  local s; s=$(fw_status_json)
  jq -e '.installed==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 环境不能安全自动接管: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
}

fw_require_manageable() {
  local s; s=$(fw_status_json)
  jq -e '.installed==true and .active==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 未启用或环境存在冲突，自动写规则被禁用: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
}

fw_rule_args_json() {
  local action=$1 source=$2 port=$3 comment=$4
  [[ $action == allow || $action == deny || $action == limit ]] || return "$RM_RC_PRECONDITION"
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  if [[ $source == any ]]; then
    jq -n --arg a "$action" --arg p "$port" --arg c "$comment" '[$a,"to","any","port",$p,"proto","tcp","comment",$c]'
  else
    jq -n --arg a "$action" --arg s "$source" --arg p "$port" --arg c "$comment" '[$a,"from",$s,"to","any","port",$p,"proto","tcp","comment",$c]'
  fi
}

fw_exec_rule_json() {
  local json=$1 op=${2:-add} placement=${3:-append}
  local -a args=()
  mapfile -t args < <(jq -r '.[]' <<<"$json")
  case "$op:$placement" in
    add:append) fw_ufw "${args[@]}" ;;
    add:prepend) fw_ufw prepend "${args[@]}" ;;
    delete:*) fw_ufw --force delete "${args[@]}" ;;
    *) return "$RM_RC_PRECONDITION" ;;
  esac
}

fw_marker_present() {
  local marker=$1
  [[ ${RM_TEST_MODE} == 1 ]] && return 0
  fw_ufw_status_text | grep -Fq "# $marker"
}

fw_port_external_allow_conflict() {
  local port=$1 text
  text=$(fw_ufw_status_text || true)
  awk -v p="$port" 'BEGIN{IGNORECASE=1; bad=0}
    /ALLOW|LIMIT/ && $0 !~ /relay-manager:/ {
      to=$1
      if (to=="Anywhere" || to==p || to==p"/tcp" || to ~ ("^" p "/")) bad=1
    }
    END{exit bad?0:1}' <<<"$text"
}

fw_store_rule() {
  local rule=$1
  state_init >/dev/null
  state_update_filter '.owned_firewall_rules=((.owned_firewall_rules + [$rule])|unique_by(.comment))' --argjson rule "$rule"
}

fw_remove_owned_rule_from_state() {
  local comment=$1
  state_update_filter '.owned_firewall_rules=[.owned_firewall_rules[]|select((.comment//"")!=$comment)]' --arg comment "$comment"
}

fw_install_packages() {
  local assume_yes=${1:-false} pm
  rm_require_root || return $?
  pm=$(system_pkg_manager_json)
  jq -e '.kind=="apt" and .locked==false' <<<"$pm" >/dev/null || {
    rm_error "包管理器不可用或被锁定: $(jq -c . <<<"$pm")"
    return "$RM_RC_PRECONDITION"
  }
  rm_info '计划安装: ufw（不会 reset，不会修改默认策略）'
  if [[ $assume_yes != true ]]; then
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_confirm '确认安装 UFW?' || return "$RM_RC_CANCEL"
  fi
  DEBIAN_FRONTEND=noninteractive apt-get update || return "$RM_RC_NETWORK"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ufw || return "$RM_RC_PRECONDITION"
}

fw_detect_ssh_ports_json() {
  if [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_TEST_SSH_PORTS:-} ]]; then
    tr ',' '\n' <<<"$RM_UFW_TEST_SSH_PORTS" | jq -R -s 'split("\n")|map(select(length>0)|tonumber)|unique'
  else
    system_ssh_json root 127.0.0.1 | jq '(.actual_listen_ports + .effective.ports)|unique'
  fi
}

fw_enable_safe() {
  rm_require_root || return $?
  local s ssh_ports preserve_ports='[]' p rule comment added='[]' arg
  s=$(fw_status_json)
  jq -e '.installed==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 环境不能安全启用: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
  if jq -e '.active==true' <<<"$s" >/dev/null; then
    jq -n '{status:"already_active",default_policy_preserved:true}'
    return 0
  fi

  while (($#)); do
    arg=$1; shift
    case "$arg" in
      --preserve-port)
        (($#)) || { rm_error '--preserve-port 缺少端口'; return "$RM_RC_PRECONDITION"; }
        p=$1; shift
        rm_valid_port "$p" || return "$RM_RC_PRECONDITION"
        preserve_ports=$(jq -c --argjson p "$p" '.+[$p]|unique' <<<"$preserve_ports")
        ;;
      *)
        rm_error "未知 UFW enable 参数: $arg（业务入口请使用 --preserve-port PORT）"
        return "$RM_RC_PRECONDITION"
        ;;
    esac
  done

  ssh_ports=$(fw_detect_ssh_ports_json)
  [[ $(jq 'length' <<<"$ssh_ports") -gt 0 ]] || {
    rm_error '无法确定现有 SSH 监听端口，拒绝启用 UFW。'
    return "$RM_RC_PRECONDITION"
  }
  for p in $(jq -r '.[]' <<<"$ssh_ports"); do rm_valid_port "$p" || return "$RM_RC_PRECONDITION"; done
  preserve_ports=$(jq -c --argjson ssh "$ssh_ports" '[.[]|select(. as $p|($ssh|index($p)|not))]|unique' <<<"$preserve_ports")

  if [[ ${RM_TEST_MODE} != 1 ]]; then
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_info '启用前检测到的监听服务如下；不会自动开放扫描到的非 SSH 端口：'
    system_network_json | jq '.listeners' >&2
    rm_info "SSH 将保留: $(jq -r 'join(",")' <<<"$ssh_ports")"
    rm_info "显式保留的其他 TCP 端口: $(jq -r 'if length==0 then "无" else join(",") end' <<<"$preserve_ports")"
    rm_confirm '确认这些就是启用 UFW 后需要保留的本机入口？现有 UFW 默认策略保持不变。' || return "$RM_RC_CANCEL"
  fi

  state_init >/dev/null
  for p in $(jq -r '.[]' <<<"$ssh_ports"); do
    comment="relay-manager:ssh:$p"
    rule=$(fw_rule_args_json allow any "$p" "$comment")
    if ! fw_exec_rule_json "$rule" add append; then
      while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
      return "$RM_RC_APPLY_ROLLED_BACK"
    fi
    added=$(jq -c --argjson r "$(jq -n --arg c "$comment" --argjson p "$p" --argjson a "$rule" '{comment:$c,port:$p,kind:"ssh-allow",source:"any",args:$a}')" '.+[$r]' <<<"$added")
  done
  for p in $(jq -r '.[]' <<<"$preserve_ports"); do
    comment="relay-manager:preserve:$p"
    rule=$(fw_rule_args_json allow any "$p" "$comment")
    if ! fw_exec_rule_json "$rule" add append; then
      while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
      return "$RM_RC_APPLY_ROLLED_BACK"
    fi
    added=$(jq -c --argjson r "$(jq -n --arg c "$comment" --argjson p "$p" --argjson a "$rule" '{comment:$c,port:$p,kind:"preserve-allow",source:"any",args:$a}')" '.+[$r]' <<<"$added")
  done

  if ! fw_ufw --force enable; then
    while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi
  if [[ ${RM_TEST_MODE} != 1 ]] && ! fw_ufw_status_text | grep -qi '^Status: active'; then
    return "$RM_RC_RECOVERY_INCOMPLETE"
  fi
  state_update_filter '.owned_firewall_rules=((.owned_firewall_rules + $rules)|unique_by(.comment))' --argjson rules "$added"
  jq -n --argjson ssh "$ssh_ports" --argjson preserve "$preserve_ports"     '{status:"enabled",ssh_ports_preserved:$ssh,business_ports_preserved:$preserve,default_policy_preserved:true,
      note:"仅开放已确认 SSH 入口和显式 --preserve-port 业务入口；未自动开放其他监听端口。"}'
}

fw_ensure_ssh_port() {
  local port=$1 status comment rule existing
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  status=$(fw_status_json)
  if ! jq -e '.installed==true and .active==true' <<<"$status" >/dev/null; then
    jq -n --argjson p "$port" '{status:"not_locally_enforced",port:$p,added:false,note:"UFW 未启用；仍需确认云安全组/NAT。"}'
    return 0
  fi
  fw_require_manageable || return $?
  state_init >/dev/null
  comment="relay-manager:ssh:$port"
  existing=$(jq -c --arg c "$comment" '[.owned_firewall_rules[]|select((.comment//"")==$c)]' "$RM_STATE_FILE")
  if [[ $(jq 'length' <<<"$existing") -gt 0 ]] && fw_marker_present "$comment"; then
    jq -n --argjson p "$port" '{status:"already_present",port:$p,added:false}'
    return 0
  fi
  rule=$(fw_rule_args_json allow any "$port" "$comment")
  fw_exec_rule_json "$rule" add append || return "$RM_RC_APPLY_ROLLED_BACK"
  fw_marker_present "$comment" || {
    fw_exec_rule_json "$rule" delete || true
    rm_error 'UFW 写入后未能读回 SSH 规则'
    return "$RM_RC_APPLY_ROLLED_BACK"
  }
  fw_store_rule "$(jq -n --arg c "$comment" --argjson p "$port" --argjson a "$rule" '{comment:$c,port:$p,kind:"ssh-allow",source:"any",args:$a}')"
  jq -n --argjson p "$port" '{status:"added",port:$p,added:true}'
}

fw_release_ssh_port() {
  local port=$1 entry comment
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  state_init >/dev/null
  comment="relay-manager:ssh:$port"
  entry=$(jq -c --arg c "$comment" '.owned_firewall_rules[]?|select((.comment//"")==$c)' "$RM_STATE_FILE" | head -n1)
  [[ -n $entry ]] || return 0
  fw_exec_rule_json "$(jq -c .args <<<"$entry")" delete || return "$RM_RC_RECOVERY_INCOMPLETE"
  fw_remove_owned_rule_from_state "$comment"
}

fw_apply_whitelist() {
  local nid=$1 port=$2; shift 2
  local sources=("$@") node status ipv6_required=false
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  fw_require_manageable || return $?
  state_init >/dev/null
  node=$(state_get_node "$nid" 2>/dev/null || true)
  if [[ -n $node && $(jq -r '.listen_address' <<<"$node") == *:* ]]; then ipv6_required=true; fi
  status=$(fw_status_json)
  if [[ $ipv6_required == true ]] && ! jq -e '.ipv6_enabled==true' <<<"$status" >/dev/null; then
    rm_error '节点监听 IPv6，但 UFW IPv6 支持未启用；拒绝产生伪白名单。'
    return "$RM_RC_PRECONDITION"
  fi
  if fw_port_external_allow_conflict "$port"; then
    rm_error "端口 $port 存在非受管 ALLOW/LIMIT 规则，无法证明白名单隔离，拒绝自动接管。"
    return "$RM_RC_PRECONDITION"
  fi

  local normalized='[]' s n
  for s in "${sources[@]}"; do
    n=$(rm_normalize_ip_or_cidr "$s") || { rm_error "无效来源: $s"; return "$RM_RC_PRECONDITION"; }
    normalized=$(jq -c --arg n "$n" '.+[$n]|unique' <<<"$normalized")
  done

  local desired='[]' r comment hash old current_sem desired_sem applied='[]' failed=false
  while IFS= read -r s; do
    [[ -n $s ]] || continue
    hash=$(printf '%s' "$s" | sha256sum | cut -c1-8)
    comment="relay-manager:$nid:allow:$hash"
    r=$(fw_rule_args_json allow "$s" "$port" "$comment")
    desired=$(jq -c --arg nid "$nid" --arg c "$comment" --argjson p "$port" --arg source "$s" --argjson a "$r" '.+[{node_id:$nid,comment:$c,port:$p,kind:"allow",source:$source,args:$a}]' <<<"$desired")
  done < <(jq -r '.[]' <<<"$normalized")
  comment="relay-manager:$nid:deny"
  r=$(fw_rule_args_json deny any "$port" "$comment")
  desired=$(jq -c --arg nid "$nid" --arg c "$comment" --argjson p "$port" --argjson a "$r" '.+[{node_id:$nid,comment:$c,port:$p,kind:"deny",source:"any",args:$a}]' <<<"$desired")

  old=$(jq -c --arg nid "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$nid)]' "$RM_STATE_FILE")
  current_sem=$(jq -c '[.[]|{port,kind,source}]|sort_by([.port,.kind,.source])' <<<"$old")
  desired_sem=$(jq -c '[.[]|{port,kind,source}]|sort_by([.port,.kind,.source])' <<<"$desired")
  if [[ $current_sem == "$desired_sem" ]]; then
    local all_present=true marker
    while IFS= read -r marker; do fw_marker_present "$marker" || all_present=false; done < <(jq -r '.[].comment' <<<"$desired")
    if [[ $all_present == true ]]; then
      jq -n --arg nid "$nid" --argjson p "$port" --argjson sources "$normalized" '{status:"already_applied_unverified",node_id:$nid,port:$p,sources:$sources}'
      return 0
    fi
  fi

  # Specific allows are prepended so they remain before an older managed deny during updates.
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" add prepend; then failed=true; break; fi
    applied=$(jq -c --argjson r "$r" '.+[$r]' <<<"$applied")
  done < <(jq -c '.[]|select(.kind=="allow")' <<<"$desired")
  if [[ $failed == false ]]; then
    r=$(jq -c '.[]|select(.kind=="deny")' <<<"$desired")
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" add append; then failed=true
    else applied=$(jq -c --argjson r "$r" '.+[$r]' <<<"$applied"); fi
  fi
  if [[ $failed == true ]]; then
    while IFS= read -r r; do [[ -n $r ]] && fw_exec_rule_json "$(jq -c .args <<<"$r")" delete || true; done < <(jq -c '.[]' <<<"$applied" | tac)
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi

  if [[ ${RM_TEST_MODE} != 1 ]]; then
    while IFS= read -r comment; do
      if ! fw_marker_present "$comment"; then
        while IFS= read -r r; do [[ -n $r ]] && fw_exec_rule_json "$(jq -c .args <<<"$r")" delete || true; done < <(jq -c '.[]' <<<"$applied" | tac)
        rm_error "UFW 写入后未读回受管规则: $comment"
        return "$RM_RC_APPLY_ROLLED_BACK"
      fi
    done < <(jq -r '.[].comment' <<<"$desired")
  fi

  # Now remove the old generation. If an exact rule is duplicated, one copy remains.
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" delete; then
      rm_error '旧 UFW 受管规则未能完整清理；保留更严格的新规则并要求人工对账。'
      return "$RM_RC_RECOVERY_INCOMPLETE"
    fi
  done < <(jq -c '.[]' <<<"$old" | tac)

  state_update_filter '.owned_firewall_rules=([.owned_firewall_rules[]|select((.node_id//"")!=$nid)] + $rules)
    | .firewall_verifications=((.firewall_verifications//{})|del(.[$nid]))' --arg nid "$nid" --argjson rules "$desired"
  jq -n --arg nid "$nid" --argjson p "$port" --argjson sources "$normalized" \
    '{status:"applied_unverified",node_id:$nid,port:$p,sources:$sources,
      note:(if ($sources|length)==0 then "空白名单已实现为节点端口默认拒绝；仍需真实网络对照测试。" else "规则已写入；只有完成允许来源成功 + 非白名单来源失败的外部对照测试后才能标记白名单有效。" end)}'
}

fw_mark_whitelist_verified() {
  local nid=$1 ans rules
  state_init >/dev/null
  rules=$(jq -c --arg id "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$id)]' "$RM_STATE_FILE")
  [[ $(jq 'length' <<<"$rules") -gt 0 ]] || { rm_error '该节点没有受管 UFW 白名单规则'; return "$RM_RC_PRECONDITION"; }
  if [[ ${RM_TEST_MODE} == 1 && ${RM_UFW_TEST_VERIFY:-} == VERIFY ]]; then ans=VERIFY
  else
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_read_tty ans '请确认：已从允许来源建立新连接成功，并从至少一个非白名单来源验证新连接失败。输入 VERIFY: '
  fi
  [[ $ans == VERIFY ]] || return "$RM_RC_CANCEL"
  state_update_filter '.firewall_verifications=((.firewall_verifications//{}) + {($nid):{verified:true,verified_at:$now}})' --arg nid "$nid"
  jq -n --arg nid "$nid" '{status:"verified_external_contrast",node_id:$nid}'
}

fw_remove_node_rules() {
  local nid=$1 rules r failed=false
  state_init >/dev/null
  rules=$(jq -c --arg nid "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$nid)]' "$RM_STATE_FILE")
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" delete; then failed=true; fi
  done < <(jq -c '.[]' <<<"$rules" | tac)
  [[ $failed == false ]] || { rm_error '部分 UFW 受管规则删除失败，状态未清理'; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  state_update_filter '.owned_firewall_rules=[.owned_firewall_rules[]|select((.node_id//"")!=$nid)]
    | .firewall_verifications=((.firewall_verifications//{})|del(.[$nid]))' --arg nid "$nid"
}

fw_temp_unit_names() {
  local nid=$1 safe=${nid//[^A-Za-z0-9_.-]/_}
  printf 'relay-manager-temp-%s\n' "$safe"
}

fw_temp_open() {
  local nid=$1 minutes=${2:-10}
  [[ $minutes =~ ^[0-9]+$ ]] && ((minutes>=1 && minutes<=1440)) || return "$RM_RC_PRECONDITION"
  fw_require_manageable || return $?
  state_init >/dev/null
  if jq -e --arg id "$nid" '.temporary_opens[]?|select(.node_id==$id)' "$RM_STATE_FILE" >/dev/null; then
    rm_error '该节点已有临时公网开放，请先等待到期或手动 expire-temp。'
    return "$RM_RC_PRECONDITION"
  fi
  local node port now deadline unit comment rule service timer tmpdir tx rc=0
  node=$(state_get_node "$nid") || return "$RM_RC_PRECONDITION"
  port=$(jq -r .listen_port <<<"$node")
  now=$(rm_epoch); deadline=$((now+minutes*60)); unit=$(fw_temp_unit_names "$nid")
  comment="relay-manager:$nid:temporary:$deadline"
  rule=$(fw_rule_args_json allow any "$port" "$comment")
  tmpdir=$(rm_safe_tmpdir); service="$tmpdir/$unit.service"; timer="$tmpdir/$unit.timer"
  cat >"$service" <<EOS
[Unit]
Description=AsterNode temporary public access expiry for $nid
[Service]
Type=oneshot
ExecStart=/usr/local/bin/relay-manager firewall expire-temp $nid
EOS
  cat >"$timer" <<EOS
[Unit]
Description=AsterNode temporary public access timer for $nid
[Timer]
OnCalendar=@$deadline
Persistent=true
AccuracySec=1s
Unit=$unit.service
[Install]
WantedBy=timers.target
EOS
  tx=$(tx_begin firewall-temp-open "$deadline") || { rm -rf "$tmpdir"; return $?; }
  tx_stage_file "$tx" "$service" "$(rm_path /etc/systemd/system/$unit.service)" 0644 root:root || rc=$?
  ((rc==0)) && tx_stage_file "$tx" "$timer" "$(rm_path /etc/systemd/system/$unit.timer)" 0644 root:root || rc=$?
  if ((rc!=0)); then tx_rollback "$tx" 'timer stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; fi
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'timer apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }

  if [[ ${RM_TEST_MODE} == 1 ]]; then
    rm_systemctl daemon-reload
    rm_systemctl enable "$unit.timer"
    rm_systemctl start "$unit.timer"
  else
    systemctl daemon-reload || { tx_rollback "$tx" 'timer daemon-reload failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl enable --now "$unit.timer" >/dev/null || { tx_rollback "$tx" 'timer enable failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl is-active --quiet "$unit.timer" || { tx_rollback "$tx" 'timer inactive' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
  fi

  # Public allow must precede the managed node deny, otherwise UFW first-match semantics would keep it blocked.
  if ! fw_exec_rule_json "$rule" add prepend; then
    [[ ${RM_TEST_MODE} == 1 ]] && rm_systemctl disable "$unit.timer" || systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
    tx_rollback "$tx" 'temporary UFW rule failed' || true
    rm -rf "$tmpdir"
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi
  tx_commit "$tx" || { fw_exec_rule_json "$rule" delete || true; rm -rf "$tmpdir"; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  state_update_filter '.temporary_opens=([.temporary_opens[]|select(.node_id!=$nid)] + [{node_id:$nid,deadline_epoch:$deadline,rule_args:$rule,unit:$unit}])' \
    --arg nid "$nid" --argjson deadline "$deadline" --argjson rule "$rule" --arg unit "$unit"
  rm -rf "$tmpdir"
  jq -n --arg nid "$nid" --argjson deadline "$deadline" '{status:"temporary_open_applied_unverified",node_id:$nid,deadline_epoch:$deadline,note:"到期只删除本次临时放行；已有连接可能继续，不执行全局 conntrack 清理。"}'
}

fw_expire_temp() {
  local nid=$1 entry unit rule
  state_init >/dev/null
  entry=$(jq -c --arg id "$nid" '.temporary_opens[]|select(.node_id==$id)' "$RM_STATE_FILE" 2>/dev/null || true)
  [[ -n $entry ]] || return 0
  unit=$(jq -r .unit <<<"$entry"); rule=$(jq -c .rule_args <<<"$entry")
  fw_exec_rule_json "$rule" delete || { rm_error '临时开放规则删除失败'; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  if [[ ${RM_TEST_MODE} == 1 ]]; then rm_systemctl disable "$unit.timer" || true
  else systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true; fi
  # Unit files are intentionally kept as owned, inert files. Avoid non-transactional rm during expiry.
  state_update_filter '.temporary_opens=[.temporary_opens[]|select(.node_id!=$nid)]' --arg nid "$nid"
}

fw_reconcile_expired() {
  state_init >/dev/null
  local now nid deadline rc=0
  now=$(rm_epoch)
  while IFS=$'\t' read -r nid deadline; do
    [[ -n $nid ]] || continue
    if ((deadline<=now)); then fw_expire_temp "$nid" || rc=$?; fi
  done < <(jq -r '.temporary_opens[]|[.node_id,.deadline_epoch]|@tsv' "$RM_STATE_FILE")
  return "$rc"
}
\n'/} ]]; then
      unverified=$(jq -c --arg p "$logical" '.+[$p]' <<<"$unverified")
      continue
    fi

    if ! grep -Fxq "$actual" <<<"$known_hashes"; then
      modified=$(jq -c --arg p "$logical" '.+[$p]' <<<"$modified")
    fi
  done

  if [[ $(jq 'length' <<<"$modified") -gt 0 ]]; then
    jq -n --argjson p "$modified" --argjson u "$unverified"       '{status:"modified",modified:true,paths:$p,unverified_paths:$u}'
  elif [[ $(jq 'length' <<<"$unverified") -gt 0 ]]; then
    jq -n --argjson u "$unverified"       '{status:"unverified",modified:null,paths:[],unverified_paths:$u}'
  else
    jq -n '{status:"ok",modified:false,paths:[],unverified_paths:[]}'
  fi
}

fw_framework_integrity_json() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    case "${RM_UFW_FRAMEWORK_MODIFIED:-false}" in
      true) jq -n '{status:"modified",modified:true,paths:["/etc/ufw/before.rules"],unverified_paths:[]}' ;;
      false) jq -n '{status:"ok",modified:false,paths:[],unverified_paths:[]}' ;;
      *) jq -n '{status:"unverified",modified:null,paths:[],unverified_paths:["test-fixture"]}' ;;
    esac
    return
  fi

  fw_framework_integrity_files_json
}

fw_complex_runtime_reason() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    printf '%s\n' "${RM_UFW_COMPLEX_REASON:-}"
    return
  fi
  local reason=''
  if systemctl is-active --quiet firewalld 2>/dev/null; then reason='firewalld 正在运行'; fi
  if systemctl is-active --quiet nftables 2>/dev/null; then reason="${reason:+$reason; }独立 nftables.service 正在运行"; fi
  if systemctl is-active --quiet docker 2>/dev/null || systemctl is-active --quiet podman 2>/dev/null; then
    reason="${reason:+$reason; }检测到容器网络服务"
  fi
  local raw
  raw=$(fw_ufw_raw_text || true)
  if grep -Eq '(^|[[:space:]])(DOCKER|CNI|CILIUM|LIBVIRT|KUBE-|PODMAN)' <<<"$raw"; then
    reason="${reason:+$reason; }底层防火墙存在容器/虚拟化链"
  fi
  printf '%s\n' "$reason"
}

fw_status_json() {
  local installed=false active=false default_in=unknown text reason='' integrity complex=false ipv6=false
  rm_have ufw && installed=true
  [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_STATUS_FILE:-} ]] && installed=true
  if [[ $installed == true ]]; then
    text=$(fw_ufw_status_text || true)
    grep -qi '^Status: active' <<<"$text" && active=true
    default_in=$(sed -nE 's/^Default: ([a-z]+) \(incoming\).*/\1/p' <<<"$text" | head -n1)
    [[ -n $default_in ]] || default_in=unknown
  fi
  fw_ipv6_enabled && ipv6=true || true
  integrity=$(fw_framework_integrity_json)
  reason=$(fw_complex_runtime_reason)
  if [[ -n $reason || $(jq -r '.modified==true' <<<"$integrity") == true ]]; then complex=true; fi
  if [[ $(jq -r .status <<<"$integrity") == unverified ]]; then
    reason="${reason:+$reason; }UFW before/after 规则完整性未能确认"
  fi
  jq -n --argjson installed "$installed" --argjson active "$active" --arg default "$default_in" \
    --argjson ipv6 "$ipv6" --argjson complex "$complex" --arg reason "$reason" --argjson integrity "$integrity" \
    '{installed:$installed,active:$active,default_incoming:$default,ipv6_enabled:$ipv6,
      framework_integrity:$integrity,complex_environment:$complex,
      reason:(if $reason=="" then null else $reason end),
      isolation_verified:false}'
}

fw_require_framework_safe() {
  local s; s=$(fw_status_json)
  jq -e '.installed==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 环境不能安全自动接管: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
}

fw_require_manageable() {
  local s; s=$(fw_status_json)
  jq -e '.installed==true and .active==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 未启用或环境存在冲突，自动写规则被禁用: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
}

fw_rule_args_json() {
  local action=$1 source=$2 port=$3 comment=$4
  [[ $action == allow || $action == deny || $action == limit ]] || return "$RM_RC_PRECONDITION"
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  if [[ $source == any ]]; then
    jq -n --arg a "$action" --arg p "$port" --arg c "$comment" '[$a,"to","any","port",$p,"proto","tcp","comment",$c]'
  else
    jq -n --arg a "$action" --arg s "$source" --arg p "$port" --arg c "$comment" '[$a,"from",$s,"to","any","port",$p,"proto","tcp","comment",$c]'
  fi
}

fw_exec_rule_json() {
  local json=$1 op=${2:-add} placement=${3:-append}
  local -a args=()
  mapfile -t args < <(jq -r '.[]' <<<"$json")
  case "$op:$placement" in
    add:append) fw_ufw "${args[@]}" ;;
    add:prepend) fw_ufw prepend "${args[@]}" ;;
    delete:*) fw_ufw --force delete "${args[@]}" ;;
    *) return "$RM_RC_PRECONDITION" ;;
  esac
}

fw_marker_present() {
  local marker=$1
  [[ ${RM_TEST_MODE} == 1 ]] && return 0
  fw_ufw_status_text | grep -Fq "# $marker"
}

fw_port_external_allow_conflict() {
  local port=$1 text
  text=$(fw_ufw_status_text || true)
  awk -v p="$port" 'BEGIN{IGNORECASE=1; bad=0}
    /ALLOW|LIMIT/ && $0 !~ /relay-manager:/ {
      to=$1
      if (to=="Anywhere" || to==p || to==p"/tcp" || to ~ ("^" p "/")) bad=1
    }
    END{exit bad?0:1}' <<<"$text"
}

fw_store_rule() {
  local rule=$1
  state_init >/dev/null
  state_update_filter '.owned_firewall_rules=((.owned_firewall_rules + [$rule])|unique_by(.comment))' --argjson rule "$rule"
}

fw_remove_owned_rule_from_state() {
  local comment=$1
  state_update_filter '.owned_firewall_rules=[.owned_firewall_rules[]|select((.comment//"")!=$comment)]' --arg comment "$comment"
}

fw_install_packages() {
  local assume_yes=${1:-false} pm
  rm_require_root || return $?
  pm=$(system_pkg_manager_json)
  jq -e '.kind=="apt" and .locked==false' <<<"$pm" >/dev/null || {
    rm_error "包管理器不可用或被锁定: $(jq -c . <<<"$pm")"
    return "$RM_RC_PRECONDITION"
  }
  rm_info '计划安装: ufw（不会 reset，不会修改默认策略）'
  if [[ $assume_yes != true ]]; then
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_confirm '确认安装 UFW?' || return "$RM_RC_CANCEL"
  fi
  DEBIAN_FRONTEND=noninteractive apt-get update || return "$RM_RC_NETWORK"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ufw || return "$RM_RC_PRECONDITION"
}

fw_detect_ssh_ports_json() {
  if [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_TEST_SSH_PORTS:-} ]]; then
    tr ',' '\n' <<<"$RM_UFW_TEST_SSH_PORTS" | jq -R -s 'split("\n")|map(select(length>0)|tonumber)|unique'
  else
    system_ssh_json root 127.0.0.1 | jq '(.actual_listen_ports + .effective.ports)|unique'
  fi
}

fw_enable_safe() {
  rm_require_root || return $?
  local s ssh_ports preserve_ports='[]' p rule comment added='[]' arg
  s=$(fw_status_json)
  jq -e '.installed==true and .complex_environment==false and .framework_integrity.status=="ok"' <<<"$s" >/dev/null || {
    rm_error "UFW 环境不能安全启用: $(jq -c . <<<"$s")"
    return "$RM_RC_PRECONDITION"
  }
  if jq -e '.active==true' <<<"$s" >/dev/null; then
    jq -n '{status:"already_active",default_policy_preserved:true}'
    return 0
  fi

  while (($#)); do
    arg=$1; shift
    case "$arg" in
      --preserve-port)
        (($#)) || { rm_error '--preserve-port 缺少端口'; return "$RM_RC_PRECONDITION"; }
        p=$1; shift
        rm_valid_port "$p" || return "$RM_RC_PRECONDITION"
        preserve_ports=$(jq -c --argjson p "$p" '.+[$p]|unique' <<<"$preserve_ports")
        ;;
      *)
        rm_error "未知 UFW enable 参数: $arg（业务入口请使用 --preserve-port PORT）"
        return "$RM_RC_PRECONDITION"
        ;;
    esac
  done

  ssh_ports=$(fw_detect_ssh_ports_json)
  [[ $(jq 'length' <<<"$ssh_ports") -gt 0 ]] || {
    rm_error '无法确定现有 SSH 监听端口，拒绝启用 UFW。'
    return "$RM_RC_PRECONDITION"
  }
  for p in $(jq -r '.[]' <<<"$ssh_ports"); do rm_valid_port "$p" || return "$RM_RC_PRECONDITION"; done
  preserve_ports=$(jq -c --argjson ssh "$ssh_ports" '[.[]|select(. as $p|($ssh|index($p)|not))]|unique' <<<"$preserve_ports")

  if [[ ${RM_TEST_MODE} != 1 ]]; then
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_info '启用前检测到的监听服务如下；不会自动开放扫描到的非 SSH 端口：'
    system_network_json | jq '.listeners' >&2
    rm_info "SSH 将保留: $(jq -r 'join(",")' <<<"$ssh_ports")"
    rm_info "显式保留的其他 TCP 端口: $(jq -r 'if length==0 then "无" else join(",") end' <<<"$preserve_ports")"
    rm_confirm '确认这些就是启用 UFW 后需要保留的本机入口？现有 UFW 默认策略保持不变。' || return "$RM_RC_CANCEL"
  fi

  state_init >/dev/null
  for p in $(jq -r '.[]' <<<"$ssh_ports"); do
    comment="relay-manager:ssh:$p"
    rule=$(fw_rule_args_json allow any "$p" "$comment")
    if ! fw_exec_rule_json "$rule" add append; then
      while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
      return "$RM_RC_APPLY_ROLLED_BACK"
    fi
    added=$(jq -c --argjson r "$(jq -n --arg c "$comment" --argjson p "$p" --argjson a "$rule" '{comment:$c,port:$p,kind:"ssh-allow",source:"any",args:$a}')" '.+[$r]' <<<"$added")
  done
  for p in $(jq -r '.[]' <<<"$preserve_ports"); do
    comment="relay-manager:preserve:$p"
    rule=$(fw_rule_args_json allow any "$p" "$comment")
    if ! fw_exec_rule_json "$rule" add append; then
      while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
      return "$RM_RC_APPLY_ROLLED_BACK"
    fi
    added=$(jq -c --argjson r "$(jq -n --arg c "$comment" --argjson p "$p" --argjson a "$rule" '{comment:$c,port:$p,kind:"preserve-allow",source:"any",args:$a}')" '.+[$r]' <<<"$added")
  done

  if ! fw_ufw --force enable; then
    while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$(jq -c .args <<<"$rr")" delete || true; done < <(jq -c '.[]' <<<"$added" | tac)
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi
  if [[ ${RM_TEST_MODE} != 1 ]] && ! fw_ufw_status_text | grep -qi '^Status: active'; then
    return "$RM_RC_RECOVERY_INCOMPLETE"
  fi
  state_update_filter '.owned_firewall_rules=((.owned_firewall_rules + $rules)|unique_by(.comment))' --argjson rules "$added"
  jq -n --argjson ssh "$ssh_ports" --argjson preserve "$preserve_ports"     '{status:"enabled",ssh_ports_preserved:$ssh,business_ports_preserved:$preserve,default_policy_preserved:true,
      note:"仅开放已确认 SSH 入口和显式 --preserve-port 业务入口；未自动开放其他监听端口。"}'
}

fw_ensure_ssh_port() {
  local port=$1 status comment rule existing
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  status=$(fw_status_json)
  if ! jq -e '.installed==true and .active==true' <<<"$status" >/dev/null; then
    jq -n --argjson p "$port" '{status:"not_locally_enforced",port:$p,added:false,note:"UFW 未启用；仍需确认云安全组/NAT。"}'
    return 0
  fi
  fw_require_manageable || return $?
  state_init >/dev/null
  comment="relay-manager:ssh:$port"
  existing=$(jq -c --arg c "$comment" '[.owned_firewall_rules[]|select((.comment//"")==$c)]' "$RM_STATE_FILE")
  if [[ $(jq 'length' <<<"$existing") -gt 0 ]] && fw_marker_present "$comment"; then
    jq -n --argjson p "$port" '{status:"already_present",port:$p,added:false}'
    return 0
  fi
  rule=$(fw_rule_args_json allow any "$port" "$comment")
  fw_exec_rule_json "$rule" add append || return "$RM_RC_APPLY_ROLLED_BACK"
  fw_marker_present "$comment" || {
    fw_exec_rule_json "$rule" delete || true
    rm_error 'UFW 写入后未能读回 SSH 规则'
    return "$RM_RC_APPLY_ROLLED_BACK"
  }
  fw_store_rule "$(jq -n --arg c "$comment" --argjson p "$port" --argjson a "$rule" '{comment:$c,port:$p,kind:"ssh-allow",source:"any",args:$a}')"
  jq -n --argjson p "$port" '{status:"added",port:$p,added:true}'
}

fw_release_ssh_port() {
  local port=$1 entry comment
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  state_init >/dev/null
  comment="relay-manager:ssh:$port"
  entry=$(jq -c --arg c "$comment" '.owned_firewall_rules[]?|select((.comment//"")==$c)' "$RM_STATE_FILE" | head -n1)
  [[ -n $entry ]] || return 0
  fw_exec_rule_json "$(jq -c .args <<<"$entry")" delete || return "$RM_RC_RECOVERY_INCOMPLETE"
  fw_remove_owned_rule_from_state "$comment"
}

fw_apply_whitelist() {
  local nid=$1 port=$2; shift 2
  local sources=("$@") node status ipv6_required=false
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"
  fw_require_manageable || return $?
  state_init >/dev/null
  node=$(state_get_node "$nid" 2>/dev/null || true)
  if [[ -n $node && $(jq -r '.listen_address' <<<"$node") == *:* ]]; then ipv6_required=true; fi
  status=$(fw_status_json)
  if [[ $ipv6_required == true ]] && ! jq -e '.ipv6_enabled==true' <<<"$status" >/dev/null; then
    rm_error '节点监听 IPv6，但 UFW IPv6 支持未启用；拒绝产生伪白名单。'
    return "$RM_RC_PRECONDITION"
  fi
  if fw_port_external_allow_conflict "$port"; then
    rm_error "端口 $port 存在非受管 ALLOW/LIMIT 规则，无法证明白名单隔离，拒绝自动接管。"
    return "$RM_RC_PRECONDITION"
  fi

  local normalized='[]' s n
  for s in "${sources[@]}"; do
    n=$(rm_normalize_ip_or_cidr "$s") || { rm_error "无效来源: $s"; return "$RM_RC_PRECONDITION"; }
    normalized=$(jq -c --arg n "$n" '.+[$n]|unique' <<<"$normalized")
  done

  local desired='[]' r comment hash old current_sem desired_sem applied='[]' failed=false
  while IFS= read -r s; do
    [[ -n $s ]] || continue
    hash=$(printf '%s' "$s" | sha256sum | cut -c1-8)
    comment="relay-manager:$nid:allow:$hash"
    r=$(fw_rule_args_json allow "$s" "$port" "$comment")
    desired=$(jq -c --arg nid "$nid" --arg c "$comment" --argjson p "$port" --arg source "$s" --argjson a "$r" '.+[{node_id:$nid,comment:$c,port:$p,kind:"allow",source:$source,args:$a}]' <<<"$desired")
  done < <(jq -r '.[]' <<<"$normalized")
  comment="relay-manager:$nid:deny"
  r=$(fw_rule_args_json deny any "$port" "$comment")
  desired=$(jq -c --arg nid "$nid" --arg c "$comment" --argjson p "$port" --argjson a "$r" '.+[{node_id:$nid,comment:$c,port:$p,kind:"deny",source:"any",args:$a}]' <<<"$desired")

  old=$(jq -c --arg nid "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$nid)]' "$RM_STATE_FILE")
  current_sem=$(jq -c '[.[]|{port,kind,source}]|sort_by([.port,.kind,.source])' <<<"$old")
  desired_sem=$(jq -c '[.[]|{port,kind,source}]|sort_by([.port,.kind,.source])' <<<"$desired")
  if [[ $current_sem == "$desired_sem" ]]; then
    local all_present=true marker
    while IFS= read -r marker; do fw_marker_present "$marker" || all_present=false; done < <(jq -r '.[].comment' <<<"$desired")
    if [[ $all_present == true ]]; then
      jq -n --arg nid "$nid" --argjson p "$port" --argjson sources "$normalized" '{status:"already_applied_unverified",node_id:$nid,port:$p,sources:$sources}'
      return 0
    fi
  fi

  # Specific allows are prepended so they remain before an older managed deny during updates.
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" add prepend; then failed=true; break; fi
    applied=$(jq -c --argjson r "$r" '.+[$r]' <<<"$applied")
  done < <(jq -c '.[]|select(.kind=="allow")' <<<"$desired")
  if [[ $failed == false ]]; then
    r=$(jq -c '.[]|select(.kind=="deny")' <<<"$desired")
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" add append; then failed=true
    else applied=$(jq -c --argjson r "$r" '.+[$r]' <<<"$applied"); fi
  fi
  if [[ $failed == true ]]; then
    while IFS= read -r r; do [[ -n $r ]] && fw_exec_rule_json "$(jq -c .args <<<"$r")" delete || true; done < <(jq -c '.[]' <<<"$applied" | tac)
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi

  if [[ ${RM_TEST_MODE} != 1 ]]; then
    while IFS= read -r comment; do
      if ! fw_marker_present "$comment"; then
        while IFS= read -r r; do [[ -n $r ]] && fw_exec_rule_json "$(jq -c .args <<<"$r")" delete || true; done < <(jq -c '.[]' <<<"$applied" | tac)
        rm_error "UFW 写入后未读回受管规则: $comment"
        return "$RM_RC_APPLY_ROLLED_BACK"
      fi
    done < <(jq -r '.[].comment' <<<"$desired")
  fi

  # Now remove the old generation. If an exact rule is duplicated, one copy remains.
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" delete; then
      rm_error '旧 UFW 受管规则未能完整清理；保留更严格的新规则并要求人工对账。'
      return "$RM_RC_RECOVERY_INCOMPLETE"
    fi
  done < <(jq -c '.[]' <<<"$old" | tac)

  state_update_filter '.owned_firewall_rules=([.owned_firewall_rules[]|select((.node_id//"")!=$nid)] + $rules)
    | .firewall_verifications=((.firewall_verifications//{})|del(.[$nid]))' --arg nid "$nid" --argjson rules "$desired"
  jq -n --arg nid "$nid" --argjson p "$port" --argjson sources "$normalized" \
    '{status:"applied_unverified",node_id:$nid,port:$p,sources:$sources,
      note:(if ($sources|length)==0 then "空白名单已实现为节点端口默认拒绝；仍需真实网络对照测试。" else "规则已写入；只有完成允许来源成功 + 非白名单来源失败的外部对照测试后才能标记白名单有效。" end)}'
}

fw_mark_whitelist_verified() {
  local nid=$1 ans rules
  state_init >/dev/null
  rules=$(jq -c --arg id "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$id)]' "$RM_STATE_FILE")
  [[ $(jq 'length' <<<"$rules") -gt 0 ]] || { rm_error '该节点没有受管 UFW 白名单规则'; return "$RM_RC_PRECONDITION"; }
  if [[ ${RM_TEST_MODE} == 1 && ${RM_UFW_TEST_VERIFY:-} == VERIFY ]]; then ans=VERIFY
  else
    rm_tty_available || return "$RM_RC_PRECONDITION"
    rm_read_tty ans '请确认：已从允许来源建立新连接成功，并从至少一个非白名单来源验证新连接失败。输入 VERIFY: '
  fi
  [[ $ans == VERIFY ]] || return "$RM_RC_CANCEL"
  state_update_filter '.firewall_verifications=((.firewall_verifications//{}) + {($nid):{verified:true,verified_at:$now}})' --arg nid "$nid"
  jq -n --arg nid "$nid" '{status:"verified_external_contrast",node_id:$nid}'
}

fw_remove_node_rules() {
  local nid=$1 rules r failed=false
  state_init >/dev/null
  rules=$(jq -c --arg nid "$nid" '[.owned_firewall_rules[]|select((.node_id//"")==$nid)]' "$RM_STATE_FILE")
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" delete; then failed=true; fi
  done < <(jq -c '.[]' <<<"$rules" | tac)
  [[ $failed == false ]] || { rm_error '部分 UFW 受管规则删除失败，状态未清理'; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  state_update_filter '.owned_firewall_rules=[.owned_firewall_rules[]|select((.node_id//"")!=$nid)]
    | .firewall_verifications=((.firewall_verifications//{})|del(.[$nid]))' --arg nid "$nid"
}

fw_temp_unit_names() {
  local nid=$1 safe=${nid//[^A-Za-z0-9_.-]/_}
  printf 'relay-manager-temp-%s\n' "$safe"
}

fw_temp_open() {
  local nid=$1 minutes=${2:-10}
  [[ $minutes =~ ^[0-9]+$ ]] && ((minutes>=1 && minutes<=1440)) || return "$RM_RC_PRECONDITION"
  fw_require_manageable || return $?
  state_init >/dev/null
  if jq -e --arg id "$nid" '.temporary_opens[]?|select(.node_id==$id)' "$RM_STATE_FILE" >/dev/null; then
    rm_error '该节点已有临时公网开放，请先等待到期或手动 expire-temp。'
    return "$RM_RC_PRECONDITION"
  fi
  local node port now deadline unit comment rule service timer tmpdir tx rc=0
  node=$(state_get_node "$nid") || return "$RM_RC_PRECONDITION"
  port=$(jq -r .listen_port <<<"$node")
  now=$(rm_epoch); deadline=$((now+minutes*60)); unit=$(fw_temp_unit_names "$nid")
  comment="relay-manager:$nid:temporary:$deadline"
  rule=$(fw_rule_args_json allow any "$port" "$comment")
  tmpdir=$(rm_safe_tmpdir); service="$tmpdir/$unit.service"; timer="$tmpdir/$unit.timer"
  cat >"$service" <<EOS
[Unit]
Description=AsterNode temporary public access expiry for $nid
[Service]
Type=oneshot
ExecStart=/usr/local/bin/relay-manager firewall expire-temp $nid
EOS
  cat >"$timer" <<EOS
[Unit]
Description=AsterNode temporary public access timer for $nid
[Timer]
OnCalendar=@$deadline
Persistent=true
AccuracySec=1s
Unit=$unit.service
[Install]
WantedBy=timers.target
EOS
  tx=$(tx_begin firewall-temp-open "$deadline") || { rm -rf "$tmpdir"; return $?; }
  tx_stage_file "$tx" "$service" "$(rm_path /etc/systemd/system/$unit.service)" 0644 root:root || rc=$?
  ((rc==0)) && tx_stage_file "$tx" "$timer" "$(rm_path /etc/systemd/system/$unit.timer)" 0644 root:root || rc=$?
  if ((rc!=0)); then tx_rollback "$tx" 'timer stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; fi
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'timer apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }

  if [[ ${RM_TEST_MODE} == 1 ]]; then
    rm_systemctl daemon-reload
    rm_systemctl enable "$unit.timer"
    rm_systemctl start "$unit.timer"
  else
    systemctl daemon-reload || { tx_rollback "$tx" 'timer daemon-reload failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl enable --now "$unit.timer" >/dev/null || { tx_rollback "$tx" 'timer enable failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl is-active --quiet "$unit.timer" || { tx_rollback "$tx" 'timer inactive' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }
  fi

  # Public allow must precede the managed node deny, otherwise UFW first-match semantics would keep it blocked.
  if ! fw_exec_rule_json "$rule" add prepend; then
    [[ ${RM_TEST_MODE} == 1 ]] && rm_systemctl disable "$unit.timer" || systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
    tx_rollback "$tx" 'temporary UFW rule failed' || true
    rm -rf "$tmpdir"
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi
  tx_commit "$tx" || { fw_exec_rule_json "$rule" delete || true; rm -rf "$tmpdir"; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  state_update_filter '.temporary_opens=([.temporary_opens[]|select(.node_id!=$nid)] + [{node_id:$nid,deadline_epoch:$deadline,rule_args:$rule,unit:$unit}])' \
    --arg nid "$nid" --argjson deadline "$deadline" --argjson rule "$rule" --arg unit "$unit"
  rm -rf "$tmpdir"
  jq -n --arg nid "$nid" --argjson deadline "$deadline" '{status:"temporary_open_applied_unverified",node_id:$nid,deadline_epoch:$deadline,note:"到期只删除本次临时放行；已有连接可能继续，不执行全局 conntrack 清理。"}'
}

fw_expire_temp() {
  local nid=$1 entry unit rule
  state_init >/dev/null
  entry=$(jq -c --arg id "$nid" '.temporary_opens[]|select(.node_id==$id)' "$RM_STATE_FILE" 2>/dev/null || true)
  [[ -n $entry ]] || return 0
  unit=$(jq -r .unit <<<"$entry"); rule=$(jq -c .rule_args <<<"$entry")
  fw_exec_rule_json "$rule" delete || { rm_error '临时开放规则删除失败'; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  if [[ ${RM_TEST_MODE} == 1 ]]; then rm_systemctl disable "$unit.timer" || true
  else systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true; fi
  # Unit files are intentionally kept as owned, inert files. Avoid non-transactional rm during expiry.
  state_update_filter '.temporary_opens=[.temporary_opens[]|select(.node_id!=$nid)]' --arg nid "$nid"
}

fw_reconcile_expired() {
  state_init >/dev/null
  local now nid deadline rc=0
  now=$(rm_epoch)
  while IFS=$'\t' read -r nid deadline; do
    [[ -n $nid ]] || continue
    if ((deadline<=now)); then fw_expire_temp "$nid" || rc=$?; fi
  done < <(jq -r '.temporary_opens[]|[.node_id,.deadline_epoch]|@tsv' "$RM_STATE_FILE")
  return "$rc"
}
