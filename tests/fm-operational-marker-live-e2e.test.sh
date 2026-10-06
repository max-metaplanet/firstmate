#!/usr/bin/env bash
# Live guard for the carrier selection in bin/fm-operational-input.sh
# (live-harness-optin family). Per .agents/skills/firstmate-coding-guidelines
# "Harness-dependent checks", whether a harness keeps or removes the operational
# marker from submitted input is a vendor behavior, so a stub can only confirm
# the assumption already written into the stub.
#
# FM_OPERATIONAL_RECORD_HARNESSES is that assumption: every harness it names is
# believed to strip the marker and therefore gets the record-backed doorbell,
# and every harness it omits is believed to keep the typed envelope. This guard
# proves both halves against the REAL installed binaries and fails naming the
# harness and version, so a vendor that starts stripping, and a vendor that
# stops, are both caught instead of silently breaking away-mode return
# classification or the launch brief's operational identity.
#
# Signals, strongest first, never a single load-bearing vendor string:
#   claude - two records of the prompt AS SUBMITTED, neither rendered nor
#     model-reported: the `UserPromptSubmit` hook's JSON payload, and the stored
#     session transcript's own user row. The guard requires them to agree; a
#     disagreement fails loudly rather than picking one. The rendered
#     "invisible character" notice is read only as corroboration and can never
#     carry a verdict by itself. Both the typed composer path (the away-mode
#     daemon's path) and the launch-prompt argument path (the launch brief's
#     path) are covered, because they are separate vendor surfaces.
#   every other harness in the declared set - no harness outside claude exposes
#     a non-rendered record of its submitted prompt, so the verdict comes from a
#     readback probe: the envelope body instructs the agent to copy its own
#     first line to a file, and that FILE is classified with the canonical
#     owner. A readback whose body does not round-trip exactly is reported
#     INCONCLUSIVE and fails the guard rather than being recorded as a verdict.
#
# Every case submits a prompt, so this guard spends real model turns and stays
# opt-in. An absent harness is reported explicitly rather than passed over, and
# a run that checked nothing fails.
#
# Refresh docs/verification/runtime-backends.md ("Operational-marker carrier
# selection") from this guard's output after any harness in the declared set
# upgrades:
#
#   FM_OPERATIONAL_MARKER_LIVE_E2E=1 tests/fm-operational-marker-live-e2e.test.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
SOCKET="fm-op-marker-$$"
CHECKED=0
LABS=()

note() { printf '# %s\n' "$1"; }
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

cleanup_all() {
  [ -z "${REAL_TMUX:-}" ] || "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  local lab
  for lab in "${LABS[@]:-}"; do
    [ -z "$lab" ] || rm -rf -- "$lab"
  done
}
trap cleanup_all EXIT

fm_live_gate opt-in FM_OPERATIONAL_MARKER_LIVE_E2E tmux

# The production primitives are driven against the private socket through a PATH
# shim, exactly as tests/fm-composer-matrix-live-e2e.test.sh does, so their bare
# `tmux` calls stay isolated from any live fleet.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-op-marker-shim.XXXXXX") || exit 1
LABS+=("$SHIM_DIR")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"

# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

# The harnesses whose marker behavior the carrier selection depends on: those it
# routes through a record, plus marker-preserving controls that must keep the
# typed envelope. A harness added to FM_OPERATIONAL_RECORD_HARNESSES without
# live evidence here is exactly what this guard exists to stop.
DECLARED_HARNESSES='claude codex opencode pi grok'

# The plain interactive launch for a harness whose composer this guard types
# into. claude has its own case below and is not in this table.
harness_launch_cmd() {  # <harness>
  case "$1" in
    codex) printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox' ;;
    opencode) printf '%s' 'opencode' ;;
    pi) printf '%s' 'pi --yolo' ;;
    grok) printf '%s' 'grok --always-approve' ;;
    *) return 1 ;;
  esac
}

