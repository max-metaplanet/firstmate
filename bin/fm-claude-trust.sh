#!/usr/bin/env bash
# Pre-register Claude Code's workspace trust, and the external-CLAUDE.md-import
# approval that rides with it, for the directory a claude launch is about to
# start in - the isolated task worktree of a ship or scout crewmate, the seeded
# home of a secondmate and the project clones it works through, a disposable lab
# home, or a project checkout a claude launch starts in directly - so the agent
# reaches its brief or charter instead of wedging on a dialog firstmate cannot
# answer.
#
# Usage: fm-claude-trust.sh <worktree> <project>
#        fm-claude-trust.sh --project <checkout>
#        fm-claude-trust.sh --secondmate-home <home> <id>
#        fm-claude-trust.sh --lab-home <home>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
#   --project   a checkout a claude launch starts in directly, including a
#               project clone registered when it is added rather than at the
#               next wedge
#   <home>      the seeded secondmate home this spawn launches into
#   <id>        the secondmate id that home must already be marked for
#   --lab-home  the disposable lab home bin/fm-live-lab.sh launches a lab
#               primary in
# Prints one line per project-config entry it registered; refuses loudly on
# anything else.
#
# WHY THIS EXISTS. Claude Code gates a folder it has never seen behind an
# interactive workspace-trust dialog, and --dangerously-skip-permissions does
# NOT cover it: `claude --help` records that the dialog is skipped only in
# non-interactive mode (-p, or a non-TTY stdout), and a spawned pane is
# interactive. Every fresh task worktree therefore hits it, and so does every
# secondmate home the operator has not opened by hand. The dialog renders
# with the cursor on "No, exit" and firstmate's steering plane carries only
# Enter, Escape and C-c with no arrow navigation, so firstmate cannot answer it
# and must not try - pressing Enter would select exit. The agent wedges before
# it ever reads the brief. Registering the trust before launch is the only
# control that reaches an interactive pane. The same reasoning covers Claude
# Code's separate "Allow external CLAUDE.md file imports?" dialog, which
# `--setting-sources project,local` (firstmate PR 10's minimal worker tool
# surface) stopped suppressing: it renders whenever a loaded Project- or
# Local-type CLAUDE.md or .claude/rules entry imports a path outside the
# working directory, and it is gated the same fail-closed way as trust: cursor
# on "No, disable", no arrow navigation from firstmate's steering plane, and
# Escape records a permanent decline.
#
# THE IMPORT APPROVAL IS STANDING CONSENT, NOT A GUESS. This script used to
# write the two import flags only onto an entry that ALREADY carried
# hasClaudeMdExternalIncludesApproved===true, because no human had authorised
# anything wider and manufacturing consent from an absent flag would have spent
# a decision nobody made. The captain gave that authorisation on 2026-11-16:
# "i pre auth and approve whatever solution means workers or agents can do it
# and i dont have to do it or it doesnt come up at all". So the gate is now the
# opposite shape: every entry this script registers receives both import flags
# UNLESS that entry records an explicit prior decline. An absent flag, a
# never-asked default pair, and a prior "Yes, allow" all take the approval.
# What stays unchanged is the one thing the standing consent does not reach: a
# human who answered "No, disable" in this very store. That pair is preserved
# below exactly as it was, because standing consent to skip a dialog is not
# consent to reverse an answer a human already gave.
#
# TWO PROJECT-CONFIG ENTRIES IN WORKTREE MODE, NOT ONE. Registering both flags
# on the worktree entry alone (the original trust-only design) leaves the
# external-imports dialog showing. Verified 2026-09-06 by disassembling the
# installed `claude` binary and reproducing in an isolated three-way tmux
# launch, and re-proven against claude 2.1.325 on 2026-11-16 (the evidence and
# the exact reads are in docs/verification/claude-external-imports.md):
# Claude Code's own trust check (`Rde`) reads the canonical
# project-root entry first and, failing that, falls back to an ancestor walk
# from the worktree upward that DOES reach the worktree's own entry - which is
# why the trust dialog kept working after PR 10. The external-imports check
# has no such fallback: it reads ONLY the canonical project-root entry, and
# that root is never the worktree - Claude Code's own git-root canonicalization
# walks a linked worktree's `.git` file through its `commondir` pointer back to
# the PRIMARY CHECKOUT, exactly the <project> argument this script already
# receives for the worktree-mode scope test below. Every mode registers the
# launch directory and, when distinct, its canonical checkout; secondmate-home
# mode also registers each eligible project clone and its canonical checkout.
# Registering either is a
# write to the launching user's OWN Claude config store, keyed by a directory
# PATH the scope test below has already verified is real - not a write to the
# project's tracked content, so hard rule 1 does not apply.
#
# AN EXPLICIT DECLINE KEEPS ITS IMPORT FLAGS. Every registered entry receives
# hasTrustDialogAccepted, in every mode. If that entry already carries
# hasClaudeMdExternalIncludesApproved===false WITH
# hasClaudeMdExternalIncludesWarningShown===true, its two import flags are read
# but never assigned: standing consent does not reverse a human's own answer.
# Every other entry receives both import flags. A decline neither refuses the
# registration nor skips any key. Verified live on 2026-11-16 with claude
# 2.1.325 on the Lima fleet VM, tmux 3.6: a trusted project with that decline
# pair and a Project-type external import reached the composer without either
# dialog. WarningShown alone suppresses the imports dialog while Approved
# false keeps the import excluded; docs/verification/claude-external-imports.md
# records the command and evidence. Approved false with WarningShown false or
# absent is the never-asked default, so it takes the standing consent.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY, and it is STRUCTURAL rather than a
# path policy. Each mode has its own, because the directories have entirely
# different shapes on disk.
#
# WORKTREE MODE. <worktree> must be a LINKED git worktree - its own git dir,
# sharing <project>'s common dir - whose top level is exactly the resolved
# argument. Git is the ground truth, so the argument is never trusted on its
# own word: a primary checkout (git dir == common dir), a worktree of an
# unrelated repo, a subdirectory of a worktree, a plain directory, and a home
# directory are each refused. Refusal is a non-zero exit, never a warning and
# never a silent skip. When <project> is itself a linked worktree (a
# secondmate home spawned from, rather than as, the primary checkout),
# refusing outright would wedge a relaunch that is otherwise perfectly valid,
# so the canonical checkout is derived structurally and verified rather than
# assumed - see canonical_checkout_of below, which is the single owner of that
# derivation for every mode.
#
# The test is deliberately NOT a treehouse or orca path prefix. Treehouse's
# root is configurable (--root, TREEHOUSE_ROOT, config, and a relative
# in-project pool), so a prefix check would refuse legitimate roots, accept
# whatever a mutable env var names, and add exactly the policy surface this
# registration must not grow. The structural test is verified for treehouse
# worktrees, which are linked git worktrees. Orca's worktree shape is UNVERIFIED:
# docs/orca-backend.md calls it an "independent worktree", which does not
# establish a shared git common dir, and orca is macOS-only and was not installed
# where this was written. If Orca clones instead of linking, its git dir equals
# its common dir, so this refuses it as a primary checkout and an orca claude
# spawn fails loudly here rather than wedging on the dialog later. fm-spawn.sh's
# own validate_spawn_worktree would not catch that case first: it compares the
# worktree root against the primary and never compares common dirs, so an
# independent clone passes it. Close this on a box that has Orca through the live
# opt-in guard family (FM_*_LIVE_E2E=1) and record the result in
# docs/verification/runtime-backends.md, rather than assuming the shape here.
#
# PROJECT MODE. A checkout a claude launch starts in directly has no second
# argument to relate it to, so its evidence is the one structural fact that
# makes a path a legitimate registration key at all: Claude Code derives the
# project-config key for a launch from the GIT ROOT of the launch directory, so
# the argument must be the top level of a git checkout and exactly the resolved
# argument, never a subdirectory of one and never a plain directory. A linked
# worktree is accepted and collapses to its primary checkout the same way
# <project> does, because a firstmate home or project clone is legitimately
# leased as one. This mode claims only "a claude launch starts here"; it never
# claims the relation between two directories that worktree mode checks, so it
# is reached only from firstmate's own tracked launch paths and from the
# project-add step the project-management skill owns.
#
# SECONDMATE-HOME MODE. A secondmate home is a whole firstmate instance rather
# than a task worktree, and bin/fm-home-seed.sh produces it in two shapes: a
# leased treehouse worktree (linked) and a standalone clone of the firstmate
# repo (a primary checkout). The worktree test above therefore cannot decide
# this case at all - it refuses the standalone clone as a primary checkout,
# which is why a claude secondmate in an explicit ~/fm-homes/<id> home met the
# dialog with nothing registered. Git shape is not the evidence here; THE SEED
# IS. The home must carry a .fm-secondmate-home marker that is a regular file
# this user owns, never a symlink, naming exactly the <id> passed; it must hold
# the firstmate instance files AGENTS.md and bin/; and each of its data, state,
# config and projects paths must resolve inside the home. That is the set
# bin/fm-home-seed.sh writes and bin/fm-spawn.sh's validate_firstmate_home_for_spawn
# re-checks before launch, so this accepts exactly the homes a secondmate spawn
# will launch into and nothing wider: a plain directory, a project checkout, an
# ordinary firstmate checkout, a home marked for a different secondmate, and a
# home whose operational directory escapes it are each refused. An ABSENT
# operational directory is accepted for the same reason the spawn accepts one -
# a test stricter than the spawn's own would move the wedge from the dialog to
# a refusal without making any unseeded directory less trusted.
#
# Home-level trust is broader than worktree trust, since the pane starts in the
# home and the secondmate works across it, so it is granted on that seed
# evidence alone and never on a caller's word about what a path is.
#
# THE HOME'S PROJECT CLONES ARE REGISTERED WITH IT. A secondmate works through
# the clones under <home>/projects, and a claude launch in one of those - the
# mate's own worker, or an operator opening it on that host - reads a
# project-config entry keyed to that clone, not to the home. Nothing registered
# those entries before, which is how a remote secondmate host ended up with
# every project but one still wedging the dialog. Each immediate child of
# <home>/projects is registered when it is itself the top level of a git
# checkout that resolves inside the home, together with the canonical checkout
# it collapses to; anything else there is skipped silently, because a stray
# file or a non-repository directory is not a launch target and refusing the
# whole home over one would strand the spawn.
#
# LAB-HOME MODE. A disposable lab primary (bin/fm-live-lab.sh) launches in a lab
# home that is neither a task worktree nor a seeded secondmate home.
# The evidence is structural: the home must carry bin/fm-lab-home.sh's marker
# (a regular file this user owns, never a symlink, holding the token
# bin/fm-gate-refuse-lib.sh owns), hold
# AGENTS.md and bin/, and be a primary git checkout whose top level is exactly
# the argument, because Claude Code keys the launch to that root.
# bin/fm-live-lab.sh removes the entry again when it tears the lab down.
#
# Only the launching user's own store is written: the projects entries listed
# above in ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json, which must be a regular
# file this uid owns. Every unrelated key and project entry is preserved, and
# every entry lands in one atomic replacement. fm-spawn.sh forwards
# CLAUDE_CONFIG_DIR onto the claude launch verbatim rather than resolving it,
# and the pane starts in the registered directory, so only an absolute value
# names the same store on both sides; a relative one is refused below rather
# than guessed at.
set -u
# Path resolution here must answer from the filesystem, never from the caller's
# environment, because the refusals below are the safety property. CDPATH would
# redirect any relative `cd` operand - notably the `.git` that
# `git rev-parse --git-common-dir` returns for a primary checkout - into an
# unrelated directory. The git overrides do the same to git's own answers: an
# inherited GIT_DIR with GIT_WORK_TREE makes a primary checkout report a linked
# worktree's git dir, so the primary-checkout refusal would pass. Git exports
# GIT_DIR into every hook environment, so an inherited value is ordinary rather
# than hostile. Clear the whole class once here so every subshell inherits it
# and a later added git call cannot silently reintroduce the hole.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-claude-trust.sh <worktree> <project>" >&2
  echo "       fm-claude-trust.sh --project <checkout>" >&2
  echo "       fm-claude-trust.sh --secondmate-home <home> <id>" >&2
  echo "       fm-claude-trust.sh --lab-home <home>" >&2
  exit 2
}

