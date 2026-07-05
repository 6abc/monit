# Monitoring Stack — 192.168.1.203

Prometheus + Alertmanager + Loki/Promtail + Grafana, deployed via Docker
Compose on Debian 13 (Trixie), with all persistent data under
`/home/ash/monitoring/data`.

## Architecture

```
                         Prometheus scrape
                 :9100  :9113  :9187  :9080
                           │
┌──────────────────────────▼───────────────────────────────┐
│  192.168.1.203 — monitoring server                        │
│                                                             │
│  ┌────────────┐ ┌─────────┐ ┌──────────────┐ ┌──────────┐ │
│  │ Prometheus │ │ Grafana │ │ Loki+Promtail│ │Alertmgr  │ │
│  │   :9090    │ │  :3000  │ │    :3100     │ │  :9093   │ │
│  └────────────┘ └─────────┘ └──────────────┘ └──────────┘ │
│  ┌────────────┐                                            │
│  │node-exporter│  (added: self-monitoring, see note below) │
│  │   :9100     │                                            │
│  └────────────┘                                            │
└──────────────────────────────────────────────────────────┘
```

**One addition beyond your diagram:** a local `node-exporter` container so
Prometheus also monitors the monitoring server's own CPU/RAM/disk. It's the
one host you'd otherwise be blind to if it started running low on disk.
Delete that service block from `docker-compose.yml` if you'd rather not have it.

