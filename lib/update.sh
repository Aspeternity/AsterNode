#!/usr/bin/env bash
# Manager/core update and rollback. No update is performed implicitly at startup.
# shellcheck source=lib/backup.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/backup.sh"

RM_INSTALL_BASE="$(rm_path /usr/local/lib/relay-manager)"
RM_VERSION_BASE="$RM_INSTALL_BASE/versions"
RM_MANAGER_CURRENT="$RM_INSTALL_BASE/current"
RM_BIN_LINK="$(rm_path /usr/local/bin/relay-manager)"
RM_TRUSTED_RELEASE_KEY="${RM_TRUSTED_RELEASE_KEY:-$(rm_path /etc/relay-manager/trusted-release.pem)}"
RM_MANAGER_PACKAGE_MAX_BYTES=${RM_MANAGER_PACKAGE_MAX_BYTES:-67108864}
RM_MANAGER_PACKAGE_MAX_UNPACKED_BYTES=${RM_MANAGER_PACKAGE_MAX_UNPACKED_BYTES:-134217728}
RM_MANAGER_PACKAGE_MAX_ENTRIES=${RM_MANAGER_PACKAGE_MAX_ENTRIES:-2000}

update_validate_release_version() {
  local v=$1
  [[ $v =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]]
}

update_validate_public_key() {
  local key=$1
  [[ -f $key && ! -L $key ]] || { rm_error '发行公钥必须是普通文件'; return "$RM_RC_PRECONDITION"; }
  openssl pkey -pubin -in "$key" -noout >/dev/null 2>&1 || {
    rm_error '发行公钥格式无效'
    return "$RM_RC_PRECONDITION"
  }
}

update_install_trusted_key() {
  local key=$1 current_sha new_sha dir
  rm_require_root || return $?
  update_validate_public_key "$key" || return $?
  new_sha=$(rm_sha256_file "$key")
  dir=$(dirname "$RM_TRUSTED_RELEASE_KEY")
  rm_mkdir_secure 0700 "$dir" || return $?

  if [[ -e $RM_TRUSTED_RELEASE_KEY || -L $RM_TRUSTED_RELEASE_KEY ]]; then
    [[ -f $RM_TRUSTED_RELEASE_KEY && ! -L $RM_TRUSTED_RELEASE_KEY ]] || {
      rm_error '受信发行公钥路径不是普通文件'
      return "$RM_RC_PRECONDITION"
    }
    current_sha=$(rm_sha256_file "$RM_TRUSTED_RELEASE_KEY")
    if [[ $current_sha != "$new_sha" ]]; then
      rm_error '已存在不同的受信发行公钥；密钥轮换必须走单独的受控流程'
      return "$RM_RC_PRECONDITION"
    fi
    chmod 0644 "$RM_TRUSTED_RELEASE_KEY"
    [[ ${RM_TEST_MODE} == 1 ]] || chown root:root "$RM_TRUSTED_RELEASE_KEY"
    return 0
  fi

  rm_atomic_write "$key" "$RM_TRUSTED_RELEASE_KEY" 0644 root:root
}

