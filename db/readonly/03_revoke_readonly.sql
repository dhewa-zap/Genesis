-- =============================================================================
-- Encerrar o acesso do terceiro (fim do projeto, troca de fornecedor, incidente)
-- =============================================================================
-- Uso:
--   psql -h HOST -U postgres -d MEUBANCO \
--        -v ro_user=dash_terceiro -v ro_role=ro_dashboard \
--        -f 03_revoke_readonly.sql
--
-- IMPORTANTE: roles sao objetos do CLUSTER, mas os privilegios ficam em cada
-- banco. Rode a parte 1 em TODOS os bancos onde os roles receberam GRANT,
-- e so depois a parte 2 (DROP ROLE), uma unica vez.
--
-- Se voce so quer cortar o acesso agora e decidir depois, o mais rapido e:
--   ALTER ROLE dash_terceiro NOLOGIN;
--   SELECT pg_terminate_backend(pid) FROM pg_stat_activity
--    WHERE usename = 'dash_terceiro';
-- =============================================================================

\set ON_ERROR_STOP on

\if :{?ro_user}
\else
\set ro_user dash_terceiro
\endif

\if :{?ro_role}
\else
\set ro_role ro_dashboard
\endif

-- Parte 0: derruba o login e mata as sessoes abertas.
ALTER ROLE :"ro_user" NOLOGIN;

SELECT pg_terminate_backend(pid) AS sessao_encerrada
  FROM pg_stat_activity
 WHERE usename = :'ro_user';

-- Parte 1: remove privilegios e default privileges NESTE banco.
-- DROP OWNED BY tambem limpa as entradas de ALTER DEFAULT PRIVILEGES,
-- que um simples REVOKE nao alcanca.
DROP OWNED BY :"ro_role", :"ro_user";

\echo 'Privilegios removidos neste banco. Repita em todos os outros bancos.'
\echo 'Depois, uma unica vez no cluster, rode a parte 2 abaixo.'

-- Parte 2: apagar os roles (descomente quando a parte 1 ja rodou em tudo).
-- DROP ROLE :"ro_user";
-- DROP ROLE :"ro_role";
