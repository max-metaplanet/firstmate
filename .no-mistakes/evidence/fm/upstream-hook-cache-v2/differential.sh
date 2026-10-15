#!/usr/bin/env bash
# Differential: run each Claude hook from BASE tree and HEAD tree by absolute
# path (as Claude's "$CLAUDE_PROJECT_DIR"/bin/... does) on identical stdin
# payloads; compare exit code, stdout, stderr (tree path normalized).
set -u
BASE=$1 HEAD=$2
LABB=$(mktemp -d /tmp/fm-lab.XXXXXX); LABH=$(mktemp -d /tmp/fm-lab.XXXXXX)
"$HEAD/bin/fm-lab-home.sh" create "$LABB" >/dev/null; "$HEAD/bin/fm-lab-home.sh" create "$LABH" >/dev/null
trap 'rm -rf "$LABB" "$LABH" "$BIGF"' EXIT
pass=0 fail=0
BIGF=$(mktemp /tmp/nm-big.XXXX); head -c 1048576 /dev/zero | tr '\0' 'x' > "$BIGF"; big=$(cat "$BIGF")
run() { # tree lab hook args... ; payload on stdin
  local tree=$1 lab=$2; shift 2
  local out err rc
  out=$(cd "$tree" && env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX FM_HOME="$lab" CLAUDE_PROJECT_DIR="$tree" "$tree/bin/$@" 2>/tmp/nm-diff-err; echo "rc=$?")
  err=$(cat /tmp/nm-diff-err)
  printf '%s\n--stderr--\n%s' "$out" "$err" | sed -e "s#$tree#<ROOT>#g" -e "s#$lab#<LAB>#g"
}
cmp_case() { # name payload hook args...
  local name=$1 payload=$2; shift 2
  local b h
  b=$(printf '%s' "$payload" | run "$BASE" "$LABB" "$@")
  h=$(printf '%s' "$payload" | run "$HEAD" "$LABH" "$@")
  local verdict; verdict=$(printf '%s' "$h" | grep -o 'rc=[0-9]*' | tail -1)
  if [ "$b" = "$h" ]; then pass=$((pass+1)); printf 'SAME  %-58s %s %s\n' "$name" "$verdict" "$( [ -n "$(printf '%s' "$h" | sed -n '/--stderr--/,$p' | tail -n +2)" ] && echo '(deny/err output identical)')"
  else fail=$((fail+1)); printf 'DIFF  %s\n  base: %s\n  head: %s\n' "$name" "$b" "$h"; fi
}
pt() { jq -cn --arg t "$1" --arg c "${2:-}" --arg cwd "${3:-/x}" '{session_id:"s",hook_event_name:"PreToolUse",cwd:$cwd,tool_name:$t,tool_input:{command:$c}}'; }
# subagent pretool (matcher .*)
for t in Read Bash Write Edit Grep Glob TodoWrite WebFetch Task Agent SendMessage TaskCreate CronCreate ScheduleWakeup Monitor EnterWorktree Workflow mcp__x__spawn_worker sub_agent Work-Flow DELEGATE remote_trigger; do
  cmp_case "subagent tool=$t" "$(pt "$t" ls)" fm-subagent-pretool-check.sh --claude
done
cmp_case "subagent Read with cwd under /worktrees/" "$(pt Read '' /a/worktrees/b)" fm-subagent-pretool-check.sh --claude
cmp_case "subagent Bash mentioning spawn in command" "$(pt Bash 'echo spawn task agent')" fm-subagent-pretool-check.sh --claude
cmp_case "subagent 1MB Write payload, tool=Write" "$(jq -cn --rawfile c "$BIGF" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{content:$c}}')" fm-subagent-pretool-check.sh --claude
cmp_case "subagent 1MB payload, tool=Task" "$(jq -cn --rawfile c "$BIGF" '{hook_event_name:"PreToolUse",tool_name:"Task",tool_input:{prompt:$c}}')" fm-subagent-pretool-check.sh --claude
cmp_case "subagent empty stdin" "" fm-subagent-pretool-check.sh --claude
cmp_case "subagent malformed JSON" "{not json" fm-subagent-pretool-check.sh --claude
cmp_case "subagent toolName (grok shape) Task, no --claude" '{"toolName":"Task"}' fm-subagent-pretool-check.sh
cmp_case "subagent cursor-host payload Task" '{"tool_name":"Task","cursor_version":"1.0","hook_event_name":"preToolUse"}' fm-subagent-pretool-check.sh --claude
# arm + cd pretool (matcher Bash)
for c in 'ls -la' 'git status' 'bin/fm-watch-arm.sh' 'bin/fm-watch-arm.sh &' 'nohup bin/fm-watch-arm.sh' 'bin/fm-watch-arm.sh | cat' "pkill -f '/bin/fm-watch.sh'" 'cd projects/foo' 'cd ..' 'pushd x' '(cd /tmp && ls)' 'cd /tmp && ls'; do
  cmp_case "arm  cmd=$c" "$(pt Bash "$c")" fm-arm-pretool-check.sh --claude
  cmp_case "cd   cmd=$c" "$(pt Bash "$c")" fm-cd-pretool-check.sh --claude
done
cmp_case "arm  1MB heredoc command" "$(jq -cn --rawfile b "$BIGF" '{tool_name:"Bash",tool_input:{command:("cat > f <<'\''E'\''\n"+$b+"\nE")}}')" fm-arm-pretool-check.sh --claude
cmp_case "cd   1MB heredoc command" "$(jq -cn --rawfile b "$BIGF" '{tool_name:"Bash",tool_input:{command:("cat > f <<'\''E'\''\n"+$b+"\nE")}}')" fm-cd-pretool-check.sh --claude
cmp_case "arm  background:true payload" "$(jq -cn '{tool_name:"Bash",tool_input:{command:"bin/fm-watch-arm.sh",background:true}}')" fm-arm-pretool-check.sh --claude
cmp_case "arm  --command CLI mode deny" "" fm-arm-pretool-check.sh --command 'bin/fm-watch-arm.sh &' --background true
cmp_case "arm  empty stdin" "" fm-arm-pretool-check.sh --claude
cmp_case "cd   empty stdin" "" fm-cd-pretool-check.sh --claude
# Stop hooks + mirror
stop=$(jq -cn '{session_id:"s",hook_event_name:"Stop",stop_hook_active:false,transcript_path:"/tmp/none.jsonl",last_assistant_message:"done"}')
cmp_case "turnend-guard Stop" "$stop" fm-turnend-guard.sh --claude
cmp_case "turnend-guard Stop with trailing newlines" "$stop"$'\n\n' fm-turnend-guard.sh --claude
cmp_case "turnend-guard empty stdin" "" fm-turnend-guard.sh --claude
cmp_case "stop-autoarm Stop" "$stop" fm-claude-stop-autoarm.sh
cmp_case "stop-autoarm cursor-host Stop" '{"hook_event_name":"stop","cursor_version":"1"}' fm-claude-stop-autoarm.sh
cmp_case "host-mirror UserPromptSubmit" "$(jq -cn '{hook_event_name:"UserPromptSubmit",prompt_id:"p",prompt:"a\nb\n\nc"}')" fm-host-mirror.sh hook claude
cmp_case "host-mirror Stop 1MB reply" "$(jq -cn --rawfile c "$BIGF" '{hook_event_name:"Stop",last_assistant_message:$c}')" fm-host-mirror.sh hook claude
echo "TOTAL same=$pass diff=$fail"
