#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$PROJECT_DIR/lib/common.sh"

assert_eq '192.0.2.1' "$(rm_normalize_ip_or_cidr 192.0.2.1)"
assert_eq '192.0.2.0/24' "$(rm_normalize_ip_or_cidr 192.0.2.77/24)"
assert_eq '2001:db8:0:0:0:0:0:1' "$(rm_normalize_ip_or_cidr 2001:db8::1)"
assert_eq '2001:db8:abcd:0:0:0:0:0/64' "$(rm_normalize_ip_or_cidr 2001:db8:abcd::1/64)"
if rm_normalize_ip_or_cidr '999.1.1.1' >/dev/null 2>&1; then fail 'invalid IPv4 accepted'; fi
if rm_normalize_ip_or_cidr '2001:::1' >/dev/null 2>&1; then fail 'invalid IPv6 accepted'; fi
if rm_valid_port 0; then fail 'port 0 accepted'; fi
if rm_valid_port 65536; then fail 'port 65536 accepted'; fi
assert_true rm_valid_port 443

root=$(new_test_root); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/a"; ln -s "$root/a" "$root/link"
assert_true rm_path_has_symlink_component "$root/link/file"
if rm_path_has_symlink_component "$root/a/file"; then fail 'regular path reported as symlink'; fi

pass 'common validation and path safety'
