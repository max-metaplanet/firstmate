#!/usr/bin/env bash
# drive.sh <firstmate-root> <sandbox-dir>
# Drives the real bin/fm-seat.sh (switch/status) against a sandboxed primary with
# three local secondmate homes. Only fakes: tmux (exit 0, so no live fleet pane
# is touched) and quota-axi (seat login probe for named seat "work").
set -u
ROOT=$1; SB=$2
rm -rf "$SB"; mkdir -p "$SB/fake" "$SB/seats/work" "$SB/client-seats/client"
P="$SB/primary"; mkdir -p "$P/config" "$P/state" "$P/data"
printf '%s\n' "$SB/seats" > "$P/config/claude-seats-root"
printf '#!/bin/sh\nexit 0\n' > "$SB/fake/tmux"
cat > "$SB/fake/quota-axi" <<'Q'
#!/bin/sh
printf '%s\n' '{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","account":{"email":"seat@example.test"},"quotaSemantics":{"status":"known","effectiveAvailability":[]}}]}'
Q
chmod +x "$SB/fake/"*
mk_sm() { local id=$1 sm="$SB/sm-$1"; mkdir -p "$sm/config" "$sm/data" "$sm/state" "$sm/bin"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"; printf 'x\n' > "$sm/AGENTS.md"
  printf 'window=firstmate:fm-%s\nkind=secondmate\nhome=%s\n' "$id" "$sm" > "$P/state/$id.meta"; }
seat() { local h=$1; shift; TMUX='' FM_HOME="$h" FM_CONFIG_OVERRIDE="$h/config" FM_STATE_OVERRIDE="$h/state" \
  FM_DATA_OVERRIDE="$h/data" CLAUDE_CONFIG_DIR='' PATH="$SB/fake:$PATH" "$ROOT/bin/fm-seat.sh" "$@" 2>&1; echo "[exit $?]"; }
show() { for h in "$SB"/sm-*; do printf '  %-14s claude-seat=%-9s seats-root=%-40s threshold=%s optout=%s\n' "$(basename "$h")" \
  "$(cat "$h/config/claude-seat" 2>/dev/null || echo '<absent>')" "$(cat "$h/config/claude-seats-root" 2>/dev/null || echo '<absent>')" \
  "$(cat "$h/config/claude-seat-threshold" 2>/dev/null || echo '<absent>')" "$([ -e "$h/config/claude-seat-local" ] || [ -L "$h/config/claude-seat-local" ] && echo yes || echo no)"; done; }
mk_sm fleet-a; mk_sm fleet-b; mk_sm client
echo "== S1 default: no opt-out anywhere; switch work"; seat "$P" switch work; show
echo "== S1b status with no opt-out"; seat "$P" status
echo "== S1c switch default"; seat "$P" switch default; show
if [ "${NO_OPTOUT_ONLY:-0}" = 1 ]; then exit 0; fi
echo "== S2 client home opts out (touch), holds its own seat/root/threshold"
touch "$SB/sm-client/config/claude-seat-local"
printf 'client\n' > "$SB/sm-client/config/claude-seat"; printf '%s\n' "$SB/client-seats" > "$SB/sm-client/config/claude-seats-root"
printf '40\n' > "$SB/sm-client/config/claude-seat-threshold"
seat "$P" switch work; show
echo "== S3 status shows the declining home"; seat "$P" status
echo "== S4 switch default from primary"; seat "$P" switch default; show
echo "== S5 fm-config-push --local-only (the convergence a switch uses) run directly"
TMUX='' FM_HOME="$P" FM_CONFIG_OVERRIDE="$P/config" FM_STATE_OVERRIDE="$P/state" FM_DATA_OVERRIDE="$P/data" PATH="$SB/fake:$PATH" \
  "$ROOT/bin/fm-config-push.sh" --local-only 2>&1 | grep -E 'secondmate|claude-seat' ; show
echo "== S6 declining home runs its own switch"; seat "$SB/sm-client" switch --force client; show
echo "  primary claude-seat: $(cat "$P/config/claude-seat" 2>/dev/null || echo '<absent>')"
echo "== S7 flag not inherited: primary also carries a flag, switch work"
touch "$P/config/claude-seat-local"; seat "$P" switch work; show; rm -f "$P/config/claude-seat-local"
echo "== S8 adversarial: flag content 'off', dangling symlink, directory"
printf 'off\n' > "$SB/sm-client/config/claude-seat-local"
rm -f "$SB/sm-fleet-b/config/claude-seat"; ln -s "$SB/nowhere" "$SB/sm-fleet-b/config/claude-seat-local"
printf 'mine\n' > "$SB/sm-fleet-b/config/claude-seat"
mkdir "$SB/sm-fleet-a/config/claude-seat-local"
seat "$P" switch default; seat "$P" switch work; show; seat "$P" status | sed -n '/declining/,$p'
echo "== S9 remove the flags: home rejoins fleet on next switch"
rm -rf "$SB"/sm-*/config/claude-seat-local; seat "$P" switch default; seat "$P" switch work; show; seat "$P" status | sed -n '/declining/,$p'
