#!/usr/bin/env bash
# Credential-protected export for a node/upstream pair.
# shellcheck source=lib/node.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/node.sh"

RM_EXPORT_DIR="$RM_VAR_DIR/exports"

export_build_spec() {
  local upid=$1 mode=${2:-current} out=$3
  state_init >/dev/null
  local nid; nid=$(jq -er --arg id "$upid" '.upstreams[]|select(.upstream_id==$id)|.node_id' "$RM_STATE_FILE") || return "$RM_RC_PRECONDITION"
  jq --arg up "$upid" --arg nid "$nid" --arg mode "$mode" '
    (.nodes[]|select(.node_id==$nid)) as $n |
    (.upstreams[]|select(.upstream_id==$up)) as $u |
    {node:$n,upstreams:[($u | if $mode=="pending" then (if .pending_uuid then .uuid=.pending_uuid else error("no pending uuid") end) else . end)]}
  ' "$RM_STATE_FILE" >"$out"
  "$RM_PROTOCOL_VR" validate "$out"
}

export_upstream() {
  local upid=$1 mode=${2:-current} show=${3:-false} tmpdir spec nid dir params outbound uri
  [[ $mode == current || $mode == pending ]] || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir); spec="$tmpdir/spec.json"
  export_build_spec "$upid" "$mode" "$spec" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  nid=$(jq -r '.node.node_id' "$spec"); dir="$RM_EXPORT_DIR/$nid/$upid/$mode"; install -d -m 0700 "$dir"
  params="$dir/params.json"; outbound="$dir/outbound.json"; uri="$dir/share.txt"
  "$RM_PROTOCOL_VR" render_client "$spec" "$upid" >"$outbound"
  "$RM_PROTOCOL_VR" render_uri "$spec" "$upid" >"$uri"
  jq --arg profile xray-v26.3.27 --arg transport_uri tcp --arg generated "$(rm_now)" '
    . as $r | ($r.upstreams[0]) as $u |
    {generated_at:$generated,profile:$profile,node_id:$r.node.node_id,upstream_id:$u.upstream_id,address:$r.node.public_host,port:$r.node.public_port,uuid:$u.uuid,flow:$r.node.flow,transport:{xray_json:"raw",share_uri:$transport_uri},security:"reality",sni:$r.node.sni,fingerprint:"chrome",password:$r.node.reality.password,short_id:$r.node.reality.short_id,server_private_key_exported:false}
  ' "$spec" >"$params"
  chmod 0600 "$params" "$outbound" "$uri"
  if [[ $show == true ]]; then
    jq -n --arg params "$(cat "$params")" --arg outbound "$(cat "$outbound")" --arg uri "$(cat "$uri")" '{params:($params|fromjson),outbound:($outbound|fromjson),share_uri:$uri}'
  else
    jq -n --arg p "$params" --arg o "$outbound" --arg u "$uri" '{status:"exported",params_file:$p,outbound_file:$o,share_file:$u,credentials_hidden:true}'
  fi
  rm -rf "$tmpdir"
}

export_invalidate_upstream() {
  local upid=$1
  [[ -d $RM_EXPORT_DIR ]] || return 0
  find "$RM_EXPORT_DIR" -type d -name "$upid" -prune -exec sh -c 'for d do [ -d "$d" ] || continue; printf "%s\n" "revoked $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$d/REVOKED"; chmod 600 "$d/REVOKED"; done' sh {} +
}
