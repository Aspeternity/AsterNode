#!/usr/bin/env bash
# Bounded, ownership-scoped maintenance for low-resource VPS installations.
# shellcheck source=lib/update.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/update.sh"
# shellcheck source=lib/export.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/export.sh"

RM_MAINT_TX_KEEP=${RM_MAINT_TX_KEEP:-30}
RM_MAINT_VERSION_MIN_AGE_SECONDS=${RM_MAINT_VERSION_MIN_AGE_SECONDS:-604800}

maintenance_dir_bytes() {
  local path=$1 value
  if [[ ! -e $path && ! -L $path ]]; then
    printf '0\n'
    return 0
  fi
  [[ -d $path && ! -L $path ]] || { printf 'null\n'; return 0; }
  value=$(du -sb -- "$path" 2>/dev/null | awk '{print $1}' || true)
  [[ $value =~ ^[0-9]+$ ]] && printf '%s\n' "$value" || printf 'null\n'
}

maintenance_direct_dir_count() {
  local path=$1 value
  if [[ ! -e $path && ! -L $path ]]; then
    printf '0\n'
    return 0
  fi
  [[ -d $path && ! -L $path ]] || { printf 'null\n'; return 0; }
  value=$(find "$path" -mindepth 1 -maxdepth 1 -type d -printf '.\n' 2>/dev/null | wc -l | tr -d ' ')
  [[ $value =~ ^[0-9]+$ ]] && printf '%s\n' "$value" || printf 'null\n'
}

