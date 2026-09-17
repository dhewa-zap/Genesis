# Contexto do projeto para o Claude Code

Leia antes de agir. Este arquivo carrega as decisões já tomadas e as armadilhas
já descobertas — rediscuti-las custa tempo, e redescobri-las custa mais.

## O que é

App de celular (PWA) que mostra ao gestor vendas, compras, financeiro e
resultado, alimentado pelo **Genesis**, um ERP desktop com PostgreSQL.

Arquitetura escolhida (**Opção A**, entre três avaliadas): um **agente** roda na
máquina do Genesis, lê views `bi.*` a cada ~5 min e **empurra agregados** por
HTTPS para um VPS; o app lê o VPS. Alternativas descartadas e o porquê estão em
`docs/app-gestor-propostas.md` — não reabra sem motivo novo.

A conexão é **sempre de dentro para fora**: nenhuma porta é aberta na rede do
cliente.

## Regras que não se quebram

1. **A 5432 nunca é aberta para a internet**, nem "só para desenvolvimento".
   Acesso externo ao banco é por túnel SSH.
2. **O app nunca fala com o banco direto.** Credencial dentro de aplicativo vaza.
   Sempre há uma API no meio.
3. **A v1 é somente-leitura.** Nada de lançar movimentação pelo celular.
4. **Nenhuma tabela do aplicativo dentro do ERP.** Metas, usuários, tokens e
   preferências vivem no banco da nuvem. No Genesis entram só marca-d'água, log
   de exclusões, índices e views.
5. **Nenhum número vai para o app sem bater com o relatório do próprio Genesis.**
   Não é "parece certo": é abrir o relatório do ERP e a view e os dois darem o
   mesmo valor no mesmo período.
6. **O ERP em `D:\genesis` é leitura para análise.** Não altere nada lá sem
   aprovação explícita — é o sistema que a empresa usa para faturar.
7. **Ajuste no banco de produção só depois de testado** numa cópia restaurada do
   backup.

## Ambiente

| | |
|---|---|
| Repositório | Azure DevOps — `zapsoftwares/Genesis/Genesis-Mobile-BI` |
| Clone local | `D:\Projetos\Genesis-Mobile-BI` |
| Código do ERP | `D:\genesis` (projeto separado, não versionado aqui) |
| Nuvem | VPS Hostinger KVM, **São Paulo**, PostgreSQL nativo — já adquirido |
| Banco do ERP | PostgreSQL, na rede do cliente |
| Idioma | documentação e mensagens de commit em **pt-BR** |

## Estado

| Item | Estado |
|---|---|
| Arquitetura decidida | ✅ `docs/app-gestor-propostas.md` |
| Plano de execução | ✅ `docs/plano-execucao.md` |
| Ajustes previstos no ERP | ✅ `docs/ajustes-no-genesis.md` |
| Infra do VPS | ✅ escrita e testada — `infra/vps/` (falta rodar no VPS) |
| Acesso somente-leitura ao Genesis | ✅ `db/readonly/` |
| **Schema do Genesis levantado** | ⬜ **bloqueia as specs** |
| Specs (4) | ⬜ |
| Código (agente, api, app) | ⬜ |

## As duas tarefas que destravam tudo

1. **Rodar o inventário** do banco do Genesis:
   `psql -h HOST -U USUARIO -d BANCO -f db/genesis/inventario_schema.sql -o inventario.txt`
   Seguro em produção: transação `READ ONLY`, lê só o catálogo do sistema,
   estimativa em vez de `count(*)`, timeouts curtos.
2. **Varrer `D:\genesis`** pela checklist de `docs/ajustes-no-genesis.md`,
   começando por `INSERT INTO <tabela> VALUES` sem lista de colunas — é o único
   ajuste capaz de derrubar o ERP, e é verificável antes.

Com esses dois resultados, escrever as quatro specs (contrato de dados,
protocolo de sincronização, API, app) e depois as views `bi.*`.

## Armadilhas já descobertas (testadas em PostgreSQL 16)

Não reescreva estas conclusões; elas custaram experimento.

- **Migração da marca-d'água.** `ALTER TABLE ... ADD COLUMN atualizado_em
  DEFAULT now()` é rápido (57 ms em 800 mil linhas, sem reescrita), mas deixa
  **todas as linhas com o mesmo timestamp**. A primeira sincronização enxerga a
  tabela inteira como alterada — a carga inicial precisa de plano.
- **Commit atrasado.** Uma transação que grava às 10h00 e confirma às 10h02 fica
  invisível para um agente que leu às 10h01 e já avançou a marca — e some para
  sempre. O agente relê sempre com **margem de segurança de 5 min**; o envio é
  idempotente, reprocessar não faz mal.
- **Agregados e edição retroativa.** A marca-d'água seleciona **linhas**; os
  **dias afetados se derivam dessas linhas** e são esses que se recalculam.
  "Ressincronizar os últimos 60 dias" perde, calada, a edição de uma venda de
  meses atrás.
- **Índice na marca-d'água é obrigatório**, e com `CONCURRENTLY` (sem isso o
  `CREATE INDEX` trava escrita e o ERP para). Medido: 44 blocos lidos com índice
  contra 5.957 sem.
- **`\echo` no psql escreve no terminal, não no arquivo de `-o`.** Use `\qecho`
  em script que gera relatório.

## Como trabalhar aqui

- **Uma fatia vertical antes de qualquer largura.** Leve *venda do dia* de ponta
  a ponta (view → agente → API → tela) antes de acrescentar indicador. É na
  primeira fatia que aparecem fuso trocando o dia, `numeric` virando float e a
  tarefa agendada que não roda sem usuário logado.
- **Teste antes de afirmar que funciona.** Os scripts em `infra/vps/` e
  `db/genesis/` foram exercitados contra um Postgres real, inclusive nos
  caminhos de falha. Mantenha esse padrão: um backup que nunca foi restaurado
  não é um backup.
- **Tudo em `America/Sao_Paulo`**, ponta a ponta.
- **Dinheiro em `numeric`**, nunca `float`.
