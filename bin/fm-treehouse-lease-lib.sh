#!/usr/bin/env bash
# Durable task leases for Treehouse pool slots.
# Requires fm-wake-lib.sh and fm-backend.sh; sourcing has no side effects.
#
# A recorded task keeps its slot until teardown, including while parked or
# after reboot. Restore only an existing pool worktree whose slot-owner claim
# matches both the task and the local home. Missing paths, released records,
# and absent/foreign/unsafe claims are skipped. No worktree contents change:
# Treehouse's state-only `lease` upgrades the interactive get's process lease.
# Teardown owns releasing both the lease (`return --force`) and the claim.
#
# Restore under the shared project allocation/return lock, re-reading records
# after acquiring it so a concurrent teardown cannot resurrect a returned slot.
# An optional held-lock argument limits the scan to that project and avoids
# retaking the caller's lock. Startup scans only its own state; spawn scans the
# existing local-home inventory before allocation and leases its committed new
# record after launch delivery. Provisional failed spawns gain no durable lease.

fm_treehouse_task_lease_restore() {  # <meta> <home> [held-project-lock]
  local meta=$1 home=$2 held=${3:-} project worktree id lock acquired=0 rc=0 pool slot lease_state root status
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  project=$(fm_meta_get "$meta" project)
  worktree=$(fm_meta_get "$meta" worktree)
  fm_treehouse_pool_slot "$project" "$worktree" || return 0
  lock=$(fm_treehouse_project_lock_path "$project") || return 1
  if [ -n "$held" ]; then
    [ "$held" = "$lock" ] || return 0
  else
    fm_lock_try_acquire "$lock" || {
      echo "TREEHOUSE_LEASE: project allocation/return busy; retry lease restoration for $meta" >&2
      return 1
    }
    acquired=1
  fi
  # Everything authoritative is re-read inside the project lock.
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    project=$(fm_meta_get "$meta" project)
    worktree=$(fm_meta_get "$meta" worktree)
    id=${meta##*/}; id=${id%.meta}
    if [ "$(fm_meta_get "$meta" worktree_claim)" != released ] &&
      fm_treehouse_pool_slot "$project" "$worktree" &&
      [ "$(fm_treehouse_project_lock_path "$project")" = "$lock" ]; then
      fm_treehouse_slot_owner_state "$worktree" "$id"
      if [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ] &&
        [ -n "$FM_TREEHOUSE_SLOT_OWNER_HOME" ] &&
        [ "$FM_TREEHOUSE_SLOT_OWNER_HOME" -ef "$home" ]; then
        worktree=$(CDPATH='' cd -- "$worktree" && pwd -P)
        slot=$(dirname "$worktree")
        pool=$(dirname "$slot")
        # Node is a universal Firstmate dependency; tmux does not require jq.
        lease_state=$(node -e '
          const fs = require("fs");
          const [file, path, name] = process.argv.slice(1);
          const matches = JSON.parse(fs.readFileSync(file, "utf8")).worktrees
            .filter(w => w.name === name && w.path === path);
          console.log(matches.length !== 1 ? "unsafe" : matches[0].leased === true ? "leased" : "unleased");
        ' "$pool/treehouse-state.json" "$worktree" "${slot##*/}" 2>/dev/null) || lease_state=unsafe
        # Preserve an existing durable lease, including its holder and id.
        # Never let a malformed pool map redirect a state-only lease command.
        if [ "$lease_state" = unsafe ]; then
          echo "TREEHOUSE_LEASE: cannot verify recorded pool entry for $worktree ($meta)" >&2
          rc=1
        elif [ "$lease_state" = unleased ]; then
          # Pin the recorded pool's root rather than inheriting TREEHOUSE_ROOT
          # from an unrelated operator shell. Treehouse appends .treehouse to
          # an explicit root. Verify its resolution before leasing:
          # a changed origin or repo name can point at a different pool.
          root=$(dirname "$(dirname "$pool")")
          if ! status=$(cd "$worktree" && treehouse --root "$root" status --json) ||
            ! printf '%s\n' "$status" | node -e '
              const fs = require("fs");
              const [path, name] = process.argv.slice(1);
              const entries = JSON.parse(fs.readFileSync(0, "utf8"));
              process.exit(entries.some(w => w.name === name && w.path === path) ? 0 : 1);
            ' "$worktree" "${slot##*/}" 2>/dev/null; then
            echo "TREEHOUSE_LEASE: Treehouse resolves a different pool for $worktree ($meta); leaving it untouched" >&2
            rc=1
          elif ! (cd "$worktree" && treehouse --root "$root" lease "${slot##*/}" \
            --lease-holder "firstmate:$home:$id") >/dev/null; then
            echo "TREEHOUSE_LEASE: could not durably lease $worktree for $id ($meta)" >&2
            rc=1
          fi
        fi
      fi
    fi
  fi
  [ "$acquired" = 0 ] || fm_lock_release "$lock"
  return "$rc"
}

fm_treehouse_leases_restore() {  # <state> <home> [held-project-lock]
  local state=$1 home=$2 held=${3:-} meta rc=0
  for meta in "$state"/*.meta; do
    fm_treehouse_task_lease_restore "$meta" "$home" "$held" || rc=1
  done
  return "$rc"
}
