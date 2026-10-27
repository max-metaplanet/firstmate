#!/usr/bin/env bash
# E2E: worker PR-ready line -> status fold -> fm-task-event pr-merged -> fm-ticket-sync -> recorded tracker action
set -u
ROOT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-e2e.XXXXXX")
url=https://github.com/example/repo/pull/7
run() { # name declaration
  local h="$T/$1"; mkdir -p "$h/state" "$h/config"
  printf 'ticket=ENG-123\n' > "$h/state/task.meta"
  cat > "$h/tracker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/tracker.log"
SH
  chmod +x "$h/tracker"; printf '%s\n' "$h/tracker" > "$h/config/ticket-sync-hook"
  printf 'done [at=100]: PR %s checks green %s\n' "$url" "$2" > "$h/state/task.status"
  echo "== scenario $1: status line: $(cat "$h/state/task.status")"
  FM_HOME=$h FM_STATE_OVERRIDE=$h/state FM_CONFIG_OVERRIDE=$h/config \
    bash -c '. "$1"; status_open_decisions_incremental "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$h/state/task.status" >/dev/null
  echo "meta after fold:"; sed 's/^/  /' "$h/state/task.meta"
  for ev in pr-opened pr-merged; do
    FM_HOME=$h FM_STATE_OVERRIDE=$h/state FM_CONFIG_OVERRIDE=$h/config "$ROOT/bin/fm-task-event.sh" task $ev --pr "$url"; echo "fm-task-event $ev exit=$?"
  done
  for i in $(seq 100); do [ -f "$h/tracker.log" ] && [ "$(wc -l < "$h/tracker.log")" -ge 2 ] && break; sleep 0.05; done
  echo "merge ledger:"; jq -c '{event,ticket_scope,pr_url}' "$h/state/task-event-prs.jsonl" 2>/dev/null | sed 's/^/  /'
  echo "tracker calls:"; sed 's/^/  /' "$h/tracker.log" 2>/dev/null
}
run complete 'ticket-scope=complete'
run unreported ''
run partial 'ticket-scope=partial'
run bogus 'ticket-scope=bogus'
rm -rf "$T"
