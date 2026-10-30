#!/usr/bin/env bash
# fm-slots.sh - compact, read-only local fleet occupancy and main-home queue.
# Usage: fm-slots.sh [--home <main-home>]
#
# Defaults to the local root of FM_HOME (or this checkout), the same home that
# owns config/fleet-capacity for admission. --home selects the queue home;
# capacity and holder discovery still follow the admission library's root walk.
# Counts and holder paths come from one fm_fleet_capacity_occupants snapshot.
# A failed admission read prints unknown rather than a partial count.
#
# State projects local declarations through fm-crew-state-lib.sh's shared
# mapping, with trusted, generation-bound busy records taking precedence.
# Working and paused workers remain working even when their harness is idle
# during validation. Idle-parked requires an idle hook and a status line that
# declares nothing beyond done; a missing status line stays unknown, and
# blocked and failed wait on firstmate action, so they stay unknown too. A matching green completion plus recorded pr= marks a declared
# merge wait. This is recorded state, not fm-crew-state.sh's live pipeline read.
# No pane capture, pipeline, forge, or LLM calls are made for display state.
# The queue uses fm-tasks-axi.sh's derived blocked/held fields and admission's
# project capacity reader. Ready work sorts by priority (0 first, unspecified
# last), then backlog order (FIFO); this does not predict firstmate's pick.
# Ready, captain-held, and other queued sections each show at most 15 rows.
# Requires bash, perl (JSON::PP), tasks-axi, and occupancy's backend tools.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"; exit 0 ;;
  --home) [ "$#" = 2 ] || { echo 'usage: fm-slots.sh [--home <main-home>]' >&2; exit 2; }; FM_HOME=$2 ;;
  '') ;;
  *) echo 'usage: fm-slots.sh [--home <main-home>]' >&2; exit 2 ;;
esac
fail() { printf 'fm-slots: %s\n' "$*" >&2; exit 1; }
FM_HOME=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || fail 'home cannot be read'
# fm-wake-lib's legacy source initialization creates STATE if absent.
# Refuse before sourcing so this reader can never create it.
STATE=$FM_HOME/state
[ -d "$STATE" ] && [ -r "$STATE" ] && [ -x "$STATE" ] || fail "state cannot be read: $STATE"
FM_STATE_OVERRIDE=$STATE
FM_CONFIG_OVERRIDE=$FM_HOME/config
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-fleet-capacity-lib.sh
. "$SCRIPT_DIR/fm-fleet-capacity-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-crew-state-lib.sh
. "$SCRIPT_DIR/fm-crew-state-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

QUEUE_HOME=$FM_HOME
if [ "$#" = 0 ]; then
  QUEUE_HOME=$(fm_firstmate_root_home "$FM_HOME") || fail 'root home cannot be resolved'
fi
CONFIG=$(fm_project_capacity_config_dir "$FM_HOME" "$FM_HOME/config") || fail 'capacity home cannot be resolved'
fm_fleet_capacity_lookup "$CONFIG" || fail "$FM_FLEET_CAPACITY_ERROR"
if ! fm_fleet_capacity_occupants "$STATE" ''; then
  printf 'slots unknown/%s (source: %s)\n' "${FM_FLEET_CAPACITY:-unlimited}" "$FM_FLEET_CAPACITY_FILE"
  fail "$FM_FLEET_CAPACITY_ERROR"
fi
ad_hoc_note=
[ "$FM_FLEET_CAPACITY_ADHOC" -eq 0 ] || ad_hoc_note=" plus $FM_FLEET_CAPACITY_ADHOC ad hoc"
printf 'slots %s/%s%s (source: %s)\n' "$FM_FLEET_CAPACITY_OCCUPANTS" "${FM_FLEET_CAPACITY:-unlimited}" "$ad_hoc_note" "$FM_FLEET_CAPACITY_FILE"
printf 'SLOTS (local records; * still holds a slot)\n'

