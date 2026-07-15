CREATE OR REPLACE VIEW `shopper-performance-prod.operacao.curated_erros_gestao_estoque`
OPTIONS (description = 'Erros de gestão de estoque por colaborador/semana, com penalidade de pontos.')
AS
WITH erros_dedup AS (
  SELECT MATRICULA, NOME, FC, DATA, IMPACTO_ERRO
  FROM `shopper-performance-prod.operacao.curated_detratoras_stock`
  WHERE MATRICULA IS NOT NULL
    AND DATA IS NOT NULL
    AND UPPER(TRIM(IMPACTO_ERRO)) NOT IN ('RUPTURA', 'PERDA')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY MATRICULA, DATA, DESC_ERRO, PRODUTO, CODIGO
    ORDER BY DATA
  ) = 1
),
erros_semana AS (
  SELECT
    SAFE_CAST(MATRICULA AS INT64)                                           AS registration_number,
    CAST(NOME AS STRING)                                                    AS user_name,
    CAST(FC AS STRING)                                                      AS fc,
    DATE_TRUNC(CAST(DATA AS DATE), WEEK(FRIDAY))                           AS semana_inicio,
    DATE_ADD(DATE_TRUNC(CAST(DATA AS DATE), WEEK(FRIDAY)), INTERVAL 6 DAY) AS semana_fim,
    COUNT(*) AS qtd_erros
  FROM erros_dedup
  GROUP BY 1, 2, 3, 4, 5
)
SELECT
  registration_number, user_name, fc, semana_inicio, semana_fim,
  semana_fim AS reference_date, qtd_erros,
  CASE
    WHEN qtd_erros = 1 THEN 100000.0
    WHEN qtd_erros = 2 THEN 300000.0
    WHEN qtd_erros = 3 THEN 500000.0
    ELSE NULL
  END AS penalidade_pts,
  qtd_erros > 3 AS zerado
FROM erros_semana;
