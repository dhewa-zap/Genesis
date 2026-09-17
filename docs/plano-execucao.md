# Plano de execução — do VPS ao app no celular

Sequência de trabalho: **planejamento → specs → codificação**. Este documento é
o planejamento. Ele diz o que fazer, em que ordem, e — mais importante — o que
bloqueia o quê.

Arquitetura já decidida em [`app-gestor-propostas.md`](app-gestor-propostas.md):
Opção A (espelho na nuvem com agente de sincronização), VPS Hostinger.

## Onde estamos

| | Estado |
|---|---|
| Arquitetura escolhida | pronto |
| VPS adquirido com Postgres | pronto |
| Infra provisionada (`infra/vps/`) | escrita e testada, falta rodar no VPS |
| Acesso somente-leitura ao Genesis (`db/readonly/`) | pronto |
| **Schema do Genesis conhecido** | **não — é o que bloqueia tudo** |
| Specs | a escrever |
| Código | a escrever |

## O caminho crítico

```
 [1] INVENTÁRIO do Genesis  ◀── você, ~15 min. Bloqueia tudo abaixo.
        │
        ├──▶ [2] SPECS ──┬── contrato de dados (bi.* + espelho)
        │                ├── protocolo de sincronização
        │                ├── API
        │                └── app (telas e fórmulas)
        │
        └──▶ [3] CÓDIGO ─┬── views bi.*        (Genesis)
                         ├── API               (VPS)
                         ├── agente            (Windows da loja)
                         └── app PWA           (navegador)
```

Uma só coisa é pré-requisito de todo o resto, e ela é rápida.

---

## Etapa 1 — Inventário do Genesis  *(agora, ~15 minutos)*

Não dá para escrever a camada de contrato sem saber como o ERP guarda venda,
compra, título e vendedor. O script `db/genesis/inventario_schema.sql` levanta
isso e produz um relatório de texto.

```bash
psql -h HOST -U USUARIO -d BANCO_DO_GENESIS \
     -f db/genesis/inventario_schema.sql -o inventario.txt
```

**É seguro rodar em produção**, e não por promessa:

- roda em transação `READ ONLY` — o banco recusa escrita mesmo que houvesse;
- lê **apenas o catálogo do sistema**, nenhuma linha das suas tabelas. O
  relatório tem nomes de tabela e coluna, e nenhum dado de cliente;
- contagem de linhas vem da estimativa do planejador, não de `count(*)` — não
  varre tabela grande;
- `statement_timeout` de 60 s e `lock_timeout` de 5 s: no pior caso desiste, nunca
  segura lock em cima do ERP;
- funciona com usuário sem nenhuma permissão nas tabelas.

Se os nomes das tabelas do Genesis não baterem com o esperado (seção 5 vier
vazia ou curta), ajuste a linha `\set dominio` no topo do script e rode de novo.

### O que o inventário decide

| Seção do relatório | Decisão que ela resolve |
|---|---|
| 7 — colunas de data/hora | **sincronização incremental × snapshot diário.** É a que mais muda código. Se houver um `atualizado_em` que muda a cada `UPDATE`, o agente lê só o que mudou. Se não houver, snapshot diário dos agregados. |
| 8 e 9 — chaves primárias | identidade estável no espelho, e quais tabelas complicam |
| 4 e 5 — volume | se o agregado cabe em minutos ou exige cuidado |
| 3 — dono das tabelas | o parâmetro `app_owner` de `db/readonly/01_create_readonly_role.sql` |
| 10 — triggers | se já existe gatilho que possa virar fila de sincronização |

---

## Etapa 2 — Specs  *(~3 dias, depois do inventário)*

Quatro documentos. Escrever antes de codificar não é burocracia: aqui o custo de
errar o contrato é alto, porque quatro peças (views, agente, API, app) têm que
concordar sobre os mesmos números.

### 2.1 Contrato de dados
As views `bi.*` no Genesis e as tabelas espelho na nuvem. Para cada indicador:
origem no ERP, grão, regra de cálculo e tipo. **É aqui que se decide o que é
"uma venda"** — conta pedido ou nota fiscal? Cancelada entra? Devolução abate no
dia da venda ou no da devolução? Frete entra no faturamento? Essas respostas
valem mais que qualquer escolha técnica: erradas, o app mostra número que não
bate com o do contador, e o gestor para de confiar — e um app em que não se
confia não é usado.

