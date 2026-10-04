#!/usr/bin/env bash
# Transaction engine for managed file changes. Implements the Stage-A TX-01..TX-07 foundation.
# shellcheck source=lib/state.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/state.sh"

RM_TX_DIR="$RM_VAR_DIR/transactions"
RM_TX_SNAPSHOT_DIR="$RM_VAR_DIR/snapshots"

_tx_rand() {
  printf '%s' "$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
}

_tx_boot_id() {
  cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf 'unknown\n'
}

tx_init_dirs() {
  state_init_dirs || return $?
  rm_mkdir_secure 0700 "$RM_TX_DIR" || return $?
  rm_mkdir_secure 0700 "$RM_TX_SNAPSHOT_DIR" || return $?
}

tx_lock_acquire() {
  tx_init_dirs || return $?
  rm_require_cmds flock || return $?
  # shellcheck disable=SC3045
  exec {RM_TX_LOCK_FD}>"$RM_LOCK_FILE" || return "$RM_RC_INTERNAL"
  flock -x "$RM_TX_LOCK_FD" || return "$RM_RC_INTERNAL"
}

tx_lock_release() {
  if [[ -n ${RM_TX_LOCK_FD:-} ]]; then
    flock -u "$RM_TX_LOCK_FD" 2>/dev/null || true
    # shellcheck disable=SC3045
    exec {RM_TX_LOCK_FD}>&- || true
    unset RM_TX_LOCK_FD
  fi
}

tx_file() { printf '%s/%s/transaction.json\n' "$RM_TX_DIR" "$1"; }
tx_dir() { printf '%s/%s\n' "$RM_TX_DIR" "$1"; }

tx_update() {
  local id=$1 filter=$2; shift 2
  local f tmp
  f=$(tx_file "$id")
  [[ -f $f && ! -L $f ]] || return "$RM_RC_PRECONDITION"
  tmp=$(mktemp "$(dirname "$f")/.tx.XXXXXX") || return "$RM_RC_INTERNAL"
  if ! jq "$@" --arg now "$(rm_now)" "($filter) | .updated_at=\$now" "$f" >"$tmp"; then
    rm -f -- "$tmp"
    return "$RM_RC_PRECONDITION"
  fi
  jq -e '.transaction_id|type=="string"' "$tmp" >/dev/null || { rm -f -- "$tmp"; return "$RM_RC_PRECONDITION"; }
  rm_atomic_write "$tmp" "$f" 0600 root:root || { local rc=$?; rm -f -- "$tmp"; return "$rc"; }
  rm -f -- "$tmp"
}

