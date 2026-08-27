-- =============================================================================
-- Acesso somente-leitura para terceiro (dashboard / BI)
-- =============================================================================
-- Cria um role de permissao (NOLOGIN) + um usuario de login que o herda,
-- concede apenas SELECT nos schemas indicados e garante que TABELAS FUTURAS
-- tambem fiquem legiveis, sem nunca permitir escrita.
--
-- Uso:
--   psql -h HOST -U postgres -d MEUBANCO \
--        -v ro_user=dash_terceiro \
--        -v app_owner=app_user \
--        -v ro_schemas=public \
--        -v valid_until='2026-12-31' \
--        -f 01_create_readonly_role.sql
--
-- Depois defina a senha SEM que ela va parar no log/historico:
--   \password dash_terceiro
--
-- Parametros (todos opcionais, com default):
--   ro_role     nome do role de permissao          (default: ro_dashboard)
--   ro_user     nome do usuario que loga           (default: dash_terceiro)
--   ro_schemas  schemas liberados, separados por , (default: public)
--   app_owner   role dono das tabelas; necessario para que as tabelas
--               criadas no futuro ja nascam legiveis (default: usuario atual)
--   valid_until data de expiracao do login         (default: sem expiracao)
--   max_conn    limite de conexoes simultaneas     (default: 5)
--
-- Requer: PostgreSQL 10+ (usa \if do psql).
-- =============================================================================

\set ON_ERROR_STOP on

\if :{?ro_role}
\else
\set ro_role ro_dashboard
\endif

\if :{?ro_user}
\else
\set ro_user dash_terceiro
\endif

\if :{?ro_schemas}
\else
\set ro_schemas public
\endif

\if :{?app_owner}
\else
\set app_owner ''
\endif

\if :{?valid_until}
\else
\set valid_until ''
\endif

\if :{?max_conn}
\else
\set max_conn 5
\endif

\echo 'Configurando acesso somente-leitura...'
\echo '  role de permissao :' :ro_role
\echo '  usuario de login  :' :ro_user
\echo '  schemas           :' :ro_schemas
\echo '  dono das tabelas  :' :app_owner

BEGIN;

-- Os nomes sao dinamicos, entao passamos por GUCs de sessao para poder
-- montar o DDL com format(%I) e evitar qualquer chance de SQL injection.
SET LOCAL genesis.ro_role     = :'ro_role';
SET LOCAL genesis.ro_user     = :'ro_user';
SET LOCAL genesis.ro_schemas  = :'ro_schemas';
SET LOCAL genesis.app_owner   = :'app_owner';
SET LOCAL genesis.valid_until = :'valid_until';
SET LOCAL genesis.max_conn    = :'max_conn';

DO $$
DECLARE
  v_role    text   := current_setting('genesis.ro_role');
  v_user    text   := current_setting('genesis.ro_user');
  v_owner   text   := nullif(current_setting('genesis.app_owner'), '');
  v_valid   text   := nullif(current_setting('genesis.valid_until'), '');
  v_maxconn int    := current_setting('genesis.max_conn')::int;
  v_schemas text[] := string_to_array(
                        replace(current_setting('genesis.ro_schemas'), ' ', ''), ',');
  v_schema  text;
  v_matview record;
