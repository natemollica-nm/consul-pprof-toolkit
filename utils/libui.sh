#!/usr/bin/env sh
# libui.sh ─ tiny POSIX logging helpers
# Sources formatting.env if present so our colours match logging.sh

# shellcheck disable=SC1091
[ -f "$(dirname "$0")/formatting.env" ] && . "$(dirname "$0")/formatting.env"

TIMESTAMP() { date '+%Y-%m-%d %H:%M:%S'; }

_info() { printf '%s %b%s %s\e[0m\n' "$(TIMESTAMP)" "${LIGHT_CYAN}[INFO]${RESET} ${DIM}" "$@"; }
_warn() { >&2 printf '%s %b%s %s\e[0m\n' "$(TIMESTAMP)" "${INTENSE_YELLOW}[WARN]${RESET} ${DIM}" "$@"; }
_error() { >&2 printf '%s %b%s %s\e[0m\n' "$(TIMESTAMP)" "${RED}[ERROR]${RESET} ${DIM}" "$@"; exit_code=1; }

# Public helpers -------------------------------------------------------------
info()  { _info  "$@"; }
warn()  { _warn  "$@"; }
error() { _error "$@"; }
fatal() { _error "$@"; exit 1; }
