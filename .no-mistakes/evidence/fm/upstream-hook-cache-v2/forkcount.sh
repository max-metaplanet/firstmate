#!/usr/bin/env bash
# Count forks per hook invocation: distinct child PIDs seen in xtrace
# (PS4 carries $BASHPID) union PIDs logged by PATH shims for externals.
# Also mean wall-clock over N runs (no tracing). Absolute-path invocation.
set -u
BASE=$1 HEAD=$2 N=${N:-10}
SHIM=$(mktemp -d /tmp/nm-shim.XXXX); LOG=$SHIM/log
for c in cat dirname basename jq tr sed git node awk grep head tail mktemp date ps readlink realpath cksum env sort wc cut uname id stat; do
  real=$(command -v $c) || continue
  printf '#!/bin/bash\necho "$$ %s" >> %s\nexec %s "$@"\n' "$c" "$LOG" "$real" > $SHIM/$c; chmod +x $SHIM/$c
done
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX); "$HEAD/bin/fm-lab-home.sh" create "$LAB" >/dev/null
PF=$(mktemp /tmp/nm-pl.XXXX)
trap 'rm -rf "$SHIM" "$LAB" "$PF"' EXIT
pad() { head -c "$1" /dev/zero | tr '\0' 'x'; }
mk() { # size kind -> payload file
  local f=$PF.$1.$2; pad "$1" > $f.pad
  case $2 in
    read) jq -cn --rawfile p $f.pad '{hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:"/x",note:$p}}' ;;
    write) jq -cn --rawfile p $f.pad '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:"/x",content:$p}}' ;;
    bash) jq -cn --rawfile p $f.pad '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:("cat > f <<'"'"'E'"'"'\n"+$p+"\nE")}}' ;;
    stop) jq -cn '{session_id:"s",hook_event_name:"Stop",stop_hook_active:false,transcript_path:"/tmp/none.jsonl"}' ;;
    ups) jq -cn --rawfile p $f.pad '{hook_event_name:"UserPromptSubmit",prompt_id:"p",prompt:("hi "+$p)}' ;;
  esac > $f; rm -f $f.pad; echo $f
}
measure() { # tree payloadfile hook args
  local tree=$1 pl=$2; shift 2
  : > $LOG
  local tr; tr=$(cd "$tree" && env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u TMUX FM_HOME=$LAB PATH="$SHIM:$PATH" PS4='+${BASHPID} ' bash -x "$tree/bin/$@" < $pl 2>&1 >/dev/null)
  local main; main=$(printf '%s\n' "$tr" | grep -m1 -o '^+*[0-9]*' | tr -d '+')
  local forks; forks=$( { printf '%s\n' "$tr" | grep -o '^++*[0-9]*' | tr -d '+'; cut -d' ' -f1 $LOG; } | grep -v "^$main\$" | grep . | sort -u | wc -l | tr -d ' ')
  local ext; ext=$(cut -d' ' -f2 $LOG | sort | uniq -c | awk '{printf "%s:%s ",$2,$1}')
  local t0 t1; t0=$(perl -MTime::HiRes=time -e 'printf "%.6f",time')
  for _ in $(seq $N); do (cd "$tree" && env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u TMUX FM_HOME=$LAB "$tree/bin/$@" < $pl >/dev/null 2>&1); done
  t1=$(perl -MTime::HiRes=time -e 'printf "%.6f",time')
  printf '%2s forks  %.3fs  [%s]' "$forks" "$(echo "($t1-$t0)/$N" | bc -l)" "$ext"
}
row() { # label size kind hook args
  local label=$1 size=$2 kind=$3; shift 3
  local pl; pl=$(mk $size $kind)
  printf '%-34s %-6s base: %s\n%-34s %-6s head: %s\n' "$label" "$size" "$(measure $BASE $pl "$@")" "" "" "$(measure $HEAD $pl "$@")"
}
for sz in 100 8000 1048576; do
  row "subagent (Read, no-op)" $sz read fm-subagent-pretool-check.sh --claude
  row "subagent (Write, no-op)" $sz write fm-subagent-pretool-check.sh --claude
  row "arm (Bash heredoc, allow)" $sz bash fm-arm-pretool-check.sh --claude
  row "cd (Bash heredoc, allow)" $sz bash fm-cd-pretool-check.sh --claude
  row "host-mirror (UserPromptSubmit)" $sz ups fm-host-mirror.sh hook claude
done
row "turnend-guard (Stop)" 100 stop fm-turnend-guard.sh --claude
row "stop-autoarm (Stop)" 100 stop fm-claude-stop-autoarm.sh
