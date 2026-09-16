#!/usr/bin/env bash
# =============================================================================
# Preparacao do VPS (Ubuntu 22.04) — Docker, firewall e endurecimento do SSH.
# =============================================================================
# Rode uma vez, como root, num VPS recem-criado:
#
#   bash setup-vps.sh
#
# E idempotente: rodar de novo nao quebra nada.
#
# SOBRE FICAR TRANCADO PARA FORA: o script so desabilita a senha do SSH depois
# de confirmar que ja existe chave publica instalada. Se nao houver, ele avisa e
# mantem a senha ligada — de proposito. E, no pior caso, a Hostinger oferece
# console pelo navegador no hPanel, que nao passa pelo SSH: e por ali que se
# conserta um firewall mal configurado.
# =============================================================================

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "rode como root (sudo bash setup-vps.sh)"

SSH_PORT="${SSH_PORT:-22}"

# --- 1. Pacotes --------------------------------------------------------------
log "Atualizando o sistema"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl ufw fail2ban unattended-upgrades postgresql-client

# --- 2. Fuso horario ---------------------------------------------------------
log "Fuso horario para America/Sao_Paulo"
timedatectl set-timezone America/Sao_Paulo

# --- 3. Docker ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  log "Docker ja instalado ($(docker --version))"
else
  log "Instalando Docker"
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

docker compose version >/dev/null 2>&1 \
  || die "plugin 'docker compose' ausente — instale docker-compose-plugin"

# --- 4. Firewall -------------------------------------------------------------
# A ordem importa: libera o SSH ANTES de ligar o ufw. Invertido, a sessao atual
# cai no meio do script.
log "Configurando o firewall (apenas ${SSH_PORT}, 80 e 443)"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}"/tcp comment 'SSH'
ufw allow 80/tcp   comment 'HTTP (ACME + redirect)'
ufw allow 443/tcp  comment 'HTTPS'
ufw allow 443/udp  comment 'HTTP/3'
ufw --force enable
ufw status verbose

warn "O Docker escreve direto no iptables e contorna o ufw quando um container"
warn "publica porta. Por isso o compose nao publica a 5432 — e a unica protecao"
warn "que realmente vale aqui. Nunca adicione 'ports: 5432' ao postgres."

# --- 5. SSH ------------------------------------------------------------------
log "Endurecendo o SSH"
install -d -m 755 /etc/ssh/sshd_config.d

has_key=0
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [[ -s "${f}" ]] && has_key=1 && break
done

{
  echo "# Gerado por setup-vps.sh"
  echo "PermitRootLogin prohibit-password"
  echo "KbdInteractiveAuthentication no"
  echo "X11Forwarding no"
  echo "MaxAuthTries 3"
  if [[ ${has_key} -eq 1 ]]; then
    echo "PasswordAuthentication no"
  else
    echo "PasswordAuthentication yes  # nenhuma chave encontrada — ver aviso"
  fi
} > /etc/ssh/sshd_config.d/99-hardening.conf

if [[ ${has_key} -eq 0 ]]; then
  warn "Nenhuma chave SSH instalada — a senha continua habilitada."
  warn "Instale a sua (ssh-copy-id) e rode este script de novo para fechar."
fi

sshd -t || die "config do sshd invalida — NADA foi recarregado, a sessao segue viva"
systemctl reload ssh 2>/dev/null || systemctl reload sshd

# --- 6. fail2ban e atualizacoes de seguranca ---------------------------------
log "Ativando fail2ban e atualizacoes automaticas de seguranca"
systemctl enable --now fail2ban
dpkg-reconfigure -f noninteractive unattended-upgrades

# --- 7. Fim ------------------------------------------------------------------
cat <<'EOF'

Pronto. Proximos passos:

  1. Aponte o registro A do seu subdominio para o IP deste VPS.
  2. cp .env.example .env  e preencha (senha com: openssl rand -base64 32)
  3. docker compose up -d
  4. Abra https://SEU_DOMINIO — deve responder com cadeado.
  5. Agende o backup (ver README) e TESTE a restauracao.

EOF
