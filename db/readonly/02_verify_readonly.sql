-- =============================================================================
-- Conferencia do acesso somente-leitura
-- =============================================================================
-- Rode DEPOIS do 01, conectado como superusuario/dono, no mesmo banco:
--   psql -h HOST -U postgres -d MEUBANCO -v ro_user=dash_terceiro -f 02_verify_readonly.sql
--
-- O resultado esperado esta descrito antes de cada consulta.
-- =============================================================================

\set ON_ERROR_STOP on

\if :{?ro_user}
\else
\set ro_user dash_terceiro
\endif

\echo '=== 1. Atributos do usuario (tudo deve ser "f", exceto Login) ==='
SELECT rolname            AS usuario,
       rolcanlogin        AS pode_logar,
       rolsuper           AS superusuario,
       rolcreatedb        AS cria_banco,
       rolcreaterole      AS cria_role,
       rolbypassrls       AS ignora_rls,
       rolreplication     AS replicacao,
       rolconnlimit       AS limite_conexoes,
       rolvaliduntil      AS expira_em
  FROM pg_roles
 WHERE rolname = :'ro_user';

\echo ''
\echo '=== 2. Permissoes de ESCRITA (esperado: NENHUMA linha) ==='
SELECT n.nspname AS schema,
       c.relname AS objeto,
       string_agg(p.priv, ', ' ORDER BY p.priv) AS privilegio_indevido
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 CROSS JOIN LATERAL (VALUES ('INSERT'),('UPDATE'),('DELETE'),
                            ('TRUNCATE'),('REFERENCES'),('TRIGGER')) AS p(priv)
 WHERE c.relkind IN ('r','p','v','m','f')
   AND n.nspname NOT IN ('pg_catalog','information_schema')
   AND n.nspname NOT LIKE 'pg_toast%'
   AND has_table_privilege(:'ro_user', c.oid, p.priv)
 GROUP BY 1, 2
 ORDER BY 1, 2;

\echo ''
\echo '=== 3. Pode criar objetos em algum schema? (esperado: NENHUMA linha) ==='
SELECT nspname AS schema_com_create
  FROM pg_namespace
 WHERE nspname NOT LIKE 'pg_%'
   AND nspname <> 'information_schema'
   AND has_schema_privilege(:'ro_user', nspname, 'CREATE');

\echo ''
\echo '=== 4. O que ele CONSEGUE ler (confira se bate com o combinado) ==='
SELECT n.nspname AS schema,
       count(*) FILTER (WHERE c.relkind IN ('r','p')) AS tabelas,
       count(*) FILTER (WHERE c.relkind = 'v')        AS views,
       count(*) FILTER (WHERE c.relkind = 'm')        AS matviews
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r','p','v','m')
   AND n.nspname NOT IN ('pg_catalog','information_schema')
   AND n.nspname NOT LIKE 'pg_toast%'
   AND has_table_privilege(:'ro_user', c.oid, 'SELECT')
 GROUP BY 1
 ORDER BY 1;

\echo ''
\echo '=== 5. Default privileges: tabelas FUTURAS ficarao legiveis? ==='
\echo '    (precisa haver uma linha por schema liberado, com r=SELECT)'
SELECT pg_get_userbyid(d.defaclrole) AS quando_criado_por,
       n.nspname                     AS schema,
       CASE d.defaclobjtype WHEN 'r' THEN 'tabelas/views'
                            WHEN 'S' THEN 'sequences'
                            WHEN 'f' THEN 'functions'
                            ELSE d.defaclobjtype::text END AS tipo,
       d.defaclacl                   AS acl
  FROM pg_default_acl d
  LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
 ORDER BY 1, 2, 3;

\echo ''
\echo '=== 6. Configuracoes de sessao aplicadas ao usuario ==='
SELECT rolname AS usuario, unnest(rolconfig) AS configuracao
  FROM pg_roles
 WHERE rolname = :'ro_user';

\echo ''
\echo '=== 7. Teste manual final ==='
\echo 'Conecte com o usuario do terceiro e confirme que TODOS falham:'
\echo '    psql "host=HOST dbname=MEUBANCO user=' :ro_user ' sslmode=require"'
\echo ''
\echo '    INSERT INTO <tabela> (col) VALUES (1);   -- deve falhar'
\echo '    UPDATE <tabela> SET col = 0;             -- deve falhar'
\echo '    DELETE FROM <tabela>;                    -- deve falhar'
\echo '    CREATE TABLE teste_ro (id int);          -- deve falhar'
\echo '    DROP TABLE <tabela>;                     -- deve falhar'
\echo '    SELECT count(*) FROM <tabela>;           -- deve funcionar'
\echo ''
\echo 'Se algum dos cinco primeiros passar, sobrou GRANT em algum lugar.'
