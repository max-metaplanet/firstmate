#!/usr/bin/env bash
# fm-prefer.sh - say which worker runtime is preferred for a kind of work.
#
# Usage:
#   fm-prefer.sh set <kind> <harness|auto> [--no-push]
#   fm-prefer.sh show
#   fm-prefer.sh clear [--no-push]
#
# `set implementation codex` is the whole of "prefer codex for implementation".
# It writes config/dispatch-prefer in the effective home, then converges every
# live secondmate home through bin/fm-config-push.sh, so one call leaves this
# machine and each remote home correct. --no-push writes only this home.
#
# What the preference does: it REORDERS the candidates of an already-matched
# crew-dispatch rule so the preferred runtime comes first. It adds no candidate
# the rule does not list, overrides no explicit per-task override, and relaxes
# no gate. bin/fm-prefer-lib.sh owns the file format and
# docs/configuration.md "Worker runtime preference (config/dispatch-prefer)"
# owns the operator contract.
#
# A kind is matched to a rule by the rule's own declared `kind` field in
# config/crew-dispatch.json, never by reading a rule's `when` text. A rule with
# no declared kind is unclassified, so no preference applies to it.
#
# `set` and `show` both report, for the named kind, which rules declare it and
# whether those rules list the preferred harness, so a preference that can only
# ever be a no-op says so at the moment it is written rather than silently.
#
# Environment overrides follow the rest of firstmate:
#   FM_HOME            active firstmate home
#   FM_ROOT_OVERRIDE   firstmate repo root
#   FM_CONFIG_OVERRIDE config dir
#   FM_STATE_OVERRIDE  state dir
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RULES="$CONFIG/crew-dispatch.json"

# shellcheck source=bin/fm-prefer-lib.sh
. "$SCRIPT_DIR/fm-prefer-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

PREFER_FILE=$(fm_prefer_path "$CONFIG") || die "config directory required"

# rules_with_kind <kind> -> one "<rule-id>\t<harnesses, comma separated>" line
# per rule declaring that kind. Silent when no rules file exists, because an
# unconfigured home has no rule to classify.
rules_with_kind() {
  local kind=$1
  [ -f "$RULES" ] && [ -r "$RULES" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg kind "$kind" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    (.rules // []) | to_entries[]
    | select(.value.kind == $kind)
    | "rule_\(.key + 1)\t\([profiles(.value.use)[].harness] | unique | join(","))"
  ' "$RULES" 2>/dev/null || return 0
}

# report_kind <kind> <harness> - the no-op disclosure, on stdout.
report_kind() {
  local kind=$1 harness=$2 matched=0 listed=0 id harnesses
  while IFS=$'\t' read -r id harnesses; do
    [ -n "$id" ] || continue
    matched=$((matched + 1))
    case ",$harnesses," in
      *",$harness,"*) listed=$((listed + 1)); printf '  %s declares kind=%s and lists %s\n' "$id" "$kind" "$harness" ;;
      *) printf '  %s declares kind=%s but lists only %s\n' "$id" "$kind" "$harnesses" ;;
    esac
  done < <(rules_with_kind "$kind")
  if [ "$matched" -eq 0 ]; then
    printf '  no rule in %s declares kind=%s, so this preference is a no-op until one does\n' "$RULES" "$kind"
  elif [ "$listed" -eq 0 ]; then
    printf '  no rule declaring kind=%s lists %s, so this preference is a no-op for those rules\n' "$kind" "$harness"
  fi
}

# write_file <content-on-stdin> - replace the preference file atomically.
write_file() {
  local tmp
  tmp=$(mktemp "$CONFIG/.dispatch-prefer.XXXXXX") || die "cannot stage $PREFER_FILE"
  cat > "$tmp" || { rm -f "$tmp"; die "cannot write $PREFER_FILE"; }
  chmod 600 "$tmp" || { rm -f "$tmp"; die "cannot protect $PREFER_FILE"; }
  mv -f "$tmp" "$PREFER_FILE" || { rm -f "$tmp"; die "cannot replace $PREFER_FILE"; }
}

# Carry the change to live secondmate homes through the one existing
# convergence. A failed push never undoes this home's change; it is reported,
# and the push can be re-run on its own.
push_to_secondmates() {
  printf 'converging secondmate homes:\n'
  if FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-config-push.sh"; then
    return 0
  fi
  printf 'warning: the preference is set here, but not every secondmate home was updated (see above); those homes keep their previous preference until bin/fm-config-push.sh succeeds\n' >&2
  return 1
}

