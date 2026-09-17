# Genesis Mobile BI

Aplicativo de celular que dá ao gestor vendas, compras, financeiro e resultado a
partir do **Genesis (ERP desktop)**, sem expor o banco do cliente à internet.

## Como funciona

```
┌────────── rede do cliente ──────────┐
│  Genesis (desktop) ──▶ PostgreSQL   │
│                          ▲          │
│                     ┌────┴────┐     │
│                     │ agente  │     │  lê as views bi.* a cada 5 min
│                     └────┬────┘     │
└──────────────────────────┼──────────┘
                           │ HTTPS 443 — somente SAÍDA
                           ▼
                  ┌──────────────────┐
                  │ VPS (São Paulo)  │  Postgres espelho + API
                  └────────┬─────────┘
                           │ HTTPS + token
                           ▼
                      📱 PWA do gestor
```

O agente **empurra** agregados para fora. Nenhuma porta é aberta na rede do
cliente, e o app nunca fala com o banco direto.

Decisão de arquitetura e alternativas descartadas: [`docs/app-gestor-propostas.md`](docs/app-gestor-propostas.md).

## Mapa do repositório

| Pasta | O que é | Estado |
|---|---|---|
| `docs/` | arquitetura, plano de execução, ajustes no ERP | escrito |
| `db/readonly/` | usuário somente-leitura no Genesis (+ auditoria e revogação) | pronto |
| `db/genesis/` | inventário do schema do ERP; futuras views `bi.*` | inventário pronto |
| `infra/vps/` | Docker Compose, TLS, firewall, backup do VPS | pronto, testado |
| `agente/` | serviço que roda no Windows da loja | a escrever |
| `api/` | API de leitura no VPS | a escrever |
| `app/` | PWA do gestor | a escrever |

## Por onde começar

1. **Leia** [`docs/plano-execucao.md`](docs/plano-execucao.md) — sequência, marcos
   e o que bloqueia o quê.
2. **Rode o inventário** do banco do Genesis
   ([`db/genesis/inventario_schema.sql`](db/genesis/inventario_schema.sql)).
   É o pré-requisito das specs. Seguro em produção: transação `READ ONLY`, lê só
   o catálogo do sistema, não toca em nenhuma linha das suas tabelas.
3. **Suba a infra** no VPS seguindo [`infra/vps/README.md`](infra/vps/README.md).
   Não depende do inventário — pode ir em paralelo.
4. **Verifique o ERP** com a checklist de
   [`docs/ajustes-no-genesis.md`](docs/ajustes-no-genesis.md), começando pela
   busca por `INSERT` sem lista de colunas: é o único ajuste capaz de derrubar o
   Genesis, e é verificável antes.

## Regras que não se quebram

- **A porta 5432 nunca é aberta para a internet.** Acesso externo ao banco é por
  túnel SSH.
- **O app nunca fala com o banco direto.** Credencial dentro de aplicativo vaza —
  sempre há uma API no meio.
- **A v1 é somente-leitura.** Lançar movimentação pelo celular fica para depois de
  a leitura estar estável e auditada.
- **Nada de tabela do aplicativo dentro do ERP.** Metas, usuários e tokens vivem
  no banco da nuvem.
- **Nenhum número vai para o app sem bater com o relatório do próprio Genesis.**

## Estado atual

| | |
|---|---|
| Arquitetura decidida | ✅ |
| VPS adquirido com Postgres | ✅ |
| Infra escrita e testada | ✅ (falta rodar no VPS) |
| Acesso somente-leitura ao Genesis | ✅ |
| Schema do Genesis levantado | ⬜ **bloqueia as specs** |
| Specs | ⬜ |
| Código | ⬜ |
