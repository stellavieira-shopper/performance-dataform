BEGIN

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Comparativo_Equipe_Fiscal`
  WHERE data_inicio = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Detalhada`
  );

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Comparativo_Equipe_Fiscal`
  WITH Base_Tratada AS (
    SELECT
      data_inicio_periodo,
      data_fim_periodo,
      matricula_colaborador,
      nome_colaborador,
      setor_colaborador,
      turno_colaborador,
      area_colaborador,
      fc_colaborador,
      fiscal_responsavel,
      atribuicao_colaborador,
      motivos_desqualificacao,
      status_ranking_final,
      pontuacao_final,
      quantidade_itens_setor,
      taxa_erros_setor,
      valor_bonificacao_final,
      TRIM(s) AS supervisor_indiv
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Detalhada`,
    UNNEST(SPLIT(supervisor_responsavel, '/')) AS s
  ),

  Calculo_Com_Lag AS (
    SELECT
      *,
      LAG(pontuacao_final) OVER (PARTITION BY matricula_colaborador, fiscal_responsavel ORDER BY data_inicio_periodo) AS pontuacao_anterior,
      LAG(quantidade_itens_setor) OVER (PARTITION BY matricula_colaborador, fiscal_responsavel ORDER BY data_inicio_periodo) AS itens_anterior
    FROM Base_Tratada
  )

  SELECT
    data_inicio_periodo AS data_inicio,
    data_fim_periodo AS data_final,
    matricula_colaborador AS MATRICULA,
    nome_colaborador AS NOME,
    setor_colaborador AS SETOR,
    turno_colaborador AS TURNO,
    area_colaborador AS AREA,
    fc_colaborador AS FC,
    fiscal_responsavel AS FISCAL,
    atribuicao_colaborador AS ATRIBUICAO,
    motivos_desqualificacao,
    supervisor_indiv AS SUPERVISOR,
    status_ranking_final AS status_ranking,
    COALESCE(pontuacao_final, 0) AS pontuacao_atual,
    COALESCE(quantidade_itens_setor, 0) AS itens_atual,
    COALESCE(taxa_erros_setor, 0) AS taxa_erro_atual,
    (COALESCE(pontuacao_final, 0) - COALESCE(pontuacao_anterior, pontuacao_final)) AS delta_pontuacao,
    (COALESCE(quantidade_itens_setor, 0) - COALESCE(itens_anterior, quantidade_itens_setor)) AS delta_itens,
    0 AS delta_taxa_erro,
    valor_bonificacao_final AS valor_bonus
  FROM Calculo_Com_Lag
  WHERE data_inicio_periodo = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Detalhada`
  );

END;