cmd_set() {
  local kind=$1 harness=$2 push=$3 existing='' line raw current rc=0
  fm_prefer_token_valid "$kind" || die "invalid kind: $kind (expected $FM_PREFER_TOKEN_RE)"
  if [ "$harness" != auto ]; then
    fm_prefer_token_valid "$harness" || die "invalid harness: $harness (expected $FM_PREFER_TOKEN_RE, or auto)"
    fm_control_harnesses | grep -qxF "$harness" ||
      die "$harness is not a verified harness; run bin/fm-control.sh harnesses for the list"
  fi
  current=$(fm_prefer_json "$CONFIG") || die "$current"
  [ -d "$CONFIG" ] || mkdir -p "$CONFIG" || die "cannot create $CONFIG"

  # Keep every other line, including comments and their order, and replace or
  # drop only this kind's line. `auto` is the absence of a preference, so it
  # removes the line rather than recording a runtime named "auto".
  if [ -f "$PREFER_FILE" ]; then
    existing=$(while IFS= read -r line || [ -n "$line" ]; do
      raw=${line%$'\r'}
      raw=${raw#"${raw%%[![:space:]]*}"}
      case "${raw%%=*}" in
        "$kind") continue ;;
      esac
      printf '%s\n' "$line"
    done < "$PREFER_FILE")
  fi
  {
    [ -z "$existing" ] || printf '%s\n' "$existing"
    [ "$harness" = auto ] || printf '%s=%s\n' "$kind" "$harness"
  } | write_file

  if [ "$harness" = auto ]; then
    printf 'no preference for %s\n' "$kind"
  else
    printf 'prefer %s for %s\n' "$harness" "$kind"
    report_kind "$kind" "$harness"
  fi
  [ "$push" = 1 ] || return 0
  push_to_secondmates || rc=1
  return "$rc"
}

cmd_show() {
  local json kind harness count
  json=$(fm_prefer_json "$CONFIG") || { printf 'error: %s\n' "$json" >&2; return 2; }
  count=$(jq -r 'length' <<<"$json" 2>/dev/null) || count=0
  printf 'preference file: %s\n' "$PREFER_FILE"
  if [ "$count" -eq 0 ]; then
    printf 'no preference declared; every kind resolves exactly as it does with no preference\n'
  else
    while IFS=$'\t' read -r kind harness; do
      [ -n "$kind" ] || continue
      printf 'prefer %s for %s\n' "$harness" "$kind"
      report_kind "$kind" "$harness"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$json")
  fi
  if [ -f "$RULES" ] && [ -r "$RULES" ] && command -v jq >/dev/null 2>&1; then
    printf 'declared rule kinds in %s:\n' "$RULES"
    jq -r '
      (.rules // []) | to_entries[]
      | "  rule_\(.key + 1): \(.value.kind // "unclassified")"
    ' "$RULES" 2>/dev/null || true
  fi
}

cmd_clear() {
  local push=$1 rc=0
  if [ -e "$PREFER_FILE" ] || [ -L "$PREFER_FILE" ]; then
    rm -f "$PREFER_FILE" || die "cannot remove $PREFER_FILE"
  fi
  printf 'no preference declared; every kind resolves exactly as it does with no preference\n'
  [ "$push" = 1 ] || return 0
  push_to_secondmates || rc=1
  return "$rc"
}

PUSH=1
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-push) PUSH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ "${#ARGS[@]}" -ge 1 ] || { usage >&2; exit 2; }

case "${ARGS[0]}" in
  set)
    [ "${#ARGS[@]}" -eq 3 ] || die "set needs <kind> and <harness|auto>"
    cmd_set "${ARGS[1]}" "${ARGS[2]}" "$PUSH"
    ;;
  show)
    [ "${#ARGS[@]}" -eq 1 ] || die "show takes no arguments"
    cmd_show
    ;;
  clear)
    [ "${#ARGS[@]}" -eq 1 ] || die "clear takes no arguments"
    cmd_clear "$PUSH"
    ;;
  *) die "unknown command ${ARGS[0]} (expected set, show, or clear)" ;;
esac
