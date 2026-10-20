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
# State uses trusted, generation-bound busy records and reconciled status
# declarations. Missing or unsupported semantic evidence is unknown; a working
# status event alone cannot prove current activity. A matching green completion
# plus recorded pr= marks a declared merge wait unless a busy record supersedes
# it. This is local recorded readiness, not a fresh forge check.
# No pane capture, pipeline, forge, or LLM calls are made for display state.
# The queue uses fm-tasks-axi.sh once, preserving its order within ready,
# blocked, and captain-held groups, and prints at most 15 rows plus a remainder.
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
printf 'slots %s/%s (source: %s)\n' "$FM_FLEET_CAPACITY_OCCUPANTS" "${FM_FLEET_CAPACITY:-unlimited}" "$FM_FLEET_CAPACITY_FILE"
printf 'SLOTS (local records; * still holds a slot)\n'

holder_state() { # <meta> <id> <harness> <pr>
  local meta=$1 id=$2 harness=$3 pr=$4 state line verb busy=unknown
  state=${meta%/*}
  # Use only hook-backed readers, never capture/native fallbacks or Muse's
  # session-discovery cache. Unknown stays unknown on every other harness.
  case "$harness" in
    claude*|pi|pi-signed|omp|opencode*|commandcode|gemini*|polytoken|codex*|kimi*|devin)
      busy=$(fm_busy_classify '' '' "$harness" "$id" "$state" 2>/dev/null) || busy=unknown ;;
  esac
  case "$busy" in busy\ *) printf working; return ;; esac
  [ -f "$state/$id.status" ] && [ -r "$state/$id.status" ] && [ ! -L "$state/$id.status" ] || { printf unknown; return; }
  line=$(status_current_line "$state/$id.status" '')
  verb=$(status_line_verb "$line")
  case "$verb" in
    needs-decision) printf 'waiting on decision'; return ;;
    done)
      if [ -n "$pr" ] && [[ "$line" == *"PR $pr checks green"* ]] \
        && [ "$(fm_meta_get "$meta" yolo)" = off ]; then
        printf 'waiting on captain merge *'; return
      fi
      ;;
  esac
  case "$busy" in idle\ *) printf idle ;; *) printf unknown ;; esac
}

for meta in ${FM_FLEET_CAPACITY_OCCUPANT_METAS[@]+"${FM_FLEET_CAPACITY_OCCUPANT_METAS[@]}"}; do
  home=${meta%/state/*}
  id=${meta##*/}; id=${id%.meta}
  fm_meta_get_to project "$meta" project
  project=${project##*/}
  fm_meta_get_to kind "$meta" kind
  fm_meta_get_to harness "$meta" harness
  fm_meta_get_to pr "$meta" pr
  fm_meta_get_to seat "$meta" "${harness}_seat"
  [ -n "$seat" ] || fm_meta_get_to seat "$meta" seat
  state=$(holder_state "$meta" "$id" "$harness" "$pr")
  printf '  %s | %s | %s | %s | %s | %s%s%s\n' "$home" "$id" "${project:-unknown}" "${kind:-unknown}" "$state" \
    "${harness:-unknown}" "${seat:+ seat=$seat}" "${pr:+ | $pr}"
done

printf 'QUEUE (%s)\n' "$QUEUE_HOME"
# Explicitly address the chosen home even when launched under a worker's
# inherited overrides. No per-item reads or staging files are needed.
queue=$(FM_HOME=$QUEUE_HOME FM_DATA_OVERRIDE="$QUEUE_HOME/data" \
  bash "$SCRIPT_DIR/fm-tasks-axi.sh" list --fields blocked,blocked_by,held,hold_kind,hold_reason,body,links) \
  || fail 'queue cannot be read'
printf '%s\n' "$queue" | perl -MJSON::PP -e '
  use strict; use warnings;
  binmode STDIN, ":encoding(UTF-8)"; binmode STDOUT, ":encoding(UTF-8)";
  my (@names, @rows, $expected, $seen, $count);
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
    if ($r{held} eq "yes") {
      if ($r{hold_kind} eq "captain") { ($group,$label)=(2,"decision: ".compact($r{hold_reason})); }
      else { ($group,$label)=(1,"blocked: hold ".compact($r{hold_reason})); }
    } elsif ($r{blocked} eq "yes") { ($group,$label)=(1,"blocked by ".compact($r{blocked_by})); }
    my $title=compact($r{title});
    my ($ticket) = join(" ", @r{qw(id title body links)}) =~ /\b(ENG-\d+)\b/;
    $ticket //= "";
    $title=substr($title,0,57)."..." if length($title)>60;
    $label=substr($label,0,77)."..." if length($label)>80;
    push @rows, [$group, scalar(@rows), "  $label | $r{id}".($ticket ? " | $ticket" : "")." | $title"];
  }
  die "fm-slots: queue snapshot incomplete\n" unless defined($count) && (($count == 0 && !defined($expected)) || (defined($expected) && $expected == $count && ($seen // 0) == $expected));
  @rows=sort { $a->[0]<=>$b->[0] || $a->[1]<=>$b->[1] } @rows;
  my $n=@rows; my $shown=$n<15 ? $n : 15;
  print $rows[$_][2], "\n" for 0..$shown-1;
  print "  (empty)\n" unless $n;
  print "  +", $n-15, " more\n" if $n>15;
' || fail 'queue cannot be decoded'
