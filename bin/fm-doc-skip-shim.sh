#!/usr/bin/env bash
# fm-doc-skip-shim.sh - install, inspect, or remove a temporary PATH shim that
# adds the pipeline's `document` step to the skip list of the no-mistakes
# invocations that start a new validation run.
#
# WHY IT EXISTS
# The fleet's standing posture is that the pipeline's `document` step is off.
# A no-mistakes binary that carries that default as persistent configuration
# exists upstream but cannot be installed while the shared daemon has live
# runs, so until that install happens the posture depends on every worker
# remembering a flag. This shim makes it hold without that memory.
#
# WHAT IT COVERS
# The shim recognizes exactly two argument shapes and rewrites nothing else:
#   `no-mistakes axi run ...`  - the flag belongs to the `run` subcommand.
#   a bare `no-mistakes` whose arguments are only `-y`, `--yes` or `--skip`
#                              - the flag belongs to the root command.
# For a recognized shape it merges `document` into an existing `--skip` value,
# or appends `--skip document` when the caller passed none. Every other
# argument is forwarded byte for byte in its original order. Any other
# invocation - another subcommand, `--help`, `-h`, `--version`, `daemon ...`,
# `axi status`, an unrecognized flag shape, or anything containing the `--`
# end-of-options marker - is exec'd against the real binary untouched.
# `FM_DOC_SKIP_SHIM_BYPASS=1` forwards every call untouched.
#
# `axi run` is also how a caller REATTACHES to a run already under way, and the
# two are the same argument vector, so the shim adds the flag to both. That is
# inert rather than wrong: the CLI consumes the skip list only on the paths
# that start a run, and reattach refusals exist for --model, --effort,
# --base-branch, --no-publish-intent, --caller-origin-file and
# --verification-plan but not for --skip.
#
# WHAT IT CANNOT COVER
#   `no-mistakes rerun` starts a NEW run and has no `--skip` flag at all; the
#     CLI sends an empty skip list and the daemon does not inherit the prior
#     run's skips, so no wrapper in front of the CLI can add the step.
#   `git push -o no-mistakes.skip=...` reaches the daemon through the gate's
#     post-receive hook, which hardcodes an absolute path to the real binary
#     in `NM_BIN=` and consults PATH only when that file is gone. A PATH shim
#     is never on that path.
# Both gaps close when the binary carrying the persistent default is installed.
#
# KNOWN LIMITS, deliberately not fixed
# The shim models no option arity, so an argument whose literal text is
# `--skip` or `--skip=...` is read as the skip flag wherever it sits, even as
# another option's value. Modeling arity would mean pinning the binary's flag
# table, which the next release would silently invalidate; an unanticipated
# flag reaching the binary unchanged is the safer failure. For the same reason
# a trailing `--skip` with no value is forwarded as-is and gains nothing.
#
# REMOVAL
# This is temporary. Run `fm-doc-skip-shim.sh uninstall` once the installed
# no-mistakes binary applies `document` from its own configuration; after that
# the shim only duplicates a default the binary already holds.
#
# USAGE
#   fm-doc-skip-shim.sh install [--dir DIR] [--shell-config FILE|--no-shell-config]
#   fm-doc-skip-shim.sh uninstall [--dir DIR] [--shell-config FILE|--no-shell-config]
#   fm-doc-skip-shim.sh status [--dir DIR] [--shell-config FILE]
#
# `install` writes DIR/no-mistakes and prepends DIR to PATH from each shell
# configuration file. It refuses a DIR that holds anything other than its own
# shim, so it cannot pollute a directory another tool manages. It touches no
# daemon, no configuration under ~/.no-mistakes, and no installed binary.
# Re-running it converges on the same state.
#
# DIR defaults to ~/.local/share/firstmate-doc-skip-shim. FILE defaults to
# BOTH ~/.config/shell/common.sh and ~/.profile, and may be repeated to name a
# different set. Both files are needed on a host whose ~/.profile prepends a
# toolchain directory of its own: ~/.bashrc sources common.sh, and then
# ~/.profile continues past that source and puts its own entries back in
# front, so an interactive login shell - which is what a terminal-multiplexer
# pane running an agent is - would otherwise resolve the real binary first.
set -euo pipefail

MARKER='# firstmate doc-skip shim'
SHIM_MARKER='TEMPORARY no-mistakes shim installed'
DEFAULT_DIR="${HOME}/.local/share/firstmate-doc-skip-shim"
DEFAULT_SHELL_CONFIGS=("${HOME}/.config/shell/common.sh" "${HOME}/.profile")