maintenance_transaction_counts_json() {
  if [[ ! -e $RM_TX_DIR && ! -L $RM_TX_DIR ]]; then
    jq -n '{total:0,terminal:0,pending_recovery:0,invalid:0}'
    return 0
  fi
  [[ -d $RM_TX_DIR && ! -L $RM_TX_DIR ]] || {
    jq -n '{total:null,terminal:null,pending_recovery:null,invalid:null,path_status:"abnormal"}'
    return 0
  }

  local f status total=0 terminal=0 pending=0 invalid=0
  for f in "$RM_TX_DIR"/*/transaction.json; do
    [[ -e $f || -L $f ]] || continue
    ((total+=1))
    if [[ ! -f $f || -L $f ]]; then ((invalid+=1)); continue; fi
    status=$(jq -r '.status // empty' "$f" 2>/dev/null || true)
    case "$status" in
      COMMITTED|ROLLED_BACK) ((terminal+=1)) ;;
      PREPARED|APPLIED_PENDING|ROLLING_BACK|NEEDS_RECOVERY) ((pending+=1)) ;;
      *) ((invalid+=1)) ;;
    esac
  done
  jq -n --argjson total "$total" --argjson terminal "$terminal" --argjson pending "$pending" --argjson invalid "$invalid" \
    '{total:$total,terminal:$terminal,pending_recovery:$pending,invalid:$invalid}'
}

maintenance_status_json() {
  local tx_bytes backup_bytes export_bytes evidence_bytes manager_bytes core_bytes snapshots_bytes
  local manager_count core_count backup_count export_count evidence_count root_path disk_total=null disk_available=null
  local tx_counts df_line

  tx_bytes=$(maintenance_dir_bytes "$RM_TX_DIR")
  snapshots_bytes=$(maintenance_dir_bytes "$RM_TX_SNAPSHOT_DIR")
  backup_bytes=$(maintenance_dir_bytes "$RM_BACKUP_DIR")
  export_bytes=$(maintenance_dir_bytes "$RM_EXPORT_DIR")
  evidence_bytes=$(maintenance_dir_bytes "$RM_VAR_DIR/evidence")
  manager_bytes=$(maintenance_dir_bytes "$RM_VERSION_BASE")
  core_bytes=$(maintenance_dir_bytes "$RM_CORE_BASE")
  manager_count=$(maintenance_direct_dir_count "$RM_VERSION_BASE")
  core_count=$(maintenance_direct_dir_count "$RM_CORE_BASE")
  tx_counts=$(maintenance_transaction_counts_json)

  if [[ -d $RM_BACKUP_DIR && ! -L $RM_BACKUP_DIR ]]; then
    backup_count=$(backup_list 2>/dev/null | jq 'length' 2>/dev/null || printf null)
  else
    backup_count=0
  fi
  if [[ -d $RM_EXPORT_DIR && ! -L $RM_EXPORT_DIR ]]; then
    export_count=$(find "$RM_EXPORT_DIR" -type f -name manifest.json -printf '.\n' 2>/dev/null | wc -l | tr -d ' ')
  else
    export_count=0
  fi
  if [[ -d $RM_VAR_DIR/evidence/d4 && ! -L $RM_VAR_DIR/evidence/d4 ]]; then
    evidence_count=$(find "$RM_VAR_DIR/evidence/d4" -maxdepth 1 -type f -name 'up-*.json' -printf '.\n' 2>/dev/null | wc -l | tr -d ' ')
  else
    evidence_count=0
  fi

  root_path=$(rm_path /)
  df_line=$(df -PB1 "$root_path" 2>/dev/null | awk 'NR==2{print $2" "$4}' || true)
  if [[ $df_line =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
    disk_total=${BASH_REMATCH[1]}
    disk_available=${BASH_REMATCH[2]}
  fi

  jq -n \
    --argjson transactions "$tx_counts" \
    --argjson tx_bytes "$tx_bytes" --argjson snapshots_bytes "$snapshots_bytes" \
    --argjson backup_bytes "$backup_bytes" --argjson export_bytes "$export_bytes" \
    --argjson evidence_bytes "$evidence_bytes" --argjson manager_bytes "$manager_bytes" --argjson core_bytes "$core_bytes" \
    --argjson backup_count "$backup_count" --argjson export_count "$export_count" --argjson evidence_count "$evidence_count" \
    --argjson manager_count "$manager_count" --argjson core_count "$core_count" \
    --argjson disk_total "$disk_total" --argjson disk_available "$disk_available" \
    --argjson tx_keep "$RM_MAINT_TX_KEEP" --argjson version_age "$RM_MAINT_VERSION_MIN_AGE_SECONDS" \
    --argjson backup_limit "$RM_BACKUP_LIMIT_BYTES" --argjson backup_keep "$RM_BACKUP_KEEP_CONFIG" \
    --argjson backup_min "$RM_BACKUP_MIN_CONFIG" --argjson backup_upgrade "$RM_BACKUP_KEEP_UPGRADE" \
    '{
      status:"ok",
      disk:{total_bytes:$disk_total,available_bytes:$disk_available},
      usage:{
        transactions:{bytes:$tx_bytes,counts:$transactions},
        transaction_snapshots:{bytes:$snapshots_bytes},
        backups:{bytes:$backup_bytes,count:$backup_count},
        exports:{bytes:$export_bytes,count:$export_count},
        evidence:{bytes:$evidence_bytes,d4_count:$evidence_count},
        manager_versions:{bytes:$manager_bytes,count:$manager_count},
        core_versions:{bytes:$core_bytes,count:$core_count}
      },
      policy:{
        terminal_transactions_keep:$tx_keep,
        inactive_version_min_age_seconds:$version_age,
        backups:{soft_limit_bytes:$backup_limit,config_keep:$backup_keep,config_min_protected:$backup_min,upgrade_keep:$backup_upgrade},
        exports:"remove only revoked or orphaned AsterNode-generated exports",
        d4_evidence:"remove only orphaned valid AsterNode evidence",
        versions:"remove only old non-current content whose AsterNode ownership/integrity can be verified"
      },
      logging:{
        xray_loglevel:"warning",
        xray_access_log:"disabled",
        system_journal:"external_not_modified",
        fail2ban_global_logrotate:"external_not_modified"
      },
      runtime:{persistent_manager_daemon:false,maintenance_mode:"systemd oneshot"}
    }'
}

maintenance_prune_transactions() {
  [[ $RM_MAINT_TX_KEEP =~ ^[0-9]+$ ]] || return "$RM_RC_PRECONDITION"
  ((RM_MAINT_TX_KEEP>=1)) || return "$RM_RC_PRECONDITION"
  [[ ! -e $RM_TX_DIR && ! -L $RM_TX_DIR ]] && { printf '0\n'; return 0; }
  [[ -d $RM_TX_DIR && ! -L $RM_TX_DIR ]] || return "$RM_RC_PRECONDITION"

  local f status updated dir row kept=0 removed=0
  local -a rows=()
  for f in "$RM_TX_DIR"/*/transaction.json; do
    [[ -f $f && ! -L $f ]] || continue
    status=$(jq -r '.status // empty' "$f" 2>/dev/null || true)
    [[ $status == COMMITTED || $status == ROLLED_BACK ]] || continue
    updated=$(jq -r '.updated_at // empty' "$f" 2>/dev/null || true)
    [[ $updated =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || continue
    dir=${f%/transaction.json}
    [[ -d $dir && ! -L $dir && $(dirname "$dir") == "$RM_TX_DIR" ]] || continue
    rows+=("$updated"$'\t'"$dir")
  done

  if (("${#rows[@]}"==0)); then printf '0\n'; return 0; fi
  mapfile -t rows < <(printf '%s\n' "${rows[@]}" | sort -r)
  for row in "${rows[@]}"; do
    dir=${row#*$'\t'}
    ((kept+=1))
    ((kept<=RM_MAINT_TX_KEEP)) && continue
    rm -rf -- "$dir"
    ((removed+=1))
  done
  printf '%s\n' "$removed"
}

maintenance_export_mode_owned() {
  local dir=$1 entry base
  [[ -d $dir && ! -L $dir ]] || return 1
  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    base=${entry##*/}
    case "$base" in params.json|outbound.json|share.txt|3x-ui.json|manifest.json|REVOKED) ;; *) return 1;; esac
    [[ -f $entry && ! -L $entry ]] || return 1
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
}

maintenance_export_upstream_owned() {
  local dir=$1 entry base
  [[ -d $dir && ! -L $dir ]] || return 1
  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    base=${entry##*/}
    case "$base" in current|pending) maintenance_export_mode_owned "$entry" || return 1;; *) return 1;; esac
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
}

maintenance_prune_exports() {
  [[ ! -e $RM_EXPORT_DIR && ! -L $RM_EXPORT_DIR ]] && { printf '0\n'; return 0; }
  [[ -d $RM_EXPORT_DIR && ! -L $RM_EXPORT_DIR ]] || return "$RM_RC_PRECONDITION"

  local node_dir up_dir mode upid removed=0
  for node_dir in "$RM_EXPORT_DIR"/*; do
    [[ -d $node_dir && ! -L $node_dir ]] || continue
    for up_dir in "$node_dir"/*; do
      [[ -d $up_dir && ! -L $up_dir ]] || continue
      upid=${up_dir##*/}
      [[ $upid =~ ^up-[A-Za-z0-9._-]{1,64}$ ]] || continue
      if ! jq -e --arg id "$upid" '.upstreams[]? | select(.upstream_id==$id)' "$RM_STATE_FILE" >/dev/null 2>&1; then
        if maintenance_export_upstream_owned "$up_dir"; then
          rm -rf -- "$up_dir"
          ((removed+=1))
        fi
        continue
      fi
      for mode in "$up_dir"/current "$up_dir"/pending; do
        [[ -d $mode && ! -L $mode && -f $mode/REVOKED && ! -L $mode/REVOKED ]] || continue
        maintenance_export_mode_owned "$mode" || continue
        rm -rf -- "$mode"
        ((removed+=1))
      done
      rmdir "$up_dir" 2>/dev/null || true
    done
    rmdir "$node_dir" 2>/dev/null || true
  done
  printf '%s\n' "$removed"
}

