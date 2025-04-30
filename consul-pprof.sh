#!/bin/sh

# POSIX-compliant script to collect Consul pprof profiles:
#   - heap
#   - profile (CPU)
#   - trace
#   - goroutine
# Uses CONSUL_HTTP_ADDR and CONSUL_HTTP_TOKEN if provided.

set -eu

###############################################################################
# 0) usage helper
###############################################################################
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Collect heap, CPU, trace and goroutine pprof data from a Consul agent (without enable_debug=true).

Options
  --addr    |--http-addr  |--consul-http-addr <URL> Consul HTTP address of desired agent (default \$CONSUL_HTTP_ADDR or http://localhost:8500)
  --token   |--http-token |--consul-http-token <T>  Consul ACL token (default \$CONSUL_HTTP_TOKEN)
  --duration|--seconds <N>                          Duration for CPU/trace captures in seconds (default 30)
  --output-dir|--out <DIR>                          Where to put the results (default /tmp/consul-pprof-<timestamp>)
  -h|--help                                         Show this help and exit

Environment variables respected:  CONSUL_HTTP_ADDR, CONSUL_HTTP_TOKEN
Command-line options always take precedence.
EOF
  exit 0
}


###############################################################################
# 1) colours
###############################################################################
RED=$(printf '\033[0;31m'); GRN=$(printf '\033[0;32m')
YLW=$(printf '\033[0;33m'); BLU=$(printf '\033[0;34m')
BOLD=$(printf '\033[1m');   RST=$(printf '\033[0m')

###############################################################################
# 2) defaults (ENV first, flags may override)
###############################################################################
CONSUL_ADDR="${CONSUL_HTTP_ADDR:-http://localhost:8500}"
CONSUL_TOKEN="${CONSUL_HTTP_TOKEN:-}"
DURATION="30"
TIMESTAMP=$(date +"%Y-%m-%dT%H-%M-%S")
OUTPUT_DIR="/tmp/consul-pprof-$TIMESTAMP"

###############################################################################
# 3) parse flags
###############################################################################
while [ $# -gt 0 ]; do
  case "$1" in
    --addr=*|--http-addr=*|--consul-http-addr=*)    CONSUL_ADDR="${1#*=}"            ;;
    --addr|--http-addr|--consul-http-addr)          shift; CONSUL_ADDR="$1"          ;;
    --token=*|--http-token=*|--consul-http-token=*) CONSUL_TOKEN="${1#*=}"           ;;
    --token|--http-token|--consul-http-token)       shift; CONSUL_TOKEN="$1"         ;;
    --duration=*|--seconds=*)                       DURATION="${1#*=}"               ;;
    --duration|--seconds)                           shift; DURATION="$1"             ;;
    --output-dir=*|--out=*)                         OUTPUT_DIR="${1#*=}"             ;;
    --output-dir|--out)                             shift; OUTPUT_DIR="$1"           ;;
    -h|--help) usage ;;
    --*) echo "Unknown option: $1" >&2; usage ;;
    *)  break ;;
  esac
  shift
done




###############################################################################
# 4) sanity-check required tools
###############################################################################
for cmd in curl sed grep mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "${RED}❌ Missing required command: $cmd${RST}" >&2; exit 1; }
done

mkdir -p "$OUTPUT_DIR"

###############################################################################
# 5) auth header / curl flags
###############################################################################
CURL_AUTH_HEADER=""
[ -n "$CONSUL_TOKEN" ] && {
  CURL_AUTH_HEADER="-H X-Consul-Token:${CONSUL_TOKEN}"
  echo "${BLU}🔐 Using explicit Consul token (CLI or ENV).${RST}"
}

CURL_FLAGS="--silent --insecure --retry 3 --retry-delay 2 --max-time $((DURATION + 15)) --connect-timeout 10"

###############################################################################
# 6) pre-flight (reachability + enable_debug hint)
###############################################################################
if ! curl $CURL_FLAGS $CURL_AUTH_HEADER "$CONSUL_ADDR/v1/status/leader" >/dev/null 2>&1; then
  echo "${RED}❌ Unable to reach Consul agent at $CONSUL_ADDR${RST}" >&2
  exit 1
fi

ENABLE_DEBUG=$(curl $CURL_FLAGS $CURL_AUTH_HEADER "$CONSUL_ADDR/v1/agent/self" \
  | sed -n 's/.*"EnableDebug":[ ]*\([^,}]*\).*/\1/p')

###############################################################################
# 7) announce run & prepare output
###############################################################################
mkdir -p "$OUTPUT_DIR"

echo "      ==> ${GRN}🔍  Collecting pprof from:${RST} $CONSUL_ADDR"
echo "      ==> ${GRN}⏱️  Duration:${RST} ${DURATION}s"
echo "      ==> ${GRN}📁  Output Dir:${RST} $OUTPUT_DIR"
echo "      ==> ${GRN}🐞  Debug Enabled:${RST} ${BOLD}$( [ "$ENABLE_DEBUG" = true ] && \
      printf '%s' "${GRN}true${RST}" || \
      printf '%s' "${RED}⚠ false${RST} ${YLW}(enable_debug=false)${RST}")"

###############################################################################
# 8) helper: validate profile file
###############################################################################
validate_profile_file() {
  file="$1"; label="$2"
  if [ ! -s "$file" ]; then
    echo "${RED}❌ $label profile empty: $file${RST}"; return 1
  fi
  if grep -qi 'stream timeout\|<html\|Usage:' "$file"; then
    echo "${YLW}⚠️  $label profile may contain errors${RST}"; return 1
  fi
  echo "${GRN}✅  ${BOLD}$label${RST} profile validated"
}

###############################################################################
# 9) capture profiles
###############################################################################
profiles="heap profile trace goroutine goroutine"
urls="heap profile?seconds=$DURATION trace?seconds=$DURATION goroutine goroutine?debug=2"
files="heap.prof profile.prof trace.out goroutine.prof goroutine-raw.prof"

i=1
for profile in $profiles; do
  url=$(printf '%s\n' "$urls"  | cut -d' ' -f$i)
  file=$(printf '%s\n' "$files" | cut -d' ' -f$i)
  path="$OUTPUT_DIR/$file"

  echo "${BLU}📦 Fetching $profile profile...${RST}"
  if ! curl $CURL_FLAGS $CURL_AUTH_HEADER "$CONSUL_ADDR/debug/pprof/$url" -o "$path"; then
    echo "${RED}❌ Failed to fetch $profile profile${RST}"; i=$((i+1)); continue
  fi
  validate_profile_file "$path" "$profile" || \
    echo "${YLW}⚠️  Skipping invalid $profile capture${RST}"
  i=$((i + 1))
done

echo "${GRN}🧪 Profile capture complete.${RST}"
echo "${GRN}📁 Results:${RST} $OUTPUT_DIR"