BEGIN

  ALTER TABLE `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Supervisores`
  ADD COLUMN IF NOT EXISTS reforco_operacao BOOL;

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Supervisores`
  WHERE data_inicio = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Supervisores`
  );

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Supervisores`

  WITH SupervisoresBase AS (
    SELECT
      s.*,
      LAG(s.pontuacao_supervisor) OVER (
        PARTITION BY CAST(s.MATRICULA AS STRING)
        ORDER BY s.data_inicio_periodo
      ) AS pontuacao_supervisor_anterior,
      LAG(s.ranking_posicao) OVER (
        PARTITION BY CAST(s.MATRICULA AS STRING)
        ORDER BY s.data_inicio_periodo
      ) AS ranking_anterior
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Supervisores` s
  ),

  Reforco_Operacao AS (
    SELECT DISTINCT
      CAST(TRIM(CAST(matricula AS STRING)) AS STRING) AS matricula
    FROM `shopper-datalakehouse-qa.Ranking_Performance.reforco_operacao`
    WHERE matricula IS NOT NULL
      AND TRIM(CAST(matricula AS STRING)) <> ''
  )

  SELECT
    s.data_inicio_periodo AS data_inicio,
    s.data_fim_periodo AS data_final,
    CAST(o.CRACHA AS STRING) AS CRACHA,
    s.MATRICULA,
    o.NOME,
    o.TURNO,
    s.SETOR AS setor,
    s.FC,
    a.Direito_a_Premiacao AS assiduidade_status,
    kpi.OBSERVACAO_KPI AS observacao_kpi,
    s.motivo_desqualificacao,

    s.pontuacao_supervisor AS pontos_supervisor_atuais,
    COALESCE(s.pontuacao_supervisor_anterior, 0) AS pontos_supervisor_anterior,
    s.pontuacao_supervisor - COALESCE(s.pontuacao_supervisor_anterior, 0) AS delta_pontuacao,

    s.ranking_posicao AS posicao_atual,
    s.ranking_anterior AS posicao_anterior,
    COALESCE(s.ranking_anterior, 0) - s.ranking_posicao AS delta_posicao,

    s.total_fiscais_avaliados,
    s.media_pontos_fiscais,
    s.fiscal_melhor_pontuado,
    s.fiscal_pior_pontuado,

    s.pontos_por_assiduidade,
    s.pontos_por_kpi,
    s.pontos_por_fiscais,

    ROUND(SAFE_DIVIDE(s.pontuacao_supervisor - COALESCE(s.pontuacao_supervisor_anterior, 0), NULLIF(s.pontuacao_supervisor_anterior, 0)), 4) AS perc_evolucao,

    (
      COALESCE(s.pontuacao_supervisor_anterior, 0) > 0
      AND s.pontuacao_supervisor > s.pontuacao_supervisor_anterior
    ) AS boa_evolucao,

    IF(ro.matricula IS NOT NULL, TRUE, FALSE) AS reforco_operacao

  FROM SupervisoresBase s
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Organograma` o
    ON CAST(s.MATRICULA AS STRING) = CAST(o.MATRICULA AS STRING)
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Assiduidade` a
    ON TRIM(CAST(s.MATRICULA AS STRING)) = TRIM(CAST(a.Matricula AS STRING))
   AND CAST(s.data_inicio_periodo AS DATE) = CAST(a.data_inicio_periodo AS DATE)
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.KPIs_OPERAÇÃO` kpi
    ON CAST(s.MATRICULA AS STRING) = CAST(kpi.MATRICULA AS STRING)
   AND CAST(s.data_inicio_periodo AS DATE) = CAST(kpi.data_inicio AS DATE)
  LEFT JOIN Reforco_Operacao ro
    ON TRIM(CAST(s.MATRICULA AS STRING)) = TRIM(ro.matricula)
  WHERE s.data_inicio_periodo = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Supervisores`
  );

END;