# MODE selects which structural scope test decides the argument, and SCOPE_NOUN
# names what the argument was expected to be so every shared refusal below reads
# correctly in both modes.
case "${1:-}" in
  --secondmate-home)
    [ "$#" -eq 3 ] || usage
    MODE=secondmate-home
    TARGET_ARG=$2
    SUB_ID=$3
    PROJ_ARG=
    SCOPE_NOUN="secondmate home"
    ;;
  --lab-home)
    [ "$#" -eq 2 ] || usage
    MODE=lab-home
    TARGET_ARG=$2
    SUB_ID=
    PROJ_ARG=
    SCOPE_NOUN="lab home"
    ;;
  --project)
    [ "$#" -eq 2 ] || usage
    MODE=project
    TARGET_ARG=$2
    SUB_ID=
    PROJ_ARG=
    SCOPE_NOUN="project checkout"
    ;;
  '' | -h | --help)
    usage
    ;;
  *)
    [ "$#" -eq 2 ] || usage
    MODE=worktree
    TARGET_ARG=$1
    SUB_ID=
    PROJ_ARG=$2
    SCOPE_NOUN="task worktree"
    ;;
esac

refuse() { echo "error: refusing to pre-register Claude trust: $1" >&2; exit 1; }

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/fm-gate-refuse-lib.sh"

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# The fully resolved path of an existing file, or empty. Resolution runs in node
# because it must follow a symlink chain to its final target, and node is
# already this script's JSON writer.
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

