#!/bin/bash -e
# Adapted from https://github.com/ros-industrial/industrial_ci/blob/master/industrial_ci/src/util.sh
# Copyright 2016-2025, Isaac I. Y. Saito, Mathias Lüdtke, Robert Haschke, Yuki Furuta

export ANSI_RED=31
export ANSI_GREEN=32
export ANSI_YELLOW=33
export ANSI_BLUE=34
export ANSI_MAGENTA=35
export ANSI_CYAN=36
export ANSI_BOLD=1
export ANSI_THIN=22
export ANSI_RESET=0

export TRACE=${TRACE:-false}
export ICI_FOLD_NAME=${ICI_FOLD_NAME:-}
export ICI_START_TIME=${ICI_START_TIME:-}
_CLEANUP_FILES=""
declare -a _CLEANUP_CMDS

__ici_log_fd=1
__ici_err_fd=2
__ici_top_level=0
__ici_setup_called=false

ici_setup() {
    # shellcheck disable=SC2064
    trap "ici_trap_exit $((128 + $(kill -l INT)))" INT # install interrupt handler
    # shellcheck disable=SC2064
    trap "ici_trap_exit $((128 + $(kill -l TERM)))" TERM # install interrupt handler

    trap "ici_trap_exit" EXIT # install exit handler

    exec {__ici_log_fd}>&1
    exec {__ici_err_fd}>&2
    __ici_top_level=$BASH_SUBSHELL
    __ici_setup_called=true
}

ici_redirect() {
    1>&"$__ici_log_fd" 2>&"$__ici_err_fd" "$@"
}

ici_log() {
    ici_redirect echo "$@"
}

ici_ansi() {
  local var="ANSI_$1"
  echo "\e[${!var}m"
}

ici_colorize() {
   local color reset
   while true ; do # process all color arguments
      case "${1:-}" in
         RED|GREEN|YELLOW|BLUE|MAGENTA|CYAN)
            color="$(ici_ansi "$1")"; reset="$(ici_ansi RESET)" ;;
         THIN)
            color="${color:-}$(ici_ansi THIN)" ;;
         BOLD)
            color="${color:-}$(ici_ansi BOLD)"; reset="${reset:-$(ici_ansi THIN)}" ;;
         *) break ;;
      esac
      shift
   done
   echo -e "${color:-}$*${reset:-}"
}

ici_color_output() {
  ici_log "$(ici_colorize "$@")"
}

ici_title() {
  ici_log
  ici_color_output BLUE "$@"
}

ici_get_log_cmd() {
  local post=""
  while true; do
    case "$1" in
      ici_asroot)
        echo -n "sudo "
        ;;
      ici_filter)
        post=" | grep -E '$2' "
        shift 1
        ;;
      ici_quiet)
        post=" > /dev/null "
        ;;
      ici_cmd|ici_guard|ici_label)
        ;;
      *)
        echo "$*$post"
        return
    esac
    shift
  done
}

_ici_guard() {
  local err=0
  "$@" || err=$?
  if [ "$err" -ne 0 ]; then
    ici_error "'$(ici_get_log_cmd "$@")' returned with $err" "$err"
  fi
}

ici_guard() {
  ici_trace "$@"
  _ici_guard "$@"
}

ici_label() {
  local cmd; cmd=$(ici_get_log_cmd "$@")
  ici_color_output BOLD "$ $cmd"
  "$@"
}

ici_cmd() {
     _ici_guard ici_label "$@"
}

ici_start_fold() {
  if [ -n "$ICI_FOLD_NAME" ]; then
    # report error _within_ the previous fold
    ici_warn "ici_start_fold: nested folds are not supported (still open: '$ICI_FOLD_NAME')"
    ici_end_fold
  fi
  # shellcheck disable=SC2001
  ICI_FOLD_NAME="$(sed -e 's/\x1b\[[0-9;]*m//g' <<< "$1")" # store name w/o color codes
  gha_cmd group "$1"
}

ici_end_fold() {
  if [ -z "$ICI_FOLD_NAME" ]; then
    ici_warn "spurious call to ici_end_fold"
  else
    gha_cmd endgroup
    ICI_FOLD_NAME=
  fi
}

ici_time_start() {
    if [ "$DEBUG_BASH" ] && [ "$DEBUG_BASH" == true ]; then set +x; fi
    ICI_START_TIME=$(date -u +%s%N)
    ici_start_fold "$1"
    if [ "$DEBUG_BASH" ] && [ "$DEBUG_BASH" == true ]; then set -x; fi
}

ici_time_end() {
    local exit_code=${1:-0}
    if [ "$DEBUG_BASH" ] && [ "$DEBUG_BASH" == true ]; then set +x; fi

    local name=$ICI_FOLD_NAME
    local color_wrap="GREEN"
    if [ "$exit_code" -ne "0" ]; then color_wrap="RED"; fi  # Red color for errors

    if [ -z "$ICI_START_TIME" ]; then ici_warn "[ici_time_end] var ICI_START_TIME is not set. You need to call ici_time_start in advance. Returning."; return; fi
    local end_time; end_time=$(date -u +%s%N)
    local elapsed_seconds; elapsed_seconds=$(( (end_time - ICI_START_TIME)/1000000000 ))

    ici_color_output "$color_wrap" "'$name' returned with code '${exit_code}' after $(( elapsed_seconds / 60 )) min $(( elapsed_seconds % 60 )) sec"
    ici_end_fold "$name"

    ICI_START_TIME=
    if [ "$DEBUG_BASH" ] && [ "$DEBUG_BASH" == true ]; then set -x; fi
}
# Execute command folding and timing it
ici_timed() {
    local title=$1; shift
    ici_time_start "$title"
    ("$@" || ici_exit)
    ici_time_end
}

