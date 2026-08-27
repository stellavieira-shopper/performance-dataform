BEGIN

  ALTER TABLE `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Nao_Mediveis`
  ADD COLUMN IF NOT EXISTS CRACHA STRING;

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Nao_Mediveis`
  WHERE data_inicio = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Colaboradores Nao Mediveis`
  );

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Nao_Mediveis`

  SELECT
    nm.data_inicio_periodo AS data_inicio,
    nm.data_fim_periodo AS data_final,
    CAST(o.CRACHA AS STRING) AS CRACHA,
    nm.MATRICULA,
    o.NOME,
    o.TURNO,
    nm.SETOR AS setor,
    nm.FC,
    nm.atribuicao,
    a.Direito_a_Premiacao AS assiduidade_status,
    kpi.OBSERVACAO_KPI AS observacao_kpi,
    nm.motivo_nao_mensuravel,
    nm.status_ranking,

    nm.pontuacao_nao_mensuravel AS pontuacao_atual,
    nm.classificacao_desempenho,

    nm.pontos_por_assiduidade,
    nm.pontos_por_kpi,
    nm.pontos_por_comportamento

  FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Colaboradores Nao Mediveis` nm
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Organograma` o
    ON CAST(nm.MATRICULA AS STRING) = CAST(o.MATRICULA AS STRING)
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Assiduidade` a
    ON TRIM(CAST(nm.MATRICULA AS STRING)) = TRIM(CAST(a.Matricula AS STRING))
   AND CAST(nm.data_inicio_periodo AS DATE) = CAST(a.data_inicio_periodo AS DATE)
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.KPIs_OPERAÇÃO` kpi
    ON CAST(nm.MATRICULA AS STRING) = CAST(kpi.MATRICULA AS STRING)
   AND CAST(nm.data_inicio_periodo AS DATE) = CAST(kpi.data_inicio AS DATE)
  WHERE nm.data_inicio_periodo = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Colaboradores Nao Mediveis`
  );

END;