Remote scrape targets assumed (based on your existing 3-server topology —
**verify and correct** in `prometheus/prometheus.yml` if anything's changed):

| Host | IP | Exporters |
|---|---|---|
| App server | 192.168.1.202 | node_exporter :9100, nginx-exporter :9113, promtail :9080 |
| DB/Redis server | 192.168.1.201 | node_exporter :9100, postgres_exporter :9187, promtail :9080 |

Those exporters must already be installed and running on `.201`/`.202` — this
deliverable only covers the monitoring server itself. If they're not
deployed yet, say the word and I'll put together the exporter installs for
those hosts too.

## Folder structure

```
/home/ash/monitoring/
├── docker-compose.yml
├── .env                        # created from .env.example, real secrets, chmod 600
├── install.sh
├── prometheus/
│   ├── prometheus.yml
│   └── rules/alerts.yml
├── alertmanager/
│   └── alertmanager.yml        # real SMTP creds live here, chmod 600
├── loki/
│   └── loki-config.yml
├── promtail/
│   └── promtail-config.yml
├── grafana/
│   └── provisioning/
│       ├── datasources/datasources.yml   # Prometheus + Loki auto-added
│       └── dashboards/
│           ├── dashboards.yml
│           └── files/           # drop dashboard JSON exports here
└── data/                        # bind-mounted persistent storage (created by install.sh)
    ├── prometheus/
    ├── alertmanager/
    ├── loki/
    ├── promtail/
    └── grafana/
```

All state lives under `data/` on the host filesystem, so `docker compose
down` / container recreation / image upgrades never lose metrics, logs,
alert state, or Grafana dashboards/users.

## Prerequisites — Docker on Debian 13 (Trixie)

Trixie is officially supported by Docker's repository. Use the deb822
source format (Trixie's recommended format, per Debian's own release notes):

```bash
sudo apt update
sudo apt install -y ca-certificates curl

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo systemctl enable --now docker
sudo usermod -aG docker ash   # log out/in for group change to apply
```

Verify: `docker compose version` should report Compose v2.

## Deployment steps

```bash
# 1. Get the files onto the server (scp, git, whatever you use), e.g.:
#    scp -r monitoring-stack ash@192.168.1.203:/home/ash/monitoring
cd /home/ash/monitoring

# 2. Bootstrap directories and permissions
chmod +x install.sh
./install.sh

# 3. Edit secrets/config it told you to edit
nano .env
nano alertmanager/alertmanager.yml
nano prometheus/prometheus.yml   # confirm .201 / .202 targets are correct

# 4. Bring the stack up
docker compose up -d

# 5. Watch it come up healthy
docker compose ps
docker compose logs -f --tail=50
```

## Verification steps

1. `docker compose ps` — all 6 containers should show `healthy` (Grafana,
   Prometheus, Alertmanager, Loki have healthchecks; Promtail/node-exporter
   don't emit HTTP health the same way, just confirm `Up`).
2. Prometheus targets page: `http://192.168.1.203:9090/targets` — every job
   should be `UP` except any remote exporter not yet deployed on `.201`/`.202`.
3. Alertmanager UI: `http://192.168.1.203:9093` — confirm it loaded without
   config errors.
4. Grafana: `http://192.168.1.203:3000` — log in with the `.env` credentials,
   confirm **Prometheus** and **Loki** datasources are present under
   Connections → Data sources (auto-provisioned, not something you need to add).
5. Logs flowing: Grafana → Explore → Loki → query `{job="docker"}` and you
   should see recent container log lines from this host.
6. Fire a test alert: stop a container (`docker stop node-exporter`), wait
   ~2 minutes, confirm `TargetDown` appears in Alertmanager and you get an
   email. Then `docker start node-exporter` and confirm it resolves.

## Rollback plan

- **Bad config change** (prometheus.yml, alertmanager.yml, loki-config.yml,
  promtail-config.yml): edit the file back, then either restart the single
  container (`docker compose restart prometheus`) or, for Prometheus only,
  reload without downtime: `curl -X POST http://localhost:9090/-/reload`.
- **Bad image upgrade**: pin back to the previous tag in `docker-compose.yml`
  and `docker compose up -d <service>`. This is why versions are pinned
  explicitly rather than `:latest` — you always have a known-good tag to
  fall back to.
- **Full stack rollback**: `docker compose down` (data in `./data` is
  untouched — it's a bind mount, not a container volume, so `down` never
  deletes it). Restore a previous config from git/backup, `docker compose
  up -d`.
- Data is only actually lost if `./data` itself is deleted — treat it like
  a database directory.

## Backups

`./data` is plain files on disk, so a standard filesystem backup covers
everything (Prometheus TSDB, Loki chunks, Grafana SQLite + dashboards,
Alertmanager silences). Simplest approach, cron'd nightly:

```bash
# Stop write-heavy containers briefly for a consistent snapshot, or skip
# --stop if you're fine with a "crash consistent" backup (usually fine for
# time-series data).
tar -czf /home/ash/backups/monitoring-$(date +%F).tar.gz \
  -C /home/ash/monitoring data/grafana data/alertmanager

# Prometheus/Loki data is intentionally excluded above — it's large and
# regenerates from your systems over the 30d retention window. Back up
# Grafana (dashboards/users) and Alertmanager (silences) instead, since
# those are hand-configured state you can't regenerate.
```

Keep 7–14 days of these off the monitoring host itself (rsync to another
server) — a backup that lives only on the box it's protecting isn't one.

## Security notes

- No ports are exposed beyond what's needed for the UIs and cross-host
  scraping. Since Prometheus scrapes `.201`/`.202` over plain HTTP on your
  LAN, make sure that LAN segment isn't reachable from anything untrusted.
- Recommend restricting inbound access with `ufw` so only your admin
  workstation/subnet can reach Grafana (3000) and Prometheus (9090) directly:
  ```bash
  sudo apt install ufw
  sudo ufw allow from 192.168.1.0/24 to any port 3000 proto tcp
  sudo ufw allow from 192.168.1.0/24 to any port 9090 proto tcp
  sudo ufw allow from 192.168.1.0/24 to any port 9093 proto tcp
  sudo ufw allow ssh
  sudo ufw enable
  ```
  Adjust the CIDR to your actual trusted range.
- `alertmanager.yml` and `.env` contain real credentials once filled in —
  both are `chmod 600` by `install.sh`, and neither should be committed to
  git. Add both to `.gitignore` if this directory is (or becomes) a repo.
- Grafana `GF_USERS_ALLOW_SIGN_UP=false` is set so nobody can self-register
  an account against your instance.
- All containers except Promtail run as their non-root image UID
  (`user:` in compose) — Promtail needs root to read `/var/log` and Docker's
  container log directory read-only.

## Common problems

- **Grafana/Prometheus/Loki container won't start, exits immediately**:
  almost always a data-directory permissions issue. Re-run `install.sh`, or
  check `docker compose logs <service>` for a `permission denied` on
  `/prometheus`, `/loki`, or `/var/lib/grafana`.
- **Remote targets show "down" in Prometheus**: either the exporter isn't
  installed on `.201`/`.202` yet, or a firewall on those hosts is blocking
  the port. `curl http://192.168.1.20X:PORT/metrics` from the monitoring
  server to confirm reachability.
- **No logs in Grafana Explore**: check `docker compose logs promtail` —
  a common cause is the container not having read access to
  `/var/lib/docker/containers` (SELinux/AppArmor on some setups) or the
  positions file getting corrupted (delete `data/promtail/positions.yaml`
  and restart if so — it'll just re-read from the current log offset).
- **Alertmanager not sending email**: `docker compose logs alertmanager` —
  most SMTP providers require `smtp_require_tls: true` and an app-specific
  password rather than your normal account password.

## Maintenance notes

- Image versions are pinned in `docker-compose.yml`. Check for updates
  periodically (Prometheus, Grafana, and Loki all ship fairly often) and
  bump deliberately rather than tracking `:latest`.
- Prometheus retention is set to 30 days (`--storage.tsdb.retention.time=30d`)
  and Loki retention to 30 days (`retention_period: 30d`) — both configurable
  in their respective config files if you need longer history.
- If disk usage on `/home/ash/monitoring/data` grows unexpectedly, `du -sh
  data/*` to see which service is the culprit before just extending the
  volume — worth confirming it's not runaway cardinality in Prometheus
  (too many unique label combinations) or a noisy log source flooding Loki.