tx_has_conflict() {
  [[ -d $RM_TX_DIR ]] || return 1
  local f status
  for f in "$RM_TX_DIR"/*/transaction.json; do
    [[ -f $f ]] || continue
    status=$(jq -r '.status // "UNKNOWN"' "$f" 2>/dev/null || printf UNKNOWN)
    case "$status" in
      PREPARED|APPLIED_PENDING|ROLLING_BACK|NEEDS_RECOVERY) return 0 ;;
    esac
  done
  return 1
}

tx_begin() {
  local type=${1:?type required} deadline=${2:-null}
  [[ -n $type && ${#type} -le 128 && $type != *$'\n'* && $type != *$'\r'* ]] || return "$RM_RC_PRECONDITION"
  if [[ $deadline != null && -n $deadline ]]; then
    [[ $deadline =~ ^[0-9]+$ ]] || return "$RM_RC_PRECONDITION"
  fi

  tx_lock_acquire || return $?
  if tx_has_conflict; then
    rm_error '存在未完成事务，必须先恢复或完成。'
    tx_lock_release
    return "$RM_RC_PRECONDITION"
  fi

  local id dir f now boot
  id=$(_tx_rand); dir=$(tx_dir "$id"); f=$(tx_file "$id"); now=$(rm_now); boot=$(_tx_boot_id)
  install -d -m 0700 -- "$dir" "$dir/snapshots" "$dir/staged"
  if [[ $deadline == null || -z $deadline ]]; then
    jq -n --arg id "$id" --arg type "$type" --arg now "$now" --arg manager "$RM_MANAGER_VERSION" --arg boot "$boot" --argjson pid "$$" \
      '{transaction_id:$id,type:$type,status:"PREPARED",manager_version:$manager,created_at:$now,updated_at:$now,
        creator_pid:$pid,boot_id:$boot,deadline_epoch:null,files:[],services:[],failure_reason:null,recovery_notes:[]}' >"$f"
  else
    jq -n --arg id "$id" --arg type "$type" --arg now "$now" --arg manager "$RM_MANAGER_VERSION" --arg boot "$boot" --argjson pid "$$" --argjson deadline "$deadline" \
      '{transaction_id:$id,type:$type,status:"PREPARED",manager_version:$manager,created_at:$now,updated_at:$now,
        creator_pid:$pid,boot_id:$boot,deadline_epoch:$deadline,files:[],services:[],failure_reason:null,recovery_notes:[]}' >"$f"
  fi
  chmod 0600 -- "$f"
  sync "$f" 2>/dev/null || true
  sync "$dir" 2>/dev/null || true
  tx_lock_release
  printf '%s\n' "$id"
}

tx_validate_destination() {
  local dest=${1:?destination required} logical base current part
  [[ $dest == /* && $dest != *$'\n'* && $dest != *$'\r'* && $dest != *$'\t'* ]] || return "$RM_RC_PRECONDITION"
  [[ $dest != *'/../'* && $dest != */.. && $dest != *'//'* ]] || return "$RM_RC_PRECONDITION"

  if [[ -n $RM_ROOT ]]; then
    base=${RM_ROOT%/}
    [[ $dest == "$base"/* ]] || { rm_error "事务目标逃逸 RM_ROOT: $dest"; return "$RM_RC_PRECONDITION"; }
    logical=${dest#"$base"}
  else
    logical=$dest
  fi

  case "$logical" in
    /etc/relay-manager/*|/etc/relay-manager-xray/*|/etc/ssh/sshd_config.d/00-relay-manager.conf|/etc/systemd/system/relay-manager-*.service|/etc/systemd/system/relay-manager-*.timer|/etc/systemd/system/ssh.socket.d/relay-manager.conf|/etc/systemd/system/ssh.socket.d/relay-manager-guard.conf|/etc/systemd/system/ssh.service.d/relay-manager-guard.conf|/etc/systemd/system/sshd.service.d/relay-manager-guard.conf|/etc/fail2ban/jail.d/relay-manager-*.local|/usr/local/lib/relay-manager/*|/usr/local/bin/relay-manager|/root/.ssh/authorized_keys) ;;
    /etc/ssh/authorized_keys/*)
      [[ $logical =~ ^/etc/ssh/authorized_keys/[^/]+$ ]] || { rm_error "事务拒绝过宽 AuthorizedKeys 路径: $logical"; return "$RM_RC_PRECONDITION"; }
      ;;
    /home/*/.ssh/authorized_keys)
      [[ $logical =~ ^/home/[^/]+/\.ssh/authorized_keys$ ]] || { rm_error "事务拒绝过宽用户公钥路径: $logical"; return "$RM_RC_PRECONDITION"; }
      ;;
    *) rm_error "事务拒绝未受管路径: $logical"; return "$RM_RC_PRECONDITION" ;;
  esac

  # Reject symbolic links in every existing path component, not only the leaf.
  current=/
  if [[ -n $RM_ROOT ]]; then current=${RM_ROOT%/}; fi
  local -a parts=()
  IFS=/ read -r -a parts <<<"${logical#/}"
  for part in "${parts[@]}"; do
    [[ -n $part ]] || continue
    if [[ $current == / ]]; then current="/$part"; else current="$current/$part"; fi
    if [[ -L $current ]]; then
      rm_error "事务路径包含符号链接: $logical"
      return "$RM_RC_PRECONDITION"
    fi
    [[ -e $current ]] || break
  done
  if [[ -e $dest && ! -f $dest ]]; then
    rm_error "事务目标不是普通文件: $logical"
    return "$RM_RC_PRECONDITION"
  fi
}