# The resolved common dir of a git worktree, or empty. --git-common-dir can be
# relative, so it is resolved from inside the worktree rather than joined here.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

# The canonical checkout a launch in <dir> collapses to, which is the project
# key Claude Code's external-imports check reads. A primary checkout (its own
# git dir IS the common dir) is its own canonical checkout. A linked worktree
# canonicalizes to the primary checkout its common dir belongs to - git's
# git-common-dir answer never changes by which worktree asks, so that primary
# is the common dir's parent directory in the standard non-bare,
# non-GIT_DIR-overridden layout this script already requires elsewhere. The
# derived path is never assumed: its own resolved git dir must equal that same
# common dir, the same primary-checkout definition used throughout, or this
# returns nothing and the caller refuses rather than guesses. This is the one
# owner of that derivation; every mode goes through it.
canonical_checkout_of() {
  local dir=$1 git_dir common canon canon_git
  git_dir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  git_dir=$(real_dir "$git_dir") || return 1
  [ -n "$git_dir" ] || return 1
  common=$(common_dir_of "$dir") || return 1
  [ -n "$common" ] || return 1
  if [ "$git_dir" = "$common" ]; then
    printf '%s\n' "$dir"
    return 0
  fi
  canon=$(real_dir "$(dirname -- "$common")") || return 1
  [ -n "$canon" ] || return 1
  canon_git=$(git -C "$canon" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  canon_git=$(real_dir "$canon_git") || return 1
  [ "$canon_git" = "$common" ] || return 1
  printf '%s\n' "$canon"
}

# The resolved top level of the git checkout at <dir>, but only when that top
# level IS <dir>; a subdirectory of a checkout answers its root and so is
# refused by the equality test rather than silently registered under it.
checkout_top_is() {
  local dir=$1 top
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ "$(real_dir "$top")" = "$dir" ]
}