holder_state() { # <meta> <id> <harness> <pr>
  local meta=$1 id=$2 harness=$3 pr=$4 state line='' declared=unknown busy=unknown
  state=${meta%/*}
  # Use only hook-backed readers, never capture/native fallbacks or Muse's
  # session-discovery cache. Unknown stays unknown on every other harness.
  case "$harness" in
    claude*|pi|pi-signed|omp|opencode*|commandcode|gemini*|polytoken|codex*|kimi*|devin)
      busy=$(fm_busy_classify '' '' "$harness" "$id" "$state" 2>/dev/null) || busy=unknown ;;
  esac
  case "$busy" in busy\ *) printf working; return ;; esac
  if [ -f "$state/$id.status" ] && [ -r "$state/$id.status" ] && [ ! -L "$state/$id.status" ]; then
    line=$(status_current_line "$state/$id.status" '')
    fm_crew_log_state "$line" declared
  fi
  [ -n "$line" ] || { printf unknown; return; }
  case "$declared" in
    working|paused) printf working; return ;;
    parked) printf 'waiting on decision'; return ;;
    done)
      if [ -n "$pr" ] && [[ "$line" == *"PR $pr checks green"* ]]; then
        printf 'waiting on merge *'; return
      fi
      ;;
    blocked|failed) printf unknown; return ;;
  esac
  case "$busy" in idle\ *) printf idle-parked ;; *) printf unknown ;; esac
}

holder_states=()
while IFS=$'\t' read -r i holder; do holder_states[i]=$holder; done < <(
  i=0
  for meta in ${FM_FLEET_CAPACITY_OCCUPANT_METAS[@]+"${FM_FLEET_CAPACITY_OCCUPANT_METAS[@]}"}; do
    (
      id=${meta##*/}; id=${id%.meta}
      fm_meta_get_to harness "$meta" harness
      fm_meta_get_to pr "$meta" pr
      holder=$(holder_state "$meta" "$id" "$harness" "$pr")
      printf '%s\t%s\n' "$i" "$holder"
    ) &
    i=$((i + 1))
  done
  wait
)

