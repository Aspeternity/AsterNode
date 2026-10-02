#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$BASE_DIR/lib/common.sh"

VR_PROFILE='xray-v26.3.27'
VR_FLOW='xtls-rprx-vision'

vr_describe() {
  jq -n --arg profile "$VR_PROFILE" --arg flow "$VR_FLOW" '{
    id:"vless-reality",
    name:"VLESS + RAW/TCP + REALITY",
    core:"xray",
    profile:$profile,
    flow_default:$flow,
    ports:{tcp:true,udp:false},
    interfaces:["describe","collect","validate","render_server","render_client","render_uri","required_ports","probe"],
    notes:[
      "服务端/客户端 Xray JSON 使用 v26.3.27 已验证字段 network=raw",
      "分享 URI 为兼容常见客户端/面板使用 type=tcp",
      "v26.3.27 REALITY 客户端原生字段使用 password；URI 兼容字段使用 pbk"
    ]
  }'
}

vr_valid_uuid() {
  [[ ${1:-} =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

vr_valid_short_id() {
  [[ ${1:-} =~ ^([0-9a-fA-F]{2}){1,8}$ ]]
}

vr_valid_x25519_key() {
  [[ ${1:-} =~ ^[A-Za-z0-9_-]{43}$ ]]
}

vr_valid_target() {
  rm_split_host_port "${1:-}" >/dev/null 2>&1
}

vr_valid_host() {
  rm_valid_host "${1:-}"
}

vr_valid_sni() {
  local sni=${1:-}
  rm_valid_host "$sni" || return 1
  rm_normalize_ip_or_cidr "$sni" >/dev/null 2>&1 && return 1
  [[ $sni == *.* ]]
}

vr_validate() {
  local f=${1:?json file required}
  rm_json_valid "$f" || { rm_error '协议输入不是有效 JSON'; return "$RM_RC_PRECONDITION"; }

  local id name listen port host pubport target sni priv pub short flow access
  id=$(jq -er '.node.node_id' "$f") || return "$RM_RC_PRECONDITION"
  name=$(jq -er '.node.name' "$f") || return "$RM_RC_PRECONDITION"
  listen=$(jq -er '.node.listen_address' "$f") || return "$RM_RC_PRECONDITION"
  port=$(jq -er '.node.listen_port' "$f") || return "$RM_RC_PRECONDITION"
  host=$(jq -er '.node.public_host' "$f") || return "$RM_RC_PRECONDITION"
  pubport=$(jq -er '.node.public_port' "$f") || return "$RM_RC_PRECONDITION"
  target=$(jq -er '.node.target' "$f") || return "$RM_RC_PRECONDITION"
  sni=$(jq -er '.node.sni' "$f") || return "$RM_RC_PRECONDITION"
  priv=$(jq -er '.node.reality.private_key' "$f") || return "$RM_RC_PRECONDITION"
  pub=$(jq -er '.node.reality.password' "$f") || return "$RM_RC_PRECONDITION"
  short=$(jq -er '.node.reality.short_id' "$f") || return "$RM_RC_PRECONDITION"
  flow=$(jq -r '.node.flow // "xtls-rprx-vision"' "$f")
  access=$(jq -r '.node.access_mode // "whitelist"' "$f")

  [[ $id =~ ^node-[A-Za-z0-9._-]{1,48}$ ]] || { rm_error 'node_id 格式错误'; return "$RM_RC_PRECONDITION"; }
  rm_valid_name "$name" || { rm_error '节点名称格式错误'; return "$RM_RC_PRECONDITION"; }
  [[ $listen == 0.0.0.0 || $listen == :: || $listen == 127.0.0.1 || $listen == ::1 ]] ||
    { rm_error '首版仅接受明确的通配或回环监听地址'; return "$RM_RC_PRECONDITION"; }
  rm_valid_port "$port" && rm_valid_port "$pubport" || { rm_error '端口范围错误'; return "$RM_RC_PRECONDITION"; }
  vr_valid_host "$host" || { rm_error '对外地址格式错误'; return "$RM_RC_PRECONDITION"; }
  vr_valid_target "$target" || { rm_error 'Target 必须为 host:port 或 [IPv6]:port'; return "$RM_RC_PRECONDITION"; }
  vr_valid_sni "$sni" || { rm_error 'SNI 必须是有效域名，不能直接使用 IP'; return "$RM_RC_PRECONDITION"; }
  vr_valid_x25519_key "$priv" && vr_valid_x25519_key "$pub" ||
    { rm_error 'REALITY X25519 密钥格式错误'; return "$RM_RC_PRECONDITION"; }
  vr_valid_short_id "$short" || { rm_error 'Short ID 必须为 1-8 字节十六进制'; return "$RM_RC_PRECONDITION"; }
  [[ $flow == "$VR_FLOW" ]] || { rm_error '首版只支持 xtls-rprx-vision'; return "$RM_RC_PRECONDITION"; }
  [[ $access == whitelist || $access == public || $access == external ]] ||
    { rm_error 'access_mode 无效'; return "$RM_RC_PRECONDITION"; }

  local target_host target_port
  IFS="$(printf '\t')" read -r target_host target_port < <(rm_split_host_port "$target")
  if [[ $target_host == "$host" && $target_port == "$pubport" ]]; then
    rm_error 'REALITY Target 不能指向本节点的对外端点，避免形成转发循环'
    return "$RM_RC_PRECONDITION"
  fi
  if [[ $target_port == "$port" &&
        ( $target_host == 127.0.0.1 || $target_host == ::1 || $target_host == localhost ) ]]; then
    rm_error 'REALITY Target 不能指向本节点本地监听端口'
    return "$RM_RC_PRECONDITION"
  fi

  local count i uuid upid upname enabled
  count=$(jq '.upstreams|length' "$f" 2>/dev/null || printf 0)
  ((count > 0)) || { rm_error '至少需要一条线路机连接'; return "$RM_RC_PRECONDITION"; }
  for ((i=0;i<count;i++)); do
    uuid=$(jq -er ".upstreams[$i].uuid" "$f") || return "$RM_RC_PRECONDITION"
    upid=$(jq -er ".upstreams[$i].upstream_id" "$f") || return "$RM_RC_PRECONDITION"
    upname=$(jq -er ".upstreams[$i].name" "$f") || return "$RM_RC_PRECONDITION"
    enabled=$(jq -r ".upstreams[$i].enabled // true" "$f")
    vr_valid_uuid "$uuid" || { rm_error "线路机 $upid UUID 无效"; return "$RM_RC_PRECONDITION"; }
    [[ $upid =~ ^up-[A-Za-z0-9._-]{1,48}$ ]] || { rm_error 'upstream_id 格式错误'; return "$RM_RC_PRECONDITION"; }
    rm_valid_name "$upname" || { rm_error "线路机 $upid 名称格式错误"; return "$RM_RC_PRECONDITION"; }
    [[ $enabled == true || $enabled == false ]] ||
      { rm_error "线路机 $upid enabled 必须是布尔值"; return "$RM_RC_PRECONDITION"; }
  done

  jq -e '([.upstreams[].upstream_id]|length)==([.upstreams[].upstream_id]|unique|length)' "$f" >/dev/null ||
    { rm_error '线路机 upstream_id 重复'; return "$RM_RC_PRECONDITION"; }
  jq -e '([.upstreams[].uuid|ascii_downcase]|length)==([.upstreams[].uuid|ascii_downcase]|unique|length)' "$f" >/dev/null ||
    { rm_error '同一节点存在重复 UUID，拒绝生成配置'; return "$RM_RC_PRECONDITION"; }
}

vr_render_server() {
  local f=${1:?json file required}
  vr_validate "$f"
  jq --arg flow "$VR_FLOW" '{
    log:{loglevel:"warning",access:"none"},
    inbounds:[{
      tag:("rm-in-" + .node.node_id),
      listen:.node.listen_address,
      port:.node.listen_port,
      protocol:"vless",
      settings:{
        decryption:"none",
        clients:[.upstreams[] | select((.enabled // true)==true) |
          {id:.uuid,flow:$flow,email:("rm:"+.upstream_id)}]
      },
      streamSettings:{
        network:"raw",
        security:"reality",
        realitySettings:{
          show:false,
          target:.node.target,
          xver:0,
          serverNames:[.node.sni],
          privateKey:.node.reality.private_key,
          shortIds:[.node.reality.short_id]
        },
        rawSettings:{acceptProxyProtocol:false,header:{type:"none"}}
      }
    }],
    outbounds:[{tag:"direct",protocol:"freedom"},{tag:"blocked",protocol:"blackhole"}]
  }' "$f"
}

vr_render_client() {
  local f=${1:?json file required} upid=${2:?upstream id required}
  vr_validate "$f"
  jq -e --arg up "$upid" --arg flow "$VR_FLOW" '
    . as $root |
    (.upstreams[] | select(.upstream_id==$up)) as $u |
    {
      tag:("rm-out-"+$u.upstream_id),
      protocol:"vless",
      settings:{
        vnext:[{
          address:$root.node.public_host,
          port:$root.node.public_port,
          users:[{id:$u.uuid,encryption:"none",flow:$flow}]
        }]
      },
      streamSettings:{
        network:"raw",
        security:"reality",
        realitySettings:{
          serverName:$root.node.sni,
          fingerprint:"chrome",
          password:$root.node.reality.password,
          shortId:$root.node.reality.short_id,
          spiderX:"/"
        },
        rawSettings:{header:{type:"none"}}
      }
    }
  ' "$f"
}

vr_render_uri() {
  local f=${1:?json file required} upid=${2:?upstream id required}
  vr_validate "$f"
  local uuid host port sni pub sid name qhost
  uuid=$(jq -er --arg up "$upid" '.upstreams[]|select(.upstream_id==$up)|.uuid' "$f")
  name=$(jq -er --arg up "$upid" '.upstreams[]|select(.upstream_id==$up)|.name' "$f")
  host=$(jq -er '.node.public_host' "$f")
  port=$(jq -er '.node.public_port' "$f")
  sni=$(jq -er '.node.sni' "$f")
  pub=$(jq -er '.node.reality.password' "$f")
  sid=$(jq -er '.node.reality.short_id' "$f")
  qhost=$host
  [[ $host == *:* ]] && qhost="[$host]"
  printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%%2F&type=tcp&headerType=none#%s\n'     "$uuid" "$qhost" "$port" "$(rm_urlencode "$VR_FLOW")" "$(rm_urlencode "$sni")"     "$(rm_urlencode "$pub")" "$(rm_urlencode "$sid")" "$(rm_urlencode "$name")"
}

vr_required_ports() {
  local f=${1:?json file required}
  vr_validate "$f"
  jq '{tcp:[.node.listen_port],udp:[]}' "$f"
}

vr_probe() {
  local config=${1:?rendered server config required} xray=${2:-xray}
  [[ -f $config ]] || return "$RM_RC_PRECONDITION"
  if ! command -v "$xray" >/dev/null 2>&1 && [[ ! -x $xray ]]; then
    jq -n '{status:"unverified",reason:"Xray 核心不可用，未执行配置测试"}'
    return 0
  fi
  local out rc
  set +e
  out=$("$xray" run -test -config "$config" 2>&1)
  rc=$?
  set -e
  if ((rc==0)); then
    jq -n '{status:"ok",check:"xray-config-test"}'
  else
    jq -n --arg msg "${out:0:800}" --argjson rc "$rc"       '{status:"failed",check:"xray-config-test",exit_code:$rc,detail:$msg}'
    return "$RM_RC_PRECONDITION"
  fi
}

vr_generate_uuid() {
  local xray=${1:-xray}
  if command -v "$xray" >/dev/null 2>&1 || [[ -x $xray ]]; then
    "$xray" uuid | head -n1
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    return "$RM_RC_PRECONDITION"
  fi
}

vr_generate_keypair() {
  local xray=${1:-xray} out private public
  if ! command -v "$xray" >/dev/null 2>&1 && [[ ! -x $xray ]]; then
    rm_error '生成 REALITY 密钥需要 Xray 核心'
    return "$RM_RC_PRECONDITION"
  fi
  out=$("$xray" x25519 2>&1)
  private=$(awk -F': *' '/Private key:|PrivateKey:/ {print $2; exit}' <<<"$out")
  public=$(awk -F': *' '/Password:|Public key:|PublicKey:/ {print $2; exit}' <<<"$out")
  if ! vr_valid_x25519_key "$private" || ! vr_valid_x25519_key "$public"; then
    rm_error '无法解析 Xray x25519 输出'
    return "$RM_RC_PRECONDITION"
  fi
  jq -n --arg private "$private" --arg password "$public" '{private_key:$private,password:$password}'
}

vr_generate_short_id() {
  rm_have openssl || { rm_error '生成 Short ID 需要 openssl'; return "$RM_RC_PRECONDITION"; }
  openssl rand -hex 8
}

vr_collect() {
  rm_tty_available || { rm_error '无 TTY，禁止交互修改。'; return "$RM_RC_PRECONDITION"; }
  local name listen port host pubport target sni access
  rm_read_tty name '节点名称: '
  rm_valid_name "$name" || return "$RM_RC_PRECONDITION"
  rm_read_tty listen '监听地址 [0.0.0.0/::]: '
  [[ -n $listen ]] || listen=0.0.0.0
  rm_read_tty port '内部监听端口 [443]: '
  [[ -n $port ]] || port=443
  rm_read_tty host '对外地址（IP/域名）: '
  rm_read_tty pubport "对外端口 [$port]: "
  [[ -n $pubport ]] || pubport=$port
  rm_read_tty target 'REALITY Target (如 example.com:443): '
  rm_read_tty sni 'REALITY SNI: '
  rm_read_tty access '访问模式 [whitelist/public/external，默认 whitelist]: '
  [[ -n $access ]] || access=whitelist
  jq -n --arg name "$name" --arg listen "$listen" --argjson port "$port"     --arg host "$host" --argjson pubport "$pubport" --arg target "$target"     --arg sni "$sni" --arg access "$access"     '{name:$name,listen_address:$listen,listen_port:$port,public_host:$host,public_port:$pubport,
      target:$target,sni:$sni,access_mode:$access}'
}

usage() {
  printf 'Usage: %s {describe|collect|validate|render_server|render_client|render_uri|required_ports|probe|generate_uuid|generate_keypair|generate_short_id} ...\n' "$0" >&2
}

cmd=${1:-}
[[ $# -gt 0 ]] && shift || true
case "$cmd" in
  describe) vr_describe "$@";;
  collect) vr_collect "$@";;
  validate) vr_validate "$@";;
  render_server) vr_render_server "$@";;
  render_client) vr_render_client "$@";;
  render_uri) vr_render_uri "$@";;
  required_ports) vr_required_ports "$@";;
  probe) vr_probe "$@";;
  generate_uuid) vr_generate_uuid "$@";;
  generate_keypair) vr_generate_keypair "$@";;
  generate_short_id) vr_generate_short_id "$@";;
  *) usage; exit "$RM_RC_PRECONDITION";;
esac
