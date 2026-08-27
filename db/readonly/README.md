# Acesso somente-leitura ao banco para terceiros (dashboard / BI)

Scripts para liberar o banco Postgres a um fornecedor externo construir dashboards
**sem nenhum risco de escrita**.

O princípio: não é "confiar que o terceiro não vai editar" — é tornar a edição
impossível no nível do banco. Um usuário dedicado que só tem `SELECT` não
consegue escrever nem que queira.

## Scripts

| Arquivo | O que faz | Quando rodar |
|---|---|---|
| `01_create_readonly_role.sql` | Cria o role/usuário e concede só leitura | Uma vez, por banco |
| `02_verify_readonly.sql` | Audita: prova que não sobrou permissão de escrita | Depois do 01, e a cada auditoria |
| `03_revoke_readonly.sql` | Corta o acesso e remove os roles | Fim do contrato / incidente |
| `04_bi_views_example.sql` | Camada de views sem dado pessoal (LGPD) | Opcional, mas recomendado |

## Passo a passo

### 1. Provisionar

```bash
psql -h SEU_HOST -U postgres -d SEU_BANCO \
     -v ro_user=dash_terceiro \
     -v app_owner=app_user \
     -v ro_schemas=public \
     -v valid_until='2026-12-31' \
     -f 01_create_readonly_role.sql
```

**`app_owner` é o parâmetro mais importante.** Ele deve ser o role que cria as
tabelas (o das migrations da aplicação, normalmente) — não o superusuário que
está rodando o script. Sem isso, toda tabela criada no futuro fica invisível
para o dashboard, e alguém acaba "resolvendo" o problema mais tarde dando
permissão demais. Na dúvida:

```sql
SELECT DISTINCT tableowner FROM pg_tables WHERE schemaname = 'public';
```

`valid_until` é opcional mas vale a pena: o acesso expira sozinho no fim do
projeto, mesmo que ninguém lembre de revogar.

### 2. Definir a senha

O script cria o usuário com `PASSWORD NULL` — login impossível até você definir
a senha. Faça isso pelo `\password`, que **não** grava a senha em log do servidor
nem no histórico do psql:

```
psql -h SEU_HOST -U postgres -d SEU_BANCO
\password dash_terceiro
```

Mande a senha por gerenciador de senhas com link expirável. Nunca por e-mail ou
WhatsApp.

### 3. Conferir

```bash
psql -h SEU_HOST -U postgres -d SEU_BANCO -v ro_user=dash_terceiro -f 02_verify_readonly.sql
```

As seções 2 e 3 têm que voltar **zero linhas**. Se voltar qualquer coisa, sobrou
GRANT em algum lugar.

### 4. Entregar

Passe host, porta, nome do banco, usuário e `sslmode=require`. E só isso.

## O que o script faz, e por quê

- **Role de permissão (`NOLOGIN`) + usuário de login separado.** Os GRANTs ficam
  no role; o usuário só o herda. Trocar de fornecedor vira criar outro usuário,
  sem refazer permissão nenhuma.
- **`REVOKE ALL ON DATABASE ... FROM PUBLIC`** — tira o acesso implícito que todo
  role recebe por padrão.
- **`REVOKE CREATE ON SCHEMA public FROM PUBLIC`** — até o PG 14, qualquer usuário
  podia criar tabela no `public`.
- **`GRANT SELECT`** nas tabelas, views, sequences e materialized views existentes.
  Matviews entram uma a uma porque `GRANT ... ON ALL TABLES` nem sempre as alcança.
- **`ALTER DEFAULT PRIVILEGES FOR ROLE <app_owner>`** — tabelas futuras já nascem
  legíveis.
- **`NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION`** — explícito,
  para não depender de default.
- **Timeouts** (`statement_timeout`, `idle_in_transaction_session_timeout`,
  `lock_timeout`) e `CONNECTION LIMIT` — uma consulta pesada de dashboard não
  derruba nem segura lock na produção.

### Sobre `default_transaction_read_only`

O script também liga `default_transaction_read_only` no usuário, mas trate isso
como **defesa em profundidade, não como o controle de acesso**: o próprio cliente
pode desligar a flag na sessão dele. Quem realmente impede escrita são os GRANTs —
o script simplesmente nunca concede `INSERT`/`UPDATE`/`DELETE`.

Testado: com a flag desligada pelo cliente, as escritas continuam falhando com
`permission denied for table`.

## Se houver dado pessoal (recomendado)

Em vez de liberar as tabelas cruas, use `04_bi_views_example.sql`: um schema `bi`
com views expondo só as colunas necessárias — sem CPF, e-mail, telefone, salário.
Rode o `01` com `-v ro_schemas=bi` e **não** conceda `USAGE` no `public`.

Ganho extra: você refatora a tabela real sem quebrar o dashboard do terceiro.

## Fora do banco

Permissão resolve escrita; não resolve exposição. Ainda é preciso:

- **Nunca** deixar a porta 5432 aberta para a internet. Use allowlist de IP,
  VPN ou túnel SSH. No RDS, security group com o IP de origem.
- **Forçar TLS**: `hostssl ... scram-sha-256` no `pg_hba.conf`, e passar
  `sslmode=require` (ou `verify-full`) para o fornecedor.
- **Réplica de leitura**, se você tiver — aí nem fisicamente há como escrever.
- Registrar a data de fim e revogar (`03_revoke_readonly.sql`).

## Ferramentas de BI que pedem escrita

Algumas ferramentas pedem permissão de escrita: o Metabase com *model
persistence* quer criar um schema próprio, dbt idem. **Não solte o freio nas
tabelas.** Crie um schema separado só para isso:

```sql
CREATE SCHEMA metabase_cache AUTHORIZATION dash_terceiro;
```

Power BI, Looker Studio, Superset e Metabase sem cache funcionam 100% só com
`SELECT`.

## Serviços gerenciados

- **RDS / Aurora**: você não é superusuário; rode como o usuário master. Prefira
  apontar o dashboard para o endpoint da réplica de leitura.
- **Supabase**: rode no SQL Editor como `postgres`. Atenção ao RLS — se as
  tabelas têm policies, o role de leitura precisa de policy de `SELECT`, e
  **não** dê `BYPASSRLS`. Não entregue a `service_role key` ao terceiro em
  hipótese alguma.
- **Neon / Cloud SQL / Azure**: funcionam como o Postgres padrão.

## Emergência

Cortar o acesso agora, sem apagar nada:

```sql
ALTER ROLE dash_terceiro NOLOGIN;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'dash_terceiro';
```

## Validação

Os quatro scripts foram executados de ponta a ponta contra um PostgreSQL 16:
provisionamento, tabela criada depois do script (herdou a leitura), tentativa de
escrita com e sem o modo read-only, camada de views e revogação.
