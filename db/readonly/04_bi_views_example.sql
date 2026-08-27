-- =============================================================================
-- Camada de views para BI (recomendado quando ha dado pessoal - LGPD)
-- =============================================================================
-- Em vez de liberar as tabelas cruas, exponha um schema "bi" com apenas as
-- colunas que o dashboard precisa. Ganhos:
--   - o terceiro nunca ve CPF, e-mail, telefone, salario;
--   - voce refatora a tabela real sem quebrar o dashboard dele;
--   - o contrato de dados fica explicito e versionado aqui.
--
-- Neste modelo NAO conceda USAGE no schema public ao role de leitura:
--   rode o 01 com -v ro_schemas=bi
-- =============================================================================

\set ON_ERROR_STOP on

\if :{?ro_role}
\else
\set ro_role ro_dashboard
\endif

BEGIN;

CREATE SCHEMA IF NOT EXISTS bi;

-- As views rodam com os privilegios do DONO (security definer implicito das
-- views comuns), entao o role de leitura enxerga os dados sem precisar de
-- qualquer permissao na tabela de origem.
COMMENT ON SCHEMA bi IS 'Camada de leitura exposta a terceiros (dashboards). Sem dado pessoal.';

-- ---------------------------------------------------------------------------
-- Exemplo. Troque pelos objetos reais do seu banco.
-- ---------------------------------------------------------------------------
-- CREATE OR REPLACE VIEW bi.vendas AS
-- SELECT v.id,
--        v.criado_em::date        AS data,
--        v.valor,
--        v.produto_id,
--        c.regiao                 -- dimensao ok
--        -- c.cpf, c.email, c.telefone  <- NUNCA aqui
--   FROM public.vendas v
--   JOIN public.clientes c ON c.id = v.cliente_id;
--
-- Precisa expor o cliente sem identifica-lo? Use um pseudonimo estavel:
-- CREATE OR REPLACE VIEW bi.clientes AS
-- SELECT encode(digest(c.id::text || current_setting('genesis.salt'), 'sha256'), 'hex')
--          AS cliente_hash,
--        c.regiao,
--        c.segmento,
--        date_trunc('month', c.criado_em) AS coorte
--   FROM public.clientes c;

GRANT USAGE ON SCHEMA bi TO :"ro_role";
GRANT SELECT ON ALL TABLES IN SCHEMA bi TO :"ro_role";
ALTER DEFAULT PRIVILEGES IN SCHEMA bi GRANT SELECT ON TABLES TO :"ro_role";

-- O role de leitura nao pode criar nada dentro de bi.
REVOKE CREATE ON SCHEMA bi FROM PUBLIC, :"ro_role";

COMMIT;
