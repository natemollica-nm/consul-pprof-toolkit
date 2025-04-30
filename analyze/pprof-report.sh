#!/usr/bin/env sh
#
# pprof-report.sh ─ Summarise Consul pprof data
#
# Supports:
#   • .tar.gz bundles from `consul debug`
#   • output directories from `consul-pprof.sh`
#
# Profiles handled: heap  profile(cpu)  goroutine  trace
# ---------------------------------------------------------------------------

##############################################################################
# SET-UP
##############################################################################
. "$(dirname "$0")/../utils/libui.sh"     # unified colours / log helpers

DEFAULT_LINES=25
KEEP_WORK=0
PROFILE_SET="heap,profile,goroutine,goroutine-raw,trace"

profile_glob() {
  case "$1" in
    profile)   echo '*profile.prof' ;;
    heap)      echo '*heap.prof' ;;
    goroutine) echo '*goroutine.prof' ;;
    goroutine-raw) echo '*goroutine-raw.prof' ;;
    trace)     echo '*trace.out' ;;
  esac
}

need() { command -v "$1" >/dev/null 2>&1 || fatal "'$1' required but missing"; }
need go; need tar; need find

##############################################################################
# USAGE
##############################################################################
usage() {
cat <<EOF
Usage: $(basename "$0") [options] <bundle.tar.gz | directory>

Options
  -n NUM          show NUM lines per profile section (default $DEFAULT_LINES)
  -p LIST         comma-separated profile list (default $PROFILE_SET)
  -k, --keep      keep extracted temp dir
  -h, --help      show this help

Examples
  # Analyse a debug bundle
  $(basename "$0") consul-pprof-2025-04-29T14-28-28.tar.gz

  # Show only heap & cpu, 40 lines each
  $(basename "$0") -p heap,profile -n 40 ./pprof-out/

  # Keep extracted files for manual inspection
  $(basename "$0") -k debug-bundle.tgz
EOF
exit 0
}

##############################################################################
# ARGUMENT PARSE
##############################################################################
LINES=$DEFAULT_LINES
while [ $# -gt 0 ]; do
  case "$1" in
    -n)  LINES=$2; shift 2 ;;
    -p)  PROFILE_SET=$2; shift 2 ;;
    -k|--keep) KEEP_WORK=1; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) fatal "Unknown option $1" ;;
    *)  break ;;
  esac
done

[ $# -eq 1 ] || usage
INPUT=$1

##############################################################################
# UNPACK IF NEEDED
##############################################################################
TMPDIR=
cleanup() { [ "$KEEP_WORK" -eq 0 ] && [ -n "$TMPDIR" ] && rm -rf "$TMPDIR"; }

case "$INPUT" in
  *.tar.gz|*.tgz)
    [ -f "$INPUT" ] || fatal "Bundle not found: $INPUT"
    TMPDIR=$(mktemp -d) || fatal "mktemp failed"
    trap cleanup EXIT INT TERM
    info "Extracting $(basename "$INPUT") → $TMPDIR"
    tar -xzf "$INPUT" -C "$TMPDIR" || fatal "tar extraction failed"
    ROOT=$TMPDIR
    ;;
  *)
    [ -d "$INPUT" ] || fatal "Directory not found: $INPUT"
    ROOT=$INPUT
    ;;
esac

##############################################################################
# PROCESS PROFILES
##############################################################################
IFS=','; SET=$PROFILE_SET; unset PROFILE_SET
FOUND=0
for prof in $SET; do
  pat=$(profile_glob "$prof") || continue
  FILES=$(find "$ROOT" -type f -iname "$pat" -print)
  [ -z "$FILES" ] && { warn "Profile '$prof' not found"; continue; }

  FOUND=1
  info "===== $prof — top $LINES ====="
  for file in $FILES; do
    info "File: $(basename "$file")"
    if [ "$prof" = trace ]; then
      info "Use: go tool trace -http=:0 \"$file\""
      echo
      continue
    fi
    go tool pprof -top "$file" 2>/dev/null | sed -n "1,${LINES}p"
    echo
  done
done

[ "$FOUND" -eq 1 ] || fatal "No matching profiles found in $(realpath "$ROOT")"
