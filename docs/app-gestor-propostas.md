# App do Gestor — integração com o Genesis (ICES)

Documento de decisão: **3 arquiteturas possíveis** para um aplicativo de celular
que mostra ao gestor vendas, compras, financeiro e resultado, alimentado pelo
Genesis (sistema desktop + PostgreSQL).

> Status: proposta. Nenhuma decisão tomada ainda. Ver "Recomendação" no fim.

---

## 1. O problema real

Não é "fazer um app". Fazer tela é a parte fácil e barata. O problema é:

> **O Postgres do Genesis está dentro da rede do cliente (ou num servidor nosso,
> mas sem exposição pública). O celular do gestor está na rua, no 4G.**

Todas as decisões difíceis saem daí. E existe uma regra que não se quebra em
nenhuma das três opções:

- **A porta 5432 nunca fica aberta para a internet.** Nem "só com senha forte",
  nem "só o IP do app". Banco de ERP exposto é ransomware em questão de semanas.
- **O app nunca fala com o banco direto.** Se a credencial do Postgres estiver
  dentro do aplicativo, ela vaza — APK se descompila, tráfego se intercepta.
  Sempre existe uma API no meio.
- **O app é somente-leitura na v1.** Lançar movimentação pelo celular multiplica
  o risco e o escopo. Primeiro consultar, depois (talvez) aprovar/lançar.

### A camada de contrato (vale para as 3 opções)

Antes de qualquer arquitetura, criar no banco do Genesis um schema `bi` com
views — o padrão que já existe em `db/readonly/04_bi_views_example.sql`:

```sql
CREATE SCHEMA bi;
CREATE VIEW bi.vendas_dia    AS SELECT ...;
CREATE VIEW bi.vendas_vendedor AS SELECT ...;
CREATE VIEW bi.contas_receber  AS SELECT ...;
CREATE VIEW bi.compras_dia     AS SELECT ...;
```

Por que isso é inegociável:

- **Desacopla do ERP.** O Genesis muda tabela, campo, versão — o app não quebra,
  só a view é ajustada. Sem isso, cada atualização do ERP vira app quebrado.
- **LGPD.** A view não carrega CPF, e-mail, telefone. O que não sai do banco não
  vaza.
- **Fica versionado aqui no repositório.** O contrato de dados é código, não
  conhecimento na cabeça de alguém.

Faça isso e a escolha entre as opções abaixo vira reversível — dá para começar
pela mais barata e migrar depois sem reescrever o app.

---

## 2. Opção A — Espelho na nuvem com agente de sincronização
### *(o agente empurra os dados para fora; nada entra)*

```
┌───────────────── rede do cliente ─────────────────┐
│  Genesis (desktop)  ──▶  PostgreSQL               │
│                            ▲                      │
│                            │ SELECT (usuário RO)   │
│                       ┌────┴─────┐                 │
│                       │  Agente  │                 │
│                       │  (sync)  │                 │
│                       └────┬─────┘                 │
└────────────────────────────┼──────────────────────┘
                             │  HTTPS 443 — só SAÍDA
                             ▼
                  ┌──────────────────────┐
                  │  Postgres na nuvem   │
                  │  + API (REST)        │
                  └──────────┬───────────┘
                             │ HTTPS + JWT
                             ▼
                        📱 App do gestor
```

**Como funciona.** Um serviço pequeno roda na máquina do Genesis (ou em qualquer
máquina da mesma rede). De X em X minutos ele lê as views `bi.*`, pega só o que
mudou desde a última execução e faz `POST` num endpoint na nuvem. O app lê a
nuvem, nunca o cliente.

**O detalhe que faz isso funcionar:** a conexão é **sempre de dentro para fora**.
Não se abre porta, não se mexe em firewall, não precisa de IP fixo. É o mesmo
caminho que o navegador usa — e que já está liberado em toda rede.

### Sincronização incremental (o que evita mandar o banco inteiro)

```sql
SELECT * FROM bi.vendas_dia
 WHERE atualizado_em > :ultimo_watermark
 ORDER BY atualizado_em
 LIMIT 5000;
```

