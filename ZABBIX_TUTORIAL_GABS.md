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

You should see the full table, e.g.:

```
==== Redis Enterprise Summary @ 2025-09-25 19:40:11 UTC ====
Exporter up:  yes
Cluster:  my-cluster
Databases:  12
DBs not active:  0
Total ingress (bytes):  1056881707
Total egress  (bytes):  12313116

DB_UID    DB_NAME      mem_used_MB  mem_used_%  HA  st  p50_us  ingress   egress
18        redis-app    1993         97.3        Y   0   264     909934330 543685
24        another-db   9            9.0         Y   0   528     1578199   1084744
...
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
Use **Regular expression preprocessing** to capture numeric values.

### Cluster-level metrics

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
- **Total ingress**
  - Key: `redis.re.cluster.ingress_bytes`
  - Units: `B`
  - Regex:
    ```
    (?m)^Total ingress \(bytes\):\s+([0-9]+)
    ```
- **Total egress**
  - Key: `redis.re.cluster.egress_bytes`
  - Units: `B`
  - Regex:
    ```
    (?m)^Total egress\s+\(bytes\):\s+([0-9]+)
    ```

### Per-DB metrics

For each database UID, create items with regex patterns that start with the DB UID.  
Below is an example for **DB UID = 18** (replace `18` with your DB’s UID):

- **Memory MB**  
  - Key: `redis.re.db.mem_mb.18`  
  - Units: `MB`  
  - Regex:
    ```
    (?m)^\s*18\s+\S+\s+([0-9.]+)\s+
    ```

- **Memory %**  
  - Key: `redis.re.db.mem_pct.18`  
  - Units: `%`  
  - Regex:
    ```
    (?m)^\s*18\s+\S+\s+\S+\s+([0-9.]+)\s+
    ```

- **HA (1/0)**  
  - Key: `redis.re.db.ha.18`  
  - Preprocessing steps:
    1. Regex:
       ```
       (?m)^\s*18\s+\S+\s+\S+\s+\S+\s+([YN])\s+
       ```
       Output: `\1`
    2. JavaScript:
       ```js
       return value === 'Y' ? 1 : 0;
       ```

- **Status**  
  - Key: `redis.re.db.status.18`  
  - Regex:
    ```
    (?m)^\s*18\s+\S+(?:\s+\S+){4}\s+([0-9]+)\s+
    ```

- **Latency p50 (µs)**  
  - Key: `redis.re.db.p50_us.18`  
  - Units: `us`  
  - Regex:
    ```
    (?m)^\s*18\s+\S+(?:\s+\S+){5}\s+([0-9.]+)\s+
    ```

- **Ingress bytes**  
  - Key: `redis.re.db.ingress.18`  
  - Units: `B`  
  - Regex:
    ```
    (?m)^\s*18\s+\S+(?:\s+\S+){6}\s+([0-9.]+)\s+
    ```

- **Egress bytes**  
  - Key: `redis.re.db.egress.18`  
  - Units: `B`  
  - Regex:
    ```
    (?m)^\s*18\s+\S+(?:\s+\S+){7}\s+([0-9.]+)\s*$
    ```

Repeat for each database UID you care about (`12, 13, 24, ...`).  
The regex’s **first number** is always the DB UID.

---

## 5. Ask Users for Script Output

Because each Redis Enterprise cluster has different DB IDs and names, you may need your users to send you a sample run of:

```bash
./re_summary_zabbix.sh --endpoint https://<their-cluster>:8070/v2 --insecure | head -n 30
```

With that, you can quickly craft the regexes for their DB UIDs.

---

## 6. Optional: Triggers

Once items are working, add triggers such as:

- Memory usage > 80%:
  ```
  last(/<Host>/redis.re.db.mem_pct.18) > 80
  ```
- p50 latency > 2 ms over 5 minutes:
  ```
  avg(/<Host>/redis.re.db.p50_us.18,5m) > 2000
  ```
- Not HA:
  ```
  last(/<Host>/redis.re.db.ha.18) = 0
  ```

---

## 7. Verify

- Check **Monitoring → Latest data** for your host.
- The cluster totals and DB-specific metrics should update every minute.
- Adjust regexes if DB IDs differ.

---

## Summary

- Use `re_summary_zabbix.sh` to fetch all metrics as one text block.
- Create **one master text item**.
- Add **dependent items** with regex extractors for cluster totals and per-DB metrics.
- Use DB UIDs as anchors in regex patterns.
- Request users’ script output to know which DB UIDs to configure.