tx_snapshot_file() {
  local id=$1 dest=$2 f dir idx snap existed=false sha='' mode='' uid='' gid=''
  tx_validate_destination "$dest" || return $?
  f=$(tx_file "$id"); dir=$(tx_dir "$id"); [[ -f $f ]] || return "$RM_RC_PRECONDITION"
  [[ $(jq -r '.status' "$f") == PREPARED ]] || return "$RM_RC_PRECONDITION"
  if jq -e --arg dest "$dest" '.files[]? | select(.destination==$dest)' "$f" >/dev/null; then return 0; fi

  idx=$(jq '.files|length' "$f")
  snap="$dir/snapshots/$idx.bin"
  if [[ -e $dest ]]; then
    existed=true
    sha=$(rm_sha256_file "$dest")
    mode=$(stat -c '%a' "$dest"); uid=$(stat -c '%u' "$dest"); gid=$(stat -c '%g' "$dest")
    cat -- "$dest" >"$snap" || return "$RM_RC_INTERNAL"
    chmod 0600 -- "$snap"
    sync "$snap" 2>/dev/null || true
  fi

  tx_update "$id" '.files += [{destination:$dest,existed:$existed,snapshot:$snap,old_sha256:$sha,old_mode:$mode,old_uid:$uid,old_gid:$gid,
                    staged:null,staged_sha256:null,desired_mode:null,desired_owner:null,phase:"SNAPSHOTTED",applied_sha256:null}]' \
    --arg dest "$dest" --argjson existed "$existed" --arg snap "$snap" --arg sha "$sha" --arg mode "$mode" --arg uid "$uid" --arg gid "$gid"
}

tx_stage_file() {
  local id=$1 src=$2 dest=$3 mode=${4:-0600} owner=${5:-root:root} f dir idx staged staged_sha
  [[ -f $src && ! -L $src ]] || { rm_error '候选文件必须是普通文件且不能是符号链接'; return "$RM_RC_PRECONDITION"; }
  [[ $mode =~ ^0?[0-7]{3}$ ]] || return "$RM_RC_PRECONDITION"
  [[ $owner =~ ^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$|^[0-9]+:[0-9]+$ ]] || return "$RM_RC_PRECONDITION"
  tx_snapshot_file "$id" "$dest" || return $?
  f=$(tx_file "$id"); dir=$(tx_dir "$id")
  idx=$(jq -r --arg dest "$dest" '.files|to_entries[]|select(.value.destination==$dest)|.key' "$f")
  [[ $idx =~ ^[0-9]+$ ]] || return "$RM_RC_INTERNAL"
  staged="$dir/staged/$idx.bin"
  cat -- "$src" >"$staged" || return "$RM_RC_INTERNAL"
  chmod 0600 -- "$staged"
  staged_sha=$(rm_sha256_file "$staged")
  sync "$staged" 2>/dev/null || true
  tx_update "$id" '(.files[]|select(.destination==$dest)) |= (.staged=$staged|.staged_sha256=$sha|.desired_mode=$mode|.desired_owner=$owner|.phase="STAGED")' \
    --arg dest "$dest" --arg staged "$staged" --arg sha "$staged_sha" --arg mode "$mode" --arg owner "$owner"
}

tx_record_service() {
  local id=$1 service=$2 managed_change=${3:-false} enabled=false active=false
  [[ $service =~ ^[A-Za-z0-9_.@:-]+$ ]] || return "$RM_RC_PRECONDITION"
  rm_service_is_enabled "$service" && enabled=true || true
  rm_service_is_active "$service" && active=true || true
  [[ $managed_change == true || $managed_change == false ]] || return "$RM_RC_PRECONDITION"
  tx_update "$id" '.services = ((.services + [{name:$name,was_enabled:$enabled,was_active:$active,managed_change:$changed}]) | unique_by(.name))' \
    --arg name "$service" --argjson enabled "$enabled" --argjson active "$active" --argjson changed "$managed_change"
}

