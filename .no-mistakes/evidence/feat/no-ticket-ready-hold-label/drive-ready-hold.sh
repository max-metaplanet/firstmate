#!/usr/bin/env bash
set -euo pipefail
E=~/.no-mistakes/evidence/01M69HSXN04R1RBCAZ039PJZ4D
S=$PWD/.ready-hold-validation
. bin/fm-dod-lib.sh
{
  printf 'Absent setting: label=<%s>\n' "$(fm_ready_hold_label "$S/config" widget)"
  test -z "$(fm_ready_hold_label "$S/config" widget)"
  printf 'widget\thold for approval\nother\tstop\nempty\t\n' > "$S/config/project-ready-hold-label"
  printf 'Configured widget: label=<%s>\n' "$(fm_ready_hold_label "$S/config" widget)"
  test "$(fm_ready_hold_label "$S/config" widget)" = 'hold for approval'
  for project in unconfigured empty; do
    label=$(fm_ready_hold_label "$S/config" "$project")
    printf '%s: label=<%s>\n' "$project" "$label"
    test -z "$label"
  done
  for mode in direct-PR no-mistakes; do
    printf '\n## %s / yolo off\n' "$mode"
    fm_dod_ready_hold_block "$S/config" /projects/widget off github "$mode"
    fm_dod_ready_hold_block "$S/config" /projects/widget on github "$mode" > "$S/yolo-on"
    test ! -s "$S/yolo-on"
    printf '\n%s / yolo on: no overlay emitted\n' "$mode"
    fm_dod_ready_hold_block "$S/config" /projects/unconfigured off github "$mode" > "$S/unconfigured"
    test ! -s "$S/unconfigured"
    printf '%s / undeclared project: no overlay emitted\n' "$mode"
  done
  fm_dod_ready_hold_block "$S/config" /projects/widget off gitlab direct-PR > "$S/gitlab"
  test ! -s "$S/gitlab"
  printf '\nGitLab: no overlay emitted\n'
  printf 'widget\thold\nwidget\tstop\n' > "$S/config/project-ready-hold-label"
  rc=0
  fm_dod_ready_hold_block "$S/config" /projects/widget off github direct-PR > "$S/duplicate" 2>&1 || rc=$?
  cat "$S/duplicate"
  printf 'Duplicate declaration exit=%s\n' "$rc"
  test "$rc" -ne 0
  printf 'widget hold\n' > "$S/config/project-ready-hold-label"
  rc=0
  fm_dod_ready_hold_block "$S/config" /projects/widget off github direct-PR > "$S/malformed" 2>&1 || rc=$?
  cat "$S/malformed"
  printf 'Malformed declaration exit=%s\n' "$rc"
  test "$rc" -ne 0
} > "$E/generated-contract.md"
rc=0
env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN GH_CONFIG_DIR="$S/gh" gh auth status > "$E/isolated-forge-access.txt" 2>&1 || rc=$?
printf '\nIsolated gh auth status exit=%s\n' "$rc" >> "$E/isolated-forge-access.txt"
cat "$E/generated-contract.md"
cat "$E/isolated-forge-access.txt"
