#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
out=$("$PROJECT_DIR/protocols/vless-reality.sh" describe)
assert_json "$out" '.interfaces|sort == (["collect","describe","probe","render_client","render_server","required_ports","validate"]|sort)'
assert_json "$out" '.core=="xray" and .id=="vless-reality"'
pass 'ARC-02 protocol interface contract is declared'