maintenance_prune_evidence() {
  local dir="$RM_VAR_DIR/evidence/d4" file upid removed=0
  [[ ! -e $dir && ! -L $dir ]] && { printf '0\n'; return 0; }
  [[ -d $dir && ! -L $dir ]] || return "$RM_RC_PRECONDITION"

  for file in "$dir"/up-*.json; do
    [[ -f $file && ! -L $file ]] || continue
    upid=${file##*/}
    upid=${upid%.json}
    [[ $upid =~ ^up-[A-Za-z0-9._-]{1,64}$ ]] || continue
    jq -e --arg id "$upid" '.result=="pass" and .upstream_id==$id and (.fingerprint|type=="string")' "$file" >/dev/null 2>&1 || continue
    if ! jq -e --arg id "$upid" '.upstreams[]? | select(.upstream_id==$id)' "$RM_STATE_FILE" >/dev/null 2>&1; then
      rm -f -- "$file"
      ((removed+=1))
    fi
  done
  rmdir "$dir" 2>/dev/null || true
  rmdir "$RM_VAR_DIR/evidence" 2>/dev/null || true
  printf '%s\n' "$removed"
}

maintenance_old_enough() {
  local path=$1 mtime now
  [[ $RM_MAINT_VERSION_MIN_AGE_SECONDS =~ ^[0-9]+$ ]] || return "$RM_RC_PRECONDITION"
  mtime=$(stat -c '%Y' "$path" 2>/dev/null || true)
  [[ $mtime =~ ^[0-9]+$ ]] || return 1
  now=$(rm_epoch)
  ((now>=mtime && now-mtime>=RM_MAINT_VERSION_MIN_AGE_SECONDS))
}

maintenance_prune_manager_versions() {
  [[ ! -e $RM_VERSION_BASE && ! -L $RM_VERSION_BASE ]] && { printf '0\n'; return 0; }
  [[ -d $RM_VERSION_BASE && ! -L $RM_VERSION_BASE ]] || return "$RM_RC_PRECONDITION"

  local current='' previous='' d removed=0
  [[ -L $RM_MANAGER_CURRENT ]] && current=$(readlink -f "$RM_MANAGER_CURRENT" 2>/dev/null || true)
  [[ -f $RM_STATE_FILE && ! -L $RM_STATE_FILE ]] && previous=$(jq -r '.previous_manager_path//empty' "$RM_STATE_FILE" 2>/dev/null || true)

  for d in "$RM_VERSION_BASE"/*; do
    [[ -d $d && ! -L $d && $(dirname "$d") == "$RM_VERSION_BASE" ]] || continue
    [[ $d == "$current" || $d == "$previous" ]] && continue
    maintenance_old_enough "$d" || continue
    [[ -f $RM_TRUSTED_RELEASE_KEY && ! -L $RM_TRUSTED_RELEASE_KEY ]] || continue
    if update_verify_release_dir "$d" "$RM_TRUSTED_RELEASE_KEY" >/dev/null 2>&1; then
      rm -rf -- "$d"
      ((removed+=1))
    fi
  done
  printf '%s\n' "$removed"
}

maintenance_prune_core_versions() {
  [[ ! -e $RM_CORE_BASE && ! -L $RM_CORE_BASE ]] && { printf '0\n'; return 0; }
  [[ -d $RM_CORE_BASE && ! -L $RM_CORE_BASE ]] || return "$RM_RC_PRECONDITION"

  local current='' rollback='' default='' d version removed=0
  [[ -L $RM_CORE_CURRENT ]] && current=$(readlink -f "$RM_CORE_CURRENT" 2>/dev/null || true)
  default=$(xray_default_version 2>/dev/null || true)
  if [[ -d $RM_BACKUP_DIR && ! -L $RM_BACKUP_DIR ]]; then
    rollback=$(backup_list 2>/dev/null | jq -r '[.[] | select(.valid==true and .kind=="upgrade")][0].core_version // empty' 2>/dev/null || true)
  fi

  for d in "$RM_CORE_BASE"/*; do
    [[ -d $d && ! -L $d && $(dirname "$d") == "$RM_CORE_BASE" ]] || continue
    [[ $d == "$current" ]] && continue
    version=${d##*/}
    [[ $version == "$rollback" || $version == "$default" ]] && continue
    maintenance_old_enough "$d" || continue
    if xray_core_verify_prepared "$version" >/dev/null 2>&1; then
      rm -rf -- "$d"
      ((removed+=1))
    fi
  done
  printf '%s\n' "$removed"
}

