CREATE OR REPLACE TABLE `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Comparativo_Atividades` AS

WITH Base AS (
  SELECT
    CAST(MATRICULA AS STRING) AS MATRICULA,
    data_inicio_periodo AS semana,
    ATIVIDADE,
    TIPO,
    CLASSIFICACAO_ERRO,
    QTD_OCORRENCIAS,
    TAXA_ERRO,
    LAG(QTD_OCORRENCIAS) OVER (
      PARTITION BY CAST(MATRICULA AS STRING), ATIVIDADE, TIPO, CLASSIFICACAO_ERRO
      ORDER BY data_inicio_periodo
    ) AS QTD_ANTERIOR,
    LAG(TAXA_ERRO) OVER (
      PARTITION BY CAST(MATRICULA AS STRING), ATIVIDADE, TIPO, CLASSIFICACAO_ERRO
      ORDER BY data_inicio_periodo
    ) AS TAXA_ANTERIOR,
    LAG(data_inicio_periodo) OVER (
      PARTITION BY CAST(MATRICULA AS STRING), ATIVIDADE, TIPO, CLASSIFICACAO_ERRO
      ORDER BY data_inicio_periodo
    ) AS semana_anterior
  FROM `shopper-datalakehouse-qa.Ranking_Performance.View_Detalhe_Atividades_Semanal`
)

SELECT
  MATRICULA,
  semana AS data_inicio,
  ATIVIDADE,
  TIPO,
  CLASSIFICACAO_ERRO,
  QTD_OCORRENCIAS,
  TAXA_ERRO,
  QTD_ANTERIOR,
  TAXA_ANTERIOR,
  semana_anterior,

  CASE
    WHEN QTD_ANTERIOR IS NULL OR DATE_DIFF(semana, semana_anterior, DAY) <> 7
      THEN NULL
    ELSE QTD_OCORRENCIAS - QTD_ANTERIOR
  END AS EVOLUCAO_QTD,

  CASE
    WHEN TAXA_ANTERIOR IS NULL OR DATE_DIFF(semana, semana_anterior, DAY) <> 7
      THEN NULL
    ELSE ROUND(TAXA_ERRO - TAXA_ANTERIOR, 4)
  END AS EVOLUCAO_TAXA

FROM Base
WHERE semana = (
  SELECT MAX(data_inicio_periodo)
  FROM `shopper-datalakehouse-qa.Ranking_Performance.View_Detalhe_Atividades_Semanal`
);
