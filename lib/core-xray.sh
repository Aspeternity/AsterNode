#!/usr/bin/env bash
# Xray core lifecycle and managed shared service.
# shellcheck source=lib/transaction.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/transaction.sh"

RM_PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RM_COMPAT_FILE="$RM_PROJECT_DIR/compat/compatibility.json"
RM_CORE_BASE="$(rm_path /usr/local/lib/relay-manager/core)"
RM_CORE_CURRENT="$RM_CORE_BASE/current"
RM_XRAY_DATA_DIR="$(rm_path /var/lib/relay-manager-xray)"
RM_XRAY_SERVICE="relay-manager-xray.service"
RM_XRAY_SERVICE_FILE="$(rm_path /etc/systemd/system/$RM_XRAY_SERVICE)"
RM_MAINT_SERVICE="relay-manager-maintenance.service"
RM_MAINT_TIMER="relay-manager-maintenance.timer"
RM_MAINT_SERVICE_FILE="$(rm_path /etc/systemd/system/$RM_MAINT_SERVICE)"
RM_MAINT_TIMER_FILE="$(rm_path /etc/systemd/system/$RM_MAINT_TIMER)"
RM_XRAY_CONFIG="$(rm_path /etc/relay-manager-xray/config.json)"

xray_default_version() { jq -er '.default_core_version' "$RM_COMPAT_FILE"; }

xray_arch() {
  case "$(uname -m)" in x86_64|amd64) printf 'amd64\n';; aarch64|arm64) printf 'arm64\n';; *) return "$RM_RC_PRECONDITION";; esac
}

xray_asset_json() {
  local version=${1:-$(xray_default_version)} arch=${2:-$(xray_arch)}
  jq -e --arg v "$version" --arg a "$arch" '.core.xray[$v].assets[$a]' "$RM_COMPAT_FILE"
}

xray_path_for_version() { printf '%s/%s/xray\n' "$RM_CORE_BASE" "$1"; }
xray_current_binary() { printf '%s/xray\n' "$RM_CORE_CURRENT"; }

xray_core_installed() { local v=${1:-$(xray_default_version)}; [[ -x $(xray_path_for_version "$v") ]]; }

xray_check_external_conflict() {
  # Existing unmanaged Xray service/binary is not overwritten. A different binary may coexist,
  # but a listening/running external xray process requires explicit resolution.
  if [[ ${RM_TEST_MODE} == 1 ]]; then return 0; fi
  local p
  p=$(pgrep -fa '(^|/)(xray)( |$)' 2>/dev/null | grep -v '/usr/local/lib/relay-manager/core/' || true)
  if [[ -n $p ]]; then rm_error "检测到非 Relay Manager 管理的 Xray 进程，停止自动接管:\n$p"; return "$RM_RC_PRECONDITION"; fi
  if systemctl list-unit-files xray.service >/dev/null 2>&1 && systemctl is-active --quiet xray.service 2>/dev/null; then
    rm_error '检测到外部 xray.service 正在运行，停止自动接管。'; return "$RM_RC_PRECONDITION"
  fi
}

xray_ensure_user() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then mkdir -p "$(rm_path /var/lib/relay-manager-xray)"; return 0; fi
  getent group rm-xray >/dev/null 2>&1 || groupadd --system rm-xray
  if ! getent passwd rm-xray >/dev/null 2>&1; then
    useradd --system --gid rm-xray --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin rm-xray
  fi
  install -d -m 0750 -o rm-xray -g rm-xray "$RM_XRAY_DATA_DIR"
}

