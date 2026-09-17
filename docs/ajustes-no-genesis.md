# Ajustes necessários no Genesis (ERP)

O que precisa mudar **no lado do ERP** para o app do gestor funcionar, por que,
e como verificar. Todo o SQL daqui foi testado contra um PostgreSQL 16.

> **Nota de acesso:** este documento foi escrito sem acesso ao código do Genesis
> (`D:\genesis` está na sua máquina; a sessão roda na nuvem). Ele cobre o que é
> previsível pela arquitetura. A seção **"O que verificar no código"** traz os
> comandos para você rodar aí e mandar o resultado — ou rode o Claude Code
> localmente apontado para `D:\genesis` e eu leio direto.

## O princípio: mexer o mínimo possível no ERP

Um ERP em produção é o sistema que a empresa usa para faturar. Cada alteração
ali é risco. Então a regra:

**Só três coisas entram no banco do Genesis.** Todo o resto — metas, usuários do
app, tokens, preferências, histórico de notificação — vive no banco da nuvem.
Nada disso é dado do ERP, e colocar tabela de aplicativo dentro do ERP é criar
um acoplamento que atrapalha nas duas direções.

As três: **marca-d'água**, **log de exclusões** e **índices**. Mais o schema `bi`,
que são views — não alteram nenhuma tabela.

E o melhor: **nenhuma delas exige mexer no código Delphi/desktop do Genesis.**
Triggers fazem o trabalho no banco, por baixo. O ERP continua fazendo o `UPDATE`
que sempre fez.

---

## Ajuste 1 — Marca-d'água (`atualizado_em`)

O que permite ao agente perguntar "o que mudou desde a última vez?" em vez de ler
tudo toda vez.

```sql
ALTER TABLE vendas ADD COLUMN atualizado_em timestamptz NOT NULL DEFAULT now();

CREATE OR REPLACE FUNCTION bi_marca_atualizacao() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.atualizado_em := clock_timestamp();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_bi_atualizado BEFORE UPDATE ON vendas
  FOR EACH ROW EXECUTE FUNCTION bi_marca_atualizacao();
```

Repita nas tabelas que alimentam os indicadores (vendas, itens, compras,
títulos, clientes).

**Testado:** o `ALTER TABLE` numa tabela de **800 mil linhas levou 57 ms** — no
PostgreSQL 11+ um `DEFAULT` desse tipo não reescreve a tabela, só grava
metadado. E um `UPDATE` feito em SQL puro, sem nenhuma mudança no ERP, moveu a
marca-d'água corretamente.

### Armadilha de migração (descoberta no teste)

Depois do `ALTER`, **todas as linhas ficam com o mesmo `atualizado_em`** — o
instante da migração. Na tabela de teste, 800 mil linhas ficaram com 3 valores
distintos. Consequência: a primeira execução do agente enxerga a tabela inteira
como "mudou" e tenta enviar tudo de uma vez.

Não é um defeito, é o comportamento esperado — mas precisa de plano:

- fazer a **carga inicial** em lotes controlados, uma vez, fora do horário de
  pico; **ou**
- semear a marca-d'água do agente já com o instante da migração, e deixar a
  carga histórica para um processo separado.

Decidir isso antes de rodar o `ALTER` em produção, não depois.

### A armadilha do commit atrasado

`clock_timestamp()` grava o instante do `UPDATE`, mas a linha só fica **visível**
no `COMMIT`. Uma transação que grava `atualizado_em = 10h00` e só confirma às
10h02 fica invisível para um agente que leu às 10h01 e já avançou sua marca —
**e nunca mais aparece**.

Mitigação (vai na spec do protocolo): o agente relê sempre a partir da
marca-d'água **menos uma margem de segurança** (5 minutos). Como o envio é
idempotente, reprocessar as mesmas linhas não causa dano.

---

## Ajuste 2 — Log de exclusões

Sincronização incremental enxerga o que mudou. **Não enxerga o que sumiu:** se o
ERP apaga uma venda, a linha some da origem e permanece para sempre no espelho.
O gestor vê faturamento que não existe mais.

```sql
CREATE TABLE bi_exclusoes (
  id          bigserial PRIMARY KEY,
  tabela      text        NOT NULL,
  chave       text        NOT NULL,
  excluido_em timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_bi_exclusoes_em ON bi_exclusoes (excluido_em);

CREATE OR REPLACE FUNCTION bi_registra_exclusao() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO bi_exclusoes (tabela, chave) VALUES (TG_TABLE_NAME, OLD.id::text);
  RETURN OLD;
END $$;

CREATE TRIGGER trg_bi_exclusao AFTER DELETE ON vendas
  FOR EACH ROW EXECUTE FUNCTION bi_registra_exclusao();
```

**Testado:** dois `DELETE` foram registrados corretamente na tabela de log.

Se o Genesis **não apaga** (usa status "cancelado"), este ajuste é desnecessário
— mas aí é essencial saber **qual é o status** e excluí-lo nas views. É a
primeira pergunta da seção de verificação.

---

## Ajuste 3 — Índice na marca-d'água