update_safe_tar_list() {
  local package=$1 size list count entry clean top='' this_top dup unpacked
  [[ -f $package && ! -L $package ]] || { rm_error '管理器发行包必须是普通文件'; return "$RM_RC_PRECONDITION"; }
  size=$(stat -c '%s' "$package")
  ((size>0 && size<=RM_MANAGER_PACKAGE_MAX_BYTES)) || {
    rm_error "管理器发行包大小超出限制: $size"
    return "$RM_RC_PRECONDITION"
  }
  list=$(tar -tzf "$package") || { rm_error '无法读取管理器发行包'; return "$RM_RC_PRECONDITION"; }
  count=$(printf '%s\n' "$list" | awk 'NF{c++} END{print c+0}')
  ((count>0 && count<=RM_MANAGER_PACKAGE_MAX_ENTRIES)) || {
    rm_error "发行包条目数量异常: $count"
    return "$RM_RC_PRECONDITION"
  }
  dup=$(printf '%s\n' "$list" | sed '/^$/d' | sort | uniq -d | head -n1)
  [[ -z $dup ]] || { rm_error "发行包包含重复路径: $dup"; return "$RM_RC_PRECONDITION"; }

  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    clean=${entry#./}; clean=${clean%/}
    [[ -n $clean ]] || { rm_error '发行包包含空根路径'; return "$RM_RC_PRECONDITION"; }
    [[ $clean != /* && $clean != ../* && $clean != *'/../'* && $clean != *'/..' &&
       $clean != *$'\n'* && $clean != *$'\r'* && $clean != *$'\t'* && $clean != *'\\'* ]] || {
      rm_error "发行包包含危险路径: $entry"
      return "$RM_RC_PRECONDITION"
    }
    this_top=${clean%%/*}
    if [[ -z $top ]]; then top=$this_top
    elif [[ $this_top != "$top" ]]; then
      rm_error "发行包必须只有一个顶层目录: $top / $this_top"
      return "$RM_RC_PRECONDITION"
    fi
  done <<<"$list"
  [[ $top =~ ^relay-manager-[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] || {
    rm_error "发行包顶层目录名称无效: $top"
    return "$RM_RC_PRECONDITION"
  }

  if tar -tvzf "$package" | awk '$1 !~ /^[-d]/ {bad=1} END{exit bad?0:1}'; then
    rm_error '发行包包含符号链接、硬链接、设备或其他特殊条目'
    return "$RM_RC_PRECONDITION"
  fi
  unpacked=$(tar -tvzf "$package" | awk '$1 ~ /^-/ {s+=$3} END{printf "%.0f\n",s+0}')
  ((unpacked<=RM_MANAGER_PACKAGE_MAX_UNPACKED_BYTES)) || {
    rm_error "发行包解压后大小超出限制: $unpacked"
    return "$RM_RC_PRECONDITION"
  }
  printf '%s\n' "$top"
}

update_manifest_path_valid() {
  local p=$1
  [[ -n $p && $p != /* && $p != . && $p != .. && $p != ../* && $p != *'/../'* &&
     $p != *'/..' && $p != *'//' && $p != *$'\n'* && $p != *$'\r'* && $p != *$'\t'* && $p != *'\\'* ]]
}

update_verify_release_dir() {
  local dir=$1 key=${2:-$RM_TRUSTED_RELEASE_KEY}
  local manifest sums sig
  local version expected_root count i p file sha size mode actual_sha actual_size actual_mode tmp_expected tmp_sums expected_count actual_count
  manifest="$dir/MANIFEST.json"
  sums="$dir/SHA256SUMS"
  sig="$dir/RELEASE.sig"
  [[ -d $dir && ! -L $dir ]] || return "$RM_RC_PRECONDITION"
  [[ -f $manifest && ! -L $manifest && -f $sums && ! -L $sums && -f $sig && ! -L $sig ]] || {
    rm_error '发行包缺少普通 manifest/checksum/signature 文件'
    return "$RM_RC_PRECONDITION"
  }
  update_validate_public_key "$key" || return $?
  if find "$dir" -type l -print -quit | grep -q .; then
    rm_error '发行目录包含符号链接'
    return "$RM_RC_PRECONDITION"
  fi

  openssl dgst -sha256 -verify "$key" -signature "$sig" "$sums" >/dev/null 2>&1 || {
    rm_error '发行包签名验证失败'
    return "$RM_RC_PRECONDITION"
  }

  jq -e --argjson schema "$RM_SCHEMA_VERSION" '
    .release_format==1 and
    .project=="relay-manager" and .product=="AsterNode" and
    (.version|type=="string" and length>0) and
    (.commit_sha|type=="string" and test("^[0-9a-f]{40}$")) and
    (.prerelease|type=="boolean") and
    (.built_at|type=="string" and length>0) and
    (.state_schema==$schema) and
    (.compatibility_document=="docs/COMPATIBILITY.md") and
    (.supported.systems|type=="array" and length>0) and
    (.supported.architectures|type=="array" and length>0) and
    (.default_core_version|type=="string" and length>0) and
    (.client_profiles|type=="array") and
    (.files|type=="array" and length>0) and
    ([.files[] |
      (.path|type=="string" and length>0) and
      (.sha256|type=="string" and test("^[0-9a-f]{64}$")) and
      (.size|type=="number" and .>=0 and .==floor) and
      (.mode|type=="string" and test("^[0-7]{3,4}$"))
    ] | all) and
    (([.files[].path]|length)==([.files[].path]|unique|length))
  ' "$manifest" >/dev/null || {
    rm_error 'MANIFEST.json 结构或当前 schema 兼容性无效'
    return "$RM_RC_PRECONDITION"
  }

  version=$(jq -r .version "$manifest")
  update_validate_release_version "$version" || return "$RM_RC_PRECONDITION"
  expected_root="relay-manager-$version"
  [[ $(basename "$dir") == "$expected_root" ]] || {
    rm_error '发行包目录名与 manifest version 不一致'
    return "$RM_RC_PRECONDITION"
  }
  [[ -f $dir/VERSION && ! -L $dir/VERSION && $(cat "$dir/VERSION") == "$version" ]] || {
    rm_error 'VERSION 与发行 manifest 不一致'
    return "$RM_RC_PRECONDITION"
  }
  if [[ $version == *-* ]]; then
    jq -e '.prerelease==true' "$manifest" >/dev/null || { rm_error '预发布版本标记不一致'; return "$RM_RC_PRECONDITION"; }
  else
    jq -e '.prerelease==false' "$manifest" >/dev/null || { rm_error '稳定版本标记不一致'; return "$RM_RC_PRECONDITION"; }
  fi

  count=$(jq '.files|length' "$manifest")
  for ((i=0;i<count;i++)); do
    p=$(jq -er ".files[$i].path" "$manifest") || return "$RM_RC_PRECONDITION"
    update_manifest_path_valid "$p" || { rm_error "manifest 包含危险路径: $p"; return "$RM_RC_PRECONDITION"; }
    case "$p" in MANIFEST.json|SHA256SUMS|RELEASE.sig) rm_error "manifest 不得把发行元数据列为 payload: $p"; return "$RM_RC_PRECONDITION";; esac
    file="$dir/$p"
    [[ -f $file && ! -L $file ]] || { rm_error "manifest 文件不存在或类型异常: $p"; return "$RM_RC_PRECONDITION"; }
    sha=$(jq -r ".files[$i].sha256" "$manifest")
    size=$(jq -r ".files[$i].size" "$manifest")
    mode=$(jq -r ".files[$i].mode" "$manifest")
    actual_sha=$(rm_sha256_file "$file"); actual_size=$(stat -c '%s' "$file"); actual_mode=$(stat -c '%a' "$file")
    [[ $actual_sha == "$sha" && $actual_size == "$size" && $actual_mode == "$mode" ]] || {
      rm_error "manifest 元数据不匹配: $p"
      return "$RM_RC_PRECONDITION"
    }
  done

  tmp_expected=$(mktemp); tmp_sums=$(mktemp)
  {
    printf './MANIFEST.json\n'
    jq -r '.files[].path | "./"+.' "$manifest"
  } | sort >"$tmp_expected"
  while IFS= read -r line; do
    [[ $line =~ ^[0-9a-fA-F]{64}[[:space:]][[:space:]](.+)$ ]] || {
      rm -f "$tmp_expected" "$tmp_sums"; rm_error 'SHA256SUMS 行格式无效'; return "$RM_RC_PRECONDITION";
    }
    p=${BASH_REMATCH[1]}
    update_manifest_path_valid "${p#./}" || {
      rm -f "$tmp_expected" "$tmp_sums"; rm_error "SHA256SUMS 包含危险路径: $p"; return "$RM_RC_PRECONDITION";
    }
    printf '%s\n' "$p"
  done <"$sums" | sort >"$tmp_sums"
  expected_count=$(wc -l <"$tmp_expected"); actual_count=$(wc -l <"$tmp_sums")
  if [[ $expected_count != "$actual_count" ]] || ! cmp -s "$tmp_expected" "$tmp_sums"; then
    rm -f "$tmp_expected" "$tmp_sums"
    rm_error 'SHA256SUMS 与 manifest 文件集合不一致'
    return "$RM_RC_PRECONDITION"
  fi
  rm -f "$tmp_expected" "$tmp_sums"
  (cd "$dir" && sha256sum -c SHA256SUMS >/dev/null) || {
    rm_error '发行包文件校验失败'
    return "$RM_RC_PRECONDITION"
  }

  tmp_expected=$(mktemp); tmp_sums=$(mktemp)
  jq -r '.files[].path' "$manifest" | sort >"$tmp_expected"
  find "$dir" -type f -printf '%P\n' | grep -Ev '^(MANIFEST\.json|SHA256SUMS|RELEASE\.sig)$' | sort >"$tmp_sums"
  if ! cmp -s "$tmp_expected" "$tmp_sums"; then
    rm -f "$tmp_expected" "$tmp_sums"
    rm_error '发行包存在未声明或缺失的 payload 文件'
    return "$RM_RC_PRECONDITION"
  fi
  rm -f "$tmp_expected" "$tmp_sums"
}

update_require_space() {
  local path=$1 required=$2 parent available
  parent=$path
  while [[ ! -e $parent && $parent != / ]]; do parent=$(dirname "$parent"); done
  available=$(df -PB1 "$parent" | awk 'NR==2{print $4}')
  [[ $available =~ ^[0-9]+$ ]] || return "$RM_RC_PRECONDITION"
  ((available>=required)) || {
    rm_error "空间不足：需要至少 $required 字节，可用 $available 字节"
    return "$RM_RC_PRECONDITION"
  }
}

update_current_managed_version_path() {
  local resolved
  if [[ ! -e $RM_MANAGER_CURRENT && ! -L $RM_MANAGER_CURRENT ]]; then
    printf '\n'
    return 0
  fi
  [[ -L $RM_MANAGER_CURRENT ]] || {
    rm_error '当前管理器路径已存在但不是 AsterNode 受管符号链接'
    return "$RM_RC_PRECONDITION"
  }
  resolved=$(readlink -f "$RM_MANAGER_CURRENT" 2>/dev/null || true)
  [[ -n $resolved && $resolved == "$RM_VERSION_BASE"/* && -d $resolved && ! -L $resolved ]] || {
    rm_error '当前管理器链接不在受管版本目录，拒绝自动切换'
    return "$RM_RC_PRECONDITION"
  }
  printf '%s\n' "$resolved"
}

update_validate_bin_link() {
  local expected_current=${1:-} resolved expected_bin literal expected_literal
  if [[ ! -e $RM_BIN_LINK && ! -L $RM_BIN_LINK ]]; then return 0; fi
  [[ -L $RM_BIN_LINK ]] || {
    rm_error 'relay-manager 命令路径已存在且不属于受管符号链接，拒绝覆盖'
    return "$RM_RC_PRECONDITION"
  }
  [[ -n $expected_current ]] || {
    rm_error '发现已有 relay-manager 命令，但没有受管 current 版本，拒绝覆盖'
    return "$RM_RC_PRECONDITION"
  }
  literal=$(readlink "$RM_BIN_LINK" 2>/dev/null || true)
  expected_literal="$RM_MANAGER_CURRENT/relay-manager.sh"
  resolved=$(readlink -f "$RM_BIN_LINK" 2>/dev/null || true)
  expected_bin="$expected_current/relay-manager.sh"
  [[ $literal == "$expected_literal" && -n $resolved && $resolved == "$expected_bin" ]] || {
    rm_error 'relay-manager 命令链接与当前受管版本不一致，拒绝覆盖'
    return "$RM_RC_PRECONDITION"
  }
}

update_run_release_smoke() {
  local dir=$1 out rc=0
  [[ -x $dir/tests/release_smoke.sh ]] || {
    rm_error '发行包缺少可执行 release smoke'
    return "$RM_RC_PRECONDITION"
  }
  set +e
  out=$("$dir/tests/release_smoke.sh" 2>&1)
  rc=$?
  set -e
  if ((rc)); then
    rm_error "发行自检失败: ${out:0:1200}"
    return "$RM_RC_PRECONDITION"
  fi
}

update_restore_manager_links() {
  local previous=${1:-} remove_bin=${2:-false}
  if [[ -n $previous && -d $previous && ! -L $previous ]]; then
    ln -sfn "$previous" "$RM_MANAGER_CURRENT.tmp" || return "$RM_RC_RECOVERY_INCOMPLETE"
    mv -Tf "$RM_MANAGER_CURRENT.tmp" "$RM_MANAGER_CURRENT" || return "$RM_RC_RECOVERY_INCOMPLETE"
  else
    rm -f "$RM_MANAGER_CURRENT.tmp" "$RM_MANAGER_CURRENT"
  fi
  if [[ $remove_bin == true ]]; then
    rm -f "$RM_BIN_LINK.tmp" "$RM_BIN_LINK"
  fi
}

update_switch_manager_links() {
  local dest=$1 previous=${2:-} bin_preexisting=${3:-false}
  [[ -d $dest && ! -L $dest && -x $dest/relay-manager.sh ]] || return "$RM_RC_PRECONDITION"

  ln -sfn "$dest" "$RM_MANAGER_CURRENT.tmp" || return "$RM_RC_INTERNAL"
  if ! mv -Tf "$RM_MANAGER_CURRENT.tmp" "$RM_MANAGER_CURRENT"; then
    rm -f "$RM_MANAGER_CURRENT.tmp"
    return "$RM_RC_INTERNAL"
  fi

  if [[ $bin_preexisting == false ]]; then
    if ! ln -s "$RM_MANAGER_CURRENT/relay-manager.sh" "$RM_BIN_LINK.tmp" ||
       ! mv -Tf "$RM_BIN_LINK.tmp" "$RM_BIN_LINK"; then
      rm -f "$RM_BIN_LINK.tmp"
      update_restore_manager_links "$previous" true || true
      return "$RM_RC_APPLY_ROLLED_BACK"
    fi
  fi

  if [[ $(readlink -f "$RM_MANAGER_CURRENT" 2>/dev/null || true) != "$dest" ||
        $(readlink -f "$RM_BIN_LINK" 2>/dev/null || true) != "$dest/relay-manager.sh" ]]; then
    update_restore_manager_links "$previous" "$([[ $bin_preexisting == false ]] && printf true || printf false)" || true
    rm_error '管理器版本切换后链接校验失败'
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi
}

update_install_manager_package() {
  local package=$1 expected_sha=${2:-} explicit_key=${3:-} verify_key top tmpdir extract root manifest version dest previous copied=false
  local required package_size root_size current_after state_rc=0 bin_preexisting=false
  rm_require_root || return $?
  [[ -f $package && ! -L $package ]] || return "$RM_RC_PRECONDITION"

  if [[ -n $expected_sha ]]; then
    [[ $expected_sha =~ ^[0-9a-fA-F]{64}$ ]] || return "$RM_RC_PRECONDITION"
    if [[ $(rm_sha256_file "$package") != "${expected_sha,,}" ]]; then
      rm_error '安装包 SHA-256 不匹配'
      return "$RM_RC_PRECONDITION"
    fi
  fi

  verify_key=${explicit_key:-$RM_TRUSTED_RELEASE_KEY}
  if [[ -n $explicit_key ]]; then
    update_validate_public_key "$explicit_key" || return $?
    if [[ -e $RM_TRUSTED_RELEASE_KEY || -L $RM_TRUSTED_RELEASE_KEY ]]; then
      [[ -f $RM_TRUSTED_RELEASE_KEY && ! -L $RM_TRUSTED_RELEASE_KEY ]] || return "$RM_RC_PRECONDITION"
      [[ $(rm_sha256_file "$RM_TRUSTED_RELEASE_KEY") == $(rm_sha256_file "$explicit_key") ]] || {
        rm_error '显式发行公钥与已固定受信公钥不一致'
        return "$RM_RC_PRECONDITION"
      }
    fi
  else
    update_validate_public_key "$RM_TRUSTED_RELEASE_KEY" || {
      rm_error '未配置有效的受信发行公钥，拒绝安装'
      return "$RM_RC_PRECONDITION"
    }
  fi

  top=$(update_safe_tar_list "$package") || return $?
  tmpdir=$(rm_safe_tmpdir); extract="$tmpdir/extract"; mkdir "$extract"
  tar -xzf "$package" -C "$extract" || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  root="$extract/$top"
  update_verify_release_dir "$root" "$verify_key" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  manifest="$root/MANIFEST.json"
  version=$(jq -r .version "$manifest")
  dest="$RM_VERSION_BASE/$version"

  if tx_has_conflict; then
    rm_error '有未完成安全事务，禁止更新管理器'
    rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"
  fi

  package_size=$(stat -c '%s' "$package")
  root_size=$(du -sb "$root" | awk '{print $1}')
  required=$((package_size + root_size * 2 + 1048576))
  update_require_space "$RM_VERSION_BASE" "$required" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }

  install -d -m 0755 "$RM_VERSION_BASE" "$(dirname "$RM_BIN_LINK")"
  previous=$(update_current_managed_version_path) || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  update_validate_bin_link "$previous" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  [[ -e $RM_BIN_LINK || -L $RM_BIN_LINK ]] && bin_preexisting=true

  if [[ -e $dest ]]; then
    if [[ ! -d $dest || -L $dest ]]; then
      rm_error "版本目标已存在且类型异常: $dest"
      rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"
    fi
    update_verify_release_dir "$dest" "$verify_key" || {
      rm_error '同版本目录已存在但不是可验证的相同发行内容'
      rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"
    }
    if [[ $(rm_sha256_file "$dest/MANIFEST.json") != $(rm_sha256_file "$manifest") ]]; then
      rm_error '同版本目录对应不同发行 manifest，拒绝覆盖'
      rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"
    fi
  else
    cp -a "$root" "$dest"
    copied=true
    [[ ${RM_TEST_MODE} == 1 ]] || chown -R root:root "$dest"
  fi

  if ! update_run_release_smoke "$dest"; then
    [[ $copied == true ]] && rm -rf "$dest"
    rm -rf "$tmpdir"
    return "$RM_RC_PRECONDITION"
  fi

  if [[ -n $explicit_key ]]; then
    if ! update_install_trusted_key "$explicit_key"; then
      local rc=$?
      [[ $copied == true ]] && rm -rf "$dest"
      rm -rf "$tmpdir"
      return "$rc"
    fi
  fi

  # Reinstalling the exact current version is a no-op for the rollback pointer.
  if [[ -n $previous && $previous == "$dest" ]]; then
    state_init >/dev/null || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
    state_update_filter '.manager_version=$v' --arg v "$version" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
    rm -rf "$tmpdir"
    jq -n --arg version "$version" --arg path "$dest"       '{status:"already_installed",version:$version,current_path:$path,previous_path_preserved:true}'
    return 0
  fi

  if ! update_switch_manager_links "$dest" "$previous" "$bin_preexisting"; then
    local rc=$?
    [[ $copied == true ]] && rm -rf "$dest"
    rm -rf "$tmpdir"
    return "$rc"
  fi

  state_rc=0
  state_init >/dev/null || state_rc=$?
  if ((state_rc==0)); then
    state_update_filter '.manager_version=$v | .previous_manager_path=$prev' --arg v "$version" --arg prev "$previous" || state_rc=$?
  fi
  if ((state_rc!=0)); then
    rm_error '管理器状态更新失败，恢复上一版本链接'
    if ! update_restore_manager_links "$previous" "$([[ $bin_preexisting == false ]] && printf true || printf false)"; then
      [[ $copied == true ]] && rm -rf "$dest"
      rm -rf "$tmpdir"
      return "$RM_RC_RECOVERY_INCOMPLETE"
    fi
    [[ $copied == true ]] && rm -rf "$dest"
    rm -rf "$tmpdir"
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi

  current_after=$(readlink -f "$RM_MANAGER_CURRENT" 2>/dev/null || true)
  [[ $current_after == "$dest" ]] || {
    rm_error '状态提交后 current 链接异常'
    rm -rf "$tmpdir"
    return "$RM_RC_RECOVERY_INCOMPLETE"
  }
  rm -rf "$tmpdir"
  jq -n --arg version "$version" --arg path "$current_after" --arg prev "$previous"     '{status:"installed",version:$version,current_path:$path,previous_path:(if $prev=="" then null else $prev end)}'
}

update_manager_rollback() {
  rm_require_root || return $?
  state_init >/dev/null || return $?
  tx_has_conflict && { rm_error '有未完成安全事务，禁止回退'; return "$RM_RC_PRECONDITION"; }
  local prev current prev_real state_rc=0
  prev=$(jq -r '.previous_manager_path//empty' "$RM_STATE_FILE")
  [[ -n $prev && -d $prev && ! -L $prev && -x $prev/relay-manager.sh ]] || {
    rm_error '没有可恢复的上一管理器版本'
    return "$RM_RC_PRECONDITION"
  }
  prev_real=$(readlink -f "$prev")
  [[ $prev_real == "$RM_VERSION_BASE"/* ]] || {
    rm_error '上一管理器版本不属于受管版本目录'
    return "$RM_RC_PRECONDITION"
  }
  update_verify_release_dir "$prev_real" "$RM_TRUSTED_RELEASE_KEY" || {
    rm_error '上一管理器版本发行完整性校验失败'
    return "$RM_RC_PRECONDITION"
  }
  update_run_release_smoke "$prev_real" || return $?

  current=$(update_current_managed_version_path) || return $?
  update_validate_bin_link "$current" || return $?
  [[ -n $current ]] || { rm_error '当前没有可回退的受管管理器版本'; return "$RM_RC_PRECONDITION"; }

  update_switch_manager_links "$prev_real" "$current" true || return $?

  state_update_filter '.previous_manager_path=$current | .manager_version=$v' --arg current "$current" --arg v "$(basename "$prev_real")" || state_rc=$?
  if ((state_rc!=0)); then
    rm_error '回退状态更新失败，恢复原管理器链接'
    update_restore_manager_links "$current" false || return "$RM_RC_RECOVERY_INCOMPLETE"
    return "$RM_RC_APPLY_ROLLED_BACK"
  fi
  jq -n --arg path "$prev_real" --arg previous "$current"     '{status:"rolled_back",current_path:$path,previous_path:$previous}'
}

update_core_to() {
  local version=$1 old backup rc=0
  state_init >/dev/null; tx_has_conflict && { rm_error '有未完成事务，禁止核心更新'; return "$RM_RC_PRECONDITION"; }
  jq -e --arg v "$version" '.core.xray[$v] != null and .core.xray[$v].channel=="stable"' "$RM_COMPAT_FILE" >/dev/null || {
    rm_error '目标核心不在稳定兼容矩阵'
    return "$RM_RC_PRECONDITION"
  }
  old=$(jq -r '.core_version//empty' "$RM_STATE_FILE")
  backup=$(backup_create upgrade) || return $?
  xray_core_install "$version" || return $?
  if [[ -f $RM_XRAY_CONFIG ]]; then
    if ! xray_test_config "$RM_XRAY_CONFIG" "$(xray_path_for_version "$version")"; then rc=$RM_RC_PRECONDITION; fi
    if ((rc==0)) && ! xray_service_enable_start true; then rc=$RM_RC_APPLY_ROLLED_BACK; fi
  fi
  if ((rc)); then
    rm_error "新核心验证/启动失败，尝试恢复 $old"
    if [[ -n $old && -x $(xray_path_for_version "$old") ]]; then
      ln -sfn "$RM_CORE_BASE/$old" "$RM_CORE_CURRENT.tmp"; mv -Tf "$RM_CORE_CURRENT.tmp" "$RM_CORE_CURRENT"
      state_update_filter '.core_version=$v' --arg v "$old"
      xray_service_enable_start true || true
    fi
    return "$rc"
  fi
  jq -n --arg version "$version" --arg backup "$backup"     '{status:"updated",core_version:$version,rollback_backup:$backup,line_end_to_end:"unverified",note:"本机配置/服务通过不代表所有线路客户端兼容；核心切换会重启共享 Xray 进程。"}'
}