tx_mark_service_changed() {
  local id=$1 service=$2
  tx_update "$id" '(.services[]|select(.name==$name)).managed_change=true' --arg name "$service"
}

_tx_dest_unchanged_since_snapshot() {
  local existed=$1 dest=$2 old_sha=$3
  if [[ $existed == true ]]; then
    [[ -f $dest && ! -L $dest ]] || return 1
    [[ $(rm_sha256_file "$dest") == "$old_sha" ]]
  else
    [[ ! -e $dest && ! -L $dest ]]
  fi
}

_tx_apply_failure_after_write() {
  local id=$1 reason=$2
  tx_update "$id" '.failure_reason=$reason' --arg reason "$reason" >/dev/null 2>&1 || true
  tx_lock_release
  if tx_rollback "$id" "$reason"; then return "$RM_RC_APPLY_ROLLED_BACK"; fi
  return "$RM_RC_RECOVERY_INCOMPLETE"
}

tx_apply() {
  local id=$1 f status count i dest existed old_sha staged staged_sha mode owner tmp sha
  tx_lock_acquire || return $?
  f=$(tx_file "$id"); [[ -f $f ]] || { tx_lock_release; return "$RM_RC_PRECONDITION"; }
  status=$(jq -r '.status' "$f")
  [[ $status == PREPARED ]] || { rm_error "事务状态不是 PREPARED: $status"; tx_lock_release; return "$RM_RC_PRECONDITION"; }

  # Recheck every destination before touching any file. This closes the confirm->apply race.
  count=$(jq '.files|length' "$f")
  for ((i=0;i<count;i++)); do
    dest=$(jq -r ".files[$i].destination" "$f"); existed=$(jq -r ".files[$i].existed" "$f"); old_sha=$(jq -r ".files[$i].old_sha256" "$f")
    if ! _tx_dest_unchanged_since_snapshot "$existed" "$dest" "$old_sha"; then
      tx_update "$id" '.failure_reason="环境在确认后发生变化；计划已过期"' >/dev/null 2>&1 || true
      tx_lock_release
      rm_error "检测到外部变化，拒绝应用: $dest"
      return "$RM_RC_PRECONDITION"
    fi
    staged=$(jq -r ".files[$i].staged // empty" "$f")
    staged_sha=$(jq -r ".files[$i].staged_sha256 // empty" "$f")
    if [[ -n $staged ]]; then
      [[ -f $staged && ! -L $staged && $(rm_sha256_file "$staged") == "$staged_sha" ]] || {
        tx_update "$id" '.failure_reason="候选文件在应用前发生变化"' >/dev/null 2>&1 || true
        tx_lock_release
        return "$RM_RC_PRECONDITION"
      }
    fi
  done

  for ((i=0;i<count;i++)); do
    f=$(tx_file "$id")
    dest=$(jq -r ".files[$i].destination" "$f"); staged=$(jq -r ".files[$i].staged // empty" "$f")
    staged_sha=$(jq -r ".files[$i].staged_sha256 // empty" "$f"); mode=$(jq -r ".files[$i].desired_mode // \"0600\"" "$f"); owner=$(jq -r ".files[$i].desired_owner // \"root:root\"" "$f")
    [[ -n $staged ]] || continue
    tx_validate_destination "$dest" || { tx_lock_release; return "$RM_RC_PRECONDITION"; }

    # Persist intent before the atomic rename. If killed immediately after mv, recovery can
    # compare the destination with staged_sha256 and still distinguish our write from drift.
    tx_update "$id" "(.files[$i].phase=\"APPLYING\")" || { tx_lock_release; return "$RM_RC_INTERNAL"; }
    mkdir -p -- "$(dirname "$dest")"
    if ! tmp=$(mktemp "$(dirname "$dest")/.rm-apply.XXXXXX"); then _tx_apply_failure_after_write "$id" '创建应用临时文件失败'; return $?; fi
    if ! cat -- "$staged" >"$tmp"; then rm -f -- "$tmp"; _tx_apply_failure_after_write "$id" '写入候选文件失败'; return $?; fi
    if ! chmod "$mode" -- "$tmp"; then rm -f -- "$tmp"; _tx_apply_failure_after_write "$id" '设置候选文件权限失败'; return $?; fi
    if [[ ${RM_TEST_MODE} != 1 && $(id -u) -eq 0 ]]; then
      if ! chown "$owner" -- "$tmp"; then rm -f -- "$tmp"; _tx_apply_failure_after_write "$id" '设置候选文件所有者失败'; return $?; fi
    fi
    if ! sync "$tmp" 2>/dev/null; then rm -f -- "$tmp"; _tx_apply_failure_after_write "$id" '候选文件落盘失败'; return $?; fi
    if ! mv -fT -- "$tmp" "$dest"; then rm -f -- "$tmp"; _tx_apply_failure_after_write "$id" '原子替换失败'; return $?; fi
    sync "$(dirname "$dest")" 2>/dev/null || true
    sha=$(rm_sha256_file "$dest")
    if [[ $sha != "$staged_sha" ]]; then _tx_apply_failure_after_write "$id" '应用后摘要不一致'; return $?; fi
    if ! tx_update "$id" "(.files[$i].applied_sha256=\$sha|.files[$i].phase=\"APPLIED\")" --arg sha "$sha"; then
      _tx_apply_failure_after_write "$id" '应用后事务日志更新失败'; return $?
    fi
  done
  tx_update "$id" '.status="APPLIED_PENDING"' || { tx_lock_release; return "$RM_RC_INTERNAL"; }
  tx_lock_release
}

