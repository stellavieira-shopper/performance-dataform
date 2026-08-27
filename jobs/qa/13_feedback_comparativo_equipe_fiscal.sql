BEGIN

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Comparativo_Equipe_Fiscal`
  WHERE data_inicio = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Detalhada`
  );

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Comparativo_Equipe_Fiscal`

  WITH DetalhePeriodo AS (
    SELECT
      data_inicio_periodo,
      CAST(MATRICULA AS STRING) AS MATRICULA,
      CAST(MATRICULA_FISCAL AS STRING) AS MATRICULA_FISCAL,
      TRIM(supervisor_responsavel) AS supervisor_responsavel_raw,
      pontuacao_colaborador,
      total_itens_colaborador,
      setor,
      FC,
      turno
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Detalhada`
    WHERE data_inicio_periodo = (
      SELECT MAX(data_inicio_periodo)
      FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Detalhada`
    )
  ),

  Supervisores AS (
    SELECT
      MATRICULA,
      MATRICULA_FISCAL,
      supervisor_responsavel_raw,
      pontuacao_colaborador,
      total_itens_colaborador,
      setor,
      FC,
      turno,
      data_inicio_periodo,
      TRIM(sup_mat) AS matricula_supervisor
    FROM DetalhePeriodo,
    UNNEST(SPLIT(supervisor_responsavel_raw, '/')) AS sup_mat
    WHERE TRIM(sup_mat) <> ''
  ),

  Base AS (
    SELECT
      s.data_inicio_periodo,
      s.matricula_supervisor,
      s.MATRICULA_FISCAL,
      s.MATRICULA,
      s.pontuacao_colaborador,
      s.total_itens_colaborador,
      s.setor,
      s.FC,
      s.turno,
      LAG(s.pontuacao_colaborador) OVER (
        PARTITION BY s.MATRICULA, s.MATRICULA_FISCAL, s.matricula_supervisor
        ORDER BY s.data_inicio_periodo
      ) AS pontuacao_anterior,
      LAG(s.total_itens_colaborador) OVER (
        PARTITION BY s.MATRICULA, s.MATRICULA_FISCAL, s.matricula_supervisor
        ORDER BY s.data_inicio_periodo
      ) AS itens_anterior
    FROM Supervisores s
  )

  SELECT
    b.data_inicio_periodo AS data_inicio,
    b.matricula_supervisor,
    b.MATRICULA_FISCAL,
    b.MATRICULA,
    b.pontuacao_colaborador,
    b.total_itens_colaborador,
    b.setor,
    b.FC,
    b.turno,
    COALESCE(b.pontuacao_anterior, 0) AS pontuacao_anterior,
    COALESCE(b.itens_anterior, 0) AS itens_anterior,
    b.pontuacao_colaborador - COALESCE(b.pontuacao_anterior, 0) AS delta_pontuacao,
    b.total_itens_colaborador - COALESCE(b.itens_anterior, 0) AS delta_itens
  FROM Base b;

END;
