#!/usr/bin/env bash
# =============================================================================
# Backup diario do Postgres. Roda no VPS, pelo cron.
# =============================================================================
# O backup incluido da Hostinger e SEMANAL. Para dado financeiro isso significa
# aceitar perder ate 7 dias. Este script e o que de fato define o RPO.
#
# Instalacao (como root):
#   crontab -e
#   10 3 * * * /opt/genesis-app/infra/vps/backup.sh >> /var/log/genesis-backup.log 2>&1
#
# Sai com codigo != 0 em qualquer falha, para o cron avisar em vez de falhar em
# silencio — que e como quase todo backup quebrado passa meses sem ser notado.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] %s\n' "$(ts)" "$*"; }
die()  { printf '[%s] ERRO: %s\n' "$(ts)" "$*" >&2; exit 1; }

[[ -f "${SCRIPT_DIR}/.env" ]] || die "arquivo .env nao encontrado em ${SCRIPT_DIR}"
set -a; . "${SCRIPT_DIR}/.env"; set +a

RETENTION="${BACKUP_RETENTION_DAYS:-30}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${BACKUP_DIR}/${POSTGRES_DB}-${STAMP}.dump"

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

cd "${SCRIPT_DIR}"

log "Iniciando backup de ${POSTGRES_DB}"

# -Fc: formato custom, ja comprimido e restauravel seletivamente pelo pg_restore.
# O dump vai para um arquivo temporario e so recebe o nome final se der certo —
# assim um dump interrompido nunca se parece com um backup bom.
if ! docker compose exec -T postgres \
        pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Fc > "${DEST}.tmp"; then
  rm -f "${DEST}.tmp"
  die "pg_dump falhou"
fi

# Um dump de 0 byte "tem sucesso" em pipeline. Confere o tamanho.
SIZE=$(stat -c%s "${DEST}.tmp")
if (( SIZE < 1024 )); then
  rm -f "${DEST}.tmp"
  die "dump suspeito: apenas ${SIZE} bytes"
fi

mv "${DEST}.tmp" "${DEST}"
chmod 600 "${DEST}"
log "Dump gravado: ${DEST} ($(numfmt --to=iec "${SIZE}"))"

# --- Copia externa -----------------------------------------------------------
# Backup no mesmo servidor nao e backup: se o VPS for perdido, some junto.
if [[ -n "${RCLONE_REMOTE:-}" ]]; then
  if command -v rclone >/dev/null 2>&1; then
    log "Enviando para ${RCLONE_REMOTE}"
    rclone copy "${DEST}" "${RCLONE_REMOTE}/" --quiet \
      || die "rclone falhou — ha copia local, mas nenhuma fora do VPS"
    log "Copia externa concluida"
  else
    die "RCLONE_REMOTE configurado mas rclone nao esta instalado"
  fi
else
  log "AVISO: RCLONE_REMOTE vazio — backup apenas local, que nao protege contra"
  log "AVISO: perda do VPS. Configure um destino externo."
fi

# --- Retencao ----------------------------------------------------------------
REMOVIDOS=$(find "${BACKUP_DIR}" -name "${POSTGRES_DB}-*.dump" -type f \
              -mtime "+${RETENTION}" -print -delete | wc -l)
log "Retencao ${RETENTION}d: ${REMOVIDOS} dump(s) antigo(s) removido(s)"

TOTAL=$(find "${BACKUP_DIR}" -name "${POSTGRES_DB}-*.dump" -type f | wc -l)
log "Backup concluido. ${TOTAL} dump(s) local(is)."