tx_commit() {
  local id=$1 f status count i dest expected
  tx_lock_acquire || return $?
  f=$(tx_file "$id"); status=$(jq -r '.status // empty' "$f" 2>/dev/null || true)
  [[ $status == APPLIED_PENDING ]] || { tx_lock_release; return "$RM_RC_PRECONDITION"; }
  count=$(jq '.files|length' "$f")
  for ((i=0;i<count;i++)); do
    expected=$(jq -r ".files[$i].applied_sha256 // empty" "$f"); [[ -n $expected ]] || continue
    dest=$(jq -r ".files[$i].destination" "$f")
    if [[ ! -f $dest || -L $dest || $(rm_sha256_file "$dest") != "$expected" ]]; then
      tx_update "$id" '.status="NEEDS_RECOVERY"|.failure_reason="提交前检测到外部修改"' >/dev/null 2>&1 || true
      tx_lock_release
      return "$RM_RC_RECOVERY_INCOMPLETE"
    fi
  done
  tx_update "$id" '.status="COMMITTED"' || { tx_lock_release; return "$RM_RC_INTERNAL"; }
  tx_lock_release
}

_tx_restore_services() {
  local f=$1 count i name before_enabled before_active changed rc=0
  count=$(jq '.services|length' "$f")
  for ((i=count-1;i>=0;i--)); do
    changed=$(jq -r ".services[$i].managed_change // false" "$f")
    [[ $changed == true ]] || continue
    name=$(jq -r ".services[$i].name" "$f"); before_enabled=$(jq -r ".services[$i].was_enabled" "$f"); before_active=$(jq -r ".services[$i].was_active" "$f")
    if [[ $before_enabled == true ]]; then rm_systemctl enable "$name" >/dev/null 2>&1 || rc=1; else rm_systemctl disable "$name" >/dev/null 2>&1 || rc=1; fi
    if [[ $before_active == true ]]; then rm_systemctl start "$name" >/dev/null 2>&1 || rc=1; else rm_systemctl stop "$name" >/dev/null 2>&1 || rc=1; fi
  done
  return "$rc"
}