harness_binary() {  # <harness>
  case "$1" in
    pi) printf '%s' pi ;;
    *) printf '%s' "$1" ;;
  esac
}

harness_version() {  # <harness>
  "$(harness_binary "$1")" --version 2>/dev/null | head -1 | tr -d '\r' || printf 'unknown'
}

# Writes the lab path into <result-var> rather than printing it: `fail` calls
# `exit`, which inside a `$(...)` subshell would only end that subshell and
# silently swallow a real failure. The local name is deliberately obscure so it
# can never shadow the caller's own result variable.
#
# The lab is shaped like a real spawn target: a base checkout plus a LINKED
# worktree at <lab>/wt, because bin/fm-claude-trust.sh pre-registers trust only
# for an isolated worktree and refuses a primary checkout. Without that
# registration a fresh folder wedges on Claude Code's interactive trust dialog,
# which firstmate's steering plane cannot answer, and the probe would never
# submit a prompt at all.
new_lab() {  # <harness> <result-var>
  local _new_lab_dir
  [ "$2" != _new_lab_dir ] || fail "$1: new_lab's result variable may not shadow its own local"
  _new_lab_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-op-marker-$1.XXXXXX") || fail "$1: could not create the isolated lab"
  LABS+=("$_new_lab_dir")
  mkdir -p "$_new_lab_dir/base" "$_new_lab_dir/state"
  git -C "$_new_lab_dir/base" init -q || fail "$1: could not initialize the isolated base checkout"
  git -C "$_new_lab_dir/base" -c user.email=marker@example.test -c user.name=marker \
    commit -q --allow-empty -m base || fail "$1: could not seed the isolated base checkout"
  git -C "$_new_lab_dir/base" worktree add -q -b "fm-op-marker-$1" "$_new_lab_dir/wt" \
    || fail "$1: could not create the isolated task worktree"
  printf -v "$2" '%s' "$_new_lab_dir"
}

# The stored session transcript's own user row holding <body>: the second
# non-rendered record of the prompt as submitted. Empty when the row has not
# been flushed yet.
transcript_user_row() {  # <transcript-path> <body>
  PROBE_T="$1" PROBE_BODY="$2" python3 -I -c '
import json, os, sys
want = os.environ["PROBE_BODY"]
try:
    handle = open(os.environ["PROBE_T"])
except OSError:
    sys.exit(0)
for line in handle:
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("type") != "user":
        continue
    content = d.get("message", {}).get("content")
    if isinstance(content, str) and want in content:
        sys.stdout.write(content)
        break
'
}

