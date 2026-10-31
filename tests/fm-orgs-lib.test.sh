#!/usr/bin/env bash
# Behavior tests for bin/fm-orgs-lib.sh, the declaration of which repository
# owners this home calls ours, and for the two commit conventions
# bin/fm-dod-lib.sh's fm_ticket_resolve renders from that decision.
#
# A contribution to a third-party upstream must not carry the captain's
# internal ticket convention: `feat/no-ticket(scope): ...` advertises a ticket
# system that project does not have. The declaration decides that, and nothing
# is inferred from a remote name, a host, or a repository owner: a home that
# declares nothing keeps the unchanged convention everywhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-orgs-lib.sh
. "$ROOT/bin/fm-orgs-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-orgs-lib)
fm_git_identity fmtest fmtest@example.invalid

# make_config <name> [<declaration>]: a config dir, optionally holding
# our-organizations. Echoes its path.
make_config() {
  local name=$1 content=${2-} dir
  dir="$TMP_ROOT/config-$name"
  mkdir -p "$dir"
  [ "$#" -lt 2 ] || printf '%s\n' "$content" > "$dir/our-organizations"
  printf '%s\n' "$dir"
}

# make_project <name> <origin-url>: a git repo whose origin names <origin-url>.
# An empty URL leaves the repo without a remote. Echoes its path.
make_project() {
  local name=$1 url=$2 dir
  dir="$TMP_ROOT/project-$name"
  git init -q "$dir"
  [ -z "$url" ] || git -C "$dir" remote add origin "$url"
  printf '%s\n' "$dir"
}

# A promoted scout receives its ship contract from bin/fm-promote.sh rather than
# from a fresh brief, so the same decision must reach that path: the task's
# recorded project is what it is compared against.
test_a_promoted_scout_takes_its_project_s_convention() {
  local home id meta out rc
  home="$TMP_ROOT/promote-home"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' github.com/our-org > "$home/config/our-organizations"
  for id in promote-outside promote-ours; do
    meta="$home/state/$id.meta"
    mkdir -p "$home/data/$id"
    printf 'You are a crewmate.\n\n# Task\n## Captain%ss intent\nInvestigate the upstream bug.\n\n## Firstmate spec\nReport findings.\n' "'" \
      > "$home/data/$id/brief.md"
    case "$id" in
      promote-outside) printf 'window=fm-%s\nkind=scout\nproject=%s\nworktree=/tmp/wt\n' \
        "$id" "$(make_project "$id" https://github.com/third-party/upstream.git)" > "$meta" ;;
      *) printf 'window=fm-%s\nkind=scout\nproject=%s\nworktree=/tmp/wt\n' \
        "$id" "$(make_project "$id" https://github.com/our-org/ours.git)" > "$meta" ;;
    esac
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" \
      "$ROOT/bin/fm-promote.sh" "$id" --mode direct-PR --ticket no-ticket \
      --commit-type fix --yolo off 2>&1)
    rc=$?
    [ "$rc" -eq 0 ] || fail "promoting $id failed (exit $rc): $out"
  done
  # shellcheck disable=SC2016 # Literal backticks in the rendered contract.
  assert_grep 'must read `fix(<scope>): <message>`' "$home/data/promote-outside/ship-instructions.md" \
    'a promoted scout on a third-party project kept the ticket segment'
  # shellcheck disable=SC2016 # Literal backticks in the rendered contract.
  assert_grep 'must read `fix/no-ticket(<scope>): <message>`' "$home/data/promote-ours/ship-instructions.md" \
    'a promoted scout on one of our projects lost the ticket convention'
  pass "a promoted scout takes the convention its recorded project declares"
}

