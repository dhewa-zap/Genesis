-- =============================================================================
-- Inventario do banco do Genesis — levantamento para desenhar as views bi.*
-- =============================================================================
-- Roda uma vez, no banco do Genesis, e produz um relatorio de texto. E o que
-- destrava a escrita das specs: sem saber como o ERP guarda venda, compra,
-- titulo e vendedor, nao da para escrever a camada de contrato.
--
-- Uso:
--   psql -h HOST -U USUARIO -d BANCO_DO_GENESIS -f inventario_schema.sql -o inventario.txt
--
-- Depois envie o inventario.txt.
--
-- SEGURO PARA RODAR EM PRODUCAO:
--   - transacao READ ONLY: o banco recusa qualquer escrita, mesmo que houvesse;
--   - so le catalogo do sistema (pg_class, information_schema) — nao le NENHUMA
--     linha das suas tabelas, entao nao ha dado de cliente neste relatorio;
--   - contagem de linhas vem da ESTIMATIVA do planejador, nao de count(*) —
--     nao varre tabela grande nem pesa no servidor;
--   - statement_timeout de 60s e lock_timeout de 5s: no pior caso ele desiste,
--     nunca segura lock em cima do ERP.
--
-- Requer: PostgreSQL 9.6+.
-- =============================================================================

\pset pager off
\pset format aligned
\timing off
\set ON_ERROR_STOP on

BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';

-- Palavras que costumam nomear as tabelas que interessam. Ajuste se o Genesis
-- usar outra nomenclatura (ex.: tabelas com prefixo, nomes em ingles).
\set dominio 'vend|compr|client|fornec|represent|titul|receb|pag|financ|caixa|banc|produt|item|nota|nf|pedid|orcament|movimen|estoq|meta|comiss'

\qecho
\qecho '############################################################'
\qecho '# 1. Servidor e banco'
\qecho '############################################################'

SELECT version() AS versao;

SELECT current_database()                           AS banco,
       pg_size_pretty(pg_database_size(current_database())) AS tamanho_total,
       current_setting('TimeZone')                  AS fuso;

\qecho
\qecho '############################################################'
\qecho '# 2. Schemas com tabelas'
\qecho '############################################################'

SELECT n.nspname                                   AS schema,
       count(*) FILTER (WHERE c.relkind = 'r')     AS tabelas,
       count(*) FILTER (WHERE c.relkind = 'v')     AS views,
       count(*) FILTER (WHERE c.relkind = 'm')     AS matviews,
       pg_size_pretty(sum(pg_total_relation_size(c.oid))) AS tamanho
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r','v','m')
   AND n.nspname NOT IN ('pg_catalog','information_schema')
   AND n.nspname !~ '^pg_'
 GROUP BY n.nspname
 ORDER BY sum(pg_total_relation_size(c.oid)) DESC;

\qecho
\qecho '############################################################'
\qecho '# 3. Donos das tabelas (parametro app_owner do 01_create_readonly_role)'
\qecho '############################################################'

SELECT tableowner AS dono, count(*) AS tabelas
  FROM pg_tables
 WHERE schemaname NOT IN ('pg_catalog','information_schema')
 GROUP BY tableowner
 ORDER BY count(*) DESC;

\qecho
\qecho '############################################################'
\qecho '# 4. As 40 maiores tabelas (onde o volume realmente esta)'
\qecho '############################################################'

SELECT n.nspname                                       AS schema,
       c.relname                                       AS tabela,
       pg_size_pretty(pg_total_relation_size(c.oid))   AS tamanho,
       CASE WHEN c.reltuples < 0 THEN NULL
            ELSE c.reltuples::bigint END               AS linhas_estimadas,
       CASE WHEN c.reltuples < 0 THEN 'nunca analisada'
            ELSE '' END                                AS obs
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'r'
   AND n.nspname NOT IN ('pg_catalog','information_schema')
   AND n.nspname !~ '^pg_'
 ORDER BY pg_total_relation_size(c.oid) DESC
 LIMIT 40;

\qecho
\qecho '############################################################'
\qecho '# 5. Tabelas candidatas do dominio (venda, compra, titulo...)'
\qecho '############################################################'

SELECT n.nspname                                     AS schema,
       c.relname                                     AS tabela,
       CASE WHEN c.reltuples < 0 THEN NULL
            ELSE c.reltuples::bigint END             AS linhas_estimadas,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS tamanho
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r','v','m')
   AND n.nspname NOT IN ('pg_catalog','information_schema')
   AND n.nspname !~ '^pg_'
   AND c.relname ~* :'dominio'
 ORDER BY n.nspname, c.relname;

