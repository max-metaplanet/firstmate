#!/usr/bin/env bash
set -euo pipefail
. bin/fm-dod-lib.sh
cfg=$PWD/.test-ready-hold/config
mkdir -p "$cfg"
evidence=~/.no-mistakes/evidence/01M69PB273Q428N9RKZRTWNQAW
printf 'sample widget\thold for approval\nother\tstop\n' > "$cfg/project-ready-hold-label"
fm_dod_ready_hold_block "$cfg" '/disposable/sample widget' off github no-mistakes > "$evidence/ready-hold-no-mistakes.md"
fm_dod_ready_hold_block "$cfg" '/disposable/sample widget' off github direct-PR > "$evidence/ready-hold-direct-pr.md"
test -s "$evidence/ready-hold-no-mistakes.md"
test -s "$evidence/ready-hold-direct-pr.md"
{
  printf 'Configured project: sample widget; configured exact label: '
  label=$(fm_ready_hold_label "$cfg" 'sample widget')
  test "$label" = 'hold for approval'
  printf '%s\n' "$label"
  for posture in on off; do
    output=$(fm_dod_ready_hold_block "$cfg" '/disposable/sample widget' "$posture" github direct-PR)
    if [ "$posture" = on ]; then test -z "$output"; printf 'yolo=on: no ready-hold overlay emitted\n'; else test -n "$output"; printf 'yolo=off: ready-hold overlay emitted\n'; fi
  done
  for forge in gitlab forgejo external; do
    output=$(fm_dod_ready_hold_block "$cfg" '/disposable/sample widget' off "$forge" direct-PR)
    test -z "$output"
    printf '%s: no overlay emitted\n' "$forge"
  done
  output=$(fm_dod_ready_hold_block "$cfg" /disposable/unconfigured off github direct-PR)
  test -z "$output"
  printf 'Unconfigured project: no overlay emitted\n'
  printf 'sample widget\t\n' > "$cfg/project-ready-hold-label"
  output=$(fm_ready_hold_label "$cfg" 'sample widget'); test -z "$output"
  printf 'Explicit empty label: lookup returns no hold\n'
  printf 'sample widget\thold\nsample widget\tstop\n' > "$cfg/project-ready-hold-label"
  if fm_dod_ready_hold_block "$cfg" '/disposable/sample widget' off github direct-PR; then exit 90; else printf 'Duplicate configuration: refused (no overlay emitted)\n'; fi
  printf 'sample widget hold\n' > "$cfg/project-ready-hold-label"
  if fm_dod_ready_hold_block "$cfg" '/disposable/sample widget' off github direct-PR; then exit 91; else printf 'Malformed configuration: refused (no overlay emitted)\n'; fi
  rm "$cfg/project-ready-hold-label"
  ln -s absent "$cfg/project-ready-hold-label"
  if fm_dod_ready_hold_block "$cfg" '/disposable/sample widget' off github direct-PR; then exit 92; else printf 'Dangling configuration: refused (no overlay emitted)\n'; fi
} > "$evidence/ready-hold-config-transcript.txt" 2>&1
cat "$evidence/ready-hold-config-transcript.txt"
cat "$evidence/ready-hold-no-mistakes.md"