test_entry_covers_the_organization_and_its_repositories() {
  local config
  config=$(make_config owns 'github.com/our-org')
  fm_orgs_owns "$config" github.com/our-org/anything \
    || fail "a declared organization did not cover a repository it owns"
  fm_orgs_owns "$config" GitHub.com/Our-Org/Anything \
    || fail "the declaration is compared case-sensitively"
  fm_orgs_owns "$config" github.com/other-org/anything \
    && fail "a declaration covered an organization it does not name"
  fm_orgs_owns "$config" github.com/our-org-extra/anything \
    && fail "a declaration matched a longer owner name by prefix"
  pass "a declared organization covers its repositories and nothing else"
}

test_a_single_repository_entry_covers_only_that_repository() {
  local config
  config=$(make_config one-repo 'github.com/other-org/one-repo')
  fm_orgs_owns "$config" github.com/other-org/one-repo \
    || fail "a full host/owner/repo entry did not cover that repository"
  fm_orgs_owns "$config" github.com/other-org/another-repo \
    && fail "a full host/owner/repo entry covered a sibling repository"
  pass "a full repository entry covers only that repository"
}

test_comments_and_blank_lines_are_ignored() {
  local config
  config=$(make_config comments)
  printf '%s\n' '# ours' '' '  github.com/our-org  ' '# trailing comment' \
    > "$config/our-organizations"
  fm_orgs_load "$config" || fail "a file of comments and one entry did not load"
  [ "$FM_ORGS_LIST" = github.com/our-org ] \
    || fail "comments or whitespace reached the declaration: '$FM_ORGS_LIST'"
  pass "comments, blank lines, and surrounding whitespace are ignored"
}

test_an_absent_or_empty_declaration_decides_nothing() {
  local config rc
  config=$(make_config absent)
  fm_orgs_owns "$config" github.com/anyone/anything
  rc=$?
  [ "$rc" -eq 2 ] || fail "an absent declaration answered ownership (exit $rc)"
  config=$(make_config empty '# nothing declared')
  fm_orgs_owns "$config" github.com/anyone/anything
  rc=$?
  [ "$rc" -eq 2 ] || fail "a comment-only declaration answered ownership (exit $rc)"
  pass "an absent or comment-only declaration decides nothing"
}

test_one_malformed_entry_voids_the_whole_declaration() {
  local config rc project
  config=$(make_config malformed 'github.com/our-org
not-a-path')
  fm_orgs_load "$config"
  rc=$?
  [ "$rc" -eq 2 ] || fail "a malformed entry was accepted (exit $rc)"
  [ -z "$FM_ORGS_LIST" ] || fail "a malformed file still produced entries: '$FM_ORGS_LIST'"
  case "$FM_ORGS_DIAG" in
    *"not-a-path"*) ;;
    *) fail "the diagnostic did not name the malformed entry: $FM_ORGS_DIAG" ;;
  esac
  # The point of voiding the file: a typo must not reclassify our own repository
  # as third-party and strip its ticket segment.
  project=$(make_project malformed-ours https://github.com/our-org/ours.git)
  fm_orgs_plain_convention "$config" "$project"
  rc=$?
  [ "$rc" -eq 2 ] || fail "a malformed declaration decided the convention (exit $rc)"
  pass "one malformed entry voids the whole declaration"
}

test_a_declared_project_keeps_the_ticket_convention() {
  local config project rc
  config=$(make_config ours 'github.com/our-org')
  project=$(make_project ours git@github.com:our-org/ours.git)
  fm_orgs_plain_convention "$config" "$project"
  rc=$?
  [ "$rc" -eq 1 ] || fail "a declared project was treated as outside (exit $rc)"
  [ "$FM_ORGS_TARGET" = github.com/our-org/ours ] \
    || fail "the resolved publication target was '$FM_ORGS_TARGET'"
  pass "a project under a declared organization keeps the ticket convention"
}