### 2.2 Protocolo de sincronização
Como o agente conversa com a API: marca-d'água, lotes, autenticação, envio
idempotente, o que fazer quando a internet cai no meio, e o modo
"ressincronizar tudo".

### 2.3 API
Endpoints, formato de resposta, autenticação (token curto), papéis (gestor vê
tudo, vendedor vê o dele — **filtrado no servidor**, nunca escondendo botão no
app), paginação e erros.

### 2.4 App
As cinco telas, cada indicador com sua fórmula, o comportamento offline, e as
regras de notificação.

---

## Etapa 3 — Codificação  *(~5 semanas)*

**A regra de ordem: uma fatia vertical inteira antes de qualquer largura.**

Pegue **um único indicador — venda do dia** — e leve-o de ponta a ponta: view no
Genesis → agente → API → número na tela do celular. Só depois acrescente os
outros.

O motivo é prático: é na primeira fatia que aparecem os problemas que nenhuma
spec prevê — fuso horário trocando o dia da venda, `numeric` virando float e
perdendo centavo, o Windows da loja com a tarefa agendada que não executa
logado, o certificado que não emite. Descobrir isso com um indicador custa um
dia. Descobrir com vinte, depois de tudo escrito, custa a reescrita.

| Ordem | Entrega | Tempo |
|---|---|---|
| 1 | Subir a infra no VPS (`infra/vps/README.md`) e testar a restauração | 1 dia |
| 2 | Views `bi.*` no Genesis + usuário somente-leitura | 2–3 dias |
| 3 | **Fatia vertical: venda do dia de ponta a ponta** | 1 semana |
| 4 | Agente completo (todos os agregados, ressincronização, log) | 1 semana |
| 5 | API completa + papéis e autenticação | 1 semana |
| 6 | App PWA: as cinco telas | 1,5 semana |
| 7 | Notificações push | 3 dias |

Em paralelo à etapa 2, vale subir um **Metabase** apontado para as views
(Fase 0 do documento de propostas). O gestor começa a olhar número em dias, e no
fim do mês você sabe quais indicadores ele realmente abre — informação que muda
o desenho das telas da etapa 6.

---

## Marcos

| Marco | Pronto quando |
|---|---|
| **M1 — Infra no ar** | `https://api.seudominio` responde com cadeado, 5432 inacessível de fora, backup agendado **e restauração testada** |
| **M2 — Contrato fechado** | views `bi.*` existem e os números conferem com os relatórios do próprio Genesis |
| **M3 — Fatia vertical** | venda do dia aparece no celular, com o mesmo valor do ERP |
| **M4 — Espelho completo** | todos os agregados sincronizando, e a sincronização se recupera sozinha de queda de internet |
| **M5 — App** | gestor usando no dia a dia, com push |

M2 tem um critério que não se negocia: **bater com o relatório do Genesis**. Não
é "parece certo" — é abrir o relatório de vendas do ERP, abrir a view, e os dois
darem o mesmo número no mesmo período.

---

## Riscos

| Risco | Sinal no inventário | O que fazer |
|---|---|---|
| Sem coluna de atualização confiável | seção 7 sem candidata | snapshot diário dos agregados; incremental fica para depois |
| Registro alterado retroativamente (venda de ontem editada hoje) | — | resincronizar sempre uma janela móvel (ex.: últimos 60 dias), não só o que mudou |
| Número não bate com o do contador | — | M2 trava isso antes de existir app |
| Tarefa agendada não roda com ninguém logado | — | configurar "executar mesmo sem usuário conectado"; validar na fatia vertical |
| Fuso trocando o dia da venda | — | tudo em `America/Sao_Paulo`, ponta a ponta; já configurado no compose |

---

## O que não fazer agora

- **Não comece pelo app.** Tela sem dado atrás é a parte que parece progresso e
  não é.
- **Não abra a 5432**, nem "só para o desenvolvimento".
- **Não coloque escrita na v1.** Consultar primeiro; lançar depois, se fizer
  sentido.
- **Não espere a spec perfeita.** As quatro specs juntas são ~3 dias, não duas
  semanas. A fatia vertical corrige o que elas erraram.

---

## O próximo passo, concretamente

Rodar o inventário e me mandar o `inventario.txt`. Com ele em mãos eu escrevo as
quatro specs e já deixo as views `bi.*` prontas para conferência.

Se quiser adiantar em paralelo, vale rodar a etapa 1 da codificação — subir a
infra no VPS seguindo `infra/vps/README.md`. Ela não depende do inventário.