O agente guarda o `ultimo_watermark` localmente e avança só depois que a nuvem
confirma. Envio idempotente (`INSERT ... ON CONFLICT DO UPDATE` pela chave do
ERP), então reenviar o mesmo lote não duplica nada. Queda de internet, reboot da
máquina, agente morto no meio do lote: na próxima execução ele continua de onde
parou. Sem intervenção manual.

Se as tabelas do Genesis **não** tiverem `atualizado_em` confiável, há duas saídas:
snapshot diário completo dos agregados (que são pequenos — uma linha por
vendedor/dia, não uma por venda), ou um gatilho no banco alimentando uma tabela
de fila. A primeira resolve 90% dos casos e é bem mais simples.

### Mande agregado, não linha crua

O gestor quer *"quanto vendi hoje"*, não 40 mil linhas de item de nota. O agente
manda o resultado já somado:

| Tabela na nuvem | Grão | Volume/mês |
|---|---|---|
| `vendas_dia` | data × filial | ~30 linhas |
| `vendas_vendedor_dia` | data × vendedor | ~600 linhas |
| `vendas_cliente_mes` | mês × cliente | ~2.000 linhas |
| `financeiro_dia` | data × tipo | ~60 linhas |
| `compras_dia` | data × fornecedor | ~500 linhas |

Alguns milhares de linhas por mês. Sincroniza em segundos, cabe inteiro no
celular, o app abre instantâneo mesmo sem sinal.

### Prós
- **Não depende do cliente estar online.** Se o servidor do Genesis cair às 23h,
  o gestor ainda abre o app e vê o dado de até a última sincronização.
- **Zero exposição.** Nada da rede do cliente é alcançável de fora. Este é o
  ponto mais forte da opção.
- **Escala para vários clientes** com a mesma nuvem (multi-tenant por `cliente_id`).
- **Barato de rodar.** Agregados são minúsculos.

### Contras
- **Dois sistemas para manter** (agente + nuvem) e o agente precisa de um jeito
  de se atualizar sozinho na máquina do cliente.
- **Dado atrasado** pelo intervalo de sincronização (5–15 min é o razoável; menos
  que isso raramente muda uma decisão de gestão).
- **Cópia do dado fora da empresa** — precisa estar no contrato e no aviso de
  privacidade (LGPD).

**Esforço:** ~3 a 5 semanas para a v1.

---

## 3. Opção B — API on-premise publicada por túnel
### *(o dado nunca sai do cliente; o app consulta ao vivo)*

```
┌──────────── rede do cliente ────────────┐
│  PostgreSQL ◀── API read-only (local)   │
│                      │                  │
│                 túnel (saída 443)       │
└──────────────────────┼──────────────────┘
                       ▼
          Cloudflare Tunnel / VPN / WireGuard
                       │
                       ▼
                  📱 App do gestor
```

**Como funciona.** Sobe uma API na máquina do Genesis conectada ao Postgres com o
usuário somente-leitura de `db/readonly/01_create_readonly_role.sql`. Ela é
publicada com um **Cloudflare Tunnel** (ou WireGuard), que também abre conexão
**só de saída** e devolve uma URL HTTPS pública — sem porta aberta, sem IP fixo,
certificado automático.

### Prós
- **Dado sempre ao vivo.** O que o app mostra é o que está no banco agora.
- **Nada replicado.** Argumento forte para cliente que não aceita dado fora, e
  simplifica a conversa de LGPD.
- **Uma peça a menos.** Não existe banco na nuvem para manter, migrar, pagar.

### Contras
- **O app morre junto com a internet do cliente.** Servidor desligado, link
  caído, energia fora: tela em branco no celular do gestor. Em comércio isso
  acontece — e acontece justamente no fim de semana, quando ele quer olhar.
- **Consulta pesada bate na produção.** Mitigável com as views, `statement_timeout`
  e cache, mas o risco nunca é zero.