test_an_undeclared_project_takes_the_plain_convention() {
  local config project rc
  config=$(make_config outside 'github.com/our-org')
  project=$(make_project outside https://github.com/third-party/upstream.git)
  fm_orgs_plain_convention "$config" "$project"
  rc=$?
  [ "$rc" -eq 0 ] || fail "a third-party project did not take the plain convention (exit $rc)"
  [ "$FM_ORGS_TARGET" = github.com/third-party/upstream ] \
    || fail "the resolved publication target was '$FM_ORGS_TARGET'"
  pass "a project outside every declared organization takes the plain convention"
}

test_upstream_outranks_origin_as_the_publication_target() {
  local config project rc
  config=$(make_config fork 'github.com/our-org')
  project=$(make_project fork https://github.com/our-org/fork.git)
  git -C "$project" remote add upstream https://github.com/third-party/upstream.git
  fm_orgs_plain_convention "$config" "$project"
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a fork of a third-party upstream was decided by its own origin (exit $rc)"
  [ "$FM_ORGS_TARGET" = github.com/third-party/upstream ] \
    || fail "the fork resolved to '$FM_ORGS_TARGET' rather than its upstream"
  pass "the publication target, not the push remote, decides the convention"
}

test_an_unresolvable_target_keeps_the_unchanged_convention() {
  local config project rc
  config=$(make_config unknown 'github.com/our-org')
  project=$(make_project unknown '')
  fm_orgs_plain_convention "$config" "$project"
  rc=$?
  [ "$rc" -eq 2 ] || fail "a project with no remote was decided (exit $rc)"
  project=$(make_project local-remote "$TMP_ROOT/some/local/path")
  fm_orgs_plain_convention "$config" "$project"
  rc=$?
  [ "$rc" -eq 2 ] || fail "a local-path remote was decided (exit $rc)"
  fm_orgs_plain_convention "$config" "$TMP_ROOT/not-a-directory"
  rc=$?
  [ "$rc" -eq 2 ] || fail "a missing project directory was decided (exit $rc)"
  pass "an unresolvable publication target keeps the unchanged convention"
}

# resolve_header <plain>: fm_ticket_resolve for a ticketless fix task, echoing
# the rendered Definition of done header.
resolve_header() {
  fm_ticket_resolve no-ticket fix t-conv '' 0 test partial "$1" \
    || fail "fm_ticket_resolve refused plain=$1"
  printf '%s\n' "$FM_TICKET_HEADER"
}

test_the_ticket_convention_is_the_unchanged_default() {
  local header
  header=$(resolve_header 0)
  # shellcheck disable=SC2016 # Literal backticks in the rendered contract.
  case "$header" in
    *'must read `fix/no-ticket(<scope>): <message>`'*) ;;
    *) fail "the default rendering lost the ticket convention: $header" ;;
  esac
  case "$header" in
    *'publishes outside the organizations'*)
      fail "the default rendering carried the third-party sentence" ;;
  esac
  pass "the ticket convention is the unchanged default rendering"
}

test_the_plain_rendering_carries_no_ticket_segment() {
  local header
  header=$(resolve_header 1)
  # shellcheck disable=SC2016 # Literal backticks in the rendered contract.
  case "$header" in
    *'must read `fix(<scope>): <message>`'*) ;;
    *) fail "the plain rendering did not require a conventional subject: $header" ;;
  esac
  # shellcheck disable=SC2016 # Literal backticks in the rendered contract.
  case "$header" in
    *'must read `fix/no-ticket(<scope>)'*)
      fail "the plain rendering still required the ticket segment: $header" ;;
  esac
  # shellcheck disable=SC2016 # Literal backticks in the rendered contract.
  case "$header" in
    *'never write `fix/no-ticket(<scope>)`'*) ;;
    *) fail "the plain rendering did not forbid the ticket segment: $header" ;;
  esac
  pass "the plain rendering requires a conventional subject with no ticket segment"
}