usage() {
  local line
  while IFS= read -r line; do
    case "$line" in
      '#!'*) continue ;;
      '#'*)
        line=${line#\#}
        printf '%s\n' "${line# }"
        ;;
      *) break ;;
    esac
  done < "${BASH_SOURCE[0]}"
}

die() {
  printf 'fm-doc-skip-shim: %s\n' "$1" >&2
  exit 1
}

# Quote a value for literal inclusion in generated POSIX shell.
sq() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# Print the real no-mistakes binary, ignoring the shim directory itself.
resolve_real() {  # <shim_dir>
  (
    set -f
    local shim_dir=$1 dir
    local IFS=:
    for dir in $PATH; do
      [ "$dir" = "$shim_dir" ] && continue
      dir=${dir:-.}
      if [ -f "$dir/no-mistakes" ] && [ -x "$dir/no-mistakes" ]; then
        printf '%s' "$dir/no-mistakes"
        return 0
      fi
    done
  )
}

write_shim() {  # <shim_dir> <fallback_real>
  local shim_dir=$1 fallback=$2 tmp
  tmp=$(mktemp "$shim_dir/.no-mistakes.XXXXXX")
  {
    printf '#!/bin/sh\n'
    printf '# TEMPORARY no-mistakes shim installed %s by bin/fm-doc-skip-shim.sh: it adds the pipeline step document to the skip list of the commands that start a new run, and it is deleted once the installed no-mistakes binary applies that skip from its own configuration.\n' \
      "$(date +%Y-%m-%d)"
    printf 'nm_shim_dir=%s\n' "$(sq "$shim_dir")"
    printf 'nm_fallback=%s\n' "$(sq "$fallback")"
    cat <<'SHIM_BODY'

# Strip trailing slashes so a PATH entry that names the shim directory in
# another spelling is still recognized as this directory. Without it the shim
# resolves itself and re-execs forever.
nm_trim() {
  nm_t=$1
  while :; do
    case "$nm_t" in
      ?*/) nm_t=${nm_t%/} ;;
      *) break ;;
    esac
  done
  printf '%s' "$nm_t"
}

nm_real=
if [ -n "${FM_DOC_SKIP_SHIM_REENTRY:-}" ]; then
  # Reached only if a PATH spelling still resolved back here. Go straight to
  # the binary recorded at install time; the rewrite below is idempotent, so
  # passing through twice changes nothing.
  nm_real=$nm_fallback
else
  nm_shim_norm=$(nm_trim "$nm_shim_dir")
  set -f
  IFS=:
  for nm_dir in $PATH; do
    nm_dir=${nm_dir:-.}
    [ "$(nm_trim "$nm_dir")" = "$nm_shim_norm" ] && continue
    if [ -f "$nm_dir/no-mistakes" ] && [ -x "$nm_dir/no-mistakes" ]; then
      nm_real=$nm_dir/no-mistakes
      break
    fi
  done
  unset IFS
  set +f
fi
if [ -z "$nm_real" ] || [ ! -x "$nm_real" ]; then
  if [ -n "$nm_fallback" ] && [ -x "$nm_fallback" ]; then
    nm_real=$nm_fallback
  else
    echo 'no-mistakes: command not found' >&2
    exit 127
  fi
fi
FM_DOC_SKIP_SHIM_REENTRY=1
export FM_DOC_SKIP_SHIM_REENTRY

if [ "${FM_DOC_SKIP_SHIM_BYPASS:-}" = 1 ]; then
  exec "$nm_real" "$@"
fi

# An explicit end-of-options marker makes later words operands, so a flag
# appended after it would change their meaning. A help or version lookup must
# reach the binary exactly as typed, including under `axi run`, because that
# output is what a reader is being told to trust. Forward both untouched.
for nm_arg in "$@"; do
  case "$nm_arg" in
    --|--help|-h|--version)
      exec "$nm_real" "$@"
      ;;
  esac
done

nm_recognized=0
if [ "$#" -eq 0 ]; then
  nm_recognized=1
elif [ "$1" = 'axi' ] && [ "$#" -ge 2 ] && [ "$2" = 'run' ]; then
  nm_recognized=1
