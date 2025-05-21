#!/usr/bin/env bash
FILE="$1"

# Detect NDJSON vs array and pick iterator
ITER='.'
if jq -e 'type=="array"' "$FILE" >/dev/null; then
  ITER='.[]'
fi

echo "== Top endpoints =="
jq -r "$ITER
       | select(.textPayload?)
       | .textPayload
       | capture(\"url=\\\"(?<u>[^\\\"]+)\\\"\")[\"u\"]
       | split(\"?\")[0]" "$FILE" \
| sort | uniq -c | sort -rn | head

echo
echo "== Top clients =="
jq -r "$ITER
       | select(.textPayload?)
       | .textPayload
       | capture(\"from=(?<ip>[^:]+)\")[\"ip\"]" "$FILE" \
| sort | uniq -c | sort -rn | head

echo
echo "== Slowest audit ops =="
jq -rc "$ITER
        | select(.jsonPayload?.event_type? // \"\" == \"audit\")
        | {
            id:       .jsonPayload.payload.id,
            stage:    .jsonPayload.payload.stage,
            ts:       (.jsonPayload.payload.timestamp // .timestamp),
            ep:       .jsonPayload.payload.request.endpoint,
            status:   (.jsonPayload.payload.response.status // \"\")
          }" "$FILE" \
| jq -s -r '
    # ───── helper:  RFC3339 → epoch-ms  (drop .nanoseconds first) ─────
    def ms:
      gsub("\\.[0-9]+Z$";"Z")
      | strptime("%Y-%m-%dT%H:%M:%SZ")
      | mktime*1000 ;

    # group the two records with the same audit id
    group_by(.id)[] | select(length==2) |

    # normalise ordering (Start may arrive after Complete in the log)
    ( if .[0].stage|endswith("Start") then {s:.[0], d:.[1]}
      else {s:.[1], d:.[0]}
      end ) as $p |

    ( ($p.d.ts|ms) - ($p.s.ts|ms) ) as $ms |

    [$ms,$p.d.status,$p.s.ep] | @tsv
' \
| sort -n -r -k1 | head \
| awk -F'\t' '
    BEGIN { printf "%-10s  %-6s  %s\n","duration","status","endpoint";
            print "----------  ------  ------------------------------------------" }
    { printf "%-10d  %-6s  %s\n",$1,$2,$3 }
'