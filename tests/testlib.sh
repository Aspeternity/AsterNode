#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$TEST_DIR/.." && pwd)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*" >&2; }

assert_eq() {
  local expected=$1 actual=$2 message
  message=${3:-"expected [$expected], got [$actual]"}
  [[ $expected == "$actual" ]] || fail "$message"
}

assert_ne() {
  local left=$1 right=$2 message
  message=${3:-"values unexpectedly equal [$left]"}
  [[ $left != "$right" ]] || fail "$message"
}

assert_true() {
  "$@" || fail "command failed: $*"
}

assert_file_mode() {
  local file=$1 expected=$2 actual
  actual=$(stat -c '%a' "$file")
  [[ $actual == "$expected" ]] || fail "$file mode=$actual expected=$expected"
}

assert_json() {
  local json=$1 filter=$2
  jq -e "$filter" <<<"$json" >/dev/null || fail "JSON assertion failed: $filter\n$json"
}

new_test_root() {
  mktemp -d "${TMPDIR:-/tmp}/relay-manager-test.XXXXXXXX"
}

snapshot_tree() {
  local root=$1
  if [[ ! -e $root ]]; then printf '<missing>\n'; return; fi
  find "$root" -xdev -printf '%P\t%y\t%m\t%s\t%T@\n' 2>/dev/null | sort
  find "$root" -xdev -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum
}
