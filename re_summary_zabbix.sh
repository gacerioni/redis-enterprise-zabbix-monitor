#!/usr/bin/env bash
# re_summary_mem.sh — Redis Enterprise Prometheus summary with memory % (portable awk)
# Usage:
#   ./re_summary_mem.sh --endpoint https://host:8070/v2 [--insecure]
#   ./re_summary_mem.sh --from-file scrape.txt

set -euo pipefail
endpoint=""; from_file=""; insecure=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) endpoint="$2"; shift 2;;
    --from-file) from_file="$2"; shift 2;;
    --insecure) insecure=1; shift;;
    -h|--help) echo "see header"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done
[[ -z "$endpoint" && -z "$from_file" ]] && { echo "Must pass --endpoint or --from-file" >&2; exit 2; }

metrics="$(mktemp)"; trap 'rm -f "$metrics"' EXIT

if [[ -n "$from_file" ]]; then
  cp "$from_file" "$metrics"
else
  flags=( -sSL --compressed
          -H 'Accept: text/plain; version=0.0.4'
          --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 1 )
  [[ -n "$insecure" ]] && flags+=(-k)
  curl "${flags[@]}" "$endpoint" -o "$metrics"
  # crude sanity check: bail if we clearly got HTML
  if head -c 256 "$metrics" | grep -qiE '<(html|!doctype)'; then
    echo "ERROR: Endpoint returned HTML (likely an error page). Check URL/TLS." >&2
    exit 3
  fi
fi

AWK="${AWK:-awk}"
"$AWK" '
function labelval(labels, key,    s,p,q,v){ s=index(labels,key"=\""); if(!s) return ""; p=s+length(key)+2; q=index(substr(labels,p),"\""); if(!q) return ""; v=substr(labels,p,q-1); return v }
function add(map,k,v){ map[k]+=v }

BEGIN{ OFS="  " }

# Database identity
/^db_config\{/ {
  labels=$0; gsub(/^db_config\{/, "", labels); sub(/\}[ \t].*$/, "", labels)
  d=labelval(labels,"db"); n=labelval(labels,"db_name"); c=labelval(labels,"cluster")
  if (cluster=="") cluster=c
  if (d!=""){ db_name[d]=n; db_seen[d]=1 }
  next
}

# Memory limit per DB (if present)
/^db_memory_limit_bytes\{/ {
  labels=$0; gsub(/^db_memory_limit_bytes\{/, "", labels); sub(/\}[ \t].*$/, "", labels)
  d=labelval(labels,"db"); if(d!="") db_mem_limit[d]=$NF+0; db_seen[d]=1; next
}

# Shard-level memory used/limit -> sum to DB
/^redis_server_used_memory\{/ {
  labels=$0; sub(/^[^{]*\{/, "", labels); sub(/\}[ \t].*$/, "", labels)
  d=labelval(labels,"db"); if(d!="") mem_used[d]+=$NF+0; next
}
/^redis_server_maxmemory\{/ {
  labels=$0; sub(/^[^{]*\{/, "", labels); sub(/\}[ \t].*$/, "", labels)
  d=labelval(labels,"db"); if(d!="") mem_max[d]+=$NF+0; next
}

# Status / HA
/^db_replication_factor\{/ {
  labels=$0; gsub(/^db_replication_factor\{/, "", labels); sub(/\}[ \t].*$/, "", labels)
  d=labelval(labels,"db"); if(d!="") repl[d]=$NF+0; db_seen[d]=1; next
}
/^db_status\{/ {
  labels=$0; gsub(/^db_status\{/, "", labels); sub(/\}[ \t].*$/, "", labels)
  d=labelval(labels,"db"); if(d!="") status[d]=$NF+0; db_seen[d]=1; next
}

# Traffic totals
/^endpoint_ingress\{/ {
  labels=$0; gsub(/^endpoint_ingress\{/, "", labels); sub(/\}[ \t].*$/, "", labels)
  d=labelval(labels,"db"); add(ingress,d,$NF+0); db_seen[d]=1; next
}
/^endpoint_egress\{/ {
  labels=$0; gsub(/^endpoint_egress\{/, "", labels); sub(/\}[ \t].*$/, "", labels)
  d=labelval(labels,"db"); add(egress,d,$NF+0); db_seen[d]=1; next
}

# Latency p50 from histogram
/^endpoint_other_requests_latency_histogram_bucket\{/ {
  labels=$0; gsub(/^endpoint_other_requests_latency_histogram_bucket\{/, "", labels); sub(/\}[ \t].*$/, "", labels)
  d=labelval(labels,"db"); le=labelval(labels,"le"); if(d!=""){ buckets[d"|"le]+=$NF+0 } db_seen[d]=1; next
}
/^endpoint_other_requests_latency_histogram_count\{/ {
  labels=$0; gsub(/^endpoint_other_requests_latency_histogram_count\{/, "", labels); sub(/\}[ \t].*$/, "", labels)
  d=labelval(labels,"db"); count[d]+=$NF+0; db_seen[d]=1; next
}

END{
  cmd="date -u +\"%Y-%m-%d %H:%M:%S UTC\""; cmd|getline now; close(cmd)
  print "==== Redis Enterprise Summary @ " now " ===="
  print "Exporter up:", (NR>0? "yes":"no")
  print "Cluster:", (cluster==""? "unknown":cluster)

  db_total=0; non_active=0; tot_in=0; tot_out=0
  for(d in db_seen){ db_total++; if(status[d]!="" && status[d]!=0) non_active++; tot_in+=ingress[d]; tot_out+=egress[d] }
  print "Databases:", db_total
  print "DBs not active:", non_active
  print "Total ingress (bytes):", tot_in+0
  print "Total egress  (bytes):", tot_out+0
  print ""

  printf "%-8s  %-26s  %-11s  %-10s  %-6s  %-6s  %-10s  %-10s  %-10s\n", \
    "DB_UID","DB_NAME","mem_used_MB","mem_used_%","HA","st","p50_us","ingress","egress"

  for(d in db_seen){
    # p50 (guard no traffic)
    if (count[d] <= 0) { p50=0 }
    else {
      half=count[d]/2.0; best=-1
      for(k in buckets){
        split(k,parts,"|"); if(parts[1]!=d) continue
        le=parts[2]; le_n=(le=="+Inf"?1e99:le+0)
        if(buckets[k]>=half){ if(best<0 || le_n<best) best=le_n }
      }
      p50=(best<0?0:best)
    }
    ha=(repl[d]>=2?"Y":"N")
    st=(status[d]==""?"":status[d])

    # memory used/%
    used=mem_used[d]; maxb=(mem_max[d]>0?mem_max[d]:db_mem_limit[d])
    usedMB=(used>0? used/(1024*1024) : 0)
    perc=(maxb>0? (100.0*used/maxb) : 0)

    printf "%-8s  %-26s  %-11.0f  %-10.1f  %-6s  %-6s  %-10.0f  %-10.0f  %-10.0f\n", \
      d, (db_name[d]==""?"-":db_name[d]), usedMB, perc, ha, st, p50, ingress[d]+0, egress[d]+0
  }
}
' "$metrics"
