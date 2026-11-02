#!/usr/bin/env bash
# Drives bin/fm-seat.sh (head vs base) with the 2026-11-02 seat readings in a
# disposable FM_HOME; only the external quota-axi boundary is faked.
WT=$1 BASE=$2
. "$WT/tests/.nm-lib-seat.sh" >/dev/null 2>&1
for label in base head; do
  if [ $label = base ]; then SEAT="$BASE/bin/fm-seat.sh"; else SEAT="$WT/bin/fm-seat.sh"; fi
  echo "===================== $label: $SEAT"
  echo "--- Claude: seat-max 5h=0% wk=10% (active), seat-max2 5h=56% wk=14%? (intent: wk 10 vs 14), trigger 20, dest-min 10"
  wall_case "live-$label-claude"
  for cmd in "launch-destination" "worker-destination --from seat-max" "auto"; do
    echo "\$ fm-seat.sh $cmd"; run_seat "$HOME_DIR" "$FAKEBIN" $cmd | tail -4; echo "  [exit=$? active=$(cat "$HOME_DIR/config/claude-seat")]"
  done
  echo "--- Claude tie-break: both seats with 5h room (seat-max 5h=40 wk=14, seat-max2 5h=56 wk=10)"
  wall_case "live-$label-tie"; seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/seat-max" 40 '2026-11-02T04:00:00Z' 14 '2026-11-07T06:00:00Z' 30 6
  seat_windows "$SPEC_DIR" "$SEATS_DIR/seat-max2" 56 '2026-11-02T04:00:00Z' 10 '2026-11-07T06:00:00Z' -40 4
  echo "\$ fm-seat.sh launch-destination"; run_seat "$HOME_DIR" "$FAKEBIN" launch-destination | tail -2
  echo "\$ fm-seat.sh auto"; run_seat "$HOME_DIR" "$FAKEBIN" auto | tail -2; echo "  [active=$(cat "$HOME_DIR/config/claude-seat")]"
  echo "--- Adversarial floor: walled seat-max, seat-max2 has 5h room but weekly 5% < dest-min 10"
  wall_case "live-$label-floor"; seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/seat-max" 0 '2026-11-02T04:00:00Z' 10 '2026-11-07T06:00:00Z' -40 6
  seat_windows "$SPEC_DIR" "$SEATS_DIR/seat-max2" 56 '2026-11-02T04:00:00Z' 5 '2026-11-07T06:00:00Z' -60 4
  echo "\$ fm-seat.sh worker-destination --from seat-max"; run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from seat-max | tail -4; echo "  [exit=${PIPESTATUS[0]}]"
  echo "\$ fm-seat.sh auto"; run_seat "$HOME_DIR" "$FAKEBIN" auto | tail -2; echo "  [active=$(cat "$HOME_DIR/config/claude-seat")]"
done
