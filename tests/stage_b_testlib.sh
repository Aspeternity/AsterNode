#!/usr/bin/env bash
# Shared helpers for Stage B isolated tests.

stage_b_fake_core() {
  local root=$1 version=${2:-v26.3.27} dir counter
  dir="$root/usr/local/lib/relay-manager/core/$version"
  counter="$root/run/fake-xray-counter"
  mkdir -p "$dir" "$root/usr/local/lib/relay-manager/core" "$root/etc/systemd/system" "$root/run"
  cat >"$dir/xray" <<'XRAY'
#!/usr/bin/env bash
set -Eeuo pipefail
counter="${RM_ROOT:?}/run/fake-xray-counter"
case "${1:-}" in
  uuid)
    n=0
    [[ -f $counter ]] && n=$(cat "$counter")
    n=$((n+1))
    printf '%s\n' "$n" >"$counter"
    printf '11111111-1111-4111-8111-%012x\n' "$n"
    ;;
  x25519)
    printf 'Private key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n'
    printf 'Password: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n'
    ;;
  run)
    cfg=''
    while (($#)); do
      case "$1" in
        -config|-c) shift; cfg=${1:-};;
      esac
      shift || true
    done
    [[ -n $cfg && -f $cfg ]]
    jq -e . "$cfg" >/dev/null
    ;;
  *)
    printf 'fake xray: unsupported command\n' >&2
    exit 10
    ;;
esac
XRAY
  chmod 0755 "$dir/xray"
  ln -sfn "$dir" "$root/usr/local/lib/relay-manager/core/current"
  printf '[Unit]\nDescription=Test managed Xray\n' >"$root/etc/systemd/system/relay-manager-xray.service"
  chmod 0644 "$root/etc/systemd/system/relay-manager-xray.service"
}

stage_b_base_spec() {
  local outfile=$1 public_host=${2:-203.0.113.10}
  jq -n --arg public_host "$public_host" '{
    node:{
      node_id:"node-stageb",
      name:"sg-node",
      listen_address:"0.0.0.0",
      listen_port:443,
      public_host:$public_host,
      public_port:443,
      target:"www.microsoft.com:443",
      sni:"www.microsoft.com",
      access_mode:"whitelist",
      flow:"xtls-rprx-vision",
      enabled:true,
      autostart:true,
      reality:{
        private_key:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        password:"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        short_id:"0011223344556677"
      }
    },
    upstreams:[
      {
        upstream_id:"up-line-a",
        name:"line-a",
        uuid:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        enabled:true,
        source_addresses:["198.51.100.9"]
      },
      {
        upstream_id:"up-line-b",
        name:"line-b",
        uuid:"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        enabled:true,
        source_addresses:["198.51.100.9"]
      }
    ]
  }' >"$outfile"
}