Sem ele, cada sincronização varre a maior tabela do ERP inteira. A cada 5
minutos. Em produção.

```sql
CREATE INDEX CONCURRENTLY ix_vendas_atualizado ON vendas (atualizado_em);
```

**`CONCURRENTLY` não é opcional:** sem essa palavra o `CREATE INDEX` trava
escrita na tabela enquanto constrói, e o ERP fica parado. Com ela, demora mais e
não bloqueia ninguém. (Não pode rodar dentro de transação.)

**Testado**, mesma consulta na tabela de 800 mil linhas:

| | Blocos lidos |
|---|---|
| Com índice (Index Scan) | **44** |
| Sem índice (Seq Scan) | 5.957 |

135× menos trabalho, a cada 5 minutos, para sempre.

---

## Ajuste 4 — Schema `bi` e usuário somente-leitura

Já versionado em `db/readonly/`. São **views**, não alteram tabela nenhuma. O
parâmetro `app_owner` sai da seção 3 do inventário.

---

## A armadilha dos agregados (vale para o agente, não para o ERP)

Merece destaque porque não é óbvia e corrompe número em silêncio.

O agente lê **linhas** pela marca-d'água, mas envia **agregados por dia**. Se uma
venda emitida em março é editada hoje, o total de **março** mudou — não o de
hoje.

**Testado:** editei duas vendas, uma de `2025-03-10` e outra de `2026-08-24`. A
consulta por marca-d'água retornou as 2 linhas, e delas se derivam os dois dias
a recalcular — incluindo o de março.

Portanto a regra do agente:

> A marca-d'água seleciona **linhas**. Os **dias afetados** se derivam dessas
> linhas, e são esses dias que se recalculam e se enviam.

Uma abordagem de "ressincronizar os últimos 60 dias" **não pega** a edição de
março. Erraria calado.

---

## O que verificar no código do Genesis

Rode aí no `D:\genesis` e me mande a saída. São buscas de leitura, não alteram
nada.

### 1. `INSERT` sem lista de colunas — o risco mais sério

Código legado costuma escrever `INSERT INTO vendas VALUES (a, b, c)` sem nomear
as colunas. **Adicionar uma coluna quebra esse INSERT na hora.** É o único
ajuste deste documento que pode derrubar o ERP, e é verificável antes.

```powershell
# PowerShell, em D:\genesis
Select-String -Path *.pas,*.dfm,*.sql -Recurse -Pattern 'INSERT\s+INTO\s+\w+\s*VALUES' |
  Select-Object Path, LineNumber, Line
```

Se voltar vazio, o Ajuste 1 é seguro. Se voltar alguma coisa, ou se corrige o
`INSERT` (nomeando as colunas) ou se evita a coluna nova naquela tabela.

### 2. `SELECT *` em código que depende da ordem das colunas

```powershell
Select-String -Path *.pas,*.sql -Recurse -Pattern 'SELECT\s+\*' | Measure-Object
```

Menos grave — mas se houver acesso por índice numérico de coluna, a coluna nova
desloca tudo.

### 3. Exclusão física de venda

```powershell
Select-String -Path *.pas,*.sql -Recurse -Pattern 'DELETE\s+FROM\s+(venda|compra|titulo|nota)' -CaseSensitive:$false
```

Se houver, o Ajuste 2 é obrigatório.

### 4. Como o ERP marca cancelamento

Procure os valores possíveis da coluna de status das vendas. Isso define o
`WHERE` das views — e é o tipo de detalhe que, errado, faz o app mostrar
faturamento maior que o real.

### 5. Dinheiro em `float`

```sql
SELECT table_name, column_name, data_type
  FROM information_schema.columns
 WHERE data_type IN ('double precision','real')
   AND column_name ~* 'valor|preco|total|desconto|custo';
```

`double precision` em valor monetário acumula erro de arredondamento. Se houver,
as views convertem para `numeric` — e vale investigar se o próprio ERP não tem
divergência de centavos hoje.

---

## Ordem de execução, quando chegar a hora

1. Rodar o **inventário** (`db/genesis/inventario_schema.sql`) — ainda pendente.
2. Rodar as **verificações de código** acima.
3. Só então aplicar os ajustes, **em cópia de restauração do backup primeiro**,
   nunca direto em produção.
4. Conferir que o ERP continua operando normalmente.
5. Aplicar em produção, fora do horário de pico, com backup recente.

Os ajustes 1, 2 e 3 são pequenos e reversíveis (`DROP TRIGGER`, `DROP COLUMN`,
`DROP INDEX`). O que não é reversível é aplicar sem testar antes.

---

## Resumo

| Ajuste | Onde | Mexe no código do ERP? | Risco |
|---|---|---|---|
| `atualizado_em` + trigger | tabelas do domínio | não | baixo — salvo `INSERT` sem colunas |
| Log de exclusões | tabela nova + trigger | não | baixo |
| Índice `CONCURRENTLY` | tabelas do domínio | não | baixo |
| Schema `bi` | views | não | nenhum |
| Metas, usuários, tokens | **nada disso vai no ERP** | — | — |