_xray_zip_safe() {
  local zip=$1 list entry
  rm_have unzip || { rm_error '缺少 unzip'; return "$RM_RC_PRECONDITION"; }
  list=$(unzip -Z1 "$zip") || return "$RM_RC_PRECONDITION"
  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    [[ $entry != /* && $entry != ../* && $entry != *'/../'* && $entry != *'/..' && $entry != *$'\n'* && $entry != *$'\r'* ]] || {
      rm_error "发行包包含危险路径: $entry"; return "$RM_RC_PRECONDITION";
    }
  done <<<"$list"
  # Xray release package is expected to contain regular files only for the binary/data/docs.
  # Reject Unix symlink entries when zipinfo is available.
  if rm_have zipinfo && zipinfo -l "$zip" | awk 'NR>3 && $1 ~ /^l/ {exit 0} END{exit 1}'; then
    rm_error '发行包包含符号链接，拒绝解压。'; return "$RM_RC_PRECONDITION"
  fi
}

xray_core_install() {
  local version=${1:-$(xray_default_version)}
  rm_require_root || return $?
  xray_check_external_conflict || return $?
  local arch asset url expected expected_size dest tmp zip actual
  arch=$(xray_arch) || { rm_error '仅支持 x86_64/ARM64 核心安装'; return "$RM_RC_PRECONDITION"; }
  asset=$(xray_asset_json "$version" "$arch") || { rm_error "版本或架构未在兼容矩阵中验证: $version/$arch"; return "$RM_RC_PRECONDITION"; }
  url=$(jq -r .url <<<"$asset"); expected=$(jq -r .sha256 <<<"$asset"); expected_size=$(jq -r .size <<<"$asset")
  dest="$RM_CORE_BASE/$version"
  if [[ -x $dest/xray ]]; then rm_info "Xray $version 已安装，保持现有文件。"; return 0; fi
  rm_require_cmds curl sha256sum unzip || return $?
  tmp=$(rm_safe_tmpdir); zip="$tmp/xray.zip"
  rm_info "下载官方 Xray $version ($arch)..."
  if ! curl -fL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 180 --retry 2 --output "$zip" "$url"; then
    rm -rf "$tmp"; return "$RM_RC_NETWORK"
  fi
  if [[ $(stat -c '%s' "$zip") -ne $expected_size ]]; then rm_error '下载大小与发布元数据不符'; rm -rf "$tmp"; return "$RM_RC_NETWORK"; fi
  actual=$(rm_sha256_file "$zip")
  if [[ $actual != "$expected" ]]; then rm_error 'Xray SHA-256 校验失败'; rm -rf "$tmp"; return "$RM_RC_NETWORK"; fi
  _xray_zip_safe "$zip" || { local rc=$?; rm -rf "$tmp"; return "$rc"; }
  mkdir -p "$tmp/unpacked"; unzip -q "$zip" -d "$tmp/unpacked"
  [[ -f $tmp/unpacked/xray ]] || { rm_error '发行包缺少 xray 二进制'; rm -rf "$tmp"; return "$RM_RC_PRECONDITION"; }
  install -d -m 0755 "$dest"
  install -m 0755 "$tmp/unpacked/xray" "$dest/xray"
  printf '%s  %s\n' "$expected" "$(jq -r .name <<<"$asset")" >"$dest/SHA256SUM"
  printf '%s\n' "$url" >"$dest/SOURCE"
  chmod 0644 "$dest/SHA256SUM" "$dest/SOURCE"
  mkdir -p "$RM_CORE_BASE"
  ln -sfn "$dest" "$RM_CORE_CURRENT.tmp"
  mv -Tf "$RM_CORE_CURRENT.tmp" "$RM_CORE_CURRENT"
  if [[ ${RM_TEST_MODE} != 1 ]]; then chown -R root:root "$dest" "$RM_CORE_CURRENT" 2>/dev/null || true; fi
  rm -rf "$tmp"
  state_init >/dev/null
  state_update_filter '.core_version=$v' --arg v "$version"
}

xray_service_install() {
  rm_require_root || return $?
  xray_ensure_user || return $?
  install -d -m 0750 "$RM_XRAY_ETC_DIR"
  if [[ ${RM_TEST_MODE} != 1 ]]; then chown root:rm-xray "$RM_XRAY_ETC_DIR"; fi

  local tx rc=0
  tx=$(tx_begin core-service) || return $?
  tx_record_service "$tx" "$RM_XRAY_SERVICE" || true
  tx_record_service "$tx" "$RM_MAINT_SERVICE" || true
  tx_record_service "$tx" "$RM_MAINT_TIMER" || true
  tx_stage_file "$tx" "$RM_PROJECT_DIR/templates/relay-manager-xray.service" "$RM_XRAY_SERVICE_FILE" 0644 root:root || rc=$?
  ((rc==0)) && tx_stage_file "$tx" "$RM_PROJECT_DIR/templates/relay-manager-maintenance.service" "$RM_MAINT_SERVICE_FILE" 0644 root:root || rc=$?
  ((rc==0)) && tx_stage_file "$tx" "$RM_PROJECT_DIR/templates/relay-manager-maintenance.timer" "$RM_MAINT_TIMER_FILE" 0644 root:root || rc=$?
  if ((rc!=0)); then tx_rollback "$tx" 'stage failed' || true; return "$RM_RC_PRECONDITION"; fi
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'apply failed' || true; return "$rc"; }

  if [[ ${RM_TEST_MODE} != 1 ]]; then
    systemctl daemon-reload || { tx_rollback "$tx" 'systemd daemon-reload failed' || true; return "$RM_RC_APPLY_ROLLED_BACK"; }
    systemctl enable --now "$RM_MAINT_TIMER" >/dev/null || {
      tx_rollback "$tx" 'maintenance timer enable failed' || true
      systemctl daemon-reload || true
      return "$RM_RC_APPLY_ROLLED_BACK"
    }
  else
    rm_systemctl daemon-reload
    rm_systemctl enable "$RM_MAINT_TIMER"
    rm_systemctl start "$RM_MAINT_TIMER"
  fi

  tx_mark_service_changed "$tx" "$RM_MAINT_TIMER" || true
  tx_commit "$tx" || return $?
  state_add_owned_file "/etc/systemd/system/$RM_XRAY_SERVICE" "$(rm_sha256_file "$RM_XRAY_SERVICE_FILE")"
  state_add_owned_file "/etc/systemd/system/$RM_MAINT_SERVICE" "$(rm_sha256_file "$RM_MAINT_SERVICE_FILE")"
  state_add_owned_file "/etc/systemd/system/$RM_MAINT_TIMER" "$(rm_sha256_file "$RM_MAINT_TIMER_FILE")"
  state_add_owned_service "$RM_XRAY_SERVICE"
  state_add_owned_service "$RM_MAINT_SERVICE"
  state_add_owned_service "$RM_MAINT_TIMER"
}
xray_test_config() {
  local cfg=${1:-$RM_XRAY_CONFIG} bin=${2:-$(xray_current_binary)} out rc
  [[ -x $bin ]] || { rm_error '受管 Xray 核心未安装'; return "$RM_RC_PRECONDITION"; }
  [[ -f $cfg ]] || { rm_error 'Xray 配置不存在'; return "$RM_RC_PRECONDITION"; }
  set +e; out=$($bin run -test -config "$cfg" 2>&1); rc=$?; set -e
  if ((rc)); then rm_error "Xray 配置测试失败: ${out:0:1200}"; return "$RM_RC_PRECONDITION"; fi
}

xray_test_config_as_service_user() {
  local cfg=${1:-$RM_XRAY_CONFIG} bin=${2:-$(xray_current_binary)} out rc
  xray_test_config "$cfg" "$bin" || return $?
  [[ -r $cfg ]] || { rm_error "Xray 配置当前用户不可读: $cfg"; return "$RM_RC_PRECONDITION"; }
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    return 0
  fi
  getent passwd rm-xray >/dev/null 2>&1 || { rm_error 'rm-xray 用户不存在'; return "$RM_RC_PRECONDITION"; }
  local mode owner group
  mode=$(stat -c '%a' "$cfg")
  owner=$(stat -c '%U' "$cfg")
  group=$(stat -c '%G' "$cfg")
  [[ $mode == 640 && $owner == root && $group == rm-xray ]] || {
    rm_error "Xray 运行配置权限异常: mode=$mode owner=$owner group=$group"
    return "$RM_RC_PRECONDITION"
  }
  set +e
  out=$(runuser -u rm-xray -- "$bin" run -test -config "$cfg" 2>&1)
  rc=$?
  set -e
  if ((rc)); then
    rm_error "rm-xray 用户无法读取/验证运行配置: ${out:0:1200}"
    return "$RM_RC_PRECONDITION"
  fi
}

xray_service_enable_start() {
  local enable=${1:-true}
  [[ $enable == true || $enable == false ]] || return "$RM_RC_PRECONDITION"
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    rm_systemctl daemon-reload
    if [[ $enable == true ]]; then rm_systemctl enable "$RM_XRAY_SERVICE"; else rm_systemctl disable "$RM_XRAY_SERVICE"; fi
    rm_systemctl restart "$RM_XRAY_SERVICE"
    return 0
  fi
  systemctl daemon-reload
  if [[ $enable == true ]]; then systemctl enable "$RM_XRAY_SERVICE" >/dev/null; else systemctl disable "$RM_XRAY_SERVICE" >/dev/null; fi
  systemctl restart "$RM_XRAY_SERVICE"
  systemctl is-active --quiet "$RM_XRAY_SERVICE"
}

xray_service_stop_if_unused() {
  state_init >/dev/null
  local n; n=$(jq '[.nodes[]|select((.enabled//true)==true)]|length' "$RM_STATE_FILE")
  if ((n==0)); then rm_systemctl stop "$RM_XRAY_SERVICE" || true; fi
}
