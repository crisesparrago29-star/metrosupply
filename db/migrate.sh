#!/usr/bin/env bash
# Applies new SQL files from db/migrations in name order, each one only once.
set -euo pipefail
cd "$(dirname "$0")/.."

PSQL=(docker compose exec -T -e PGOPTIONS=-cclient_min_messages=warning
      postgres psql -U metro_admin -d metrosupply -v ON_ERROR_STOP=1 -q)

"${PSQL[@]}" -c "CREATE TABLE IF NOT EXISTS schema_migrations (
  filename   text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);"

for file in db/migrations/*.sql; do
  name=$(basename "$file")
  already=$("${PSQL[@]}" -tAc "SELECT 1 FROM schema_migrations WHERE filename = '$name'")
  if [ "$already" = "1" ]; then
    echo "skip   $name"
    continue
  fi
  echo "apply  $name"
  { cat "$file"; echo; echo "INSERT INTO schema_migrations (filename) VALUES ('$name');"; } \
    | "${PSQL[@]}" --single-transaction
done
echo "All migrations applied."