\qecho
\qecho '############################################################'
\qecho '# 6. Colunas dessas tabelas candidatas'
\qecho '############################################################'

SELECT c.table_schema                        AS schema,
       c.table_name                          AS tabela,
       c.ordinal_position                    AS pos,
       c.column_name                         AS coluna,
       c.data_type                           AS tipo,
       c.is_nullable                         AS aceita_nulo
  FROM information_schema.columns c
  JOIN pg_class    pc ON pc.relname = c.table_name
  JOIN pg_namespace pn ON pn.oid = pc.relnamespace AND pn.nspname = c.table_schema
 WHERE c.table_schema NOT IN ('pg_catalog','information_schema')
   AND c.table_name ~* :'dominio'
 ORDER BY c.table_schema, c.table_name, c.ordinal_position;

\qecho
\qecho '############################################################'
\qecho '# 7. CRITICO: colunas de data/hora — servem de marca-dagua'
\qecho '############################################################'
\qecho '# E o que decide entre sincronizacao incremental (le so o que mudou)'
\qecho '# e snapshot diario completo. Procuramos algo tipo atualizado_em que'
\qecho '# MUDE A CADA UPDATE, nao apenas a data de criacao do registro.'
\qecho

SELECT c.table_schema                        AS schema,
       c.table_name                          AS tabela,
       c.column_name                         AS coluna,
       c.data_type                           AS tipo,
       CASE
         WHEN c.column_name ~* 'atualiz|updat|alter|modific|ultim|sync'
           THEN '<<< CANDIDATA A MARCA-DAGUA'
         WHEN c.column_name ~* 'cria|inclu|cadastr|insert|emiss|lancam'
           THEN 'so criacao — nao serve sozinha'
         ELSE ''
       END                                   AS avaliacao
  FROM information_schema.columns c
 WHERE c.table_schema NOT IN ('pg_catalog','information_schema')
   AND c.table_name ~* :'dominio'
   AND c.data_type IN ('date','timestamp without time zone',
                       'timestamp with time zone','time without time zone')
 ORDER BY (c.column_name ~* 'atualiz|updat|alter|modific|ultim|sync') DESC,
          c.table_schema, c.table_name, c.column_name;

\qecho
\qecho '############################################################'
\qecho '# 8. Chaves primarias (identidade estavel para o espelho)'
\qecho '############################################################'

SELECT n.nspname                              AS schema,
       t.relname                              AS tabela,
       string_agg(a.attname, ', '
                  ORDER BY array_position(i.indkey::int[], a.attnum)) AS chave_primaria
  FROM pg_index i
  JOIN pg_class     t ON t.oid = i.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(i.indkey)
 WHERE i.indisprimary
   AND n.nspname NOT IN ('pg_catalog','information_schema')
   AND t.relname ~* :'dominio'
 GROUP BY n.nspname, t.relname
 ORDER BY n.nspname, t.relname;

\qecho
\qecho '############################################################'
\qecho '# 9. Tabelas SEM chave primaria (complicam o espelho)'
\qecho '############################################################'

SELECT n.nspname AS schema, c.relname AS tabela
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'r'
   AND n.nspname NOT IN ('pg_catalog','information_schema')
   AND n.nspname !~ '^pg_'
   AND c.relname ~* :'dominio'
   AND NOT EXISTS (SELECT 1 FROM pg_index i
                    WHERE i.indrelid = c.oid AND i.indisprimary)
 ORDER BY n.nspname, c.relname;

\qecho
\qecho '############################################################'
\qecho '# 10. Triggers existentes (podem virar fila de sincronizacao)'
\qecho '############################################################'

SELECT n.nspname   AS schema,
       c.relname   AS tabela,
       t.tgname    AS trigger
  FROM pg_trigger t
  JOIN pg_class     c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE NOT t.tgisinternal
   AND n.nspname NOT IN ('pg_catalog','information_schema')
   AND c.relname ~* :'dominio'
 ORDER BY n.nspname, c.relname, t.tgname;

COMMIT;

\qecho
\qecho '############################################################'
\qecho '# Fim. Envie este arquivo.'
\qecho '# Nenhuma linha das suas tabelas foi lida: o relatorio tem'
\qecho '# apenas nomes de tabela e coluna, nenhum dado de cliente.'
\qecho '############################################################'