# --- claude: the prompt as submitted, from two non-rendered records -------------
# Returns 0 when the marker survived into BOTH records, 1 when it survived into
# neither, and fails the guard when they disagree or neither exists.
claude_marker_survived() {  # <prompt-record-dir> <envelope-body> <label>
  local dir=$1 body=$2 label=$3 payload hook_prompt transcript tpath hook_has transcript_has
  payload=$(find "$dir" -maxdepth 1 -type f -name '*.json' | sort | tail -1)
  [ -n "$payload" ] \
    || fail "claude ($CLAUDE_VERSION): $label submitted no UserPromptSubmit record, so the prompt as submitted could not be read"
  hook_prompt=$(PROBE_PAYLOAD="$payload" python3 -I -c '
import json, os, sys
d = json.load(open(os.environ["PROBE_PAYLOAD"]))
sys.stdout.write(d.get("prompt", ""))
') || fail "claude ($CLAUDE_VERSION): $label UserPromptSubmit record could not be read"
  tpath=$(PROBE_PAYLOAD="$payload" python3 -I -c '
import json, os, sys
d = json.load(open(os.environ["PROBE_PAYLOAD"]))
sys.stdout.write(d.get("transcript_path", ""))
')
  [ -n "$tpath" ] \
    || fail "claude ($CLAUDE_VERSION): $label named no session transcript, so the second record is missing"
  # The hook fires at submit, before the row is flushed to the transcript, so
  # wait for the row itself rather than for the file to merely exist.
  transcript=''
  for _ in $(seq 1 120); do
    [ -f "$tpath" ] && transcript=$(transcript_user_row "$tpath" "$body") && [ -n "$transcript" ] && break
    transcript=''
    sleep 1
  done
  [ -n "$transcript" ] \
    || fail "claude ($CLAUDE_VERSION): $label never reached the session transcript at $tpath within 120s, so the probe proved nothing"

  case "$hook_prompt" in *"$FM_OPERATIONAL_MARK"*) hook_has=1 ;; *) hook_has=0 ;; esac
  case "$transcript" in *"$FM_OPERATIONAL_MARK"*) transcript_has=1 ;; *) transcript_has=0 ;; esac
  [ "$hook_has" = "$transcript_has" ] \
    || fail "claude ($CLAUDE_VERSION): $label records disagree about the marker (submitted-prompt hook=$hook_has, session transcript=$transcript_has); neither may carry this verdict alone"
  case "$hook_prompt" in
    *"$body") : ;;
    *) fail "claude ($CLAUDE_VERSION): $label body did not round-trip, so the marker verdict is INCONCLUSIVE - submitted: $hook_prompt" ;;
  esac
  [ "$hook_has" = 1 ] && return 0
  return 1
}

