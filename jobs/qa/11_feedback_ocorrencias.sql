CREATE OR REPLACE TABLE `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Ocorrencias_Semana` AS
WITH

RawPonto AS (
  SELECT
    SAFE_CAST(registration_number AS STRING) AS MATRICULA,
    reference_date AS DATA_EVENTO,
    DATE_TRUNC(reference_date, WEEK(FRIDAY)) AS data_inicio_periodo,
    DATE_ADD(DATE_TRUNC(reference_date, WEEK(FRIDAY)), INTERVAL 6 DAY) AS data_fim_periodo,
    absence, medical_certificate, delay, hours_declaration, vacation
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Expected Points Tratada`
  WHERE reference_date >= '2024-01-01'
),

RawMedidas AS (
  SELECT
    SAFE_CAST(MATRICULA AS STRING) AS MATRICULA,
    DATA_OCORRENCIA AS DATA_EVENTO,
    DATE_TRUNC(DATA_OCORRENCIA, WEEK(FRIDAY)) AS data_inicio_periodo,
    DATE_ADD(DATE_TRUNC(DATA_OCORRENCIA, WEEK(FRIDAY)), INTERVAL 6 DAY) AS data_fim_periodo,
    MOTIVO AS descricao_medida
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Medidas Disciplinares `
  WHERE APLICADA IS TRUE AND INDEVIDA IS FALSE AND DATA_OCORRENCIA >= '2024-01-01'
),

OcorrenciasIndividuais AS (
  SELECT MATRICULA, DATA_EVENTO, data_inicio_periodo, data_fim_periodo, 'FALTA' AS TIPO_OCORRENCIA, NULL AS INFO_EXTRA FROM RawPonto WHERE absence IS NOT NULL
  UNION ALL
  SELECT MATRICULA, DATA_EVENTO, data_inicio_periodo, data_fim_periodo, 'ATESTADO' AS TIPO_OCORRENCIA, NULL AS INFO_EXTRA FROM RawPonto WHERE medical_certificate IS NOT NULL
  UNION ALL
  SELECT MATRICULA, DATA_EVENTO, data_inicio_periodo, data_fim_periodo, 'ATRASO' AS TIPO_OCORRENCIA, CAST(delay AS STRING) AS INFO_EXTRA FROM RawPonto WHERE delay IS NOT NULL AND delay > '00:00:00'
  UNION ALL
  SELECT MATRICULA, DATA_EVENTO, data_inicio_periodo, data_fim_periodo, 'DECLARAÇÃO DE HORAS' AS TIPO_OCORRENCIA, CAST(hours_declaration AS STRING) AS INFO_EXTRA FROM RawPonto WHERE hours_declaration IS NOT NULL AND hours_declaration > '00:00:00'
  UNION ALL
  SELECT MATRICULA, DATA_EVENTO, data_inicio_periodo, data_fim_periodo, 'ADVERTÊNCIA' AS TIPO_OCORRENCIA, COALESCE(descricao_medida, 'Sem motivo') AS INFO_EXTRA FROM RawMedidas
  UNION ALL
  SELECT MATRICULA, DATA_EVENTO, data_inicio_periodo, data_fim_periodo, 'FÉRIAS' AS TIPO_OCORRENCIA, NULL AS INFO_EXTRA FROM RawPonto WHERE vacation IS NOT NULL
),

AgrupamentoFinal AS (
  SELECT
    MATRICULA,
    data_inicio_periodo AS DATA_INICIO,
    data_fim_periodo AS DATA_FINAL,
    TIPO_OCORRENCIA,
    COUNT(*) AS QTD_OCORRENCIAS,
    STRING_AGG(
      CASE
        WHEN TIPO_OCORRENCIA IN ('ATRASO', 'DECLARAÇÃO DE HORAS', 'ADVERTÊNCIA') THEN CONCAT(FORMAT_DATE('%d/%m', DATA_EVENTO), ' (', INFO_EXTRA, ')')
        ELSE FORMAT_DATE('%d/%m', DATA_EVENTO)
      END,
      ' | ' ORDER BY DATA_EVENTO ASC
    ) AS LISTA_DETALHES
  FROM OcorrenciasIndividuais
  GROUP BY MATRICULA, data_inicio_periodo, data_fim_periodo, TIPO_OCORRENCIA
)

SELECT
  o.MATRICULA,
  org.CRACHA,
  o.DATA_INICIO,
  o.DATA_FINAL,
  o.TIPO_OCORRENCIA,
  o.QTD_OCORRENCIAS,
  o.LISTA_DETALHES
FROM AgrupamentoFinal o
LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Organograma` org
  ON SAFE_CAST(o.MATRICULA AS INT64) = SAFE_CAST(org.MATRICULA AS INT64)
ORDER BY o.MATRICULA, o.DATA_INICIO DESC, o.TIPO_OCORRENCIA;