test_a_real_ticket_is_kept_out_of_a_third_party_subject() {
  local header
  fm_ticket_resolve ENG-42 feat t-eng '' 0 test partial 1 \
    || fail "fm_ticket_resolve refused a real ticket on a third-party project"
  header=$FM_TICKET_HEADER
  # shellcheck disable=SC2016 # Literal backticks in the rendered contract.
  case "$header" in
    *'must read `feat(<scope>): <message>`'*) ;;
    *) fail "a real ticket did not render the plain subject: $header" ;;
  esac
  case "$header" in
    *'Ticket: ENG-42'*) ;;
    *) fail "the brief header stopped recording the ticket: $header" ;;
  esac
  case "$header" in
    *'read ticket ENG-42 in full'*) ;;
    *) fail "the plain rendering dropped the read-the-ticket instruction: $header" ;;
  esac
  pass "a real ticket still binds the worker while staying out of the published subject"
}

test_the_plain_retitle_step_confirms_rather_than_inserts() {
  local retitle
  fm_ticket_resolve no-ticket fix t-retitle '' 0 test partial 1 \
    || fail "fm_ticket_resolve refused the plain retitle case"
  retitle=$FM_TICKET_NM_RETITLE
  case "$retitle" in
    *'never add a ticket segment'*) ;;
    *) fail "the plain retitle step did not forbid a ticket segment: $retitle" ;;
  esac
  # shellcheck disable=SC2016 # Literal backticks in the rendered contract.
  case "$retitle" in
    *'insert `/no-ticket`'*)
      fail "the plain retitle step still inserted the ticket: $retitle" ;;
  esac
  case "$retitle" in
    *'no-mistakes(<step>)'*) ;;
    *) fail "the plain retitle step never named the pipeline's own commits: $retitle" ;;
  esac
  case "$retitle" in
    *'never updates a remote'*) ;;
    *) fail "the plain retitle step did not state the custody limit: $retitle" ;;
  esac
  fm_ticket_resolve no-ticket fix t-retitle-default '' 0 test partial 0 \
    || fail "fm_ticket_resolve refused the default retitle case"
  # shellcheck disable=SC2016 # Literal backticks in the rendered contract.
  case "$FM_TICKET_NM_RETITLE" in
    *'insert `/no-ticket`'*) ;;
    *) fail "the default retitle step stopped inserting the ticket: $FM_TICKET_NM_RETITLE" ;;
  esac
  pass "the plain retitle step confirms the conventional title and states the custody limit"
}

test_the_branch_is_unaffected_by_the_convention() {
  local plain_branch ticket_branch
  fm_ticket_resolve no-ticket fix t-branch '' 0 test partial 1 \
    || fail "fm_ticket_resolve refused the plain branch case"
  plain_branch=$FM_TICKET_BRANCH
  fm_ticket_resolve no-ticket fix t-branch '' 0 test partial 0 \
    || fail "fm_ticket_resolve refused the default branch case"
  ticket_branch=$FM_TICKET_BRANCH
  [ "$plain_branch" = "$ticket_branch" ] \
    || fail "the convention changed the ship branch: '$plain_branch' vs '$ticket_branch'"
  [ "$plain_branch" = fix/no-ticket-t-branch ] \
    || fail "the ship branch is no longer the convention's branch: $plain_branch"
  pass "the ship branch is identical under both conventions"
}

test_entry_covers_the_organization_and_its_repositories
test_a_single_repository_entry_covers_only_that_repository
test_comments_and_blank_lines_are_ignored
test_an_absent_or_empty_declaration_decides_nothing
test_one_malformed_entry_voids_the_whole_declaration
test_a_declared_project_keeps_the_ticket_convention
test_an_undeclared_project_takes_the_plain_convention
test_upstream_outranks_origin_as_the_publication_target
test_an_unresolvable_target_keeps_the_unchanged_convention
test_the_ticket_convention_is_the_unchanged_default
test_the_plain_rendering_carries_no_ticket_segment
test_a_real_ticket_is_kept_out_of_a_third_party_subject
test_the_plain_retitle_step_confirms_rather_than_inserts
test_the_branch_is_unaffected_by_the_convention
test_a_promoted_scout_takes_its_project_s_convention

echo "all fm-orgs-lib tests passed"
