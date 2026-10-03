#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/system.sh
source "$BASE_DIR/lib/system.sh"

usage() {
  cat <<'TXT'
AsterNode / Relay Manager installer
Usage:
  ./install.sh                  Existing managed installation: enter local manager; otherwise install this source tree.
  ./install.sh --install-source Explicitly install this source tree.
  ./install.sh --package FILE --sha256 HEX [--trusted-key PUBLIC_KEY]

Notes:
  * The source-tree path is for development and isolated validation.
  * --package requires a signed release package. First-install trust can be supplied explicitly with --trusted-key.
  * An existing trusted key is never silently replaced; key rotation is a separate Stage-D operation.
  * No default remote domain is invented. The public one-line bootstrap will be generated from an explicit fixed
    release URL, package SHA-256 and embedded trusted public key rather than floating main.
TXT
}

install_dependencies() {
  local missing=() c pkglist=() pkg
  for c in jq curl openssl ip ss flock unzip sha256sum tar fuser; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]}==0)) && return 0
  [[ -f /etc/debian_version ]] || { rm_error "缺少依赖: ${missing[*]}"; return "$RM_RC_PRECONDITION"; }
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    rm_error "隔离测试模式缺少依赖且禁止安装系统包: ${missing[*]}"
    return "$RM_RC_PRECONDITION"
  fi
  for c in "${missing[@]}"; do
    case "$c" in
      jq) pkg=jq;; curl) pkg=curl;; openssl) pkg=openssl;; ip|ss) pkg=iproute2;; flock) pkg=util-linux;; unzip) pkg=unzip;; sha256sum) pkg=coreutils;; tar) pkg=tar;; fuser) pkg=psmisc;; *) continue;;
    esac
    pkglist+=("$pkg")
  done
  mapfile -t pkglist < <(printf '%s\n' "${pkglist[@]}" | sort -u)
  rm_info "缺少依赖，将安装: ${pkglist[*]}"
  if [[ ${RM_ASSUME_YES:-0} != 1 ]]; then
    rm_tty_available || { rm_error '非 TTY 环境不会自动安装依赖'; return "$RM_RC_PRECONDITION"; }
    rm_confirm '确认安装依赖?' || return "$RM_RC_CANCEL"
  fi

  local pkg_state
  pkg_state=$(system_pkg_manager_json)
  jq -e '.kind=="apt" and .locked==false' <<<"$pkg_state" >/dev/null || {
    rm_error "包管理器当前不可安全使用: $(jq -r .reason <<<"$pkg_state")"
    return "$RM_RC_PRECONDITION"
  }
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkglist[@]}"
}

install_source_tree() {
  rm_require_root || return $?
  install_dependencies || return $?
  local version dest base current bin bindir
  version=$(cat "$BASE_DIR/VERSION")
  [[ $version =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] || { rm_error 'VERSION 格式无效'; return "$RM_RC_PRECONDITION"; }
  base=$(rm_path /usr/local/lib/relay-manager); dest="$base/versions/$version"; current="$base/current"; bin=$(rm_path /usr/local/bin/relay-manager); bindir=$(dirname "$bin")

  rm_assert_no_symlink_components "$(dirname "$base")" || return $?
  [[ ! -L $base ]] || { rm_error "安装目录不能是符号链接: $base"; return "$RM_RC_PRECONDITION"; }
  install -d -m 0755 -- "$base/versions" "$bindir"

  if [[ ! -d $dest ]]; then
    install -d -m 0755 -- "$dest"
    tar --exclude=.git --exclude='*.tar.gz' -C "$BASE_DIR" -cf - . | tar -C "$dest" -xf -
    if [[ ${RM_TEST_MODE} != 1 ]]; then chown -R root:root "$dest"; fi
  else
    [[ -f $dest/VERSION && $(cat "$dest/VERSION") == "$version" ]] || {
      rm_error "已存在的版本目录与 VERSION 不一致: $dest"
      return "$RM_RC_PRECONDITION"
    }
  fi

  ln -sfn "$dest" "$current.tmp"
  mv -Tf "$current.tmp" "$current"
  ln -sfn "$current/relay-manager.sh" "$bin.tmp"
  mv -Tf "$bin.tmp" "$bin"

  # Status is intentionally read-only and must not create managed state.
  "$bin" status
}

install_package_file() {
  local package=$1 expected=$2 trusted_key=${3:-}
  [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || { rm_error 'SHA-256 必须是 64 位十六进制'; return "$RM_RC_PRECONDITION"; }
  # shellcheck source=lib/update.sh
  source "$BASE_DIR/lib/update.sh"
  update_install_manager_package "$package" "${expected,,}" "$trusted_key"
}

cmd=${1:-}
case "$cmd" in
  -h|--help) usage; exit 0 ;;
  --package)
    [[ $# -eq 4 || $# -eq 6 ]] || { usage; exit "$RM_RC_PRECONDITION"; }
    [[ $3 == --sha256 ]] || { usage; exit "$RM_RC_PRECONDITION"; }
    if [[ $# -eq 6 ]]; then
      [[ $5 == --trusted-key ]] || { usage; exit "$RM_RC_PRECONDITION"; }
      install_package_file "$2" "$4" "$6"
    else
      install_package_file "$2" "$4"
    fi
    ;;
  --install-source) install_source_tree ;;
  '')
    installed_bin=$(rm_path /usr/local/bin/relay-manager)
    install_base=$(rm_path /usr/local/lib/relay-manager)
    if [[ -x $installed_bin ]] && [[ $(readlink -f "$installed_bin" 2>/dev/null || true) == "$install_base"/* ]]; then
      exec "$installed_bin"
    else
      install_source_tree
    fi
    ;;
  *) usage; exit "$RM_RC_PRECONDITION" ;;
esac
