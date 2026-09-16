#!/usr/bin/env bash
# =============================================================================
# Teste de restauracao. Um backup que nunca foi restaurado nao e um backup —
# e uma suposicao.
# =============================================================================
# Restaura o dump mais recente (ou o indicado) num banco descartavel dentro do
# mesmo Postgres, conta o que voltou e apaga o banco de teste. Nao encosta no
# banco de producao em momento algum.
#
#   ./restore-test.sh                       # usa o dump mais recente
#   ./restore-test.sh backups/xxx.dump      # usa um dump especifico
#
# Rode antes de dar a Fase 1 por pronta, e depois a cada trimestre.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${SCRIPT_DIR}/.env" ]] || die "arquivo .env nao encontrado"
set -a; . "${SCRIPT_DIR}/.env"; set +a

cd "${SCRIPT_DIR}"

DUMP="${1:-$(ls -1t "${BACKUP_DIR}"/*.dump 2>/dev/null | head -1 || true)}"
[[ -n "${DUMP}" && -f "${DUMP}" ]] || die "nenhum dump encontrado em ${BACKUP_DIR}"

TEST_DB="restore_test_$(date +%s)"
log "Dump:  ${DUMP} ($(numfmt --to=iec "$(stat -c%s "${DUMP}")"))"
log "Banco de teste: ${TEST_DB}"

psql_admin() {
  docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 "$@"
}

cleanup() {
  log "Removendo o banco de teste"
  psql_admin -c "DROP DATABASE IF EXISTS ${TEST_DB};" >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql_admin -c "CREATE DATABASE ${TEST_DB};" >/dev/null

log "Restaurando"
if ! docker compose exec -T postgres \
        pg_restore -U "${POSTGRES_USER}" -d "${TEST_DB}" --no-owner --no-privileges \
        < "${DUMP}"; then
  die "pg_restore falhou — ESTE BACKUP NAO SERVE. Investigue antes de confiar nele."
fi

log "Conferindo o que voltou"
docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${TEST_DB}" -P pager=off -c "
  SELECT schemaname            AS schema,
         relname               AS tabela,
         n_live_tup            AS linhas
    FROM pg_stat_user_tables
   ORDER BY n_live_tup DESC
   LIMIT 20;"

TABELAS=$(docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${TEST_DB}" \
            -tAc "SELECT count(*) FROM pg_stat_user_tables;" | tr -d '[:space:]')

[[ "${TABELAS}" -gt 0 ]] \
  || die "restaurou sem erro, mas o banco voltou com ZERO tabelas — dump vazio"

printf '\n\033[1;32mOK\033[0m  Backup restauravel: %s tabela(s).\n\n' "${TABELAS}"
