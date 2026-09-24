#!/usr/bin/env bash
# Drives the real bin/fm-seat.sh + bin/fm-config-push.sh against a throwaway
# primary home with three local secondmate homes. Only external oracles are
# stubbed: quota-axi (so no real Claude account is probed) and tmux/herdr (so
# reread nudges can never reach the live session).
set -u
WT=/Users/max/.no-mistakes/worktrees/61c6dd39b831/01M38EMSZK94XQT0XGEJ7ACAKR
SB=$(mktemp -d /tmp/fm-seat-optout.XXXXXX)
P=$SB/primary; SEATS=$SB/seats; FB=$SB/fakebin
mkdir -p $P/config $P/state $P/data $SEATS/work $SEATS/team2 $FB $SB/personal-seats/client
printf '%s\n' "$SEATS" > $P/config/claude-seats-root
cat > $FB/quota-axi <<'Q'
#!/usr/bin/env bash
printf '{"schemaVersion":5,"providers":[{"provider":"claude","source":"oauth","account":{"email":"x@example.test"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"}}]}}]}\n'
Q
for b in tmux herdr; do printf '#!/bin/sh\nexit 0\n' > $FB/$b; done
chmod +x $FB/*
mk_sm() { local id=$1 sm=$SB/sm-$1; mkdir -p $sm/config $sm/data $sm/state $sm/bin
  printf '%s\n' $id > $sm/.fm-secondmate-home; printf 'x\n' > $sm/AGENTS.md
  printf 'window=firstmate:fm-%s\nkind=secondmate\nhome=%s\n' $id $sm > $P/state/$id.meta; echo $sm; }
seat() { local h=$1; shift; echo "\$ FM_HOME=$h fm-seat.sh $*"
  TMUX='' FM_HOME=$h FM_CONFIG_OVERRIDE=$h/config FM_STATE_OVERRIDE=$h/state FM_DATA_OVERRIDE=$h/data \
  CLAUDE_CONFIG_DIR= PATH="$FB:$PATH" $WT/bin/fm-seat.sh "$@" 2>&1; echo "[exit $?]"; }
show() { for f in claude-seat claude-seats-root claude-seat-threshold; do
  printf '    %s/config/%s = %s\n' "$(basename $1)" $f "$(cat $1/config/$f 2>/dev/null || echo '<absent>')"; done; }

A=$(mk_sm fleet1); B=$(mk_sm fleet2)
echo "=== S1 default: no opt-out anywhere, switch reaches every home ==="
seat $P switch work; show $A; show $B
seat $P status | sed -n '/declining/,$p'

echo; echo "=== S2 one home declines (touch config/claude-seat-local) with its own personal seat ==="
C=$(mk_sm client); touch $C/config/claude-seat-local
printf 'personal\n' > $C/config/claude-seat; printf '%s\n' $SB/personal-seats > $C/config/claude-seats-root; printf '40\n' > $C/config/claude-seat-threshold
seat $P switch team2; show $A; show $B; show $C

echo; echo "=== S3 status shows the declining home and its real seat ==="
seat $P status

echo; echo "=== S4 declining home runs its own switch; primary untouched ==="
seat $C switch client; show $C; echo "    primary claude-seat = $(cat $P/config/claude-seat)"

echo; echo "=== S5 adversarial: flag contains 'off'; flag is a dir; flag is dangling symlink; no own seat ==="
printf 'off\n' > $C/config/claude-seat-local
rm -f $A/config/claude-seat*; mkdir $A/config/claude-seat-local
rm -f $B/config/claude-seat*; ln -s $SB/nowhere $B/config/claude-seat-local
seat $P switch default; show $A; show $B; show $C
seat $P status | sed -n '/declining/,$p'

echo; echo "=== S6 removing the flag restores fleet-wide default ==="
rm -rf $A/config/claude-seat-local $B/config/claude-seat-local $C/config/claude-seat-local
seat $P switch work; show $A; show $B; show $C
seat $P status | sed -n '/declining/,$p'
rm -rf "$SB"
