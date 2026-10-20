#!/usr/bin/env bash
# Drives the real bin/fm-task-event.sh -> bin/fm-ticket-sync.sh path against a
# disposable FM_HOME whose legacy ticket-sync-hook records each tracker call.
set -u
REPO=${1:?repo}
run_case() {  # name, then a function body via eval
  local name=$1; shift
  H=$(mktemp -d "${TMPDIR:-/tmp}/fm-ts-live.XXXXXX")
  mkdir -p "$H/state" "$H/config"
  cat > "$H/hook.sh" <<HK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$H/calls.log"
HK
  chmod +x "$H/hook.sh"; printf '%s\n' "$H/hook.sh" > "$H/config/ticket-sync-hook"
  echo "### $name"
  "$@"
  for _ in $(seq 1 50); do [ -z "$(ls "$H/state/task-events" 2>/dev/null | grep -v '^\.')" ] && break; sleep 0.2; done
  sleep 0.5
  echo "tracker calls:"; sed 's/^/  /' "$H/calls.log" 2>/dev/null || echo "  (none)"
  echo "published facts (event ticket_scope merge pr):"
  jq -r '"  \(.task_id) \(.event) scope=\(.ticket_scope) pr=\(.pr_url)"' "$H/state/task-event-prs.jsonl" 2>/dev/null
  rm -rf "$H"; echo
}
ev() { FM_HOME=$H bash "$REPO/bin/fm-task-event.sh" "$@"; }
meta() { printf 'ticket=ENG-1\n%s\n' "$2" > "$H/state/$1.meta"; }

s1() { meta a ''; ev a pr-opened --pr https://x/pull/1; ev a pr-merged --pr https://x/pull/1; }
run_case "S1 partial (default) scope, single PR merges -> review, never done" s1
s2() { meta a 'ticket_scope=complete'; ev a pr-opened --pr https://x/pull/1; ev a pr-merged --pr https://x/pull/1; }
run_case "S2 declared complete, PR merges -> done" s2
s3() { meta a 'ticket_scope=complete'; meta b 'ticket_scope=complete'; ev a pr-opened --pr https://x/pull/1; ev b pr-opened --pr https://x/pull/2; ev a pr-merged --pr https://x/pull/1; }
run_case "S3 complete scope but sibling PR still open -> no close (merge partial)" s3
s4() { meta a ''; ev a pr-opened --pr https://x/pull/1; ev a pr-merged --pr https://x/pull/1; ev b pr-opened --ticket ENG-1 --pr https://x/pull/2; rm -f "$H/state/b.meta"; ev b cancelled --ticket ENG-1 --ticket-scope complete --pr https://x/pull/2; }
run_case "S4 A partial merged, B complete cancelled unmerged -> bare review, no done, no abandoned URL" s4
s5() { meta a 'ticket_scope=complete'; ev a pr-opened --pr https://x/pull/1; ev a pr-merged --pr https://x/pull/1; rm -f "$H/state/a.meta"; ev a cancelled --ticket ENG-1 --ticket-scope complete --pr https://x/pull/1; }
run_case "S5 complete task cancelled after own PR merged -> done allowed" s5
s6() { meta a 'ticket_scope=COMPLETE'; ev a pr-opened --pr https://x/pull/1; ev a pr-merged --pr https://x/pull/1; }
run_case "S6 adversarial: malformed scope value treated as partial" s6
s7() { printf 'ticket=no-ticket\nticket_scope=complete\n' > "$H/state/a.meta"; ev a pr-merged --pr https://x/pull/1; }
run_case "S7 adversarial: ticketless complete scope publishes partial, no tracker call" s7
