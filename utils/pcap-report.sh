#!/usr/bin/env bash
#
# pcap-report.sh – one-shot triage for Consul packet captures
#
# Dependencies: tshark, capinfos, awk, grep, (optional) datamash
# Author: HashiCorp Support • updated 16-May-2025
#
# Defaults follow Consul-server port reference:
# 8300 RPC • 8301 LAN gossip • 8302 WAN gossip •
# 8500 HTTP • 8501 HTTPS • 8502 gRPC • 8503 gRPC-TLS • 8600 DNS
#

set -uo pipefail

###############################################################################
# Colour helpers
###############################################################################
NOCOL='\033[0m'
BOLD='\033[1m'
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
CYAN='\033[0;36m'

c_info() { printf "${CYAN}%b${NOCOL}\n" "$*"; }
c_ok() { printf "${GRN}%b${NOCOL}\n" "$*"; }
c_warn() { printf "${YLW}%b${NOCOL}\n" "$*"; }
c_err() { printf "${RED}%b${NOCOL}\n" "$*"; }

###############################################################################
usage() {
    cat <<EOF
${BOLD}Usage:${NOCOL} $(basename "$0") -f <capture.pcap> [-p ports] [-o report.txt]

  -f  Packet-capture file (required)
  -p  Comma-separated port list to analyse
        Default: 8300,8301,8302,8500,8501,8502,8503,8600
  -o  Also write colourised output to <file>
  -h  Show this help

Examples
  $(basename "$0") -f consul-event.pcap
  $(basename "$0") -f cap.pcap -p 443,8200 -o out.txt
EOF
}

###############################################################################
# Parse options
###############################################################################
PORTS="8300,8301,8302,8500,8501,8502,8503,8600"
OUTFILE=""

while getopts ":f:p:o:h" opt; do
    case "$opt" in
    f) PCAP="$OPTARG" ;;
    p) PORTS="$OPTARG" ;;
    o) OUTFILE="$OPTARG" ;;
    h)
        usage
        exit 0
        ;;
    \?)
        c_err "Unknown option: -$OPTARG"
        usage
        exit 1
        ;;
    :)
        c_err "Option -$OPTARG requires an argument."
        usage
        exit 1
        ;;
    esac
done

[[ -z "${PCAP:-}" ]] && {
    c_err "You must supply -f <pcap>"
    usage
    exit 1
}
[[ ! -f "$PCAP" ]] && {
    c_err "File '$PCAP' not found"
    exit 1
}

###############################################################################
# Dependencies
###############################################################################
for bin in tshark capinfos; do
    command -v "$bin" >/dev/null 2>&1 || {
        c_err "Missing $bin"
        exit 1
    }
done
DATAMASH_OK=true
command -v datamash >/dev/null 2>&1 || DATAMASH_OK=false

###############################################################################
# Helpers
###############################################################################
emit() {
    [[ -n "$OUTFILE" ]] && printf '%b\n' "$1" >>"$OUTFILE"
    printf '%b\n' "$1"
}

# Build filter strings
IFS=',' read -ra PORT_ARR <<<"$PORTS"
MAINPORT="${PORT_ARR[0]}"

build_filter() {
    local proto="$1" # tcp or udp
    local filter=""
    for p in "${PORT_ARR[@]}"; do
        filter+="(${proto}.port==${p}) || "
    done
    echo "${filter::-4}" # strip trailing ' || '
}
TCP_FILTER=$(build_filter "tcp")
UDP_FILTER=$(build_filter "udp")
ANY_FILTER="(${TCP_FILTER}) || (${UDP_FILTER})"

###############################################################################
# 0. Basic capture info (do not abort on truncated pcap)
###############################################################################
c_info "\n=== CAPTURE INFO ========================================="
set +e
CAPINFO=$(capinfos -T "$PCAP" 2>/dev/null)
CAP_RC=$?
set -e
emit "$CAPINFO"
[[ $CAP_RC -ne 0 ]] && c_warn "capinfos returned $CAP_RC – proceeding anyway."

###############################################################################
# 1. Conversation summaries
###############################################################################
c_info "\n=== TCP CONVERSATIONS (Consul ports) ====================="
CONV_TCP=$(tshark -r "$PCAP" -Y "$TCP_FILTER" -q -z conv,tcp,ip.addr 2>/dev/null || true)
emit "$CONV_TCP"

