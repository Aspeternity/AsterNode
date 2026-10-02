#!/usr/bin/env bash
# Relay Manager common helpers. Libraries do not change the caller's shell options.

RM_MANAGER_VERSION="${RM_MANAGER_VERSION:-$(cat "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/VERSION" 2>/dev/null || printf '0.1.0-dev')}"
RM_SCHEMA_VERSION="1"
RM_ROOT="${RM_ROOT:-}"
RM_TEST_MODE="${RM_TEST_MODE:-0}"
RM_VERBOSE="${RM_VERBOSE:-0}"
RM_UMASK="077"

RM_RC_OK=0
RM_RC_CANCEL=2
RM_RC_PRECONDITION=10
RM_RC_APPLY_ROLLED_BACK=20
RM_RC_RECOVERY_INCOMPLETE=21
RM_RC_NETWORK=30
RM_RC_INTERNAL=70

rm_path() {
  local p=${1:?path required}
  [[ $p == /* ]] || { printf 'rm_path requires an absolute path: %s\n' "$p" >&2; return "$RM_RC_PRECONDITION"; }
  if [[ -n ${RM_ROOT} ]]; then
    printf '%s%s\n' "${RM_ROOT%/}" "$p"
  else
    printf '%s\n' "$p"
  fi
}

rm_now() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
rm_epoch() { date +%s; }

rm_info() { printf '[INFO] %s\n' "$*" >&2; }
rm_warn() { printf '[WARN] %s\n' "$*" >&2; }
rm_error() { printf '[ERROR] %s\n' "$*" >&2; }
rm_debug() { [[ ${RM_VERBOSE} == 1 ]] && printf '[DEBUG] %s\n' "$*" >&2 || true; }

rm_die() {
  local code=$1; shift
  rm_error "$*"
  return "$code"
}

rm_require_root() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then return 0; fi
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { rm_error '需要 root 权限。'; return "$RM_RC_PRECONDITION"; }
}

rm_have() { command -v "$1" >/dev/null 2>&1; }

rm_require_cmds() {
  local miss=() c
  for c in "$@"; do rm_have "$c" || miss+=("$c"); done
  if ((${#miss[@]})); then
    rm_error "缺少依赖: ${miss[*]}"
    return "$RM_RC_PRECONDITION"
  fi
}

# Returns success when any existing component of PATH is a symbolic link.
# Missing tail components are safe to ignore because they cannot yet redirect traversal.
rm_path_has_symlink_component() {
  local path=${1:?path required} current=/ part
  [[ $path == /* ]] || return 0
  local -a parts=()
  IFS=/ read -r -a parts <<<"${path#/}"
  for part in "${parts[@]}"; do
    [[ -n $part ]] || continue
    if [[ $current == / ]]; then current="/$part"; else current="$current/$part"; fi
    if [[ -L $current ]]; then return 0; fi
    [[ -e $current ]] || break
  done
  return 1
}

rm_assert_no_symlink_components() {
  local path=${1:?path required}
  if rm_path_has_symlink_component "$path"; then
    rm_error "路径包含符号链接，拒绝自动写入: $path"
    return "$RM_RC_PRECONDITION"
  fi
}

rm_mkdir_secure() {
  local mode=$1 path=$2
  [[ $path == /* ]] || return "$RM_RC_PRECONDITION"
  if [[ -L $path || ( -e $path && ! -d $path ) ]]; then
    rm_error "安全目录路径不是普通目录: $path"
    return "$RM_RC_PRECONDITION"
  fi
  # Validate existing parents before mkdir/install follows them.
  local parent
  parent=$(dirname -- "$path")
  rm_assert_no_symlink_components "$parent" || return $?
  install -d -m "$mode" -- "$path"
  chmod "$mode" -- "$path"
  if [[ ${RM_TEST_MODE} != 1 && $(id -u) -eq 0 ]]; then chown root:root -- "$path"; fi
}

rm_safe_tmpdir() {
  local base
  base=$(rm_path /run/relay-manager)
  rm_mkdir_secure 0700 "$base" || return $?
  umask "$RM_UMASK"
  mktemp -d "$base/tmp.XXXXXXXX"
}

rm_json_valid() { jq -e . "$1" >/dev/null 2>&1; }

rm_atomic_write() {
  local src=$1 dst=$2 mode=${3:-0600} owner=${4:-root:root}
  local dir tmp
  [[ -f $src && $dst == /* ]] || return "$RM_RC_PRECONDITION"
  dir=$(dirname -- "$dst")
  rm_assert_no_symlink_components "$dir" || return $?
  [[ ! -L $dst ]] || { rm_error "拒绝覆盖符号链接: $dst"; return "$RM_RC_PRECONDITION"; }
  mkdir -p -- "$dir"
  tmp=$(mktemp "$dir/.rm-write.XXXXXX") || return 1
  if ! cat -- "$src" >"$tmp"; then rm -f -- "$tmp"; return 1; fi
  chmod "$mode" -- "$tmp"
  if [[ ${RM_TEST_MODE} != 1 && $(id -u) -eq 0 ]]; then chown "$owner" -- "$tmp"; fi
  sync "$tmp" 2>/dev/null || true
  mv -fT -- "$tmp" "$dst"
  sync "$dir" 2>/dev/null || true
}

rm_sha256_file() { sha256sum -- "$1" | awk '{print $1}'; }

rm_json_redact() {
  jq 'walk(if type == "object" then
      with_entries(if (.key|test("(?i)(private|password|uuid|secret|token|key)$")) then .value="<redacted>" else . end)
    else . end)'
}

_rm_ipv4_to_int() {
  local ip=$1 a b c d extra
  IFS=. read -r a b c d extra <<<"$ip"
  [[ -z ${extra:-} && $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] || return 1
  ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255)) || return 1
  printf '%u\n' "$(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d ))"
}

_rm_int_to_ipv4() {
  local n=$1
  printf '%u.%u.%u.%u\n' "$(( (n>>24)&255 ))" "$(( (n>>16)&255 ))" "$(( (n>>8)&255 ))" "$(( n&255 ))"
}

_rm_normalize_ipv6() {
  local input=$1 addr prefix=128 left right dots ipv4 n
  local -a lhs=() rhs=() groups=()
  [[ $input != *%* ]] || return 1
  if [[ $input == */* ]]; then
    addr=${input%/*}; prefix=${input##*/}
    [[ $prefix =~ ^[0-9]+$ ]] && ((10#$prefix <= 128)) || return 1
    prefix=$((10#$prefix))
  else
    addr=$input
  fi
  [[ -n $addr ]] || return 1
  dots=${addr//[^.]/}
  if [[ -n $dots ]]; then
    ipv4=${addr##*:}; n=$(_rm_ipv4_to_int "$ipv4") || return 1
    addr=${addr%$ipv4}
    [[ $addr == *: ]] || return 1
    addr+=$(printf '%x:%x' "$(( (n>>16)&65535 ))" "$(( n&65535 ))")
  fi
  [[ $addr != *:::* ]] || return 1
  if [[ $addr == *::* ]]; then
    [[ ${addr#*::} != *::* ]] || return 1
    left=${addr%%::*}; right=${addr#*::}
    if [[ -n $left ]]; then IFS=: read -r -a lhs <<<"$left"; fi
    if [[ -n $right ]]; then IFS=: read -r -a rhs <<<"$right"; fi
    ((${#lhs[@]} + ${#rhs[@]} < 8)) || return 1
  else
    IFS=: read -r -a lhs <<<"$addr"
    ((${#lhs[@]} == 8)) || return 1
  fi
  local g
  for g in "${lhs[@]}" "${rhs[@]}"; do [[ $g =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; done
  groups=("${lhs[@]}")
  if [[ $addr == *::* ]]; then
    local missing=$((8-${#lhs[@]}-${#rhs[@]})) i
    for ((i=0;i<missing;i++)); do groups+=(0); done
  fi
  groups+=("${rhs[@]}")
  ((${#groups[@]} == 8)) || return 1
  local i val bits mask out=''
  for ((i=0;i<8;i++)); do
    val=$((16#${groups[$i]}))
    bits=$((prefix-i*16))
    if ((bits <= 0)); then val=0
    elif ((bits < 16)); then mask=$(( (65535 << (16-bits)) & 65535 )); val=$((val & mask)); fi
    printf -v g '%x' "$val"
    out+=${out:+:}$g
  done
  if [[ $input == */* ]]; then printf '%s/%u\n' "$out" "$prefix"; else printf '%s\n' "$out"; fi
}

rm_normalize_ip_or_cidr() {
  local input=${1:-} addr prefix n mask
  [[ -n $input && $input != *$'\n'* && $input != *$'\r'* ]] || return 1
  if [[ $input == *:* ]]; then _rm_normalize_ipv6 "$input"; return; fi
  if [[ $input == */* ]]; then
    addr=${input%/*}; prefix=${input##*/}
    [[ $prefix =~ ^[0-9]+$ ]] && ((10#$prefix <= 32)) || return 1
    prefix=$((10#$prefix)); n=$(_rm_ipv4_to_int "$addr") || return 1
    if ((prefix == 0)); then mask=0; else mask=$(( (0xffffffff << (32-prefix)) & 0xffffffff )); fi
    addr=$(_rm_int_to_ipv4 "$((n & mask))")
    printf '%s/%u\n' "$addr" "$prefix"
  else
    n=$(_rm_ipv4_to_int "$input") || return 1
    _rm_int_to_ipv4 "$n"
  fi
}

rm_valid_host() {
  local h=${1:-} label
  [[ -n $h && ${#h} -le 253 && $h != */* && $h != *$'\n'* && $h != *$'\r'* && $h != *' '* ]] || return 1
  rm_normalize_ip_or_cidr "$h" >/dev/null 2>&1 && return 0
  [[ $h != .* && $h != *. && $h != *..* ]] || return 1
  local -a _rm_labels=()
  IFS=. read -r -a _rm_labels <<<"$h"
  for label in "${_rm_labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

rm_split_host_port() {
  local input=${1:-} host port
  if [[ $input == \[*\]:* ]]; then host=${input#\[}; host=${host%%\]*}; port=${input##*:}
  else [[ $input == *:* && ${input#*:} != *:* ]] || return 1; host=${input%:*}; port=${input##*:}; fi
  rm_valid_host "$host" && rm_valid_port "$port" || return 1
  printf '%s\t%s\n' "$host" "$port"
}

rm_valid_port() {
  [[ ${1:-} =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

rm_valid_name() {
  [[ ${1:-} =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

rm_systemctl() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    if [[ -n ${RM_SYSTEMCTL_LOG:-} ]]; then printf '%s\n' "$*" >>"$RM_SYSTEMCTL_LOG"; fi
    return 0
  fi
  systemctl "$@"
}

rm_service_is_active() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then return 1; fi
  systemctl is-active --quiet "$1"
}

rm_service_is_enabled() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then return 1; fi
  systemctl is-enabled --quiet "$1" 2>/dev/null
}

rm_tty_available() {
  [[ -t 0 && -t 1 ]] && return 0
  (exec 9<>/dev/tty) 2>/dev/null
}

rm_read_tty() {
  local __var=$1 prompt=$2 value
  if rm_tty_available && [[ -r /dev/tty && -w /dev/tty ]]; then
    IFS= read -r -p "$prompt" value </dev/tty || return 1
  elif [[ -t 0 ]]; then
    IFS= read -r -p "$prompt" value || return 1
  else
    return 1
  fi
  printf -v "$__var" '%s' "$value"
}

rm_confirm() {
  local prompt=$1 ans
  rm_read_tty ans "$prompt [y/N]: " || return "$RM_RC_CANCEL"
  [[ $ans == y || $ans == Y || $ans == yes || $ans == YES || $ans == 是 ]] || return "$RM_RC_CANCEL"
}

rm_urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}
