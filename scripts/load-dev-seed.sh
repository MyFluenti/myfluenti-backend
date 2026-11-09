#!/usr/bin/env bash
# Carrega os DADOS FICTÍCIOS DE TESTE no banco LOCAL (contêiner do supabase start).
# Nunca use contra staging/produção: este script só fala com o contêiner local.
set -euo pipefail
CONTAINER="supabase_db_myfluenti-backend"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERRO: contêiner '$CONTAINER' não está rodando. Rode 'supabase start' (banco local) primeiro." >&2
  exit 1
fi

# Copia o arquivo para dentro do contêiner e roda lá (sem pipe de stdin pelo shell do host: preserva UTF-8).
(
  cd "$ROOT"
  docker cp supabase/dev-seed/dev_content.sql "$CONTAINER:/tmp/dev_content.sql"
  docker exec "$CONTAINER" sh -c "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/dev_content.sql 2>&1; rc=\$?; rm -f /tmp/dev_content.sql; exit \$rc"
)
