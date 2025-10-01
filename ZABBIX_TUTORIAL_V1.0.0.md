# Monitoring Redis Enterprise with Zabbix Agent 2 and `re_summary_zabbix.sh`

This tutorial explains how to use the [`re_summary_zabbix.sh`](./re_summary_zabbix.sh) script together with **Zabbix Agent 2** to monitor Redis Enterprise clusters and databases.

> ⚠️ This guide assumes you already have a working **Zabbix Server** and **Zabbix Agent 2** installed and connected.

---

## 1. Install the script

On the host where Zabbix Agent 2 runs (often the Zabbix Server itself):

```bash
sudo mkdir -p /etc/zabbix/scripts
sudo curl -o /etc/zabbix/scripts/re_summary_zabbix.sh \
  https://raw.githubusercontent.com/gacerioni/redis-enterprise-zabbix-monitor/main/re_summary_zabbix.sh
sudo chmod 755 /etc/zabbix/scripts/re_summary_zabbix.sh
sudo chown zabbix:zabbix /etc/zabbix/scripts/re_summary_zabbix.sh
```

---

## 2. Configure Zabbix Agent 2

Create a new config file for the user parameters:

```bash
sudo tee /etc/zabbix/zabbix_agent2.d/redis_enterprise.conf >/dev/null <<'EOF'
# Master item: fetches the full Prometheus text once per call
UserParameter=redis.re.summary[*],/etc/zabbix/scripts/re_summary_zabbix.sh --endpoint $1 $2
EOF
```

Restart the agent:

```bash
sudo systemctl restart zabbix-agent2
```

Test it:

```bash
zabbix_agent2 -t 'redis.re.summary[https://<your-cluster>:8070/v2,--insecure]'
```

You should see output similar to:

```
==== Redis Enterprise Summary @ 2025-10-01 18:22:32 UTC ====
Exporter up:  yes
Cluster:  rj-prod.redis.adiq.local
Cluster version:  7.4.6-102
Databases:  3
DBs not active:  0
Total ingress (bytes):  70122.6
Total egress  (bytes):  1.66281e+06

DB_UID    mem_used_MB  mem_used_%  st      avg_latency_us      ingress     egress
2         94           2.3         active  389                 296         3478
3         728          35.5        active  865                 153         200
4         1173         31.0        active  302                 69673       1659130
```

---

## 3. Create a Master Item in Zabbix

In the Zabbix frontend:

1. Go to **Configuration → Hosts → Items → Create item** (on the host where agent2 runs).
2. Fill in:
   - **Name:** `RE v2 summary (text)`
   - **Type:** `Zabbix agent`
   - **Key:**  
     ```
     redis.re.summary[https://<your-cluster>:8070/v2,--insecure]
     ```
   - **Type of information:** `Text`
   - **Update interval:** `60s`
   - **History:** `1d`
   - **Trends:** `0`
3. Save.

This item stores the whole script output.

---

## 4. Create Dependent Items for Metrics

Each metric you want must be a **Dependent item** that parses the master text item.  
Use **Regular expression preprocessing** to capture values. For numeric values that might appear as integers, decimals, or scientific notation, the regex below already handles all formats.

> **Tip:** If your Zabbix requires a single capture group, keep only the desired group `(...)` and use `?:` for non-capturing where shown.

### 4.1 Cluster-level metrics

- **Exporter up (1/0)**  
  - Key: `redis.re.cluster.exporter_up`  
  - Preprocessing:
    1) **Regular expression**
       ```
       (?m)^Exporter up:\s+(yes|no)
       ```
       Output: `\1`  
    2) **JavaScript**
       ```js
       return value === 'yes' ? 1 : 0;
       ```

- **Cluster name**  
  - Key: `redis.re.cluster.name`  
  - Type of information: `Text`  
  - Regex:
    ```
    (?m)^Cluster:\s+(.+)$
    ```

- **Cluster version (text)**  
  - Key: `redis.re.cluster.version`  
  - Type of information: `Text`  
  - Regex:
    ```
    (?m)^Cluster version:\s+([0-9A-Za-z.\-]+)
    ```

- **DB count**  
  - Key: `redis.re.cluster.db_count`  
  - Regex:
    ```
    (?m)^Databases:\s+([0-9]+)
    ```

