#!/usr/bin/env bash
# Drive the real bin/fm-worker-park.sh CLI from the base commit and from the
# change head against identical disposable FM_HOME fixtures, then diff every
# resulting park record, control call and stdout/stderr/exit. fm-control and
# fm-busy-lib are stubbed so no real worker lifecycle runs.
set -u
REPO=$1 BASE=$2 HEAD=$3
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-park-eq.XXXXXX")
trap 'rm -rf "$W"' EXIT
URL=https://github.com/example/repo/pull/99
for side in base head; do
  rev=$BASE; [ "$side" = head ] && rev=$HEAD
  mkdir -p "$W/$side"
  git -C "$REPO" archive "$rev" bin | tar -x -C "$W/$side"
  rm "$W/$side/bin/fm-control.sh" "$W/$side/bin/fm-busy-lib.sh"
  cat > "$W/$side/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/control.log"
if [ "$2" != exit ]; then printf 'spawn_gen=replacement\n' >> "$FM_HOME/state/$1.meta"; fi
SH
  chmod +x "$W/$side/bin/fm-control.sh"
  printf 'fm_busy_classify() { printf "%%s\\n" "idle hook"; }\n' > "$W/$side/bin/fm-busy-lib.sh"
done

setup_home() { # <home>
  local h=$1
  mkdir -p "$h/state" "$h/config" "$h/data" "$h/project"
  git -C "$h/project" init -q && git -C "$h/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  # w1: ready PR -> auto parks
  printf 'kind=ship\nbackend=tmux\nwindow=%%1\nspawn_gen=g1\nyolo=off\nmode=direct-PR\npr=%s\nworktree=%s\nharness=codex\n' "$URL" "$h/project" > "$h/state/w1.meta"
  printf 'done: PR %s checks green\n' "$URL" > "$h/state/w1.status"
  # w2: already parked, unchanged status -> tick keeps it parked
  printf 'kind=ship\nbackend=herdr\nwindow=pane-2\nspawn_gen=g2\nyolo=off\nworktree=%s\n' "$h/project" > "$h/state/w2.meta"
  printf 'waiting\n' > "$h/state/w2.status"
  printf 'phase=parked\ngeneration=g2\nendpoint=pane-2\nreason=external wait\nuntil=0\nqueued_at=0\nstatus_line=waiting\n' > "$h/state/w2.park"
  # w3: parked with stale generation -> load must reject
  printf 'kind=ship\nbackend=zellij\nwindow=z3\nspawn_gen=new\nworktree=%s\n' "$h/project" > "$h/state/w3.meta"
  printf 'phase=parked\ngeneration=old\nendpoint=z3\nreason=stale\nuntil=0\nqueued_at=0\n' > "$h/state/w3.park"
  # w4: hint phase with matching status -> auto parks with hint reason
  printf 'kind=ship\nbackend=tmux\nwindow=%%4\nspawn_gen=g4\nyolo=on\nworktree=%s\n' "$h/project" > "$h/state/w4.meta"
  printf 'blocked: upstream\n' > "$h/state/w4.status"
  printf 'phase=hint\nstatus_line=blocked: upstream\nreason=waiting on upstream maintainer\n' > "$h/state/w4.park"
  # w5: no endpoint -> skipped
  printf 'kind=ship\nbackend=tmux\nspawn_gen=g5\n' > "$h/state/w5.meta"
  # w6: parked whose status changed -> tick queues wake/resume
  printf 'kind=ship\nbackend=orca\nterminal=orca-6\nwindow=fallback\nspawn_gen=g6\nyolo=off\nworktree=%s\n' "$h/project" > "$h/state/w6.meta"
  printf 'new steer\n' > "$h/state/w6.status"
  printf 'phase=parked\ngeneration=g6\nendpoint=orca-6\nreason=external wait\nuntil=0\nqueued_at=0\nstatus_line=old\n' > "$h/state/w6.park"
}

run() { # <side> <label> <args...>
  local side=$1 label=$2; shift 2
  local h="$W/home-$side" out
  out=$(cd "$h" && FM_HOME=$h FM_STATE_OVERRIDE=$h/state FM_CONFIG_OVERRIDE=$h/config \
    bash "$W/$side/bin/fm-worker-park.sh" "$@" 2>&1); local rc=$?
  printf '== %s rc=%s\n%s\n' "$label" "$rc" "$out" | sed "s#$h#<HOME>#g; s#$W/$side#<BIN>#g"
}

for side in base head; do
  setup_home "$W/home-$side"
  {
    run $side 'auto w1' auto w1
    run $side 'auto w4' auto w4
    run $side 'status w2' status w2
    run $side 'status w3' status w3
    run $side 'tick' tick
    run $side 'status w6' status w6
    for f in "$W/home-$side/state/"*.park "$W/home-$side/control.log"; do
      [ -f "$f" ] || continue
      printf -- '-- %s\n' "${f##*/}"
      grep -v -E '^(queued_at|at|parked_at|updated_at|until)=' "$f" | sed "s#$W/home-$side#<HOME>#g"
    done
  } > "$W/$side.transcript"
done
cat "$W/head.transcript"
echo "######## diff base vs head ########"
if diff -u "$W/base.transcript" "$W/head.transcript"; then echo 'IDENTICAL: base and head CLI behaviour match'; else echo 'DIFFERENT'; exit 1; fi
