BEGIN

  ALTER TABLE `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Fiscais`
  ADD COLUMN IF NOT EXISTS reforco_operacao BOOL;

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Fiscais`
  WHERE data_inicio = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais`
  );

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Fiscais`

  WITH FiscaisBase AS (
    SELECT
      f.*,
      LAG(f.pontuacao_fiscal) OVER (
        PARTITION BY CAST(f.MATRICULA AS STRING)
        ORDER BY f.data_inicio_periodo
      ) AS pontuacao_fiscal_anterior,
      LAG(f.ranking_posicao) OVER (
        PARTITION BY CAST(f.MATRICULA AS STRING)
        ORDER BY f.data_inicio_periodo
      ) AS ranking_anterior
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais` f
  ),

  Reforco_Operacao AS (
    SELECT DISTINCT
      CAST(TRIM(CAST(matricula AS STRING)) AS STRING) AS matricula
    FROM `shopper-datalakehouse-qa.Ranking_Performance.reforco_operacao`
    WHERE matricula IS NOT NULL
      AND TRIM(CAST(matricula AS STRING)) <> ''
  )

  SELECT
    f.data_inicio_periodo AS data_inicio,
    f.data_fim_periodo AS data_final,
    CAST(o.CRACHA AS STRING) AS CRACHA,
    f.MATRICULA,
    o.NOME,
    o.TURNO,
    f.SETOR AS setor,
    f.EQUIPE,
    f.FC,
    a.Direito_a_Premiacao AS assiduidade_status,
    kpi.OBSERVACAO_KPI AS observacao_kpi,
    f.motivo_desqualificacao,

    f.pontuacao_fiscal AS pontos_fiscais_atuais,
    COALESCE(f.pontuacao_fiscal_anterior, 0) AS pontos_fiscais_anterior,
    f.pontuacao_fiscal - COALESCE(f.pontuacao_fiscal_anterior, 0) AS delta_pontuacao,

    f.ranking_posicao AS posicao_atual,
    f.ranking_anterior AS posicao_anterior,
    COALESCE(f.ranking_anterior, 0) - f.ranking_posicao AS delta_posicao,

    f.total_colaboradores_avaliados,
    f.colaboradores_acima_1m,
    f.media_pontos_equipe,

    f.pontos_por_assiduidade,
    f.pontos_por_kpi,
    f.pontos_por_equipe,

    ROUND(SAFE_DIVIDE(f.pontuacao_fiscal - COALESCE(f.pontuacao_fiscal_anterior, 0), NULLIF(f.pontuacao_fiscal_anterior, 0)), 4) AS perc_evolucao,

    (
      COALESCE(f.pontuacao_fiscal_anterior, 0) > 0
      AND f.pontuacao_fiscal > f.pontuacao_fiscal_anterior
    ) AS boa_evolucao,

    IF(ro.matricula IS NOT NULL, TRUE, FALSE) AS reforco_operacao

  FROM FiscaisBase f
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Organograma` o
    ON CAST(f.MATRICULA AS STRING) = CAST(o.MATRICULA AS STRING)
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Assiduidade` a
    ON TRIM(CAST(f.MATRICULA AS STRING)) = TRIM(CAST(a.Matricula AS STRING))
   AND CAST(f.data_inicio_periodo AS DATE) = CAST(a.data_inicio_periodo AS DATE)
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.KPIs_OPERAÇÃO` kpi
    ON CAST(f.MATRICULA AS STRING) = CAST(kpi.MATRICULA AS STRING)
   AND CAST(f.data_inicio_periodo AS DATE) = CAST(kpi.data_inicio AS DATE)
  LEFT JOIN Reforco_Operacao ro
    ON TRIM(CAST(f.MATRICULA AS STRING)) = TRIM(ro.matricula)
  WHERE f.data_inicio_periodo = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais`
  );

END;