i=0
for meta in ${FM_FLEET_CAPACITY_OCCUPANT_METAS[@]+"${FM_FLEET_CAPACITY_OCCUPANT_METAS[@]}"}; do
  home=${meta%/state/*}
  id=${meta##*/}; id=${id%.meta}
  fm_meta_get_to project "$meta" project
  project=${project##*/}
  fm_meta_get_to kind "$meta" kind
  fm_meta_get_to harness "$meta" harness
  fm_meta_get_to pr "$meta" pr
  fm_meta_get_to seat "$meta" "${harness}_seat"
  printf '  %s | %s | %s | %s | %s | %s%s%s\n' "$home" "$id" "${project:-unknown}" "${kind:-unknown}" \
    "${holder_states[i]:-unknown}" "${harness:-unknown}" "${seat:+ seat=$seat}" "${pr:+ | $pr}"
  i=$((i + 1))
done

printf 'PARKED/WAITING (no active slot)\n'
for meta in ${FM_FLEET_CAPACITY_PARKED_METAS[@]+"${FM_FLEET_CAPACITY_PARKED_METAS[@]}"}; do
  fm_worker_park_load "$meta" || continue
  id=${meta##*/}; id=${id%.meta}
  printf '  %s | %s | %s | %s\n' "${meta%/state/*}" "$id" "$FM_WORKER_PARK_PHASE" "$FM_WORKER_PARK_REASON"
done

printf 'QUEUE (%s)\n' "$QUEUE_HOME"
# Validate the declaration with its owner before reading its project names.
# Only capped projects need another local admission read; uncapped fleets pay
# no extra home walk or project identity probes.
fm_project_capacity_lookup "$CONFIG" '' || fail "$FM_PROJECT_CAPACITY_ERROR"
capacity_rows=
if [ -n "$FM_PROJECT_CAPACITY_ANY" ]; then
  for i in "${!FM_PROJECT_CAPACITY_NAMES[@]}"; do
    name=${FM_PROJECT_CAPACITY_NAMES[i]}
    cap=${FM_PROJECT_CAPACITY_CAPS[i]}
    project=$QUEUE_HOME/projects/$name
    reason=
    if ! lock=$(fm_treehouse_project_lock_path "$project" 2>/dev/null); then
      reason='project capacity unknown (project unavailable)'
    elif ! fm_project_capacity_occupants "$lock" "$project" "$STATE" ''; then
      reason="project capacity unknown ($FM_PROJECT_CAPACITY_ERROR)"
    elif [ "$FM_PROJECT_CAPACITY_OCCUPANTS" -ge $((cap + FM_PROJECT_CAPACITY_ADHOC)) ]; then
      reason="project capacity $FM_PROJECT_CAPACITY_OCCUPANTS/$cap"
      [ "$FM_PROJECT_CAPACITY_ADHOC" -eq 0 ] || reason+=" plus $FM_PROJECT_CAPACITY_ADHOC ad hoc"
    fi
    [ -z "$reason" ] || capacity_rows+="$name"$'\t'"$reason"$'\n'
  done
fi
# Explicitly address the chosen home even when launched under a worker's
# inherited overrides. No per-item reads or staging files are needed.
queue=$(FM_HOME=$QUEUE_HOME FM_DATA_OVERRIDE="$QUEUE_HOME/data" \
  bash "$SCRIPT_DIR/fm-tasks-axi.sh" list --fields blocked,blocked_by,held,hold_kind,hold_reason,hold_until,priority,body,links) \
  || fail 'queue cannot be read'
printf '%s\n' "$queue" | FM_SLOTS_PROJECT_GATES="$capacity_rows" perl -MJSON::PP -e '
  use strict; use warnings;
  use Encode qw(decode);
  binmode STDIN, ":encoding(UTF-8)"; binmode STDOUT, ":encoding(UTF-8)";
  my (@names, @rows, $expected, $seen, $count, %capacity);
  for (split /\n/, decode("UTF-8", $ENV{FM_SLOTS_PROJECT_GATES} // "")) {
    my ($repo,$reason)=split /\t/, $_, 2; $capacity{$repo}=$reason;
  }
  my $json = JSON::PP->new->allow_nonref;
  sub compact { my $s = shift // ""; $s =~ s/[\x00-\x20\x7f]+/ /g; return $s; }
  while (<STDIN>) {
    if (/^count: (\d+)\s*$/) { $count = $1; }
    if (/^tasks\[(\d+)\]\{([^}]+)\}:\s*$/) { $expected=$1; @names=split /,/, $2; next; }
    @names=() if @names && !/^  /;
    next unless @names && /^  (.*)$/;
    my $row=$1;
    my @values;
    pos($row)=0;
    while ($row =~ /\G("(?:[^"\\]|\\.)*"|[^,]*)(?:,|$)/g) {
      my $v=$1;
      push @values, $v =~ /^"/ ? $json->decode($v) : $v;
      last if pos($row) == length($row);
    }
    die "fm-slots: queue row cannot be parsed\n" unless @values == @names;
    my %r; @r{@names}=@values; $seen++;
    next unless $r{state} eq "queued" || ($r{held} eq "yes" && $r{hold_kind} eq "captain" && $r{state} ne "done");
    my ($group,$label)=(0,"ready");
    if ($r{held} eq "yes" && $r{hold_kind} eq "captain") {
      ($group,$label)=(1,"decision: ".compact($r{hold_reason}));
      $label.=" until $r{hold_until}" if $r{hold_until} ne "-";
    } elsif ($r{kind} eq "captain") {
      # Legacy question rows may predate structured holds. An explicit release
      # is no longer a question, but remains a queued record to reconcile.
      if ($r{body} =~ /(?:^|\n)Resolution mode: released(?:\n|$)/) {
        ($group,$label)=(2,"released captain item");
      } else { ($group,$label)=(1,"decision: captain item"); }
    } elsif ($r{held} eq "yes") {
      ($group,$label)=(2,"hold: ".compact($r{hold_reason}));
      $label.=" until $r{hold_until}" if $r{hold_until} ne "-";
    } elsif ($r{blocked} eq "yes") { ($group,$label)=(2,"blocked by ".compact($r{blocked_by})); }
    elsif (exists $capacity{$r{repo}}) { ($group,$label)=(2,$capacity{$r{repo}}); }
    elsif ($r{kind} eq "public-followup") { ($group,$label)=(2,"public follow-up (not worker dispatch)"); }
    my $title=compact($r{title});
    my ($ticket) = join(" ", @r{qw(id title body links)}) =~ /\b(ENG-\d+)\b/;
    $ticket //= "";
    $title=substr($title,0,57)."..." if length($title)>60;
    $label=substr($label,0,77)."..." if length($label)>80;
    my $priority=$r{priority} =~ /^[0-4]$/ ? 0+$r{priority} : 5;
    push @rows, [$group, $priority, scalar(@rows), "  $label | $r{id}".($ticket ? " | $ticket" : "")." | $title"];
  }
  die "fm-slots: queue snapshot incomplete\n" unless defined($count) && (($count == 0 && !defined($expected)) || (defined($expected) && $expected == $count && ($seen // 0) == $expected));
  @rows=sort { $a->[0]<=>$b->[0] || ($a->[0] == 0 ? $a->[1]<=>$b->[1] : 0) || $a->[2]<=>$b->[2] } @rows;
  my @sections=("A. ready for a slot (priority, then oldest)", "B. waiting on captain", "C. other queued");
  for my $group (0..2) {
    print "$sections[$group]\n";
    my @section=grep { $_->[0] == $group } @rows;
    my $n=@section; my $shown=$n<15 ? $n : 15;
    print $section[$_][3], "\n" for 0..$shown-1;
    print "  (empty)\n" unless $n;
    print "  +", $n-15, " more\n" if $n>15;
  }
' || fail 'queue cannot be decoded'