tx_rollback() {
  local id=$1 reason=${2:-'requested rollback'} f status count i dest existed snap old_sha staged_sha applied current_sha mode uid gid conflict=false tmp
  tx_lock_acquire || return $?
  f=$(tx_file "$id"); [[ -f $f ]] || { tx_lock_release; return "$RM_RC_PRECONDITION"; }
  status=$(jq -r '.status' "$f")
  case "$status" in
    PREPARED|APPLIED_PENDING|NEEDS_RECOVERY|ROLLING_BACK) ;;
    COMMITTED|ROLLED_BACK) tx_lock_release; return 0 ;;
    *) tx_lock_release; return "$RM_RC_PRECONDITION" ;;
  esac
  tx_update "$id" '.status="ROLLING_BACK"|.failure_reason=$reason' --arg reason "$reason" || { tx_lock_release; return "$RM_RC_INTERNAL"; }
  f=$(tx_file "$id"); count=$(jq '.files|length' "$f")

  for ((i=count-1;i>=0;i--)); do
    f=$(tx_file "$id")
    dest=$(jq -r ".files[$i].destination" "$f"); existed=$(jq -r ".files[$i].existed" "$f"); snap=$(jq -r ".files[$i].snapshot" "$f")
    old_sha=$(jq -r ".files[$i].old_sha256 // empty" "$f"); staged_sha=$(jq -r ".files[$i].staged_sha256 // empty" "$f"); applied=$(jq -r ".files[$i].applied_sha256 // empty" "$f")

    if [[ -L $dest || ( -e $dest && ! -f $dest ) ]]; then
      rm_warn "回滚发现目标类型被外部改变，保留现场: $dest"; conflict=true; continue
    fi
    current_sha=''
    [[ -f $dest ]] && current_sha=$(rm_sha256_file "$dest")

    if [[ $existed == true ]]; then
      if [[ $current_sha == "$old_sha" ]]; then
        continue
      fi
      if [[ -z $current_sha || ( $current_sha != "$applied" && $current_sha != "$staged_sha" ) ]]; then
        rm_warn "回滚发现外部修改，保留文件: $dest"; conflict=true; continue
      fi
      [[ -f $snap ]] || { rm_warn "回滚快照缺失: $dest"; conflict=true; continue; }
      mode=$(jq -r ".files[$i].old_mode" "$f"); uid=$(jq -r ".files[$i].old_uid" "$f"); gid=$(jq -r ".files[$i].old_gid" "$f")
      mkdir -p -- "$(dirname "$dest")"
      tmp=$(mktemp "$(dirname "$dest")/.rm-rollback.XXXXXX") || { conflict=true; continue; }
      if ! cat -- "$snap" >"$tmp"; then rm -f -- "$tmp"; conflict=true; continue; fi
      chmod "$mode" -- "$tmp" || { rm -f -- "$tmp"; conflict=true; continue; }
      if [[ ${RM_TEST_MODE} != 1 && $(id -u) -eq 0 ]]; then chown "$uid:$gid" -- "$tmp" || { rm -f -- "$tmp"; conflict=true; continue; }; fi
      sync "$tmp" 2>/dev/null || true
      mv -fT -- "$tmp" "$dest" || { rm -f -- "$tmp"; conflict=true; continue; }
    else
      if [[ -z $current_sha ]]; then continue; fi
      if [[ $current_sha == "$applied" || $current_sha == "$staged_sha" ]]; then
        rm -f -- "$dest" || { conflict=true; continue; }
      else
        rm_warn "回滚发现外部创建/修改，保留文件: $dest"; conflict=true
      fi
    fi
  done

  f=$(tx_file "$id")
  if ! _tx_restore_services "$f"; then
    rm_warn '服务状态未能完整恢复。'
    conflict=true
  fi

  if [[ $conflict == true ]]; then
    tx_update "$id" '.status="NEEDS_RECOVERY"|.recovery_notes += ["存在外部冲突或恢复失败；未覆盖现场"]' >/dev/null 2>&1 || true
    tx_lock_release
    return "$RM_RC_RECOVERY_INCOMPLETE"
  fi
  tx_update "$id" '.status="ROLLED_BACK"' || { tx_lock_release; return "$RM_RC_INTERNAL"; }
  tx_lock_release
}

