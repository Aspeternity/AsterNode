#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

[[ -f "$BASE_DIR/VERSION" ]]
version=$(cat "$BASE_DIR/VERSION")
[[ $version =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]]
[[ -x "$BASE_DIR/relay-manager.sh" && -x "$BASE_DIR/install.sh" && -x "$BASE_DIR/diagnostics.sh" ]]
jq -e '.schema_version==1 and (.default_core_version|type=="string")' "$BASE_DIR/compat/compatibility.json" >/dev/null
if [[ -f $BASE_DIR/MANIFEST.json ]]; then
  jq -e --arg v "$version" '.release_format==1 and .project=="relay-manager" and .product=="AsterNode" and .version==$v' "$BASE_DIR/MANIFEST.json" >/dev/null
fi
while IFS= read -r file; do bash -n "$file"; done < <(find "$BASE_DIR" -maxdepth 4 -type f -name '*.sh' -print | sort)
"$BASE_DIR/relay-manager.sh" help >/dev/null
printf 'release smoke: PASS\n'
