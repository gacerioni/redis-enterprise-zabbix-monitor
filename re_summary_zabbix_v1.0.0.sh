#!/usr/bin/env bash
# re_summary_zabbix_v1.0.0.sh — summary parser for bdb_* + redis_* metrics
# Adds CNM version from node_up

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
  flags=(-sSL --compressed -H 'Accept: text/plain; version=0.0.4'
         --connect-timeout 5 --max-time 20 --retry 2 --retry-delay 1)
  [[ -n "$insecure" ]] && flags+=(-k)
  curl "${flags[@]}" "$endpoint" -o "$metrics"
  if head -c 256 "$metrics" | grep -qiE '<(html|!doctype)'; then
    echo "ERROR: Endpoint returned HTML (likely wrong URL/TLS)" >&2
    exit 3
  fi
fi

AWK="${AWK:-awk}"
"$AWK" '
function labelval(labels, key,     pat, ok, start, len) {
  pat = key"=\"[^\"]*\""
  ok = match(labels, pat)
  if (!ok) return ""
  start = RSTART + length(key) + 2
  len   = RLENGTH - length(key) - 3
  return substr(labels, start, len)
}
function grab_labels(   s){ s=$0; sub(/^[^{]*\{/, "", s); sub(/\}[ \t].*$/, "", s); return s }

BEGIN{ OFS="  " }

# --- bdb basics
/^bdb_up\{/          { lbl=grab_labels(); b=labelval(lbl,"bdb"); st=labelval(lbl,"status"); cl=labelval(lbl,"cluster");
                       if(cluster=="") cluster=cl; if(b!=""){ bdb_seen[b]=1; bdb_status[b]=st; up[b]+=$NF+0 } next }
/^bdb_memory_limit\{/ { lbl=grab_labels(); b=labelval(lbl,"bdb"); if(b!=""){ mem_limit[b]=($NF+0); bdb_seen[b]=1 } next }
/^bdb_used_memory\{/   { lbl=grab_labels(); b=labelval(lbl,"bdb"); if(b!=""){ mem_used[b]+=($NF+0); bdb_seen[b]=1 } next }
/^redis_maxmemory\{/   { lbl=grab_labels(); b=labelval(lbl,"bdb"); if(b!=""){ redis_max_sum[b]+=($NF+0); bdb_seen[b]=1 } next }
/^redis_used_memory\{/ { lbl=grab_labels(); b=labelval(lbl,"bdb"); if(b!=""){ redis_used_sum[b]+=($NF+0); bdb_seen[b]=1 } next }
/^bdb_ingress_bytes\{/ { lbl=grab_labels(); b=labelval(lbl,"bdb"); if(b!=""){ ingress[b]+=($NF+0); bdb_seen[b]=1 } next }
/^bdb_egress_bytes\{/  { lbl=grab_labels(); b=labelval(lbl,"bdb"); if(b!=""){ egress[b]+=($NF+0); bdb_seen[b]=1 } next }
/^bdb_avg_latency\{/   { lbl=grab_labels(); b=labelval(lbl,"bdb"); if(b!=""){ avg_lat_s[b]=($NF+0); bdb_seen[b]=1 } next }

# --- capture CNM version from node_up
/^node_up\{/ {
  lbl=grab_labels()
  cl2=labelval(lbl,"cluster")
  ver=labelval(lbl,"cnm_version")
  if (cnm_version=="" && ver!="") cnm_version=ver
  if (cluster=="" && cl2!="") cluster=cl2
  next
}

END{
  for (b in bdb_seen) {
    if ((!(b in mem_used) || mem_used[b]==0) && redis_used_sum[b]>0) mem_used[b]=redis_used_sum[b]
    if ((!(b in mem_limit) || mem_limit[b]==0) && redis_max_sum[b]>0) mem_limit[b]=redis_max_sum[b]
  }

  cmd="date -u +\"%Y-%m-%d %H:%M:%S UTC\""; cmd|getline now; close(cmd)
  print "==== Redis Enterprise Summary @ " now " ===="
  print "Exporter up:", (NR>0? "yes":"no")
  print "Cluster:", (cluster==""? "unknown":cluster)
  if (cnm_version!="") print "Cluster version:", cnm_version

  db_total=0; non_active=0; tot_in=0; tot_out=0
  for (b in bdb_seen) {
    db_total++
    if (!(up[b]>0 && bdb_status[b]=="active")) non_active++
    tot_in+=ingress[b]
    tot_out+=egress[b]
  }
  print "Databases:", db_total
  print "DBs not active:", non_active
  print "Total ingress (bytes):", tot_in+0
  print "Total egress  (bytes):", tot_out+0
  print ""

  # Header
  printf "%-8s  %-11s  %-10s  %-6s  %-18s  %-10s  %-10s\n", \
    "DB_UID","mem_used_MB","mem_used_%","st","avg_latency_us","ingress","egress"

  for (b in bdb_seen) {
    used=mem_used[b]+0; lim=mem_limit[b]+0
    usedMB=(used>0? used/1048576.0 : 0)
    perc =(lim>0? (100.0*used/lim) : 0)
    st=(bdb_status[b]==""?"":bdb_status[b])
    avg_us=(avg_lat_s[b]>0? avg_lat_s[b]*1e6 : 0)

    printf "%-8s  %-11.0f  %-10.1f  %-6s  %-18.0f  %-10.0f  %-10.0f\n", \
      b, usedMB, perc, st, avg_us, ingress[b]+0, egress[b]+0
  }
}
' "$metrics"