else
  nm_recognized=1
  nm_expect=0
  for nm_arg in "$@"; do
    if [ "$nm_expect" = 1 ]; then
      nm_expect=0
      continue
    fi
    case "$nm_arg" in
      -y|--yes) ;;
      --skip) nm_expect=1 ;;
      --skip=*) ;;
      *)
        nm_recognized=0
        break
        ;;
    esac
  done
  if [ "$nm_expect" = 1 ]; then
    nm_recognized=0
  fi
fi

if [ "$nm_recognized" = 0 ]; then
  exec "$nm_real" "$@"
fi

nm_has_skip=0
for nm_arg in "$@"; do
  case "$nm_arg" in
    --skip|--skip=*)
      nm_has_skip=1
      break
      ;;
  esac
done

if [ "$nm_has_skip" = 0 ]; then
  exec "$nm_real" "$@" --skip document
fi

# Union, never replacement: the caller's own steps survive verbatim.
nm_merge() {
  nm_value=$1
  nm_probe=,$(printf '%s' "$nm_value" | tr -d '[:space:]'),
  case "$nm_probe" in
    ,,) printf 'document' ;;
    *,document,*) printf '%s' "$nm_value" ;;
    *) printf '%s,document' "$nm_value" ;;
  esac
}

nm_count=$#
nm_i=0
nm_take=0
while [ "$nm_i" -lt "$nm_count" ]; do
  nm_arg=$1
  shift
  nm_i=$((nm_i + 1))
  if [ "$nm_take" = 1 ]; then
    nm_take=0
    set -- "$@" "$(nm_merge "$nm_arg")"
    continue
  fi
  case "$nm_arg" in
    --skip)
      nm_take=1
      set -- "$@" "$nm_arg"
      ;;
    --skip=*)
      set -- "$@" "--skip=$(nm_merge "${nm_arg#--skip=}")"
      ;;
    *)
      set -- "$@" "$nm_arg"
      ;;
  esac
done

exec "$nm_real" "$@"
SHIM_BODY
  } > "$tmp"
  chmod 0755 "$tmp"
  mv "$tmp" "$shim_dir/no-mistakes"
}

assert_dedicated_dir() {  # <shim_dir>
  local shim_dir=$1 entry
  [ -d "$shim_dir" ] || return 0
  for entry in "$shim_dir"/* "$shim_dir"/.[!.]*; do
    [ -e "$entry" ] || continue
    case "${entry##*/}" in
      no-mistakes | .no-mistakes.*) continue ;;
    esac
    die "refusing to install into $shim_dir: it holds $entry, so another tool may own it"
  done
}

# Copy <config> to <tmp> without the lines this script owns. A line qualifies
# only when it both carries the marker and IS a PATH assignment, so a user's
# prose that merely mentions the marker survives. A read failure must leave the
# caller's shell configuration untouched rather than write a partial result.
filter_marked_lines() {  # <config> <tmp>
  local rc=0
  awk -v m="$MARKER" \
    'index($0, m) > 0 && index($0, "export PATH=") == 1 { next } { print }' \
    "$1" > "$2" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$2"
    die "could not read $1 (exit $rc); left it untouched"
  fi
}

# Replace <config>'s contents with <tmp>'s. A regular file is replaced by
# rename, which is atomic and cannot leave a half-written login profile; the
# mode is carried over first because mktemp creates 0600. A symlink is written
# through instead, because renaming onto it would replace the link with a file.
commit_config() {  # <config> <tmp>
  local config=$1 tmp=$2
  if [ -L "$config" ]; then
    cat "$tmp" > "$config"
    rm -f "$tmp"
    return 0
  fi
  chmod "$(config_mode "$config")" "$tmp" 2>/dev/null || true
  mv "$tmp" "$config"
}

# The config's permission bits, as a chmod-compatible symbolic mode. `stat`
# spells its format differently on BSD and GNU, so read them from `ls`, which
# does not.
config_mode() {  # <config>
  local perms
  # shellcheck disable=SC2012 # `stat` spells its format differently on BSD and GNU.
  perms=$(ls -ld "$1" | cut -c2-10)
  printf 'u=%s,g=%s,o=%s' \
    "$(printf '%s' "${perms:0:3}" | tr -d -)" \
    "$(printf '%s' "${perms:3:3}" | tr -d -)" \
    "$(printf '%s' "${perms:6:3}" | tr -d -)"
}

