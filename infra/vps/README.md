# Infraestrutura da nuvem — VPS Hostinger

Provisionamento do VPS que hospeda o espelho de dados e a API do app do gestor
(Opção A do documento `docs/app-gestor-propostas.md`).

Aqui fica só a **infraestrutura**: banco, TLS, firewall e backup. A API e o
agente de sincronização entram depois — e este ambiente é feito para recebê-los
sem mudança estrutural.

## Antes de começar

1. **VPS criado com a região São Paulo.** A região se escolhe uma vez, na criação,
   e não se troca depois sem recriar a máquina. Servidor nos EUA acrescenta
   ~120 ms em toda requisição, e mantém dado financeiro fora do Brasil.
2. **Plano KVM 1** (1 vCPU, 4 GB, 50 GB NVMe) — sobra para dado agregado. Upgrade
   para KVM 2 depois, se isso atender vários clientes da base ICES.
3. **Ubuntu 22.04** (ou 24.04).
4. **Registro A** do subdomínio (ex.: `api.seudominio.com.br`) apontando para o
   IP do VPS. **Faça isso antes do passo 4** — sem DNS propagado o Let's Encrypt
   não emite o certificado.

## Passo a passo

### 1. Enviar sua chave SSH

Antes de qualquer coisa, para que o passo 2 possa desligar o login por senha:

```bash
ssh-copy-id root@SEU_IP
```

### 2. Preparar a máquina

```bash
scp -r infra/vps root@SEU_IP:/opt/genesis-app-infra
ssh root@SEU_IP
cd /opt/genesis-app-infra
bash setup-vps.sh
```

Instala Docker, fecha o firewall (só 22, 80 e 443), liga fail2ban e atualizações
automáticas de segurança, e endurece o SSH.

**Sobre ficar trancado para fora:** o script só desliga a senha do SSH depois de
confirmar que já existe chave instalada — se não houver, ele avisa e mantém a
senha ligada, de propósito. E a Hostinger oferece console pelo navegador no
hPanel, que não passa pelo SSH: é por ali que se conserta um firewall mal
configurado.

### 3. Configurar

```bash
cp .env.example .env
openssl rand -base64 32     # cole o resultado em POSTGRES_PASSWORD
nano .env
chmod 600 .env
```

### 4. Subir

```bash
docker compose up -d
docker compose ps
```

### 5. Conferir

```bash
curl -I https://api.seudominio.com.br
```

Tem que voltar `HTTP/2 200` com certificado válido. Enquanto a API não existe, o
domínio responde uma mensagem de infraestrutura no ar — e isso é útil: prova que
DNS, firewall e TLS estão corretos **antes** de existir qualquer código.

Confirme também que o banco **não** está exposto, de fora do VPS:

```bash
nc -zv SEU_IP 5432      # tem que dar timeout/recusa
```

### 6. Agendar o backup — não pule

```bash
crontab -e
```

```
10 3 * * * /opt/genesis-app-infra/backup.sh >> /var/log/genesis-backup.log 2>&1
```

E **teste a restauração** antes de considerar isto pronto:

```bash
./restore-test.sh
```

## Operação

| Tarefa | Comando |
|---|---|
| Logs | `docker compose logs -f` |
| Reiniciar | `docker compose restart` |
| Backup manual | `./backup.sh` |
| Testar restauração | `./restore-test.sh` |
| Abrir o psql | `docker compose exec postgres psql -U genesis_app -d genesis_app` |
| Atualizar imagens | `docker compose pull && docker compose up -d` |

### Acessar o banco de fora (DBeaver, pgAdmin)

Túnel SSH — **nunca** abrindo a 5432:

```bash
ssh -L 5432:localhost:5432 root@SEU_IP -N
```

Para isso funcionar, o Postgres precisa estar alcançável no host. Como o compose
não publica porta, use:

```bash
ssh -L 5432:$(docker compose exec -T postgres hostname -i | tr -d '\r'):5432 root@SEU_IP -N
```

Depois é só conectar em `localhost:5432` na sua máquina.

## Backup: por que tanto cuidado

O backup incluído da Hostinger é **semanal**. Para dado financeiro, aceitar
perder até 7 dias não serve. O `backup.sh` é o que de fato define o RPO:

- `pg_dump -Fc` diário, retenção configurável (30 dias por padrão);
- grava em arquivo temporário e só renomeia no fim — um dump interrompido nunca
  se parece com um backup bom;
- **recusa dump anormalmente pequeno**, porque um arquivo de 0 byte "tem sucesso"
  em pipeline e é assim que um backup quebrado passa meses sem ser notado;
- sai com código != 0 em qualquer falha, para o cron avisar;
- envia cópia para fora do VPS via `rclone` — **backup no mesmo servidor não é
  backup**. Com `RCLONE_REMOTE` vazio, o script avisa em toda execução.

Atenuante: a nuvem é **espelho**, não origem. O dado verdadeiro segue no Genesis,
e no pior caso se reconstrói ressincronizando do zero.

## O que não fazer

- **Não publique a porta 5432** no compose. É a proteção que realmente vale aqui:
  o Docker escreve direto no iptables e contorna o `ufw` quando um container
  publica porta — o firewall não vai te salvar dessa.
- **Não apague o volume `caddy_data`** — ali ficam os certificados. Sem ele, o
  Let's Encrypt reemite e há limite de emissões por semana.
- **Não comite o `.env`.** Já está no `.gitignore`.
- **Não confie num backup que nunca foi restaurado.** Rode o `restore-test.sh`.

## Quando a API chegar

1. Descomente o serviço `api` no `docker-compose.yml`.
2. No `Caddyfile`, comente o `respond` e descomente o `reverse_proxy api:3000`.
3. `docker compose up -d --build`

## O que foi testado

Contra um PostgreSQL 16 real, com dados de exemplo (259 + 376 linhas):

- `docker compose config` válido — com e sem o serviço `api` ativo;
- ciclo completo `backup.sh` → `restore-test.sh`, com as contagens de linhas
  conferindo após a restauração;
- `pg_dump` falhando: sai com erro, sem deixar `.dump` nem `.tmp` órfãos;
- dump truncado de 5 bytes: rejeitado pela checagem de tamanho;
- `RCLONE_REMOTE` configurado sem o rclone instalado: falha em vez de se dar por
  concluído;
- retenção: dump de 45 dias removido, recentes preservados;
- dump corrompido: `restore-test.sh` recusa e ainda assim apaga o banco de teste;
- banco de produção intacto depois de todos os testes de restauração;
- detecção de chave SSH do `setup-vps.sh`, incluindo o caso do `authorized_keys`
  vazio, que não conta como chave.

**Não testado aqui:** a subida real dos containers e a emissão do certificado
TLS — o registro de imagens do Docker está bloqueado neste ambiente. O passo 5
existe para validar isso no VPS.