tx_recover_pending() {
  tx_init_dirs || return $?
  local f id status rc=0 one
  for f in "$RM_TX_DIR"/*/transaction.json; do
    [[ -f $f ]] || continue
    id=$(jq -r '.transaction_id' "$f" 2>/dev/null || true); status=$(jq -r '.status' "$f" 2>/dev/null || true)
    [[ -n $id && -n $status ]] || { rm_warn "损坏的事务记录: $f"; rc=$RM_RC_RECOVERY_INCOMPLETE; continue; }
    one=0
    case "$status" in
      APPLIED_PENDING|ROLLING_BACK) tx_rollback "$id" '启动恢复未完成事务' || one=$? ;;
      NEEDS_RECOVERY) rm_warn "事务需要人工恢复: $id"; one=$RM_RC_RECOVERY_INCOMPLETE ;;
      PREPARED) tx_rollback "$id" '清理未完成/未提交事务' || one=$? ;;
    esac
    ((one==0)) || rc=$one
  done
  return "$rc"
}

tx_reconcile_pending() {
  tx_init_dirs || return $?
  local f id status deadline now rc=0 one
  now=$(rm_epoch)
  for f in "$RM_TX_DIR"/*/transaction.json; do
    [[ -f $f ]] || continue
    id=$(jq -r '.transaction_id' "$f" 2>/dev/null || true)
    status=$(jq -r '.status' "$f" 2>/dev/null || true)
    deadline=$(jq -r '.deadline_epoch // null' "$f" 2>/dev/null || printf null)
    [[ -n $id && -n $status ]] || { rm_warn "损坏的事务记录: $f"; rc=$RM_RC_RECOVERY_INCOMPLETE; continue; }
    one=0
    case "$status" in
      APPLIED_PENDING)
        if [[ $deadline =~ ^[0-9]+$ ]] && ((now < deadline)); then
          continue
        fi
        tx_rollback "$id" '周期维护发现事务确认期限已到或无有效期限' || one=$?
        ;;
      ROLLING_BACK)
        tx_rollback "$id" '周期维护继续恢复未完成回滚' || one=$?
        ;;
      NEEDS_RECOVERY)
        rm_warn "事务需要人工恢复: $id"
        one=$RM_RC_RECOVERY_INCOMPLETE
        ;;
      PREPARED)
        tx_rollback "$id" '周期维护清理未完成/未提交事务' || one=$?
        ;;
    esac
    ((one==0)) || rc=$one
  done
  return "$rc"
}

tx_diff_summary_json() {
  local id=$1 f
  f=$(tx_file "$id"); [[ -f $f ]] || return "$RM_RC_PRECONDITION"
  jq '{transaction_id,type,status,deadline_epoch,files:[.files[]|{destination,existed,old_sha256,staged_sha256,desired_mode,desired_owner,phase}],services}' "$f"
}

tx_status_json() {
  # Read-only status path: never create state/transaction directories.
  [[ -d $RM_TX_DIR && ! -L $RM_TX_DIR ]] || { printf '[]\n'; return 0; }
  local f first=true
  printf '['
  for f in "$RM_TX_DIR"/*/transaction.json; do
    [[ -f $f && ! -L $f ]] || continue
    $first || printf ','; first=false
    jq -c '{transaction_id,type,status,created_at,updated_at,deadline_epoch,failure_reason}' "$f"
  done
  printf ']\n'
}
