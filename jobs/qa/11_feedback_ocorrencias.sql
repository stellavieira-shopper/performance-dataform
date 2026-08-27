CREATE OR REPLACE TABLE `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Ocorrencias_Semana` AS

WITH Periodo AS (
  SELECT MAX(data_inicio_periodo) AS data_inicio
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Ranking Semanal`
),

Faltas AS (
  SELECT
    CAST(registration_number AS STRING) AS MATRICULA,
    reference_date AS data_ocorrencia,
    'FALTA' AS TIPO_OCORRENCIA,
    NULL AS descricao
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Expected Points Tratada`
  WHERE reference_date >= (SELECT data_inicio FROM Periodo)
    AND absence IS NOT NULL
    AND (motivo_consolidado IS NULL
         OR UPPER(motivo_consolidado) NOT LIKE '%FÉRIAS%'
         AND UPPER(motivo_consolidado) NOT LIKE '%FERIAS%'
         AND UPPER(motivo_consolidado) NOT LIKE '%ATESTADO%')
),

Atestados AS (
  SELECT
    CAST(registration_number AS STRING) AS MATRICULA,
    reference_date AS data_ocorrencia,
    'ATESTADO' AS TIPO_OCORRENCIA,
    motivo_consolidado AS descricao
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Expected Points Tratada`
  WHERE reference_date >= (SELECT data_inicio FROM Periodo)
    AND medical_certificate IS NOT NULL
),

Atrasos AS (
  SELECT
    CAST(registration_number AS STRING) AS MATRICULA,
    reference_date AS data_ocorrencia,
    'ATRASO' AS TIPO_OCORRENCIA,
    NULL AS descricao
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Expected Points Tratada`
  WHERE reference_date >= (SELECT data_inicio FROM Periodo)
    AND delay IS NOT NULL
),

DeclaracoesHoras AS (
  SELECT
    CAST(registration_number AS STRING) AS MATRICULA,
    reference_date AS data_ocorrencia,
    'DECLARAÇÃO DE HORAS' AS TIPO_OCORRENCIA,
    NULL AS descricao
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Expected Points Tratada`
  WHERE reference_date >= (SELECT data_inicio FROM Periodo)
    AND hours_declaration IS NOT NULL
),

Advertencias AS (
  SELECT
    CAST(Matricula AS STRING) AS MATRICULA,
    Data_Ocorrencia AS data_ocorrencia,
    'ADVERTÊNCIA' AS TIPO_OCORRENCIA,
    Tipo_Advertencia AS descricao
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Medidas Disciplinares `
  WHERE Data_Ocorrencia >= (SELECT data_inicio FROM Periodo)
    AND UPPER(TRIM(Tipo_Advertencia)) LIKE '%ADVERTÊN%'
),

Ferias AS (
  SELECT
    CAST(registration_number AS STRING) AS MATRICULA,
    reference_date AS data_ocorrencia,
    'FÉRIAS' AS TIPO_OCORRENCIA,
    motivo_consolidado AS descricao
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Expected Points Tratada`
  WHERE reference_date >= (SELECT data_inicio FROM Periodo)
    AND vacation IS NOT NULL
),

Todas AS (
  SELECT * FROM Faltas
  UNION ALL SELECT * FROM Atestados
  UNION ALL SELECT * FROM Atrasos
  UNION ALL SELECT * FROM DeclaracoesHoras
  UNION ALL SELECT * FROM Advertencias
  UNION ALL SELECT * FROM Ferias
)

SELECT
  t.MATRICULA,
  o.CRACHA,
  o.NOME,
  o.SETOR,
  o.TURNO,
  o.FC,
  t.data_ocorrencia,
  t.TIPO_OCORRENCIA,
  t.descricao,
  (SELECT data_inicio FROM Periodo) AS data_inicio_periodo
FROM Todas t
LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Organograma` o
  ON TRIM(CAST(t.MATRICULA AS STRING)) = TRIM(CAST(o.MATRICULA AS STRING));