check_claude() {
  local lab rec envelope body target screen survived_typed survived_launch notice=absent
  CLAUDE_VERSION=$(harness_version claude)
  new_lab claude lab
  rec="$lab/prompts"
  mkdir -p "$rec" "$lab/wt/.claude"
  "$ROOT/bin/fm-claude-trust.sh" "$lab/wt" "$lab/base" >/dev/null \
    || fail "claude ($CLAUDE_VERSION): could not pre-register workspace trust for the lab worktree, so no prompt could be submitted"
  # The hook records every prompt exactly as Claude Code submits it: JSON on the
  # hook's stdin, no rendering and no model involvement.
  cat > "$lab/wt/.claude/settings.json" <<JSON
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "cat > $rec/\$(date +%s)-\$\$.json" } ] }
    ]
  }
}
JSON

  # 1. Launch-prompt argument path: the launch brief's own surface.
  body='Reply with exactly MARKERPROBE and nothing else.'
  fm_operational_input_encode launch-brief "$body" envelope \
    || fail "claude: could not encode the launch-brief probe"
  target="claude-launch:w"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s claude-launch -n w -c "$lab/wt" -x 200 -y 50 -- \
    claude --dangerously-skip-permissions "$envelope" \
    || fail "claude ($CLAUDE_VERSION): could not launch the real binary with the encoded launch prompt"
  wait_for_record "$rec" claude "the launch prompt"
  screen=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" capture-pane -p -t "$target" -S -40 2>/dev/null || true)
  case "$screen" in *'invisible character'*) notice=present ;; esac
  if claude_marker_survived "$rec" "$body" "the launch prompt"; then
    survived_launch=yes
  else
    survived_launch=no
  fi
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-session -t claude-launch >/dev/null 2>&1 || true

  # 2. Typed composer path: the away-mode daemon's own surface, submitted
  #    through the production primitive rather than a hand-rolled send.
  rm -f "$rec"/*.json
  body='Reply with exactly TYPEDPROBE and nothing else.'
  fm_operational_input_encode away-supervisor "$body" envelope \
    || fail "claude: could not encode the away-supervisor probe"
  target="claude-typed:w"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s claude-typed -n w -c "$lab/wt" -x 200 -y 50 -- \
    claude --dangerously-skip-permissions \
    || fail "claude ($CLAUDE_VERSION): could not launch the real binary for the typed probe"
  wait_for_composer "$target" claude
  fm_backend_send_text_submit tmux "$target" "$envelope" 8 0.5 0.5 >/dev/null \
    || fail "claude ($CLAUDE_VERSION): the production submit primitive could not deliver the typed probe"
  wait_for_record "$rec" claude "the typed composer"
  if claude_marker_survived "$rec" "$body" "the typed composer"; then
    survived_typed=yes
  else
    survived_typed=no
  fi
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-session -t claude-typed >/dev/null 2>&1 || true

  [ "$survived_typed" = "$survived_launch" ] \
    || fail "claude ($CLAUDE_VERSION): the typed path (marker kept: $survived_typed) and the launch-prompt path (marker kept: $survived_launch) now differ; the carrier selection is per harness and cannot express that"
  assert_selection_matches claude "$CLAUDE_VERSION" "$survived_typed" \
    "submitted-prompt hook and session transcript agree; rendered removal notice $notice"

  # 3. The carrier this selection chooses must actually land: publish a real
  #    record through the owner and type only its doorbell, exactly as the away
  #    daemon does. The instruction lives ONLY inside the record, so the probe
  #    file can appear only if the agent followed the doorbell, opened the
  #    record, and acted on the envelope it holds.
  if fm_operational_harness_needs_record claude; then
    check_claude_doorbell_lands "$lab"
  fi
}

check_claude_doorbell_lands() {  # <lab>
  local lab=$1 probe doorbell target _
  probe="$lab/doorbell-acted"
  fm_operational_record_write "$lab/state" away-supervisor \
    "Run exactly this one command and nothing else, then stop: touch $probe" doorbell \
    || fail "claude ($CLAUDE_VERSION): the owner could not publish the away-supervisor record this check delivers"
  case "$doorbell" in
    *"$FM_OPERATIONAL_MARK"*) fail "claude ($CLAUDE_VERSION): the doorbell carries the marker it exists to avoid" ;;
  esac
  target="claude-doorbell:w"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s claude-doorbell -n w -c "$lab/wt" -x 200 -y 50 -- \
    claude --dangerously-skip-permissions \
    || fail "claude ($CLAUDE_VERSION): could not launch the real binary for the doorbell delivery"
  wait_for_composer "$target" claude
  fm_backend_send_text_submit tmux "$target" "$doorbell" 8 0.5 0.5 >/dev/null \
    || fail "claude ($CLAUDE_VERSION): the production submit primitive could not deliver the doorbell"
  for _ in $(seq 1 240); do
    [ -e "$probe" ] && break
    sleep 1
  done
  [ -e "$probe" ] \
    || fail "claude ($CLAUDE_VERSION): the agent never acted on the record the typed doorbell named, so marked operational input does not reach it recognizably - pane:
$("$REAL_TMUX" -f /dev/null -L "$SOCKET" capture-pane -p -t "$target" -S -40 2>/dev/null || true)"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-session -t claude-doorbell >/dev/null 2>&1 || true
  # Deliberately does not advance CHECKED: that counter answers "how many
  # harnesses had their carrier selection verified", and this is the same
  # harness's delivery proof, not a second harness.
  pass "claude ($CLAUDE_VERSION): a typed record-backed doorbell reaches the agent recognizably - it opened the record and carried out the operational input the envelope holds"
}

wait_for_record() {  # <record-dir> <harness> <label>
  local dir=$1 harness=$2 label=$3 _
  for _ in $(seq 1 180); do
    [ -n "$(find "$dir" -maxdepth 1 -type f -name '*.json' -print -quit)" ] && return 0
    sleep 1
  done
  fail "$harness: $label never reached the submitted-prompt hook within 180s"
}

wait_for_composer() {  # <target> <harness>
  local target=$1 harness=$2 _
  for _ in $(seq 1 120); do
    [ "$(fm_backend_composer_state tmux "$target" 2>/dev/null)" = empty ] && return 0
    sleep 1
  done
  fail "$harness: the real pane never reached an empty composer within 120s"
}

# --- every other declared harness: a classified readback of its own first line --
check_readback_harness() {  # <harness>
  local harness=$1 version lab cmd target envelope body probe written kind
  version=$(harness_version "$harness")
  cmd=$(harness_launch_cmd "$harness") || fail "$harness: no declared plain interactive launch for this guard"
  new_lab "$harness" lab
  probe="$lab/readback.txt"
  body="Do exactly this and nothing else, then stop: create the file $probe whose entire contents are the first line of this message, copied byte for byte starting at its very first character."
  fm_operational_input_encode away-supervisor "$body" envelope \
    || fail "$harness: could not encode the readback probe"
  target="$harness-readback:w"
  # shellcheck disable=SC2086 # The declared launch is a fixed word list.
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "$harness-readback" -n w -c "$lab/wt" -x 200 -y 50 -- $cmd \
    || fail "$harness ($version): could not launch the real binary"
  wait_for_composer "$target" "$harness"
  fm_backend_send_text_submit tmux "$target" "$envelope" 8 0.5 0.5 >/dev/null \
    || fail "$harness ($version): the production submit primitive could not deliver the typed probe"
  for _ in $(seq 1 240); do
    [ -s "$probe" ] && break
    sleep 1
  done
  [ -s "$probe" ] \
    || fail "$harness ($version): the agent never wrote the readback file, so the marker verdict is INCONCLUSIVE"
  written=$(cat "$probe"; printf x)
  written=${written%x}
  written=${written%$'\n'}
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-session -t "$harness-readback" >/dev/null 2>&1 || true
  if kind=$(printf '%s' "$written" | "$ROOT/bin/fm-operational-input.sh" classify 2>/dev/null) \
    && [ "$kind" = away-supervisor ]; then
    assert_selection_matches "$harness" "$version" yes "the agent's own readback classifies as away-supervisor"
    return
  fi
  case "$written" in
    *"$body") assert_selection_matches "$harness" "$version" no "the agent's readback round-tripped the body with no marker" ;;
    *) fail "$harness ($version): the readback did not round-trip the probe body, so the marker verdict is INCONCLUSIVE - read back: $written" ;;
  esac
}

# --- the assertion both paths share -------------------------------------------
assert_selection_matches() {  # <harness> <version> <marker-kept yes|no> <evidence>
  local harness=$1 version=$2 kept=$3 evidence=$4
  if fm_operational_harness_needs_record "$harness"; then
    [ "$kept" = no ] \
      || fail "$harness ($version): FM_OPERATIONAL_RECORD_HARNESSES routes it through a record, but it KEPT the operational marker - drop it from that list and let it carry the typed envelope ($evidence)"
    pass "$harness ($version): strips the operational marker from submitted input, so the record-backed doorbell carrier is required ($evidence)"
  else
    [ "$kept" = yes ] \
      || fail "$harness ($version): it STRIPS the operational marker, but FM_OPERATIONAL_RECORD_HARNESSES does not route it through a record - add it to that list, or marked input reaches it as plain text ($evidence)"
    pass "$harness ($version): keeps the operational marker in submitted input, so the typed envelope carrier stays correct ($evidence)"
  fi
  CHECKED=$((CHECKED + 1))
}

command -v python3 >/dev/null 2>&1 \
  || fail "python3 is required to read the submitted-prompt records without a rendered surface"

for harness in $DECLARED_HARNESSES; do
  if ! command -v "$(harness_binary "$harness")" >/dev/null 2>&1; then
    note "$harness: not installed on this machine; its carrier selection is UNVERIFIED by this run"
    continue
  fi
  case "$harness" in
    claude) check_claude ;;
    *) check_readback_harness "$harness" ;;
  esac
done

[ "$CHECKED" -gt 0 ] \
  || fail "no declared harness was installed, so this run proved nothing about the operational-marker carrier selection"
note "verified the carrier selection against $CHECKED installed harness(es)"
