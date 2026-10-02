#!/usr/bin/env bash
# Manager/core update and rollback. No update is performed implicitly at startup.
# shellcheck source=lib/backup.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/backup.sh"

RM_INSTALL_BASE="$(rm_path /usr/local/lib/relay-manager)"
RM_VERSION_BASE="$RM_INSTALL_BASE/versions"
RM_MANAGER_CURRENT="$RM_INSTALL_BASE/current"
RM_BIN_LINK="$(rm_path /usr/local/bin/relay-manager)"
RM_TRUSTED_RELEASE_KEY="$(rm_path /etc/relay-manager/trusted-release.pem)"

update_safe_tar_list() {
  local tar=$1 entry
  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    [[ $entry != /* && $entry != ../* && $entry != *'/../'* && $entry != *'/..' && $entry != *$'\n'* && $entry != *$'\r'* ]] || { rm_error "包包含危险路径: $entry"; return "$RM_RC_PRECONDITION"; }
  done < <(tar -tzf "$tar")
  # Reject symlinks/hardlinks/device entries in manager package.
  if tar -tvzf "$tar" | awk '$1 !~ /^-/ && $1 !~ /^d/ {bad=1} END{exit bad?0:1}'; then rm_error '包包含链接或特殊文件'; return "$RM_RC_PRECONDITION"; fi
}

update_verify_release_dir() {
  local dir=$1
  [[ -f $dir/MANIFEST.json && -f $dir/SHA256SUMS && -f $dir/RELEASE.sig ]] || { rm_error '发行包缺少 manifest/checksum/signature'; return "$RM_RC_PRECONDITION"; }
  [[ -f $RM_TRUSTED_RELEASE_KEY ]] || { rm_error '未配置受信发行公钥，拒绝安装签名包'; return "$RM_RC_PRECONDITION"; }
  (cd "$dir" && sha256sum -c SHA256SUMS >/dev/null) || { rm_error '发行包文件校验失败'; return "$RM_RC_PRECONDITION"; }
  openssl dgst -sha256 -verify "$RM_TRUSTED_RELEASE_KEY" -signature "$dir/RELEASE.sig" "$dir/SHA256SUMS" >/dev/null 2>&1 || { rm_error '发行包签名验证失败'; return "$RM_RC_PRECONDITION"; }
  jq -e '.project=="relay-manager" and (.version|type=="string") and (.files|type=="array")' "$dir/MANIFEST.json" >/dev/null || return "$RM_RC_PRECONDITION"
}

update_install_manager_package() {
  local package=$1 expected_sha=${2:-} tmpdir extract root version dest previous
  rm_require_root || return $?
  [[ -f $package ]] || return "$RM_RC_PRECONDITION"
  if [[ -n $expected_sha && $(rm_sha256_file "$package") != "$expected_sha" ]]; then rm_error '安装包 SHA-256 不匹配'; return "$RM_RC_PRECONDITION"; fi
  update_safe_tar_list "$package" || return $?
  tmpdir=$(rm_safe_tmpdir); extract="$tmpdir/extract"; mkdir "$extract"; tar -xzf "$package" -C "$extract"
  root=$(find "$extract" -mindepth 1 -maxdepth 1 -type d -name 'relay-manager-*' | head -n1); [[ -n $root ]] || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  update_verify_release_dir "$root" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  version=$(jq -r .version "$root/MANIFEST.json"); dest="$RM_VERSION_BASE/$version"
  if tx_has_conflict; then rm_error '有未完成安全事务，禁止更新管理器'; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; fi
  install -d -m 0755 "$RM_VERSION_BASE"; [[ -d $dest ]] || cp -a "$root" "$dest"
  chown -R root:root "$dest" 2>/dev/null || true
  "$dest/tests/run.sh" --unit-only || { rm_error '新版本自测失败，未切换'; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  previous=$(readlink -f "$RM_MANAGER_CURRENT" 2>/dev/null || true)
  ln -sfn "$dest" "$RM_MANAGER_CURRENT.tmp"; mv -Tf "$RM_MANAGER_CURRENT.tmp" "$RM_MANAGER_CURRENT"
  ln -sfn "$RM_MANAGER_CURRENT/relay-manager.sh" "$RM_BIN_LINK.tmp"; mv -Tf "$RM_BIN_LINK.tmp" "$RM_BIN_LINK"
  state_init >/dev/null; state_update_filter '.manager_version=$v | .previous_manager_path=$prev' --arg v "$version" --arg prev "$previous"
  rm -rf "$tmpdir"; printf '%s\n' "$version"
}

update_manager_rollback() {
  state_init >/dev/null
  local prev; prev=$(jq -r '.previous_manager_path//empty' "$RM_STATE_FILE"); [[ -n $prev && -d $prev && -x $prev/relay-manager.sh ]] || { rm_error '没有可恢复的上一管理器版本'; return "$RM_RC_PRECONDITION"; }
  tx_has_conflict && { rm_error '有未完成安全事务，禁止回退'; return "$RM_RC_PRECONDITION"; }
  local current; current=$(readlink -f "$RM_MANAGER_CURRENT" 2>/dev/null || true)
  ln -sfn "$prev" "$RM_MANAGER_CURRENT.tmp"; mv -Tf "$RM_MANAGER_CURRENT.tmp" "$RM_MANAGER_CURRENT"
  ln -sfn "$RM_MANAGER_CURRENT/relay-manager.sh" "$RM_BIN_LINK.tmp"; mv -Tf "$RM_BIN_LINK.tmp" "$RM_BIN_LINK"
  state_update_filter '.previous_manager_path=$current | .manager_version=$v' --arg current "$current" --arg v "$(basename "$prev")"
}

update_core_to() {
  local version=$1 old backup rc=0
  state_init >/dev/null; tx_has_conflict && { rm_error '有未完成事务，禁止核心更新'; return "$RM_RC_PRECONDITION"; }
  jq -e --arg v "$version" '.core.xray[$v] != null and .core.xray[$v].channel=="stable"' "$RM_COMPAT_FILE" >/dev/null || { rm_error '目标核心不在稳定兼容矩阵'; return "$RM_RC_PRECONDITION"; }
  old=$(jq -r '.core_version//empty' "$RM_STATE_FILE"); backup=$(backup_create upgrade) || return $?
  xray_core_install "$version" || return $?
  if [[ -f $RM_XRAY_CONFIG ]]; then
    if ! xray_test_config "$RM_XRAY_CONFIG" "$(xray_path_for_version "$version")"; then rc=$RM_RC_PRECONDITION; fi
    if ((rc==0)) && ! xray_service_enable_start true; then rc=$RM_RC_APPLY_ROLLED_BACK; fi
  fi
  if ((rc)); then
    rm_error "新核心验证/启动失败，尝试恢复 $old"
    if [[ -n $old && -x $(xray_path_for_version "$old") ]]; then ln -sfn "$RM_CORE_BASE/$old" "$RM_CORE_CURRENT.tmp"; mv -Tf "$RM_CORE_CURRENT.tmp" "$RM_CORE_CURRENT"; state_update_filter '.core_version=$v' --arg v "$old"; xray_service_enable_start true || true; fi
    return "$rc"
  fi
  jq -n --arg version "$version" --arg backup "$backup" '{status:"updated",core_version:$version,rollback_backup:$backup,line_end_to_end:"unverified"}'
}