- **Cada cliente é uma instalação e um túnel.** Para 1 cliente, ótimo. Para 30,
  vira operação.

**Esforço:** ~2 a 3 semanas para a v1 — é a mais rápida de colocar de pé.

---

## 4. Opção C — Sem app próprio: BI pronto com aplicativo móvel
### *(validar o negócio antes de escrever código)*

**Como funciona.** Usa o que o repositório já entrega: cria o usuário
somente-leitura, aponta um **Metabase** (ou Power BI / Looker Studio) para as
views `bi.*` e monta os painéis. Todas essas ferramentas têm app de celular e
envio programado por e-mail/WhatsApp.

O acesso ao banco continua por túnel ou pela nuvem do Metabase — o problema de
rede é o mesmo das opções A e B; o que muda é que **não se escreve aplicativo**.

### Prós
- **Dias, não semanas.** Dá para ter o gestor olhando número nesta semana.
- **Custo quase zero** (Metabase open-source; Looker Studio grátis).
- **Descobre o que ele realmente olha.** Quase sempre, depois de 30 dias, o gestor
  usa 4 números e ignora os outros 20. Saber quais são esses 4 *antes* de
  desenhar o app economiza mais tempo do que qualquer decisão técnica.

### Contras
- **Não é um app.** É um painel dentro do app de outra empresa: sem notificação
  push própria, sem marca, sem offline de verdade, navegação de dashboard e não
  de produto.
- **Não vira produto.** Não dá para vender/licenciar para outros clientes.
- **Teto baixo.** Alerta de meta, aprovação de pedido, comissão do vendedor no
  celular dele — nada disso cabe bem.

**Esforço:** ~3 a 5 dias.

---

## 5. Comparação

| | **A — Espelho na nuvem** | **B — API por túnel** | **C — BI pronto** |
|---|---|---|---|
| Esforço v1 | 3–5 semanas | 2–3 semanas | 3–5 dias |
| Atualidade do dado | 5–15 min | tempo real | tempo real |
| Funciona com cliente offline | **sim** | não | não |
| Funciona sem sinal no celular | **sim** (cache) | não | não |
| Exposição da rede do cliente | nenhuma | nenhuma (túnel) | nenhuma (túnel) |
| Cópia do dado fora | sim | **não** | depende |
| Carga na produção | mínima | média | média/alta |
| Escala p/ vários clientes | **ótima** | ruim | média |
| Push de alertas | **sim** | sim | não |
| Vira produto vendável | **sim** | sim | não |
| Custo mensal | baixo | quase zero | quase zero |

---

## 6. Recomendação

**C agora, A como destino. B só se o cliente proibir dado fora.**

Não são alternativas excludentes — são fases, e a camada `bi.*` é a mesma nas
três, então nada do trabalho é jogado fora.

### Fase 0 — esta semana (~3 dias)
Criar as views `bi.*` no Genesis, rodar `01_create_readonly_role.sql`, subir um
Metabase apontado para elas. **O gestor começa a olhar número já.** Objetivo real
desta fase: descobrir quais indicadores ele abre todo dia e quais ele nunca abriu.

### Fase 1 — mês 1 (~3 semanas)
Agente de sincronização + banco na nuvem + API. O Metabase continua funcionando
(agora lendo a nuvem, sem tocar a produção do cliente).

### Fase 2 — mês 2 (~2 semanas)
O app, construído sobre a API que já está pronta e testada — com as telas que a
Fase 0 provou que ele usa, não as que a gente imaginou.

### Por que A e não B como destino

O que decide não é técnico, é o comportamento do gestor: ele abre o app **no
sábado, no carro, no 4G ruim, para ver como fechou a semana**. Na opção B, se o
servidor do escritório estiver desligado — e no sábado costuma estar — ele vê
tela de erro. Duas vezes seguidas e o app está desinstalado. Na opção A o dado
está no celular dele; abre em um segundo, inclusive em elevador.

O segundo motivo: se isso um dia for vendido para outros clientes da base ICES,
A é a única que escala sem virar uma operação de instalação por cliente.