add_path_line() {  # <shell_config> <shim_dir>
  local config=$1 shim_dir=$2 tmp
  [ -e "$config" ] || die "shell config $config does not exist"
  tmp=$(mktemp "$config.XXXXXX")
  filter_marked_lines "$config" "$tmp"
  # shellcheck disable=SC2016 # $PATH must stay literal in the generated line.
  printf 'export PATH="%s:$PATH"  %s (temporary; remove with bin/fm-doc-skip-shim.sh uninstall)\n' \
    "$shim_dir" "$MARKER" >> "$tmp"
  commit_config "$config" "$tmp"
}

remove_path_line() {  # <shell_config>
  local config=$1 tmp
  [ -e "$config" ] || return 0
  grep -q -F -- "$MARKER" "$config" || return 0
  tmp=$(mktemp "$config.XXXXXX")
  filter_marked_lines "$config" "$tmp"
  commit_config "$config" "$tmp"
}

cmd_install() {  # <shim_dir> <shell_config...>
  local shim_dir=$1 real config
  shift
  # Every destination is checked before anything is written, so a bad path
  # cannot leave the host half-installed.
  for config in "$@"; do
    [ -e "$config" ] || die "shell config $config does not exist; nothing was installed"
    [ -w "$config" ] || die "shell config $config is not writable; nothing was installed"
  done
  assert_dedicated_dir "$shim_dir"
  real=$(resolve_real "$shim_dir")
  [ -n "$real" ] || die 'no real no-mistakes found on PATH; install it before the shim'
  mkdir -p "$shim_dir"
  write_shim "$shim_dir" "$real"
  for config in "$@"; do
    add_path_line "$config" "$shim_dir"
    printf 'PATH entry written to %s\n' "$config"
  done
  printf 'installed %s/no-mistakes in front of %s\n' "$shim_dir" "$real"
  printf 'shells started after this pick it up; already-running shells keep their current PATH\n'
}

cmd_uninstall() {  # <shim_dir> <shell_config...>
  local shim_dir=$1 config
  shift
  for config in "$@"; do
    remove_path_line "$config"
  done
  if [ -e "$shim_dir/no-mistakes" ]; then
    # Only ever delete this script's own output: an operator who mistypes
    # --dir must not lose the real binary.
    grep -q -F -- "$SHIM_MARKER" "$shim_dir/no-mistakes" 2>/dev/null ||
      die "$shim_dir/no-mistakes is not a generated shim; left it alone"
    rm -f "$shim_dir/no-mistakes"
  fi
  rmdir "$shim_dir" 2>/dev/null || true
  printf 'removed the shim from %s\n' "$shim_dir"
}

cmd_status() {  # <shim_dir> <shell_config...>
  local shim_dir=$1 real resolved config
  shift
  if [ -x "$shim_dir/no-mistakes" ]; then
    printf 'shim: present at %s/no-mistakes\n' "$shim_dir"
  else
    printf 'shim: absent from %s\n' "$shim_dir"
  fi
  for config in "$@"; do
    if [ -e "$config" ] && grep -q -F -- "$MARKER" "$config"; then
      printf 'path entry: present in %s\n' "$config"
    else
      printf 'path entry: absent from %s\n' "$config"
    fi
  done
  real=$(resolve_real "$shim_dir")
  printf 'real binary: %s\n' "${real:-<not found>}"
  resolved=$(command -v no-mistakes || true)
  printf 'this shell resolves: %s\n' "${resolved:-<not found>}"
}

main() {
  local action=${1:-} shim_dir=$DEFAULT_DIR
  local configs=() explicit=0
  case "$action" in
    install | uninstall | status) shift ;;
    -h | --help | help | '')
      usage
      return 0
      ;;
    *) die "unknown command '$action' (expected install, uninstall, or status)" ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)
        shim_dir=${2:-}
        [ -n "$shim_dir" ] || die '--dir needs a directory'
        shift 2
        ;;
      --shell-config)
        [ -n "${2:-}" ] || die '--shell-config needs a file'
        configs+=("$2")
        explicit=1
        shift 2
        ;;
      --no-shell-config)
        configs=()
        explicit=1
        shift
        ;;
      *) die "unknown option '$1'" ;;
    esac
  done
  if [ "$explicit" = 0 ]; then
    configs=("${DEFAULT_SHELL_CONFIGS[@]}")
  fi
  "cmd_$action" "$shim_dir" ${configs[@]+"${configs[@]}"}
}

main "$@"