BEGIN
  ---------------------------------------------------------------------------
  -- 1. Role de permissao (NOLOGIN) e usuario de login que o herda.
  --    Separar os dois permite trocar/revogar o usuario sem refazer os GRANTs.
  ---------------------------------------------------------------------------
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
    EXECUTE format('CREATE ROLE %I NOLOGIN', v_role);
    RAISE NOTICE 'role % criado', v_role;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_user) THEN
    -- PASSWORD NULL: o login fica impossivel ate voce definir a senha
    -- com \password, que nao grava a senha em log nem no historico do psql.
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD NULL CONNECTION LIMIT %s',
                   v_user, v_maxconn);
    RAISE NOTICE 'usuario % criado (sem senha ainda - use \password %)', v_user, v_user;
  ELSE
    EXECUTE format('ALTER ROLE %I CONNECTION LIMIT %s', v_user, v_maxconn);
  END IF;

  -- Garantias explicitas: o usuario nao pode criar bancos, roles, nem burlar RLS.
  EXECUTE format('ALTER ROLE %I NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION',
                 v_user);

  IF v_valid IS NOT NULL THEN
    EXECUTE format('ALTER ROLE %I VALID UNTIL %L', v_user, v_valid);
    RAISE NOTICE 'login de % expira em %', v_user, v_valid;
  END IF;

  EXECUTE format('GRANT %I TO %I', v_role, v_user);

  ---------------------------------------------------------------------------
  -- 2. Nivel de banco: tira o acesso implicito de PUBLIC e libera so o CONNECT.
  ---------------------------------------------------------------------------
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), v_role);

  ---------------------------------------------------------------------------
  -- 3. Por schema: leitura sim, criacao de objetos nao.
  ---------------------------------------------------------------------------
  FOREACH v_schema IN ARRAY v_schemas LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema) THEN
      RAISE EXCEPTION 'schema % nao existe neste banco (%)', v_schema, current_database();
    END IF;

    -- Ate o PG 14 o schema public dava CREATE a PUBLIC por padrao.
    EXECUTE format('REVOKE CREATE ON SCHEMA %I FROM PUBLIC', v_schema);
    EXECUTE format('REVOKE CREATE ON SCHEMA %I FROM %I', v_schema, v_role);

    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I', v_schema, v_role);

    -- GRANT ... ON ALL TABLES nem sempre alcanca materialized views:
    -- concedemos uma a uma para nao deixar buraco.
    FOR v_matview IN
      SELECT c.oid::regclass AS rel
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = v_schema AND c.relkind = 'm'
    LOOP
      EXECUTE format('GRANT SELECT ON %s TO %I', v_matview.rel, v_role);
    END LOOP;

    -------------------------------------------------------------------------
    -- 4. TABELAS FUTURAS. Este e o passo que quase todo mundo esquece:
    --    sem ele, toda tabela nova fica invisivel para o dashboard e alguem
    --    "resolve" mais tarde dando permissao demais.
    --
    --    ALTER DEFAULT PRIVILEGES so vale para objetos criados pelo role
    --    indicado em FOR ROLE. Se as migrations rodam como app_user, e
    --    app_user que precisa estar aqui - nao o superusuario que executa
    --    este script.
    -------------------------------------------------------------------------
    IF v_owner IS NULL THEN
      RAISE WARNING 'app_owner nao informado: tabelas futuras criadas por outro role NAO ficarao legiveis. Rode de novo com -v app_owner=<dono_das_tabelas>.';
      EXECUTE format(
        'ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO %I',
        v_schema, v_role);
      EXECUTE format(
        'ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON SEQUENCES TO %I',
        v_schema, v_role);
    ELSE
      EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON TABLES TO %I',
        v_owner, v_schema, v_role);
      EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON SEQUENCES TO %I',
        v_owner, v_schema, v_role);
    END IF;

    RAISE NOTICE 'schema % liberado para leitura', v_schema;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 5. Cintos de seguranca operacionais.
--
--    ATENCAO: default_transaction_read_only e defesa em profundidade, NAO e
--    o controle de acesso. O proprio cliente pode desligar essa flag na
--    sessao dele. Quem realmente impede escrita sao os GRANTs acima - por
--    isso o script nunca concede INSERT/UPDATE/DELETE.
--
--    Os timeouts evitam que uma consulta pesada de dashboard segure lock ou
--    conexao na producao.
-- ---------------------------------------------------------------------------
ALTER ROLE :"ro_user" SET default_transaction_read_only = on;
ALTER ROLE :"ro_user" SET statement_timeout = '60s';
ALTER ROLE :"ro_user" SET idle_in_transaction_session_timeout = '120s';
ALTER ROLE :"ro_user" SET lock_timeout = '5s';

COMMIT;

\echo ''
\echo 'Pronto. Agora defina a senha (nao entra em log nem no historico):'
\echo '    \\password' :ro_user
\echo 'E rode 02_verify_readonly.sql para conferir que nao sobrou permissao de escrita.'
