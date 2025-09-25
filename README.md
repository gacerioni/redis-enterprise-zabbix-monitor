# Redis Enterprise Monitoring Script (Zabbix-Ready)

This repository provides a portable Bash script (`re_summary_zabbix.sh`) to fetch and summarize key Redis Enterprise metrics from the Prometheus v2 endpoint.  
It is designed to run both on **Linux** and **macOS** (BSD awk compatible) and can be integrated with **Zabbix** as custom checks or external scripts.

## Features

- ✅ Cluster overview:
  - Exporter status
  - Cluster name
  - Total number of databases
  - Ingress/Egress traffic totals
- ✅ Per-database details:
  - Memory used (MB)
  - Memory usage (% of maxmemory)
  - Replication factor (HA flag)
  - Status (0 = active)
  - Latency p50 (µs, derived from histogram)
  - Ingress / Egress bytes

## Usage

Fetch metrics from a live endpoint (with self-signed TLS):

```bash
./re_summary_zabbix.sh --endpoint https://redis.platformengineer.io:8070/v2 --insecure
```

Or read from a saved scrape file:

```bash
./re_summary_zabbix.sh --from-file scrape_out.txt
```

Example output:

```
==== Redis Enterprise Summary @ 2025-09-25 17:08:55 UTC ====
Exporter up:  yes
Cluster:  gabs.redisdemo.com
Databases:  13
DBs not active:  0
Total ingress (bytes):  1394948
Total egress  (bytes):  541359

DB_UID    DB_NAME                     mem_used_MB  mem_used_%  HA      status  p50_us  ingress   egress
22        cache-soccer-workshop       3            0.1        N       0       1       107148    17978
24        aa-adiq                     7            7.4        Y       0       528     115904    32500
...
```

## Integration with Zabbix

1. Copy `re_summary_zabbix.sh` to your Zabbix agent host:

   ```bash
   sudo mkdir -p /etc/zabbix/scripts
   sudo cp re_summary_zabbix.sh /etc/zabbix/scripts/
   sudo chown zabbix:zabbix /etc/zabbix/scripts/re_summary_zabbix.sh
   sudo chmod 755 /etc/zabbix/scripts/re_summary_zabbix.sh
   ```

2. Add UserParameters in `/etc/zabbix/zabbix_agentd.d/redis_enterprise.conf`:

   ```ini
   UserParameter=redis.re.summary[*],/etc/zabbix/scripts/re_summary_zabbix.sh --endpoint $1 $2
   ```

   You can extend this with awk filters to extract specific DB metrics (e.g., memory %, p50 latency).

3. Restart the Zabbix agent and create items/triggers pointing to the new keys.

## Notes

- Requires `curl` and `awk` (already present on most systems).
- Compatible with both GNU awk and BSD awk (macOS default).
- If your Prometheus endpoint does not expose `redis_server_used_memory` and `redis_server_maxmemory`, memory % will remain `0`. In that case, check cluster settings or scrape another node.

## License

MIT