# Register command to be executed on teardown
ici_on_teardown() {
    _CLEANUP_CMDS+=("$@")
}

ici_teardown() {
    local exit_code=${1:-$?}; shift || true

    # don't run teardown code within subshells, but only at top level
    if [  "$BASH_SUBSHELL" -le "$__ici_top_level" ]; then
        # Reset signal handler since the shell is about to exit.
        [ "$__ici_setup_called" == true ] && trap - EXIT

        local cleanup=()
        # shellcheck disable=SC2016
        IFS=: command eval 'cleanup=(${_CLEANUP_FILES})'
        for c in "${cleanup[@]}"; do
          rm -rf "${c/#\~/$HOME}"
        done

        if [ "$exit_code" -ne 0 ]; then
            local addon=""
            [ -n "$ICI_FOLD_NAME" ] && addon="(in '$ICI_FOLD_NAME')"

            if [ -n "$*" ]; then # issue custom error message
              "$@" "$addon" || true
            else # issue default error message
              gha_error "Failure with exit code: $exit_code" "$addon"
            fi
        fi

        # end fold/timing if needed
        if [ -n "$ICI_FOLD_NAME" ]; then
            if [ -n "$ICI_START_TIME" ]; then
              ici_time_end "$exit_code" # close timed fold
            else
              ici_end_fold "$ICI_FOLD_NAME" # close untimed fold
            fi
        fi

        for c in "${_CLEANUP_CMDS[@]}"; do
          $c
        done

        if [ "$__ici_setup_called" = true ]; then
            # These will fail if ici_setup was not called
            exec {__ici_log_fd}>&-
            exec {__ici_err_fd}>&-
        fi
        __ici_setup_called=false
    fi
}

ici_backtrace() {
  if [ "$TRACE" = true ]; then
    ici_log
    ici_color_output MAGENTA "TRACE: ${BASH_SOURCE[2]#$SRC_PATH/}:${BASH_LINENO[1]} ${FUNCNAME[1]} $*"
    for ((i=3;i<${#BASH_SOURCE[@]};i++)); do
        ici_color_output MAGENTA " from: ${BASH_SOURCE[$i]#$SRC_PATH/}:${BASH_LINENO[$((i-1))]} ${FUNCNAME[$((i-1))]}"
    done
  fi
}

ici_trap_exit() {
    local exit_code=${1:-$?}
    local cmd=gha_error
    local msg
    if [ "$exit_code" -gt "128" ]; then
        msg="Terminating on signal $(kill -l $((exit_code - 128)))"
        # simple message instead of error for SIGINT
        [ "$exit_code" -eq "130" ] && cmd="ici_log"
    else
        msg="Unexpected failure with exit code '$exit_code'"
        TRACE=true
    fi

    ici_backtrace "$@"
    ici_teardown "$exit_code" "$cmd" "$msg"
    exit "$exit_code"
}

ici_exit() {
    local exit_code=${1:-$?}
    ici_backtrace "$@"
    shift || true
    ici_teardown "$exit_code" "$@"

    if [ "$exit_code" == "${EXPECT_EXIT_CODE:-0}" ] ; then
        exit_code=0
    elif [ "$exit_code" == "0" ]; then # 0 was not expected
        exit_code=1
    fi

    exit "$exit_code"
}

ici_warn() {
    ici_color_output YELLOW "$*"
}

ici_error() {
    local exit_code=${2:-$?} #
    if [ -n "$1" ]; then
        __ici_log_fd=$__ici_err_fd ici_color_output RED "$1"
    fi
    if [ "$exit_code" == "0" ]; then # 0 is not error
        exit_code=1
    fi
    ici_exit "$exit_code"
}

ici_asroot() {
   if [ "$EUID" -ne 0 ] && command -v sudo > /dev/null; then
       sudo -E "$@"
   else
       "$@"
   fi
 }

gha_cmd() {
  local cmd=$1; shift
  # turn newlines into %0A, carriage returns into %0D, and % into %25
  echo -e "::$cmd::$*" | sed -e 's/%/%25/g' -e 's/\r/%0D/g' -e 's/\n/%0A/g'
}

gha_error() {
  gha_cmd error "$*"
}

gha_warning() {
  gha_cmd warning "$*"
}

ici_start_group() {
  if [ -n "$ICI_FOLD_NAME" ]; then
    # report error _within_ the previous fold
    ici_warn "ici_start_fold: nested folds are not supported (still open: '$ICI_FOLD_NAME')"
    ici_end_fold
  fi
  # shellcheck disable=SC2001
  ICI_FOLD_NAME="$(sed -e 's/\x1b\[[0-9;]*m//g' <<< "$1")" # store name w/o color codes
  gha_cmd group "$1"
}

ici_end_group() {
  if [ -z "$ICI_FOLD_NAME" ]; then
    ici_warn "spurious call to ici_end_fold"
  else
    gha_cmd endgroup
    ICI_FOLD_NAME=
  fi
}