c_info "\n=== UDP CONVERSATIONS (gossip/DNS) ========================"
CONV_UDP=$(tshark -r "$PCAP" -Y "$UDP_FILTER" -q -z conv,udp,ip.addr 2>/dev/null || true)
emit "$CONV_UDP"

###############################################################################
# 2. New connections per second (SYNs)
###############################################################################
c_info "\n=== NEW CONNECTIONS PER SECOND ============================"
SYN_JSON=$(tshark -r "$PCAP" -Y "tcp.flags.syn==1 && tcp.flags.ack==0 && ($TCP_FILTER)" \
    -T fields -e frame.time_epoch 2>/dev/null || true)
if [[ -z "$SYN_JSON" ]]; then
    c_ok "No SYN packets on selected ports."
else
    SYN_RATE=$(printf '%s\n' "$SYN_JSON" |
        awk '{print int($1)}' | sort | uniq -c | sort -nr | head)
    emit "$SYN_RATE"
fi

###############################################################################
# 3. TCP resets
###############################################################################
c_info "\n=== TCP RESETS (who sent them) ============================"
RST_LINES=$(tshark -r "$PCAP" -Y "tcp.flags.reset==1 && ($TCP_FILTER)" \
    -T fields -e frame.time -e ip.src -e ip.dst -e tcp.port 2>/dev/null || true)
[[ -z "$RST_LINES" ]] && c_ok "No RSTs on these ports." || emit "$RST_LINES"

###############################################################################
# 4. Retransmissions / Dup-ACKs
###############################################################################
c_info "\n=== RETRANSMISSIONS / DUP-ACKs ============================"
RETRANS=$(tshark -r "$PCAP" -q -z io,stat,1,"COUNT(tcp.analysis.retransmission && ($TCP_FILTER)) retrans" 2>/dev/null || true)
emit "$RETRANS"

###############################################################################
# 5. RTT stats (main port only)
###############################################################################
c_info "\n=== RTT STATISTICS (port $MAINPORT) ======================="
RTT_VALS=$(tshark -r "$PCAP" -Y "tcp.analysis.ack_rtt && tcp.port==$MAINPORT" \
    -T fields -e tcp.analysis.ack_rtt 2>/dev/null || true)
if [[ -z "$RTT_VALS" ]]; then
    c_warn "No ack RTT samples for port $MAINPORT."
else
    if $DATAMASH_OK; then
        RTT_STATS=$(printf '%s\n' $RTT_VALS | datamash mean 1 perc:95 1 max 1)
        emit "$(printf 'mean_ns p95_ns max_ns\n%s' "$RTT_STATS")"
    else
        # Fallback awk percentile
        RTT_STATS=$(printf '%s\n' $RTT_VALS | awk '
      {a[NR]=$1; sum+=$1}
      END{
        n=NR; asort(a);
        printf "mean_ns %.0f p95_ns %.0f max_ns %.0f\n", sum/n, a[int(n*0.95)], a[n];
      }')
        emit "$RTT_STATS"
    fi
fi

###############################################################################
# 6. TLS handshakes
###############################################################################
c_info "\n=== TLS HANDSHAKES (ClientHello) =========================="
HELLOS=$(tshark -r "$PCAP" -Y "tls.handshake.type==1 && ($TCP_FILTER)" 2>/dev/null | wc -l | tr -d '[:space:]' || true)
emit "ClientHello packets on selected ports: $HELLOS"

###############################################################################
# 7. HTTP response codes (API port 8500 clear-text only)
###############################################################################
c_info "\n=== TOP HTTP RESPONSE CODES (port 8500|8501) ===================="
HTTP_STATS=$(tshark -r "$PCAP" -Y 'http.response.code && (tcp.port==8500 || tcp.port == 8501)' \
    -T fields -e http.response.code 2>/dev/null |
    sort | uniq -c | sort -nr | head -10 || true)
[[ -z "$HTTP_STATS" ]] && c_warn "No clear-text HTTP on port 8500 or 8501." || emit "$HTTP_STATS"

c_ok "\nReport complete."
