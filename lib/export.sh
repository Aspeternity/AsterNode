#!/usr/bin/env bash
# Credential-protected export for a node/upstream pair.
# shellcheck source=lib/node.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/node.sh"

RM_EXPORT_DIR="$RM_VAR_DIR/exports"

export_build_spec() {
  local upid=$1 mode=${2:-current} out=$3
  state_init >/dev/null
  local nid
  nid=$(jq -er --arg id "$upid" '.upstreams[]|select(.upstream_id==$id)|.node_id' "$RM_STATE_FILE") || return "$RM_RC_PRECONDITION"
  jq --arg up "$upid" --arg nid "$nid" --arg mode "$mode" '
    (.nodes[]|select(.node_id==$nid)) as $n |
    (.upstreams[]|select(.upstream_id==$up)) as $u |
    {node:$n,upstreams:[($u |
      if $mode=="pending" then
        (if (.pending_uuid//"")!="" then .uuid=.pending_uuid else error("no pending uuid") end)
      else . end)]}
  ' "$RM_STATE_FILE" >"$out" || return "$RM_RC_PRECONDITION"
  "$RM_PROTOCOL_VR" validate "$out"
}

export_validate_outbound() {
  local outbound=$1 tmpdir full bin rc=0
  bin=$(xray_current_binary)
  [[ -x $bin ]] || { rm_error '导出前需要已安装的受管 Xray 核心用于配置检查'; return "$RM_RC_PRECONDITION"; }
  tmpdir=$(rm_safe_tmpdir); full="$tmpdir/client-check.json"
  jq -n --slurpfile outbound "$outbound" '{log:{loglevel:"none"},outbounds:[$outbound[0]]}' >"$full"
  xray_test_config "$full" "$bin" || rc=$?
  rm -rf "$tmpdir"
  return "$rc"
}

export_upstream() {
  local upid=$1 mode=${2:-current} show=${3:-false}
  [[ $mode == current || $mode == pending ]] || return "$RM_RC_PRECONDITION"
  [[ $show == true || $show == false ]] || return "$RM_RC_PRECONDITION"
  rm_require_root || return $?

  local tmpdir spec nid dir params outbound uri panel manifest profile now
  tmpdir=$(rm_safe_tmpdir); spec="$tmpdir/spec.json"
  export_build_spec "$upid" "$mode" "$spec" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  nid=$(jq -r '.node.node_id' "$spec")
  dir="$RM_EXPORT_DIR/$nid/$upid/$mode"
  install -d -m 0700 "$dir"
  rm -f "$dir/REVOKED"

  params="$dir/params.json"
  outbound="$dir/outbound.json"
  uri="$dir/share.txt"
  panel="$dir/3x-ui.json"
  manifest="$dir/manifest.json"
  profile=$(jq -er '.core.xray[.default_core_version].profiles[0]' "$RM_COMPAT_FILE")
  now=$(rm_now)

  "$RM_PROTOCOL_VR" render_client "$spec" "$upid" >"$outbound"
  "$RM_PROTOCOL_VR" render_uri "$spec" "$upid" >"$uri"
  export_validate_outbound "$outbound" || { local rc=$?; rm -f "$outbound" "$uri"; rm -rf "$tmpdir"; return "$rc"; }

  jq --arg profile "$profile" --arg generated "$now" '
    . as $r | ($r.upstreams[0]) as $u |
    {generated_at:$generated,profile:$profile,node_id:$r.node.node_id,upstream_id:$u.upstream_id,
     address:$r.node.public_host,port:$r.node.public_port,uuid:$u.uuid,flow:$r.node.flow,
     transport:{xray_json:"raw",share_uri:"tcp",header:"none"},
     security:"reality",sni:$r.node.sni,fingerprint:"chrome",
     password:$r.node.reality.password,public_key_alias:$r.node.reality.password,
     short_id:$r.node.reality.short_id,spider_x:"/",server_private_key_exported:false}
  ' "$spec" >"$params"

  jq --arg profile "$profile" --arg generated "$now" '
    . as $r | ($r.upstreams[0]) as $u |
    {generated_at:$generated,panel:"3x-ui",profile:$profile,node_id:$r.node.node_id,upstream_id:$u.upstream_id,
     fields:{
       address:$r.node.public_host,port:$r.node.public_port,protocol:"vless",uuid:$u.uuid,
       flow:$r.node.flow,transport_for_xray_json:"raw",transport_for_share_uri:"tcp",
       security:"reality",server_name:$r.node.sni,fingerprint:"chrome",
       password_or_public_key:$r.node.reality.password,short_id:$r.node.reality.short_id,spider_x:"/"
     },
     routing_guide:{
       outbound_tag:("rm-out-"+$u.upstream_id),
       merge_outbound_into:"outbounds[]",
       route_selected_traffic_with:"routing.rules[].outboundTag",
       overwrite_existing_config:false
     },
     notes:[
       "3x-ui 界面字段名称会随版本变化；请按语义对应，不承诺一键粘贴。",
       "outbound.json 是单个 outbound 对象，不是完整线路机配置。",
       "真实兼容性只有完成线路 VPS 的 REALITY 认证与代理请求后才算验证。"
     ]}
  ' "$spec" >"$panel"

  chmod 0600 "$params" "$outbound" "$uri" "$panel"
  local sha_params sha_out sha_uri sha_panel
  sha_params=$(rm_sha256_file "$params")
  sha_out=$(rm_sha256_file "$outbound")
  sha_uri=$(rm_sha256_file "$uri")
  sha_panel=$(rm_sha256_file "$panel")
  jq -n --arg generated "$now" --arg profile "$profile" --arg node "$nid" --arg up "$upid" --arg mode "$mode"     --arg p "$sha_params" --arg o "$sha_out" --arg u "$sha_uri" --arg x "$sha_panel"     '{generated_at:$generated,profile:$profile,node_id:$node,upstream_id:$up,credential_mode:$mode,
      files:{"params.json":$p,"outbound.json":$o,"share.txt":$u,"3x-ui.json":$x},
      validation:{xray_config_test:"pass",line_end_to_end:"unverified"},
      secret_policy:{server_private_key_exported:false,permissions:"0600"}}' >"$manifest"
  chmod 0600 "$manifest"

  if [[ $show == true ]]; then
    jq -n --argjson params "$(cat "$params")" --argjson outbound "$(cat "$outbound")"       --argjson panel "$(cat "$panel")" --arg uri "$(cat "$uri")" --argjson manifest "$(cat "$manifest")"       '{params:$params,outbound:$outbound,share_uri:$uri,three_x_ui:$panel,manifest:$manifest}'
  else
    jq -n --arg p "$params" --arg o "$outbound" --arg u "$uri" --arg x "$panel" --arg m "$manifest"       '{status:"exported",params_file:$p,outbound_file:$o,share_file:$u,three_x_ui_file:$x,manifest_file:$m,credentials_hidden:true}'
  fi
  rm -rf "$tmpdir"
}

export_invalidate_upstream_mode() {
  local upid=$1 mode=$2 d
  [[ $upid =~ ^up-[A-Za-z0-9._-]{1,48}$ ]] || return "$RM_RC_PRECONDITION"
  [[ $mode == current || $mode == pending ]] || return "$RM_RC_PRECONDITION"
  [[ -d $RM_EXPORT_DIR ]] || return 0
  for d in "$RM_EXPORT_DIR"/*/"$upid"/"$mode"; do
    [[ -d $d ]] || continue
    rm -f "$d/params.json" "$d/outbound.json" "$d/share.txt" "$d/3x-ui.json" "$d/manifest.json"
    printf 'revoked_at=%s\nupstream_id=%s\ncredential_mode=%s\n' "$(rm_now)" "$upid" "$mode" >"$d/REVOKED"
    chmod 0600 "$d/REVOKED"
  done
}

export_invalidate_upstream() {
  local upid=$1
  export_invalidate_upstream_mode "$upid" current
  export_invalidate_upstream_mode "$upid" pending
}