---

## 7. Escopo funcional da v1 (vale para qualquer opção)

Cinco telas. Não mais que isso — app de gestão morre de excesso de tela.

1. **Hoje** — venda do dia e do mês, % da meta, comparação com mês anterior,
   resultado (entradas − saídas), saldo previsto. É a tela que ele abre 20×/dia;
   tem que responder em 1 segundo e ser legível em 3.
2. **Vendas** — série do mês, ranking de vendedores, top produtos, ticket médio.
3. **Compras** — total do período, principais fornecedores, compras × vendas.
4. **Financeiro** — a receber, a pagar, vencidos, inadimplência, fluxo previsto
   dos próximos 30 dias.
5. **Clientes** — curva ABC, quem parou de comprar (sem pedido há N dias),
   maiores devedores.

**Notificações push** (é o que transforma relatório em ferramenta):
meta do dia batida, venda acima de R$ X, título grande vencido, cliente A parado
há 30 dias, resumo às 19h.

**Fora da v1, de propósito:** lançar pedido, dar baixa em título, cadastrar
cliente, editar qualquer coisa. Escrita entra depois que a leitura estiver
estável e auditada.

---

## 8. Segurança e LGPD (não é opcional)

- Usuário `SELECT`-only no Genesis — o script `01` do repositório já faz isso, e
  o `02` prova que não sobrou permissão de escrita.
- Views `bi.*` sem CPF, e-mail, telefone, salário. Cliente identificado por
  pseudônimo estável quando der.
- Toda comunicação em HTTPS/TLS. Nenhuma credencial de banco dentro do app.
- Login por usuário, token de curta duração, e **escopo por papel**: o vendedor
  vê o dele, o gestor vê tudo. Filtrado no servidor — nunca escondendo botão no app.
- Log de acesso: quem viu o quê e quando.
- Revogação imediata disponível (`03_revoke_readonly.sql` e desligar o token).

---

## 9. Onde hospedar: a Hostinger serve — mas só de VPS para cima

Assinatura disponível: **Hostinger**. Isso resolve a Fase 1, com uma ressalva que
muda a escolha do plano.

### O fato que decide

**PostgreSQL não roda nos planos de Web Hosting nem de Cloud Hosting da
Hostinger.** É limitação declarada da própria empresa — esses planos entregam
PHP + MySQL/MariaDB e não dão as permissões e os recursos que o Postgres exige.
Para ter Postgres é preciso **VPS**, onde há root e Docker (a Hostinger inclusive
tem instalação do Postgres em um clique).

Segundo fato, igualmente importante: nos planos compartilhados **não se roda
processo 24×7**. Só PHP respondendo a requisição e cron agendado.

### Os dois caminhos

**Caminho 1 — Web/Cloud Hosting que você já tem (custo adicional zero).**
Tecnicamente funciona para a Opção A, e por um motivo que costuma passar
despercebido: **o lado da nuvem não precisa de processo 24×7**. Quem tem
iniciativa é o agente na loja — ele faz `POST`, um script PHP recebe e grava. API
é só PHP respondendo a requisição, que é exatamente o que hospedagem
compartilhada faz. O resumo das 19h sai por cron.

O preço disso é gravar em **MySQL em vez de Postgres**: a nuvem passa a ter
tecnologia diferente da origem, e alguém mantém a tradução de tipos para sempre.
Para agregados (data, vendedor, valor) a tradução é trivial. Mas é dívida que só
cresce.

**Caminho 2 — VPS KVM (recomendado).** Root, Docker, Postgres nativo, processo
contínuo, sem teto. **KVM 1** (1 vCPU, 4 GB RAM, 50 GB NVMe) já sobra para este
uso — estamos falando de alguns milhares de linhas agregadas por mês, não de
carga de ERP. Sai na faixa de US$ 4,99/mês promocional (~US$ 11,99 na renovação;
conte com a renovação, não com a promoção). **KVM 2** só se isso for atender
vários clientes da base ICES.

