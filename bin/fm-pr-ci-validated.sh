#!/usr/bin/env bash
# fm-pr-ci-validated.sh - apply the CI-validated marker to one GitHub pull
# request.
#
# Some firstmate pull requests are raised outside the no-mistakes pipeline on
# purpose, under the captain's standing rule that local validation skips the
# long serial suite and this repository's own parallel CI decides instead.
# Those pull requests carry no no-mistakes signature, so the "PR must be raised
# via no-mistakes" job in .github/workflows/no-mistakes-required.yml fails and
# mails a failure for a deliberate delivery choice. That noise is what makes a
# real failure hard to spot. This script applies the one marker that job
# accepts, so the check reports the deliberate state instead.
#
# The marker is a pull-request label, not a commit trailer or a body line,
# because only an account with triage or write access on the repository can add
# one. No ordinary push and no outside contributor gets it by default, so an
# unmarked pull request raised outside the pipeline still fails that check.
#
# Applying the marker is not a merge waiver and grants no merge authority.
# bin/fm-pr-merge.sh's attended --allow-red remains the unchanged fallback for
# a check that is red for any other reason.
#
# Usage:
#   fm-pr-ci-validated.sh <pr-url>   add the marker to that pull request
#   fm-pr-ci-validated.sh --label    print the marker label name
#   fm-pr-ci-validated.sh --help
#
# <pr-url> is a full https://github.com/<owner>/<repo>/pull/<number> URL; the
# marker is a GitHub label, so no other forge is accepted. The label is created
# on the repository when it does not exist yet, and adding it twice is a no-op.
#
# Exit codes: 0 when the marker was applied, 2 on a usage or URL error, and 1
# when gh-axi is missing or the forge refused a read or write.
set -u

FM_PR_CI_VALIDATED_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$FM_PR_CI_VALIDATED_SELF_DIR/fm-pr-lib.sh"

# The one name this script and .github/workflows/no-mistakes-required.yml must
# agree on; tests/fm-no-mistakes-required.test.sh holds them together.
FM_CI_VALIDATED_LABEL=fm-ci-validated
FM_CI_VALIDATED_COLOR=0e8a16
FM_CI_VALIDATED_DESCRIPTION='Deliberately validated by this repository CI instead of the local no-mistakes pipeline'

fm_pr_ci_validated_usage() {
  cat <<'USAGE'
Usage: fm-pr-ci-validated.sh <pr-url>
       fm-pr-ci-validated.sh --label
       fm-pr-ci-validated.sh --help
USAGE
}

# True when the repository already carries the marker label. Reads gh-axi's
# label listing, whose names are the indented lines under its labels block.
fm_pr_ci_validated_label_exists() {  # <owner/repo>
  local listing
  listing=$(gh-axi label list --repo "$1" 2>/dev/null) || return 2
  printf '%s\n' "$listing" | awk -v want="$FM_CI_VALIDATED_LABEL" '
    /^labels\[/ { listing = 1; next }
    listing && /^  / { name = substr($0, 3); if (name == want) { found = 1 } ; next }
    listing { listing = 0 }
    END { exit found ? 0 : 1 }
  '
}

case "${1-}" in
  --help | -h)
    fm_pr_ci_validated_usage
    exit 0
    ;;
  --label)
    [ "$#" -eq 1 ] || { echo "error: --label takes no further arguments" >&2; exit 2; }
    printf '%s\n' "$FM_CI_VALIDATED_LABEL"
    exit 0
    ;;
esac

if [ "$#" -ne 1 ] || [ -z "${1-}" ]; then
  fm_pr_ci_validated_usage >&2
  exit 2
fi

if ! fm_pr_url_parse "$1"; then
  echo "error: not a recognized pull request URL: $1" >&2
  exit 2
fi
if [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: the CI-validated marker is a GitHub pull-request label, and $FM_PR_URL is a $FM_PR_PROVIDER request" >&2
  exit 2
fi

if ! command -v gh-axi >/dev/null 2>&1; then
  echo "error: gh-axi is required to apply the $FM_CI_VALIDATED_LABEL marker" >&2
  exit 1
fi

fm_pr_ci_validated_label_exists "$FM_PR_PATH"
case "$?" in
  0) ;;
  1)
    if ! gh-axi label create --name "$FM_CI_VALIDATED_LABEL" \
      --color "$FM_CI_VALIDATED_COLOR" \
      --description "$FM_CI_VALIDATED_DESCRIPTION" \
      --repo "$FM_PR_PATH" >/dev/null; then
      echo "error: could not create the $FM_CI_VALIDATED_LABEL label on $FM_PR_PATH" >&2
      exit 1
    fi
    ;;
  *)
    echo "error: could not read the labels of $FM_PR_PATH" >&2
    exit 1
    ;;
esac

if ! gh-axi pr edit "$FM_PR_NUMBER" --repo "$FM_PR_PATH" \
  --add-label "$FM_CI_VALIDATED_LABEL" >/dev/null; then
  echo "error: could not add the $FM_CI_VALIDATED_LABEL label to $FM_PR_URL" >&2
  exit 1
fi

printf 'marked %s with %s\n' "$FM_PR_URL" "$FM_CI_VALIDATED_LABEL"
