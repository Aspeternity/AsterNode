#!/usr/bin/env bash
# Versioned REALITY target probing; read-only and bounded.
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
RM_TARGETS_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/compat/targets.json"

target_split() {
  local target=$1
  if [[ $target == \[*\]:* ]]; then printf '%s\t%s\n' "${target#\[}" "${target##*:}" | sed 's/]\t/\t/';
  else printf '%s\t%s\n' "${target%:*}" "${target##*:}"; fi
}

target_probe() {
  local target=$1 sni=$2 host port start end ms r1 r2 http_status='unverified' redirect='' resolved=''
  rm_split_host_port "$target" >/dev/null 2>&1 || return "$RM_RC_PRECONDITION"
  rm_valid_host "$sni" || return "$RM_RC_PRECONDITION"
  IFS=$'\t' read -r host port < <(target_split "$target")
  if ! getent ahosts "$host" >/dev/null 2>&1 && ! getent ahostsv6 "$host" >/dev/null 2>&1; then jq -n --arg t "$target" --arg s "$sni" '{status:"failed",target:$t,sni:$s,checks:{dns:"failed"},reason:"DNS 解析失败"}'; return 0; fi
  rm_have openssl && rm_have timeout || { jq -n --arg t "$target" --arg s "$sni" '{status:"unverified",target:$t,sni:$s,reason:"缺少 openssl/timeout"}'; return 0; }
  start=$(date +%s%3N 2>/dev/null || date +%s000)
  set +e; r1=$(timeout 6 openssl s_client -connect "$target" -servername "$sni" -verify_hostname "$sni" -verify_return_error -alpn h2 -tls1_3 -brief </dev/null 2>&1); local rc1=$?; set -e
  end=$(date +%s%3N 2>/dev/null || date +%s000); ms=$((end-start))
  set +e; r2=$(timeout 6 openssl s_client -connect "$target" -servername "$sni" -verify_hostname "$sni" -verify_return_error -alpn h2 -tls1_3 -brief </dev/null 2>&1); local rc2=$?; set -e
  local tls=false cert=false h2=false stable=false
  ((rc1==0)) && grep -Eq 'Protocol version: TLSv1\.3|Protocol.*TLSv1\.3' <<<"$r1" && tls=true
  ((rc1==0)) && cert=true
  grep -Eqi 'ALPN.*h2|Negotiated protocol: h2' <<<"$r1" && h2=true
  ((rc1==0 && rc2==0)) && stable=true
  if rm_have curl; then
    resolved=$(getent ahosts "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)
    [[ -n $resolved ]] || resolved=$(getent ahostsv6 "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)
    if [[ -n $resolved ]]; then
      local resolve_arg=$resolved hdr
      [[ $resolved == *:* ]] && resolve_arg="[$resolved]"
      hdr=$(curl -IsS --max-time 5 --connect-timeout 2 --resolve "$sni:$port:$resolve_arg" "https://$sni:$port/" 2>/dev/null | head -n8 || true)
      http_status=$(awk 'toupper($1) ~ /^HTTP\// {print $2; exit}' <<<"$hdr"); [[ -n $http_status ]] || http_status=unverified
      redirect=$(awk 'tolower($1)=="location:" {$1="";sub(/^ /,"");gsub(/\r/,"");print;exit}' <<<"$hdr")
    fi
  fi
  local status=unverified; [[ $tls == true && $cert == true && $stable == true ]] && status=suitable_measured; [[ $tls == false || $cert == false ]] && status=failed
  jq -n --arg status "$status" --arg t "$target" --arg s "$sni" --argjson latency "$ms" --argjson tls "$tls" --argjson cert "$cert" --argjson h2 "$h2" --argjson stable "$stable" --arg http "$http_status" --arg redirect "$redirect" \
    '{status:$status,target:$t,sni:$s,latency_ms:$latency,checks:{dns:"ok",tls13:$tls,certificate_hostname:$cert,h2:$h2,repeated_handshake:$stable,http_status:$http,redirect:(if $redirect=="" then null else $redirect end)},note:"结果仅是目标 VPS 本次实测；最终由用户确认，不自动替换现有 Target。"}'
}

target_probe_candidates() {
  local results='[]' row t s r
  while IFS=$'\t' read -r t s; do r=$(target_probe "$t" "$s"); results=$(jq -c --argjson r "$r" '.+[$r]' <<<"$results"); done < <(jq -r '.candidates[]|[.target,.sni]|@tsv' "$RM_TARGETS_FILE")
  jq -n --argjson results "$results" --arg policy "$(jq -r .policy "$RM_TARGETS_FILE")" '{results:$results,policy:$policy}'
}
