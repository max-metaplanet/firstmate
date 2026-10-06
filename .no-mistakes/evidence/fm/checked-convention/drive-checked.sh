#!/usr/bin/env bash
# Drives the real bin/fm-brief.sh and bin/fm-captain-hold.sh in an isolated FM_HOME.
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-checked-XXXX)
home="$T/home"; mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$t"; chmod +x "$home/fakebin/$t"; done

echo "=== S1: ship briefs (needs-decision rule) ==="
for mode in no-mistakes direct-PR local-only; do
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship-$mode some-proj --mode $mode >/dev/null 2>&1 || echo "SCAFFOLD FAIL $mode"
  echo "--- $mode: $home/data/ship-$mode/brief.md"
  grep -n -A4 'append `needs-decision' "$home/data/ship-$mode/brief.md"
done

echo; echo "=== S2: scout brief (needs-decision + report contract) ==="
FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" scout-x some-proj --scout >/dev/null 2>&1 || echo "SCAFFOLD FAIL scout"
grep -n -A4 'append `needs-decision' "$home/data/scout-x/brief.md"
grep -n -B1 -A1 'Precede every question' "$home/data/scout-x/brief.md"

echo; echo "=== S3: secondmate charter (decision only, not blocker) ==="
FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' "$ROOT/bin/fm-brief.sh" mate-x --secondmate --no-projects >/dev/null 2>&1 || echo "SCAFFOLD FAIL mate"
grep -n 'checked:' "$home/data/mate-x/brief.md"
echo "count of 'decision or blocker, carry': $(grep -c 'decision or blocker, carry' "$home/data/mate-x/brief.md")"
echo "blocked line requires checked?: $(grep -n '^.*append `blocked' "$home/data/mate-x/brief.md" | grep -c checked)"

run_captain() { PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }

echo; echo "=== S4: hold with the skill's documented checked: example reason ==="
R='checked: tasks-axi show eng-2531 records the ruling as confirmed but files no query or date, and two reports read the column the other way. Rule on which meaning holds'
run_captain hold checked-call --title "Choose column meaning" --reason "$R" --repo sample; echo "exit=$?"
grep -n 'checked-call' -A3 "$home/data/backlog.md"

echo; echo "=== S5: hold with 'checked: none possible - <why>' ==="
run_captain hold none-call --title "Pick vendor" --reason "checked: none possible - the vendor quote exists only in the captain's email. Pick vendor A or B" --repo sample; echo "exit=$?"
grep -n 'none-call' -A3 "$home/data/backlog.md"

echo; echo "=== S6 adversarial: hold WITHOUT checked: is still accepted - not enforced yet ==="
run_captain hold bare-call --title "Bare call" --reason "captain must pick north or south" --repo sample; echo "exit=$?"
grep -n 'bare-call' -A3 "$home/data/backlog.md"

echo; echo "=== S7 adversarial: checked: part with parentheses is refused by the existing one-line contract ==="
run_captain hold paren-call --title "Paren call" --reason "checked: grep (bin/) found nothing. Rename it" --repo sample; echo "exit=$?"
rm -rf "$T"
