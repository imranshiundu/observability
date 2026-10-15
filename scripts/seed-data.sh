#!/bin/bash
# Idempotent demo-history seeder — see demo-data.sql for details.
set -euo pipefail

CONTAINER="${PG_CONTAINER:-iloveshopping-postgres}"
USER="${POSTGRES_USER:-iloveshopping}"
DB="${POSTGRES_DB:-iloveshopping}"

if ! docker exec "$CONTAINER" true 2>/dev/null; then
  echo "seed-data: platform postgres container ($CONTAINER) is not running" >&2
  exit 1
fi

if docker exec "$CONTAINER" psql -U "$USER" -d "$DB" -tA -c \
    "SELECT 1 FROM information_schema.tables WHERE table_name = 'demo_seed_marker' AND 1 = (SELECT count(*) FROM demo_seed_marker)" 2>/dev/null | grep -q 1; then
  echo "seed-data: demo data already present — nothing to do"
  exit 0
fi

echo "seed-data: writing demo history into $DB …"
docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 < "$(dirname "${BASH_SOURCE[0]}")/demo-data.sql"
echo "seed-data: done — dashboards now have historical data"