### Escolha o data center de São Paulo

A Hostinger abriu data center próprio em São Paulo. Dois ganhos diretos:

- **Latência.** O agente na loja e o celular do gestor estão no Brasil. Servidor
  nos EUA acrescenta ~120 ms em toda requisição — o app "pesado" sem motivo.
- **LGPD.** Dado financeiro de empresa brasileira permanecendo em território
  nacional encurta bastante a conversa de contrato e de transferência
  internacional.

Na criação do VPS a região é escolhida uma vez e **não se troca depois sem
recriar**. É o tipo de clique de 5 segundos que custa uma migração se errado.

### Stack sugerida no VPS

```
Ubuntu 22.04 + Docker Compose
├── postgres:16      → só na rede interna do Docker, SEM porta publicada
├── api              → Node/Fastify (ou PHP, tanto faz) :3000 interno
└── caddy            → 443, TLS automático, proxy para a api
```

Firewall: **só 22 e 443 abertos**. A porta 5432 não é publicada nem para o host —
é a mesma regra da seção 1, e vale tanto para o banco do cliente quanto para este.
SSH por chave, senha desabilitada.

### Backup — o ponto onde VPS barato costuma decepcionar

O backup incluído da Hostinger é **semanal**. Para dado financeiro isso significa
aceitar perder até 7 dias, o que não é aceitável. Some a isso:

- `pg_dump` diário com retenção de 30 dias, **enviado para fora do VPS** (backup
  no mesmo servidor não é backup);
- restauração testada de verdade uma vez, antes de considerar a Fase 1 pronta.

Atenuante real: como a nuvem é **espelho** e não origem, o dado verdadeiro
continua no Genesis. No pior caso, reconstrói-se a nuvem re-sincronizando do
zero. Vale desenhar o agente para permitir isso desde o começo — um modo
"ressincronizar tudo" que se roda sob demanda. Custa pouco agora e um dia salva
o fim de semana de alguém.

### Onde a Hostinger não resolve

- **Notificação push** não é hospedagem. Use Firebase Cloud Messaging (grátis) ou
  Web Push a partir do próprio PWA — o servidor só dispara.
- **O agente roda na loja, no Windows do Genesis**, não na Hostinger. O jeito mais
  robusto não é serviço do Windows: é **Tarefa Agendada a cada 5 minutos**,
  executando um binário que faz o lote e encerra. Serviço que morre fica morto até
  alguém perceber; tarefa agendada que falha simplesmente roda de novo em 5
  minutos. Menos código, e se conserta sozinha.

### Custo mensal realista

| Item | Custo |
|---|---|
| VPS KVM 1 (São Paulo) | ~US$ 5–12/mês |
| Domínio/subdomínio | já incluso na assinatura |
| TLS (Caddy/Let's Encrypt) | R$ 0 |
| Firebase Cloud Messaging | R$ 0 |
| **Total** | **~R$ 30–70/mês** |

Cabe em um único cliente. Se virar produto para a base ICES, o mesmo VPS atende
vários (multi-tenant por `cliente_id`) até crescer bastante.

---

## 10. Pendências antes de começar

1. **Onde roda o Postgres do Genesis hoje?** Máquina na loja, servidor próprio,
   ou já em nuvem? Muda o esforço da Fase 1.
2. **Quantos clientes ICES** vão usar isso — 1 ou a base inteira? Se for a base,
   pula a hesitação e vai direto para A.
3. **As tabelas têm data de atualização confiável?** Define sincronização
   incremental × snapshot diário.
4. ~~Qual a assinatura para hospedar?~~ **Resolvido: Hostinger.** Falta confirmar
   *qual plano* — se for Web/Cloud Hosting, é preciso somar um VPS KVM 1 (Postgres
   não roda nesses planos); se já for VPS, não há custo novo.
5. **iOS, Android ou os dois?** Recomendação: **PWA** primeiro — instala nos dois
   pelo navegador, sem loja, sem revisão da Apple, atualização instantânea. App
   nativo só quando houver motivo concreto.
