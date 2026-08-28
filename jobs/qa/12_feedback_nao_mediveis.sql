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
    p.data_inicio_periodo AS data_inicio,
    p.data_fim_periodo    AS data_final,
    CAST(p.matricula AS STRING) AS MATRICULA,
    p.nome                AS NOME,
    UPPER(TRIM(p.fc))         AS FC,
    UPPER(TRIM(p.setor))      AS SETOR,
    UPPER(TRIM(p.turno))      AS TURNO,
    UPPER(TRIM(p.atribuicao)) AS ATRIBUICAO,
    p.pontuacao_atribuida  AS PONTUACAO_FINAL,
    p.valor_bonificacao    AS VALOR_BONIFICACAO,
    p.qtd_faltas           AS FALTAS,
    p.qtd_atestados        AS ATESTADOS,
    p.qtd_advertencias     AS ADVERTENCIAS,
    p.atrasos              AS ATRASOS,
    p.declaracao_horas     AS DECLARACAO_HORAS,
    p.saldo_da_carteira    AS SALDO_CARTEIRA,

    COALESCE(a.Direito_a_Premiacao, 'NÃO') AS ASSIDUIDADE,

    k.OBSERVACAO_KPI         AS OBSERVACAO_KPI,
    p.motivo_desqualificacao AS MOTIVO_DESQUALIFICACAO,

    CASE
      WHEN p.motivo_desqualificacao IS NOT NULL AND TRIM(p.motivo_desqualificacao) != ''
        THEN p.motivo_desqualificacao
      WHEN k.OBSERVACAO_KPI IS NOT NULL AND TRIM(k.OBSERVACAO_KPI) NOT IN ('NULL', '')
        THEN k.OBSERVACAO_KPI
      ELSE ''
    END AS OBSERVACAO_FINAL,

    o.CRACHA AS CRACHA

  FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Colaboradores Nao Mediveis` p

  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Assiduidade` a
    ON CAST(p.matricula AS STRING) = CAST(a.Matricula AS STRING)
   AND p.data_inicio_periodo = a.data_inicio_periodo

  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.KPIs_OPERAÇÃO` k
    ON CAST(p.matricula AS STRING) = CAST(k.MATRICULA AS STRING)
   AND p.data_inicio_periodo = k.data_inicio

  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Organograma` o
    ON p.matricula = o.MATRICULA

  WHERE p.data_inicio_periodo = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Colaboradores Nao Mediveis`
  );

END;