maintenance_prune_safe() {
  rm_require_root || return $?
  state_init >/dev/null || return $?
  state_validate || return "$RM_RC_PRECONDITION"
  tx_has_conflict && {
    rm_error '存在未完成或待恢复事务，资源回收已暂停。'
    return "$RM_RC_PRECONDITION"
  }

  local tx_removed exports_removed evidence_removed manager_removed core_removed
  local backups_before=0 backups_after=0 backups_removed=0

  tx_removed=$(maintenance_prune_transactions) || return $?
  if [[ -d $RM_BACKUP_DIR && ! -L $RM_BACKUP_DIR ]]; then
    backups_before=$(backup_list | jq 'length')
    backup_prune || return $?
    backups_after=$(backup_list | jq 'length')
    backups_removed=$((backups_before-backups_after))
  fi
  exports_removed=$(maintenance_prune_exports) || return $?
  evidence_removed=$(maintenance_prune_evidence) || return $?
  manager_removed=$(maintenance_prune_manager_versions) || return $?
  core_removed=$(maintenance_prune_core_versions) || return $?

  jq -n --argjson tx "$tx_removed" --argjson backups "$backups_removed" \
    --argjson exports "$exports_removed" --argjson evidence "$evidence_removed" \
    --argjson manager "$manager_removed" --argjson core "$core_removed" '{
      status:"pruned",
      removed:{
        terminal_transactions:$tx,
        backups:$backups,
        export_directories:$exports,
        d4_evidence:$evidence,
        manager_versions:$manager,
        core_versions:$core
      },
      safety:"pending/recovery transactions, current/previous versions, rollback core, unknown paths and system-global logs are preserved"
    }'
}
