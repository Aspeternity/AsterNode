#!/usr/bin/env bash
# Versioned REALITY target probing; read-only and bounded.
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
RM_TARGETS_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/compat/targets.json"

RM_TARGET_HANDSHAKE_ATTEMPTS=2
RM_TARGET_TLS_TIMEOUT_SECONDS=6
RM_TARGET_HTTP_TIMEOUT_SECONDS=5
RM_TARGET_ABUSE_TIMEOUT_SECONDS=4
RM_TARGET_MAX_PARALLEL=2

target_split() {
  rm_split_host_port "$1"
}

target_resolve_host() {
  local host=$1 norm
  if norm=$(rm_normalize_ip_or_cidr "$host" 2>/dev/null) && [[ $norm != */* ]]; then
    printf '%s\n' "$norm"
    return 0
  fi
  getent ahosts "$host" 2>/dev/null | awk 'NR==1{print $1;exit}'
}

target_shared_edge_suffix() {
  local name=${1%.}
  [[ -r $RM_TARGETS_FILE ]] || return 1
  jq -r --arg n "${name,,}" '
    .shared_edge_suffixes[]? |
    select($n == . or ($n|endswith("." + .)))
  ' "$RM_TARGETS_FILE" 2>/dev/null | head -n1
}

target_dns_shared_edge_json() {
  local host=$1 resolved=$2 current answer next ptr rc suffix depth=0
  local query_failed=false chain='[]' ptrs='[]' matches='[]'

  if ! rm_have dig; then
    jq -n '{status:"unverified",cname_chain:[],ptr_names:[],matches:[],
      reason:"缺少 dig，无法验证 CNAME/PTR 共享 CDN/边缘链路"}'
    return 0
  fi

  current=${host%.}
  if ! rm_normalize_ip_or_cidr "$current" >/dev/null 2>&1; then
    while ((depth < 8)); do
      set +e
      answer=$(dig +time=2 +tries=1 +noall +answer CNAME "$current" 2>/dev/null)
      rc=$?
      set -e
      if ((rc != 0)); then
        query_failed=true
        break
      fi
      next=$(awk 'toupper($4)=="CNAME"{print $5;exit}' <<<"$answer")
      [[ -n $next ]] || break
      next=${next%.}
      chain=$(jq -c --arg v "$next" '. + [$v]' <<<"$chain")
      suffix=$(target_shared_edge_suffix "$next" || true)
      if [[ -n $suffix ]]; then
        matches=$(jq -c --arg name "$next" --arg suffix "$suffix"           '. + [{source:"cname",name:$name,suffix:$suffix}]' <<<"$matches")
      fi
      [[ ${next,,} == ${current,,} ]] && { query_failed=true; break; }
      current=$next
      depth=$((depth+1))
    done
    ((depth >= 8)) && query_failed=true
  fi

  suffix=$(target_shared_edge_suffix "$host" || true)
  if [[ -n $suffix ]]; then
    matches=$(jq -c --arg name "${host%.}" --arg suffix "$suffix"       '. + [{source:"target-host",name:$name,suffix:$suffix}]' <<<"$matches")
  fi

  set +e
  ptr=$(dig +time=2 +tries=1 +short -x "$resolved" 2>/dev/null)
  rc=$?
  set -e
  if ((rc != 0)); then
    query_failed=true
  else
    local p
    while IFS= read -r p; do
      [[ -n $p ]] || continue
      p=${p%.}
      ptrs=$(jq -c --arg v "$p" '. + [$v]' <<<"$ptrs")
      suffix=$(target_shared_edge_suffix "$p" || true)
      if [[ -n $suffix ]]; then
        matches=$(jq -c --arg name "$p" --arg suffix "$suffix"           '. + [{source:"ptr",name:$name,suffix:$suffix}]' <<<"$matches")
      fi
    done <<<"$ptr"
  fi

  if jq -e 'length>0' <<<"$matches" >/dev/null; then
    jq -n --argjson chain "$chain" --argjson ptrs "$ptrs" --argjson matches "$matches" '{
      status:"high",cname_chain:$chain,ptr_names:$ptrs,matches:$matches,
      reason:"CNAME/PTR 命中已知共享 CDN/边缘网络特征，拒绝作为 REALITY 推荐 Target"
    }'
  elif [[ $query_failed == true ]]; then
    jq -n --argjson chain "$chain" --argjson ptrs "$ptrs" --argjson matches "$matches" '{
      status:"unverified",cname_chain:$chain,ptr_names:$ptrs,matches:$matches,
      reason:"DNS CNAME/PTR 安全检查未完整完成，按 fail-closed 处理"
    }'
  else
    jq -n --argjson chain "$chain" --argjson ptrs "$ptrs" --argjson matches "$matches" '{
      status:"low",cname_chain:$chain,ptr_names:$ptrs,matches:$matches,
      reason:"本次未发现已知共享 CDN/边缘 CNAME/PTR 特征"
    }'
  fi
}

target_catalog_policy_json() {
  local target=$1 sni=$2
  if [[ -r $RM_TARGETS_FILE ]]; then
    jq -c --arg t "$target" --arg s "$sni" '
      ([.candidates[]? | select(.target==$t and .sni==$s)] | first) as $c |
      if $c==null then
        {recommendable:true,official_reference:false,risk_class:"unclassified-manual",note:"手工 Target，必须通过动态滥用风险探测",source:"manual"}
      else
        {
          recommendable:(if ($c|has("recommendable")) then $c.recommendable else true end),
          official_reference:($c.official_reference//false),
          risk_class:($c.risk_class//"standard"),
          note:($c.note//""),
          source:"catalog"
        }
      end
    ' "$RM_TARGETS_FILE"
  else
    jq -nc '{recommendable:true,official_reference:false,risk_class:"unclassified-manual",note:"候选目录不可读，依赖动态滥用风险探测",source:"manual"}'
  fi
}

target_cross_sni_risk_json() {
  local resolved=$1 port=$2 original_sni=$3 tmpdir=$4 connect probe log rc
  local accepted=false timed_out=false tls13 h2 results='[]' count=0
  local -a probes=(www.cloudflare.com www.microsoft.com www.google.com www.amazon.com www.youtube.com www.wikipedia.org)

  connect=$resolved
  [[ $resolved == *:* ]] && connect="[$resolved]"

  for probe in "${probes[@]}"; do
    [[ $probe == "$original_sni" ]] && continue
    ((count >= 4)) && break
    log="$tmpdir/cross-sni-$count.log"

    set +e
    timeout "$RM_TARGET_ABUSE_TIMEOUT_SECONDS" openssl s_client \
      -connect "$connect:$port" -servername "$probe" -verify_hostname "$probe" -verify_return_error \
      -alpn h2 -tls1_3 </dev/null >"$log" 2>&1
    rc=$?
    set -e

    tls13=false
    h2=false
    grep -aEqi 'Protocol version:[[:space:]]*TLSv1\.3|Protocol[[:space:]]*:?[[:space:]]*TLSv1\.3|New,[[:space:]]*TLSv1\.3' "$log" && tls13=true
    grep -aEqi 'ALPN protocol:[[:space:]]*h2|Negotiated protocol:[[:space:]]*h2|ALPN.*h2' "$log" && h2=true

    if ((rc==0)) && [[ $tls13 == true ]]; then accepted=true; fi
    ((rc==124)) && timed_out=true

    results=$(jq -c --arg sni "$probe" --argjson rc "$rc" --argjson tls13 "$tls13" --argjson h2 "$h2" \
      '. + [{sni:$sni,exit_code:$rc,tls13:$tls13,h2:$h2,valid_hostname_handshake:($rc==0 and $tls13)}]' <<<"$results")
    count=$((count+1))
  done

  if [[ $accepted == true ]]; then
    jq -n --argjson probes "$results" '{
      status:"high",
      cross_sni_valid_hostname:true,
      probes:$probes,
      reason:"Target 当前解析 IP 能为无关 SNI 完成有效 TLS 1.3 主机名验证，存在共享边缘/跨 SNI 转发滥用风险"
    }'
  elif [[ $timed_out == true ]]; then
    jq -n --argjson probes "$results" '{
      status:"unverified",
      cross_sni_valid_hostname:false,
      probes:$probes,
      reason:"跨 SNI 安全探测发生超时，不能证明 Target 不会转发其他站点流量"
    }'
  else
    jq -n --argjson probes "$results" '{
      status:"low",
      cross_sni_valid_hostname:false,
      probes:$probes,
      reason:"对多个无关 SNI 的有效主机名握手均未通过；本次未发现共享边缘跨 SNI 转发证据"
    }'
  fi
}

target_probe() {
  local target=$1 sni=$2 host port resolved connect start end ms tmpdir first_log second_log hdrfile
  local http_status='unverified' redirect='' redirected=false catalog abuse shared_edge cross_sni recommendation_eligible=false recommendation_reason=''
  local risk_note='REALITY 未认证流量可能表现为转发到 Target；CDN/共享目标需单独评估滥用与来源限制。本工具不会因 Target 探测自动开放额外端口。'

  rm_split_host_port "$target" >/dev/null 2>&1 || {
    rm_error 'Target 必须为 host:port 或 [IPv6]:port'
    return "$RM_RC_PRECONDITION"
  }
  rm_valid_host "$sni" || {
    rm_error 'SNI 格式无效'
    return "$RM_RC_PRECONDITION"
  }
  if rm_normalize_ip_or_cidr "$sni" >/dev/null 2>&1; then
    rm_error 'SNI 必须使用域名，不能直接使用 IP'
    return "$RM_RC_PRECONDITION"
  fi

  IFS=$'\t' read -r host port < <(target_split "$target")
  resolved=$(target_resolve_host "$host" || true)
  if [[ -z $resolved ]]; then
    jq -n --arg t "$target" --arg s "$sni" --arg risk "$risk_note" \
      --argjson attempts "$RM_TARGET_HANDSHAKE_ATTEMPTS" --argjson timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" \
      '{status:"failed",target:$t,sni:$s,
        checks:{dns:"failed",tcp:false,tls13:false,certificate_hostname:false,h2:false,repeated_handshake:false,http_redirect:null},
        reason:"DNS/地址解析失败",risk_note:$risk,
        probe_policy:{handshake_attempts:$attempts,tls_timeout_seconds:$timeout}}'
    return 0
  fi

  if ! rm_have openssl || ! rm_have timeout; then
    jq -n --arg t "$target" --arg s "$sni" --arg r "$resolved" --arg risk "$risk_note" \
      --argjson attempts "$RM_TARGET_HANDSHAKE_ATTEMPTS" --argjson timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" \
      '{status:"unverified",target:$t,sni:$s,resolved_address:$r,
        reason:"缺少 openssl/timeout",risk_note:$risk,
        probe_policy:{handshake_attempts:$attempts,tls_timeout_seconds:$timeout}}'
    return 0
  fi

  tmpdir=$(rm_safe_tmpdir) || return $?
  first_log="$tmpdir/tls-1.log"
  connect=$resolved
  [[ $resolved == *:* ]] && connect="[$resolved]"
  second_log="$tmpdir/tls-2.log"
  hdrfile="$tmpdir/http-headers.txt"

  start=$(date +%s%3N 2>/dev/null || date +%s000)
  set +e
  timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" openssl s_client \
    -connect "$connect:$port" -servername "$sni" -verify_hostname "$sni" -verify_return_error \
    -alpn h2 -tls1_3 </dev/null >"$first_log" 2>&1
  local rc1=$?
  set -e
  end=$(date +%s%3N 2>/dev/null || date +%s000)
  ms=$((end-start))

  set +e
  timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" openssl s_client \
    -connect "$connect:$port" -servername "$sni" -verify_hostname "$sni" -verify_return_error \
    -alpn h2 -tls1_3 </dev/null >"$second_log" 2>&1
  local rc2=$?
  set -e

  local tcp=false tls=false cert=false h2=false stable=false second_tls=false second_h2=false
  if ((rc1==0)) || grep -aEqi 'CONNECTED|CONNECTION ESTABLISHED|Protocol version:' "$first_log"; then tcp=true; fi
  if ((rc1==0)) && grep -aEqi 'Protocol version:[[:space:]]*TLSv1\.3|Protocol[[:space:]]*:?[[:space:]]*TLSv1\.3|New,[[:space:]]*TLSv1\.3' "$first_log"; then tls=true; fi
  ((rc1==0)) && cert=true
  grep -aEqi 'ALPN protocol:[[:space:]]*h2|Negotiated protocol:[[:space:]]*h2|ALPN.*h2' "$first_log" && h2=true
  grep -aEqi 'Protocol version:[[:space:]]*TLSv1\.3|Protocol[[:space:]]*:?[[:space:]]*TLSv1\.3|New,[[:space:]]*TLSv1\.3' "$second_log" && second_tls=true
  grep -aEqi 'ALPN protocol:[[:space:]]*h2|Negotiated protocol:[[:space:]]*h2|ALPN.*h2' "$second_log" && second_h2=true
  ((rc1==0 && rc2==0)) && [[ $second_tls == true && $second_h2 == true ]] && stable=true

  if rm_have curl; then
    local resolve_arg=$resolved
    [[ $resolved == *:* ]] && resolve_arg="[$resolved]"
    set +e
    curl -sS -o /dev/null -D "$hdrfile" --max-time "$RM_TARGET_HTTP_TIMEOUT_SECONDS" --connect-timeout 2 \
      --resolve "$sni:$port:$resolve_arg" "https://$sni:$port/" >/dev/null 2>&1
    set -e
    if [[ -s $hdrfile ]]; then
      http_status=$(awk 'toupper($1) ~ /^HTTP\// {last=$2; if ($2 !~ /^1[0-9][0-9]$/) final=$2} END{print (final!=""?final:last)}' "$hdrfile")
      [[ -n $http_status ]] || http_status=unverified
      redirect=$(awk 'tolower($1)=="location:" {$1="";sub(/^ /,"");gsub(/\r/,"");loc=$0} END{print loc}' "$hdrfile")
      [[ $http_status =~ ^3[0-9][0-9]$ ]] && redirected=true
    fi
  fi

  local status=unverified reason=''
  if [[ $tcp == true && $tls == true && $cert == true && $h2 == true && $stable == true && $redirected == false ]]; then
    status=suitable_measured
  elif [[ $tcp == false || $tls == false || $cert == false ]]; then
    status=failed
    reason='TCP/TLS 1.3/证书检查未通过'
  elif [[ $redirected == true ]]; then
    reason='Target 域名发生 HTTP 重定向，不满足推荐条件'
  else
    reason='基础握手成功，但 H2 或重复握手稳定性未达到推荐条件'
  fi

  catalog=$(target_catalog_policy_json "$target" "$sni")
  shared_edge=$(jq -nc '{status:"unverified",cname_chain:[],ptr_names:[],matches:[],reason:"基础 Target 条件未通过，未执行共享边缘 DNS 检查"}')
  cross_sni=$(jq -nc '{status:"unverified",cross_sni_valid_hostname:null,probes:[],reason:"基础 Target 条件未通过，未执行跨 SNI 安全探测"}')
  if [[ $status == suitable_measured ]]; then
    shared_edge=$(target_dns_shared_edge_json "$host" "$resolved")
    if jq -e '.status!="high"' <<<"$shared_edge" >/dev/null; then
      cross_sni=$(target_cross_sni_risk_json "$resolved" "$port" "$sni" "$tmpdir")
    else
      cross_sni=$(jq -nc '{status:"skipped",cross_sni_valid_hostname:null,probes:[],
        reason:"CNAME/PTR 已命中共享边缘高风险，跳过额外跨 SNI 探测"}')
    fi
  fi

  abuse=$(jq -n --argjson edge "$shared_edge" --argjson cross "$cross_sni" '
    if $edge.status=="high" or $cross.status=="high" then
      {status:"high",shared_edge:$edge,cross_sni:$cross,
       reason:(if $edge.status=="high" then $edge.reason else $cross.reason end)}
    elif $edge.status=="unverified" or $cross.status=="unverified" then
      {status:"unverified",shared_edge:$edge,cross_sni:$cross,
       reason:"共享边缘或跨 SNI 安全检查存在未验证项，按 fail-closed 处理"}
    elif $edge.status=="low" and ($cross.status=="low" or $cross.status=="skipped") then
      {status:"low",shared_edge:$edge,cross_sni:$cross,
       reason:"CNAME/PTR 共享边缘检查与跨 SNI 检查均未发现高风险证据"}
    else
      {status:"unverified",shared_edge:$edge,cross_sni:$cross,
       reason:"安全检查状态组合无法确认，按 fail-closed 处理"}
    end
  ')

  if [[ $status == suitable_measured ]] &&
     jq -e '.status=="low"' <<<"$abuse" >/dev/null &&
     jq -e '.recommendable==true' <<<"$catalog" >/dev/null; then
    recommendation_eligible=true
    recommendation_reason='网络条件、CNAME/PTR 共享边缘检查与跨 SNI 安全门槛均通过'
  elif jq -e '.recommendable==false' <<<"$catalog" >/dev/null; then
    recommendation_reason='候选目录将此 Target 标记为不参与推荐'
  elif [[ $status == suitable_measured ]]; then
    recommendation_reason=$(jq -r '.reason' <<<"$abuse")
  else
    recommendation_reason=${reason:-'Target 网络条件未达到推荐标准'}
  fi

  local warning=''
  if [[ $sni == *apple* || $sni == *icloud* ]]; then
    warning='当前固定 Xray 版本会对 Apple/iCloud REALITY Target 给出风险警告，本项目不推荐作为默认候选'
  fi

  jq -n \
    --arg status "$status" --arg t "$target" --arg s "$sni" --arg r "$resolved" \
    --argjson latency "$ms" --argjson tcp "$tcp" --argjson tls "$tls" \
    --argjson cert "$cert" --argjson h2 "$h2" --argjson stable "$stable" \
    --arg http "$http_status" --arg redirect "$redirect" --argjson redirected "$redirected" --arg reason "$reason" \
    --arg warning "$warning" --arg risk "$risk_note" --arg recommendation_reason "$recommendation_reason" \
    --argjson catalog "$catalog" --argjson abuse "$abuse" --argjson eligible "$recommendation_eligible" \
    --argjson attempts "$RM_TARGET_HANDSHAKE_ATTEMPTS" \
    --argjson tls_timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" \
    --argjson http_timeout "$RM_TARGET_HTTP_TIMEOUT_SECONDS" \
    '{status:$status,target:$t,sni:$s,resolved_address:$r,latency_ms:$latency,
      checks:{dns:"ok",tcp:$tcp,tls13:$tls,certificate_hostname:$cert,h2:$h2,
        repeated_handshake:$stable,http_status:$http,http_redirect:$redirected,
        redirect:(if $redirect=="" then null else $redirect end)},
      reason:(if $reason=="" then null else $reason end),
      warning:(if $warning=="" then null else $warning end),
      abuse_risk:$abuse,
      catalog_policy:$catalog,
      recommendation_eligible:$eligible,
      recommendation_reason:$recommendation_reason,
      note:"HTTP 非 200 不自动等于 REALITY 不可用；HTTP 重定向、共享 CDN/边缘 CNAME/PTR、跨 SNI 风险或未验证风险均不进入推荐结果。结果仅代表当前 VPS 本次实测。",
      risk_note:$risk,
      probe_policy:{handshake_attempts:$attempts,tls_timeout_seconds:$tls_timeout,
        http_timeout_seconds:$http_timeout}}'

  rm -rf "$tmpdir"
}

target_probe_candidates() {
  local tmpdir order t s recommendable official_reference risk_class note file results suitable recommended policy idx=0 pid
  local -a pids=()
  tmpdir=$(rm_safe_tmpdir) || return $?

  while IFS=$'\t' read -r order t s recommendable official_reference risk_class note; do
    file=$(printf '%s/%04d.json' "$tmpdir" "$idx")
    (
      target_probe "$t" "$s" |
        jq --argjson order "$order" --argjson recommendable "$recommendable" \
          --argjson official_reference "$official_reference" --arg risk_class "$risk_class" --arg note "$note" \
          '. + {candidate:{order:$order,recommendable:$recommendable,official_reference:$official_reference,risk_class:$risk_class,note:$note}}'
    ) >"$file" &
    pids+=("$!")
    idx=$((idx+1))

    if ((${#pids[@]} >= RM_TARGET_MAX_PARALLEL)); then
      wait "${pids[0]}" || true
      pids=("${pids[@]:1}")
    fi
  done < <(jq -r '.candidates | to_entries[] |
    [.key,.value.target,.value.sni,(if (.value|has("recommendable")) then .value.recommendable else true end),(.value.official_reference//false),(.value.risk_class//"standard"),(.value.note//"")] | @tsv' "$RM_TARGETS_FILE")

  for pid in "${pids[@]}"; do wait "$pid" || true; done

  local f
  for f in "$tmpdir"/*.json; do
    [[ -f $f ]] || continue
    if ! jq -e . "$f" >/dev/null 2>&1; then
      jq -n '{status:"unverified",reason:"候选探测子任务未返回有效 JSON"}' >"$f"
    fi
  done

  results=$(jq -s '.' "$tmpdir"/*.json)
  suitable=$(jq '[
      .[] | select(.status=="suitable_measured") |
      {target,sni,resolved_address,latency_ms,recommendation_eligible,abuse_risk,candidate}
    ] | sort_by(.latency_ms)' <<<"$results")
  recommended=$(jq '[
      .[] |
      select(.status=="suitable_measured" and .recommendation_eligible==true and (if (.candidate|has("recommendable")) then .candidate.recommendable else true end)==true) |
      . + {_selection_rank:[.latency_ms,(if (.candidate.official_reference//false) then 0 else 1 end),(.candidate.order//999)]}
    ] | sort_by(._selection_rank) |
      (.[0] // null) |
      if .==null then null else
        {target,sni,resolved_address,latency_ms,abuse_risk,candidate,
         selection_reason:"通过 CNAME/PTR 共享边缘与跨 SNI 双重防偷跑门槛的候选中实测握手延迟最低；同延迟时优先官方参考候选"}
      end' <<<"$results")
  policy=$(jq -r .policy "$RM_TARGETS_FILE")

  jq -n --argjson results "$results" --argjson suitable "$suitable" --argjson recommended "$recommended" --arg policy "$policy" \
    --argjson max_parallel "$RM_TARGET_MAX_PARALLEL" \
    --argjson attempts "$RM_TARGET_HANDSHAKE_ATTEMPTS" \
    --argjson timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" \
    '{results:$results,
      suitable:$suitable,
      recommended:$recommended,
      policy:$policy,
      auto_selected:false,
      auto_applied:false,
      selection_basis:"只在 recommendable=true、无 HTTP 重定向、CNAME/PTR 共享边缘与跨 SNI 综合 abuse_risk=low 且 suitable_measured 的候选中按当前 VPS 实测握手延迟选择；high/unverified 均 fail-closed，且不会自动写入节点配置",
      probe_policy:{max_parallel:$max_parallel,handshake_attempts:$attempts,tls_timeout_seconds:$timeout}}'
  rm -rf "$tmpdir"
}
