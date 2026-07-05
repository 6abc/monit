#!/usr/bin/env bash
#
# Bootstrap script for the Meraki monitoring stack on 192.168.1.203 (Debian 13).
# Run this once from /home/ash/monitoring before the first `docker compose up`.
#
# What it does:
#   1. Creates the persistent data directories under ./data
#   2. Chowns each to the UID the corresponding container runs as
#      (so containers running as non-root can actually write their data)
#   3. Creates the empty grafana dashboards/files folder used by provisioning
#   4. Copies .env.example -> .env if missing, and locks down permissions
#
# It does NOT chmod 777 anything - ownership is set precisely instead.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

echo "==> Creating persistent data directories under ${BASE_DIR}/data"
mkdir -p data/prometheus data/alertmanager data/loki data/promtail data/grafana
mkdir -p grafana/provisioning/dashboards/files

echo "==> Setting ownership to match container UIDs"
# Prometheus & Alertmanager run as nobody:nogroup (65534:65534)
sudo chown -R 65534:65534 data/prometheus data/alertmanager
sudo chown 65534:65534 alertmanager/alertmanager.yml
# Loki runs as uid 10001
sudo chown -R 10001:10001 data/loki
# Grafana runs as uid 472
sudo chown -R 472:472 data/grafana
# Promtail runs as root inside the container (needs to read /var/log & docker logs)
sudo chown -R root:root data/promtail

echo "==> Setting directory permissions (owner rwx, no world access)"
find data -maxdepth 1 -type d -exec chmod 750 {} \;

if [ ! -f .env ]; then
  echo "==> Creating .env from .env.example - EDIT THIS before starting the stack"
  cp .env.example .env
  chmod 600 .env
else
  echo "==> .env already exists, leaving it as-is"
fi

echo "==> Locking down alertmanager.yml permissions (contains SMTP credentials once filled in)"
chmod 600 alertmanager/alertmanager.yml

cat <<'EOF'

Next steps:
  1. Edit .env                          - set a real Grafana admin password
  2. Edit alertmanager/alertmanager.yml - set real SMTP / webhook details
  3. Edit prometheus/prometheus.yml     - confirm the remote target IPs match
                                           your actual DB (.201) and app (.202) hosts
  4. docker compose up -d
  5. docker compose ps                  - confirm all containers are healthy

EOF
