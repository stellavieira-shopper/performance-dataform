-- Schema vazio — popular via INSERT abaixo (lê de assiduidade_resultados do QA)
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_bonificacao_faltas`
(
  store_code           STRING,
  nome                 STRING,
  mat                  STRING,
  year_ref             INT64,
  week_ref             INT64,
  periodo_inicio       DATE,
  periodo_fim          DATE,
  assiduidade_any_flag BOOL,
  faltas_num           INT64,
  atestados_num        INT64,
  advertencias_num     INT64,
  suspensoes_num       INT64,
  motivo               STRING,
  tem_direito          STRING
);

-- ============================================================
-- INSERT — executar após criar a tabela, substituindo:
--   [YEAR_REF]  → ano ISO da semana  (ex: 2026)
--   [WEEK_REF]  → semana ISO         (ex: 22)
--   [INICIO]    → data início período (ex: '2026-05-23')
--   [FIM]       → data fim período    (ex: '2026-05-29')
-- ============================================================

DELETE FROM `shopper-performance-prod.darkstore.raw_bonificacao_faltas`
WHERE year_ref = [YEAR_REF] AND week_ref = [WEEK_REF];

INSERT INTO `shopper-performance-prod.darkstore.raw_bonificacao_faltas`
SELECT
  LOWER(TRIM(org.setor))                                    AS store_code,
  UPPER(TRIM(org.nome))                                     AS nome,
  org.mat,
  [YEAR_REF]                                                AS year_ref,
  [WEEK_REF]                                                AS week_ref,
  DATE(a.periodo_inicio)                                    AS periodo_inicio,
  DATE(a.periodo_fim)                                       AS periodo_fim,
  CASE WHEN a.tem_direito = 'Sim' THEN FALSE ELSE TRUE END  AS assiduidade_any_flag,
  CASE WHEN a.tem_direito = 'Sim' THEN 0    ELSE 1    END  AS faltas_num,
  0 AS atestados_num,
  0 AS advertencias_num,
  0 AS suspensoes_num,
  a.motivo,
  a.tem_direito
FROM `shopper-datalakehouse-qa.Ranking_Performance.assiduidade_resultados` a
INNER JOIN `shopper-performance-prod.darkstore.raw_bonificacao_cargos` org
  ON a.matricula = org.mat
WHERE a.periodo_inicio = '[INICIO]'
  AND a.periodo_fim    = '[FIM]'
  AND UPPER(TRIM(org.fun_o)) NOT IN ('APRENDIZ', '');
