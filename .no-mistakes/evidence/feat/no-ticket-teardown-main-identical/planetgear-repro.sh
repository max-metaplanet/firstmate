# Sourced after tests/fm-teardown.test.sh's fixture helpers (test calls stripped).
# Reproduces the PlanetGear case: merged PR, copy left holding 34 staged files
# that a branch update restaged byte-identical to origin/main.
build_planetgear_case() {  # <name> <teardown-script>
  local case_dir i tmp
  case_dir=$(make_case "$1")
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "pilot feature"
  land_on_origin_main "$case_dir" feature.txt hello
  append_pr_meta_for_current_head "$case_dir"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  # Other work lands on main after the merge: 34 files, one of them executable.
  tmp="$case_dir/_land34"; git clone -q "$case_dir/origin.git" "$tmp"
  mkdir -p "$tmp/app/sub dir"
  for i in $(seq 1 33); do printf 'line %s\n' "$i" > "$tmp/app/sub dir/f$i.txt"; done
  printf '#!/bin/sh\necho hi\n' > "$tmp/app/run.sh"; chmod +x "$tmp/app/run.sh"
  git -C "$tmp" add -A; git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main moves on"
  git -C "$tmp" push -q origin HEAD:main; rm -rf "$tmp"
  # The branch update restages main's own content into the copy.
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" checkout origin/main -- app
  printf '%s\n' "$case_dir"
}
run_case() {  # <label> <case_dir> <teardown>
  local label=$1 case_dir=$2 rc
  echo "=== $label"
  echo "--- git status --porcelain (count / sample):"
  git -C "$case_dir/wt" status --porcelain | wc -l | tr -d ' '
  git -C "$case_dir/wt" status --porcelain | head -3
  TEARDOWN=$3
  set +e; run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?; set -e
  echo "--- fm-teardown.sh task-x1 exit=$rc; stderr:"
  sed 's/^/    /' "$case_dir/stderr" | head -15
  if [ -f "$case_dir/state/task-x1.meta" ]; then echo "--- task record: STILL PRESENT"; else echo "--- task record: removed (teardown completed)"; fi
  echo "--- staged entries after: $(git -C "$case_dir/wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
}
NEW=$ROOT/bin/fm-teardown.sh
c=$(build_planetgear_case pg-old); NEWROOT=$ROOT; ROOT=$OLD_ROOT; run_case "BEFORE (base f64491e2): 34 staged base-identical files" "$c" "$OLD_ROOT/bin/fm-teardown.sh"; ROOT=$NEWROOT
c=$(build_planetgear_case pg-new); run_case "AFTER (this change): 34 staged base-identical files" "$c" "$NEW"
c=$(build_planetgear_case pg-one-byte); printf 'line 7 edited\n' > "$c/wt/app/sub dir/f7.txt"
run_case "ADVERSARIAL: 33 identical + 1 edited file" "$c" "$NEW"
c=$(build_planetgear_case pg-mode); chmod -x "$c/wt/app/run.sh"
run_case "ADVERSARIAL: identical bytes but exec bit dropped" "$c" "$NEW"
c=$(build_planetgear_case pg-staged-hidden); printf 'secret staged\n' > "$c/wt/app/sub dir/f3.txt"; git -C "$c/wt" add -- "app/sub dir/f3.txt"; printf 'line 3\n' > "$c/wt/app/sub dir/f3.txt"
run_case "ADVERSARIAL: staged unique blob, working tree reverted to base bytes" "$c" "$NEW"
c=$(build_planetgear_case pg-forced); printf 'mine\n' > "$c/wt/app/unique.txt"
TEARDOWN=$NEW; set +e; run_teardown "$c" --force >/dev/null 2>&1; echo "=== ESCAPE HATCH: unique dirt + --force exit=$?"; set -e