- **DBs not active**  
  - Key: `redis.re.cluster.db_not_active`  
  - Regex:
    ```
    (?m)^DBs not active:\s+([0-9]+)
    ```

- **Total ingress (bytes)**  
  - Key: `redis.re.cluster.ingress_bytes`  
  - Units: `B`  
  - Regex:
    ```
    (?m)^Total ingress \(bytes\):\s+([0-9]+(?:\.[0-9]+)?(?:e[+\-]?[0-9]+)?)
    ```

- **Total egress (bytes)**  
  - Key: `redis.re.cluster.egress_bytes`  
  - Units: `B`  
  - Regex:
    ```
    (?m)^Total egress\s+\(bytes\):\s+([0-9]+(?:\.[0-9]+)?(?:e[+\-]?[0-9]+)?)
    ```

### 4.2 Per-DB metrics

For each database **UID**, create items with regex patterns that **start with the DB UID** at the beginning of the line.  
Below is an example for **DB UID = 4** (replace `4` with your DB’s UID). The table columns are:

```
DB_UID    mem_used_MB  mem_used_%  st      avg_latency_us      ingress     egress
```

- **Memory MB**  
  - Key: `redis.re.db.mem_mb.4`  
  - Units: `MB`  
  - Regex:
    ```
    (?m)^\s*4\s+([0-9]+(?:\.[0-9]+)?)
    ```

- **Memory %**  
  - Key: `redis.re.db.mem_pct.4`  
  - Units: `%`  
  - Regex:
    ```
    (?m)^\s*4\s+\S+\s+([0-9]+(?:\.[0-9]+)?)
    ```

- **Status (active=1, otherwise=0)**  
  - Key: `redis.re.db.status.4`  
  - Preprocessing steps:
    1) **Regular expression**
       ```
       (?m)^\s*4\s+\S+\s+\S+\s+(\S+)
       ```
       Output: `\1`  
    2) **JavaScript**
       ```js
       return value === 'active' ? 1 : 0;
       ```

- **Average latency (µs)**  
  - Key: `redis.re.db.avg_latency_us.4`  
  - Units: `us`  
  - Regex:
    ```
    (?m)^\s*4\s+\S+\s+\S+\s+\S+\s+([0-9]+(?:\.[0-9]+)?)
    ```

- **Ingress bytes**  
  - Key: `redis.re.db.ingress.4`  
  - Units: `B`  
  - Regex:
    ```
    (?m)^\s*4\s+\S+\s+\S+\s+\S+\s+\S+\s+([0-9]+(?:\.[0-9]+)?(?:e[+\-]?[0-9]+)?)
    ```

- **Egress bytes**  
  - Key: `redis.re.db.egress.4`  
  - Units: `B`  
  - Regex:
    ```
    (?m)^\s*4\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+([0-9]+(?:\.[0-9]+)?(?:e[+\-]?[0-9]+)?)
    ```

> 🔁 Repeat for each database UID you care about (`2, 3, 4, ...`). Only the **first number** in the regex changes.

---

## 5. Ask Users for Script Output

Because each Redis Enterprise cluster has different DB IDs, you may need your users to send a sample run:

```bash
./re_summary_zabbix.sh --endpoint https://<their-cluster>:8070/v2 --insecure | head -n 30
```

With that, you can quickly craft the regexes for their DB UIDs.

---

## 6. Optional: Triggers

Once items are working, add triggers such as:

- Memory usage > 80%:
  ```
  last(/<Host>/redis.re.db.mem_pct.4) > 80
  ```
- Avg latency > 2 ms over 5 minutes:
  ```
  avg(/<Host>/redis.re.db.avg_latency_us.4,5m) > 2000
  ```
- DB not active:
  ```
  last(/<Host>/redis.re.db.status.4) = 0
  ```
- Exporter down:
  ```
  last(/<Host>/redis.re.cluster.exporter_up) = 0
  ```

---

## 7. Verify

- Check **Monitoring → Latest data** for your host.
- The cluster totals and DB-specific metrics should update every minute.
- Adjust regexes if DB UIDs differ.

---

## Summary

- Use `re_summary_zabbix.sh` to fetch all metrics as one text block.
- Create **one master text item**.
- Add **dependent items** with regex extractors for cluster totals and per-DB metrics.
- Anchor per-DB regexes by **DB UID**.
- Request users’ script output to know which DB UIDs to configure.