TARGET_REAL=$(real_dir "$TARGET_ARG") || true
[ -n "$TARGET_REAL" ] || refuse "$SCOPE_NOUN '$TARGET_ARG' is not an accessible directory"
if [ "$MODE" = worktree ]; then
  PROJ_REAL=$(real_dir "$PROJ_ARG") || true
  [ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"
fi

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-${HOME:-}}
[ -n "$CONFIG_DIR" ] || refuse "neither CLAUDE_CONFIG_DIR nor HOME is set, so the store cannot be located"
# A relative value resolves against this process's cwd here but against the
# worker's own cwd once fm-spawn.sh forwards it verbatim onto the launch, so the
# two sides can name different stores and the registration would report a
# success the worker never sees. Refuse rather than guess at the worker's cwd.
case ${CLAUDE_CONFIG_DIR:-} in
  '' | /*) ;;
  *) refuse "CLAUDE_CONFIG_DIR '$CLAUDE_CONFIG_DIR' is a relative path, so the store the worker reads cannot be guaranteed to be the one written here; set it to an absolute path" ;;
esac
# Trust registration may create the store inside an existing profile, but must
# never replace a removed seat with an empty, signed-out profile.
CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
[ -n "$CONFIG_DIR_REAL" ] || refuse "Claude config directory '$CONFIG_DIR' does not exist"

# The filesystem root, a home directory, and the config directory are never
# something this registers, in either mode. Checked explicitly so the refusal
# names the real reason instead of the scope verdict behind it.
[ "$TARGET_REAL" != / ] || refuse "'/' is the filesystem root, not a $SCOPE_NOUN"
[ "$TARGET_REAL" != "$CONFIG_DIR_REAL" ] || refuse "'$TARGET_REAL' is the Claude config directory, not a $SCOPE_NOUN"
if [ -n "${HOME:-}" ]; then
  HOME_REAL=$(real_dir "$HOME") || true
  [ "$TARGET_REAL" != "${HOME_REAL:-}" ] || refuse "'$TARGET_REAL' is the home directory, not a $SCOPE_NOUN"
fi

LAUNCH_KEYS=()
CLONE_KEYS=()

if [ "$MODE" = worktree ]; then
  WT_TOP=$(git -C "$TARGET_REAL" rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$WT_TOP" ] || refuse "'$TARGET_REAL' is not inside a git repository"
  WT_TOP_REAL=$(real_dir "$WT_TOP") || true
  [ "$WT_TOP_REAL" = "$TARGET_REAL" ] || refuse "'$TARGET_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

  WT_GIT_DIR=$(git -C "$TARGET_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
  [ -n "$WT_GIT_DIR" ] || refuse "'$TARGET_REAL' has no resolvable git directory"
  WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
  [ -n "$WT_GIT_DIR" ] || refuse "'$TARGET_REAL' has an unresolvable git directory"
  WT_COMMON=$(common_dir_of "$TARGET_REAL") || true
  [ -n "$WT_COMMON" ] || refuse "'$TARGET_REAL' has no resolvable git common directory"
  [ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$TARGET_REAL' is a primary checkout, not an isolated worktree"

  PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
  [ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
  [ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$TARGET_REAL' is not a worktree of project '$PROJ_REAL'"

  # The external-imports flags must land on the canonical checkout, because
  # that is exactly the path Claude Code's own git-root canonicalization
  # collapses every linked worktree to. canonical_checkout_of owns the
  # derivation and proves it rather than assuming it, including when <project>
  # is itself a linked worktree - a secondmate home spawned from, rather than
  # as, the primary checkout - which would otherwise wedge a relaunch that is
  # perfectly valid.
  PROJ_CANON=$(canonical_checkout_of "$PROJ_REAL") || true
  [ -n "$PROJ_CANON" ] \
    || refuse "project '$PROJ_REAL' is a linked worktree whose primary checkout could not be resolved"
  LAUNCH_KEYS=("$TARGET_REAL" "$PROJ_CANON")
elif [ "$MODE" = project ]; then
  checkout_top_is "$TARGET_REAL" \
    || refuse "'$TARGET_REAL' is not the top level of a git checkout, so Claude Code would key its project config somewhere else"
  PROJ_CANON=$(canonical_checkout_of "$TARGET_REAL") || true
  [ -n "$PROJ_CANON" ] \
    || refuse "'$TARGET_REAL' is a linked worktree whose primary checkout could not be resolved"
  if [ "$PROJ_CANON" = "$TARGET_REAL" ]; then
    LAUNCH_KEYS=("$TARGET_REAL")
  else
    LAUNCH_KEYS=("$TARGET_REAL" "$PROJ_CANON")
  fi
elif [ "$MODE" = lab-home ]; then
  LAB_MARKER="$TARGET_REAL/$FM_GATE_LAB_MARKER"
  [ ! -L "$LAB_MARKER" ] || refuse "'$LAB_MARKER' is a symlink; a lab home carries the marker as a regular file"
  if ! { [ -f "$LAB_MARKER" ] && [ -O "$LAB_MARKER" ] && fm_gate_lab_home "$TARGET_REAL"; }; then
    refuse "'$TARGET_REAL' carries no lab-home marker owned by this user, so it is not a disposable lab home"
  fi
  [ -f "$TARGET_REAL/AGENTS.md" ] || refuse "'$TARGET_REAL' has no AGENTS.md, so it is not a firstmate home"
  [ -d "$TARGET_REAL/bin" ] || refuse "'$TARGET_REAL' has no bin/, so it is not a firstmate home"
  LAB_TOP=$(git -C "$TARGET_REAL" rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$LAB_TOP" ] && [ "$(real_dir "$LAB_TOP")" = "$TARGET_REAL" ] \
    || refuse "'$TARGET_REAL' is not the top level of a git checkout"
  LAB_GIT_DIR=$(git -C "$TARGET_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
  LAB_GIT_DIR=$(real_dir "${LAB_GIT_DIR:-}") || true
  LAB_COMMON=$(common_dir_of "$TARGET_REAL") || true
  [ -n "$LAB_GIT_DIR" ] && [ "$LAB_GIT_DIR" = "$LAB_COMMON" ] \
    || refuse "'$TARGET_REAL' is a linked worktree, not the primary checkout a lab primary launches in"
  LAUNCH_KEYS=("$TARGET_REAL")
else
  # The seed evidence, in the order that names the most useful reason first: the
  # marker decides whether this is a secondmate home at all, the id decides
  # whose, and the instance files and operational directories decide whether it
  # is the shape bin/fm-home-seed.sh leaves behind. The marker is the token the
  # whole boundary rests on, so it is judged as a file rather than as a value: a
  # symlink is refused outright rather than followed, because a link is a way to
  # make some other file's bytes stand in for the seed, and a marker this user
  # does not own was planted by someone else.
  [ -n "$SUB_ID" ] || refuse "no secondmate id was supplied, so '$TARGET_REAL' cannot be matched against its seed marker"
  SUB_MARKER="$TARGET_REAL/.fm-secondmate-home"
  [ ! -L "$SUB_MARKER" ] || refuse "'$SUB_MARKER' is a symlink; a seeded secondmate home carries the marker as a regular file"
  [ -f "$SUB_MARKER" ] || refuse "'$TARGET_REAL' carries no .fm-secondmate-home marker, so it is not a seeded secondmate home"
  [ -O "$SUB_MARKER" ] || refuse "'$SUB_MARKER' is not owned by this user"
  SUB_MARKER_ID=$(cat "$SUB_MARKER" 2>/dev/null) || true
  [ "$SUB_MARKER_ID" = "$SUB_ID" ] || refuse "'$TARGET_REAL' is marked for secondmate '${SUB_MARKER_ID:-unknown}', not '$SUB_ID'"
  [ -f "$TARGET_REAL/AGENTS.md" ] || refuse "'$TARGET_REAL' has no AGENTS.md, so it is not a firstmate home"
  [ -d "$TARGET_REAL/bin" ] || refuse "'$TARGET_REAL' has no bin/, so it is not a firstmate home"
  for sub_dir_name in data state config projects; do
    sub_dir="$TARGET_REAL/$sub_dir_name"
    if [ -L "$sub_dir" ] && [ ! -e "$sub_dir" ]; then
      refuse "'$sub_dir' is a broken symlink, so this home's $sub_dir_name directory cannot be shown to stay inside it"
    fi
    [ -e "$sub_dir" ] || continue
    [ -d "$sub_dir" ] || refuse "'$sub_dir' is not a directory, so '$TARGET_REAL' is not a seeded secondmate home"
    sub_dir_real=$(real_dir "$sub_dir") || true
    [ -n "$sub_dir_real" ] || refuse "'$sub_dir' cannot be resolved"
    case "$sub_dir_real" in
      "$TARGET_REAL"/*) ;;
      *) refuse "'$sub_dir' resolves to '$sub_dir_real', outside the home, so '$TARGET_REAL' is not a safe secondmate home" ;;
    esac
  done
  PROJ_CANON=$(canonical_checkout_of "$TARGET_REAL") || true
  [ -n "$PROJ_CANON" ] \
    || refuse "'$TARGET_REAL' has no resolvable canonical checkout"
  LAUNCH_KEYS=("$TARGET_REAL")
  [ "$PROJ_CANON" = "$TARGET_REAL" ] || LAUNCH_KEYS+=("$PROJ_CANON")

  # The home's project clones, which a claude launch on this host starts in
  # just as readily as the home itself. A clone qualifies on the same
  # structural evidence every other mode uses - it is the top level of a git
  # checkout, and both it and the canonical checkout it collapses to resolve
  # inside this already-verified home - and anything else under projects/ is
  # skipped rather than refused, because a stray file or a half-finished clone
  # is not a launch target and refusing the whole home over one would strand
  # the spawn that needs the home registered.
  for clone_path in "$TARGET_REAL"/projects/*; do
    [ -d "$clone_path" ] || continue
    clone_real=$(real_dir "$clone_path") || true
    [ -n "$clone_real" ] || continue
    case "$clone_real" in "$TARGET_REAL"/*) ;; *) continue ;; esac
    checkout_top_is "$clone_real" || continue
    clone_canon=$(canonical_checkout_of "$clone_real") || true
    [ -n "$clone_canon" ] || continue
    case "$clone_canon" in "$TARGET_REAL"/*) ;; *) continue ;; esac
    CLONE_KEYS+=("$clone_real")
    [ "$clone_canon" = "$clone_real" ] || CLONE_KEYS+=("$clone_canon")
  done
fi

# The store write needs node, and a missing interpreter refuses like every other
# failure here. Degrading instead would launch a worker straight into the dialog
# this registration exists to remove, which is the one outcome the whole control
# is for; the other node callers in bin/ step aside because what they protect is
# optional, and this is not. A node-less home never reaches a spawn anyway, since
# bin/fm-bootstrap.sh lists node in COMMON_TOOLS and reports it at setup, which is
# where a missing tool belongs rather than as a stalled pane later.
command -v node >/dev/null 2>&1 || refuse "node is required to record workspace trust and was not found on PATH"

STORE="$CONFIG_DIR_REAL/.claude.json"
# A dotfile manager or a synced folder legitimately symlinks this store, so the
# link is followed to its final target and every check below judges that target.
# Ownership is the property that matters: another user's file is refused however
# it is reached. Writing to the resolved path is what keeps the link itself in
# place, since staging beside the link and renaming would replace it with a
# regular file and break that layout.
if [ -L "$STORE" ]; then
  STORE_REAL=$(real_file "$STORE") || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write, then read back and confirm. fm-spawn runs from a live
# firstmate Claude Code session that writes this same file, so the store can move
# under us in both directions and each needs its own answer.
#
# Losing the VENDOR's write is the serious one: this renames a whole
# re-serialisation over the file, so anything Claude changed since the read -
# oauthAccount, user-scope mcpServers, another project's history - would be gone,
# in a format this does not own. So the bytes read are fingerprinted and
# re-checked immediately before the rename, and a store that moved is not
# overwritten: the whole read-modify-write is retried once, and a second move
# refuses rather than clobbering.
#
# That narrows the window; it does not close it. Rename cannot be conditioned on
# content, so a write landing between the final check and the rename is still
# lost, and this claims no more than that.
#
# Losing OUR entry is the mild one: a vendor rewrite that drops it only resurrects
# the dialog this registration removes, which reaches firstmate as an ordinary
# stale wake and a relaunch registers again. The readback catches it within these
# attempts, and it must fail loudly rather than report a trust it did not leave.
# ponytail: fingerprint-and-refuse, not a lock; flock is absent on macOS and
# cannot stop a vendor session's own rewrite anyway.
#
# Every entry this registration touches lands in the same read-modify-write
# attempt, so a single rename either records all of it or none of it - there is
# no state where one entry is fresh and another stale.
#
TRUST_FLAG='hasTrustDialogAccepted'
IMPORT_FLAGS='["hasClaudeMdExternalIncludesApproved","hasClaudeMdExternalIncludesWarningShown"]'
# The two key lists travel as plain argv rather than as JSON, because encoding
# them would cost two more node starts on the hot path of every claude spawn:
# the launch keys come first and their count says where the clone keys begin.
WRITE_ARGS=("$STORE" "$TRUST_FLAG" "$IMPORT_FLAGS" "${#LAUNCH_KEYS[@]}"
  ${LAUNCH_KEYS[@]+"${LAUNCH_KEYS[@]}"} ${CLONE_KEYS[@]+"${CLONE_KEYS[@]}"})
if ! REGISTERED=$(node - "${WRITE_ARGS[@]}" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, trustFlag, importFlagsJson, launchCount] = process.argv.slice(2, 6);
const importFlags = JSON.parse(importFlagsJson);
const keyArgs = process.argv.slice(6);
const launchKeys = keyArgs.slice(0, Number(launchCount));
const cloneKeys = keyArgs.slice(Number(launchCount));
const entryFlags = [trustFlag, ...importFlags];
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const fingerprint = (buf) =>
  buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex");
const setFlags = (projects, key, flags) => {
  let entry = projects[key];
  if (entry === undefined || entry === null || typeof entry !== "object" || Array.isArray(entry)) {
    entry = {};
  }
  for (const flag of flags) entry[flag] = true;
  projects[key] = entry;
};
const flagsLanded = (projects, key, flags) =>
  flags.every((flag) => projects?.[key]?.[flag] === true);
const declinedExternalImports = (projects, key) =>
  projects?.[key]?.hasClaudeMdExternalIncludesApproved === false &&
  projects?.[key]?.hasClaudeMdExternalIncludesWarningShown === true;
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = {};
  if (original !== null) {
    const raw = original.toString("utf8");
    if (raw.trim() !== "") {
      root = JSON.parse(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (root.projects === undefined) root.projects = {};
  const projects = root.projects;
  if (projects === null || typeof projects !== "object" || Array.isArray(projects)) {
    throw new Error(`${store} has a non-object "projects" value`);
  }
  const registered = [
    ...launchKeys.map((key) => ["launch", key]),
    ...cloneKeys.map((key) => ["clone", key]),
  ];
  const keys = [];
  const seen = new Set();
  for (const [role, key] of registered) {
    if (seen.has(key)) continue;
    seen.add(key);
    const declined = declinedExternalImports(projects, key);
    const flags = declined ? [trustFlag] : entryFlags;
    setFlags(projects, key, flags);
    keys.push([declined ? "declined" : role, key, flags]);
  }
  // Unpredictable name plus an exclusive create: the config directory may be
  // writable by another local account, and a predictable path could be
  // pre-created there as a symlink that a plain write would follow into some
  // other file this user owns. "wx" refuses an existing path outright.
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.claude.json.fm-trust.${unique}`);
  // Two-space pretty-printed, because that is the format Claude Code itself
  // writes: the store on the box this was measured on begins "{\n  " and runs
  // 9646 lines. Compact would reformat the operator's whole config on every
  // spawn and the vendor's next write would expand it again, so this must not
  // be "simplified" to JSON.stringify(root) without re-measuring the vendor.
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  const landed = keys.every(([role, key, flags]) =>
    flagsLanded(back.projects, key, flags) &&
    (role !== "declined" || declinedExternalImports(back.projects, key)));
  if (!landed) return "dropped";
  return keys.map(([role, key]) => `${role} ${key}`).join("\n");
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result !== "moved" && result !== "dropped") {
      if (result !== "") process.stdout.write(`${result}\n`);
      process.exit(0);
    }
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain trust for ${launchKeys.join(", ")} after 3 attempts`);
process.exit(1);
NODE
); then
  refuse "could not record trust for '$TARGET_REAL' in '$STORE'"
fi

# One line per entry that actually landed, so the caller's log names the same
# set the store now holds rather than the set this run intended.
while IFS= read -r registered_line; do
  [ -n "$registered_line" ] || continue
  registered_role=${registered_line%% *}
  registered_key=${registered_line#* }
  if [ "$registered_role" = declined ]; then
    echo "trusted: $registered_key; project keeps its recorded external-imports decline in $STORE"
  elif [ "$registered_key" = "$TARGET_REAL" ]; then
    echo "trusted: $registered_key"
  elif [ "$registered_role" = clone ]; then
    echo "trusted (project clone): $registered_key"
  else
    echo "trusted (project root): $registered_key"
  fi
done <<EOF
$REGISTERED
EOF
