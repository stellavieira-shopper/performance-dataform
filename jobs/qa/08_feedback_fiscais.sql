BEGIN

  ALTER TABLE `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Fiscais`
  ADD COLUMN IF NOT EXISTS reforco_operacao BOOL;

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Fiscais`
  WHERE data_inicio = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais`
  );

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Fiscais`
  WITH Base_Historico_Fiscais AS (
    SELECT
      pf.*,
      LAG(pf.pontuacao_combinada_fiscal) OVER (
        PARTITION BY pf.matricula_fiscal
        ORDER BY pf.data_inicio_periodo
      ) AS pontuacao_combinada_anterior
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais` pf
  ),

  Supervisores_Detalhados AS (
    SELECT
      data_inicio_periodo,
      CAST(matricula_colaborador AS STRING) AS matricula,
      ANY_VALUE(supervisor_responsavel) AS supervisor_responsavel
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Detalhada`
    GROUP BY 1, 2
  ),

  Reforco_Operacao AS (
    SELECT DISTINCT
      CAST(TRIM(matricula) AS STRING) AS matricula
    FROM `shopper-datalakehouse-qa.Ranking_Performance.reforco_operacao`
    WHERE matricula IS NOT NULL
      AND TRIM(CAST(matricula AS STRING)) <> ''
  ),

  Calculo_Final AS (
    SELECT
      f.data_inicio_periodo AS data_inicio,
      f.data_fim_periodo AS data_final,
      CAST(o.CRACHA AS STRING) AS CRACHA,
      f.matricula_fiscal AS MATRICULA,
      f.nome_fiscal AS NOME,

      f.turno AS TURNO,
      f.setor AS SETOR,
      f.area AS AREA,
      f.atribuicao_fiscal AS ATRIBUICAO,

      COALESCE(sd.supervisor_responsavel, f.supervisor_responsavel) AS SUPERVISOR,

      f.fc AS FC,
      a.Direito_a_Premiacao AS assiduidade_status,

      CASE
        WHEN COALESCE(f.valor_bonificacao_fiscal, 0) > 0 THEN 'BONIFICADO'
        WHEN f.motivos_desqualificacao_fiscal IS NULL
          OR TRIM(f.motivos_desqualificacao_fiscal) = ''
          OR TRIM(f.motivos_desqualificacao_fiscal) = 'Elegível' THEN 'ELEGÍVEL'
        ELSE 'DESQUALIFICADO'
      END AS status_ranking,

      kpi.OBSERVACAO_KPI AS observacao_kpi,

      CASE
        WHEN COALESCE(f.valor_bonificacao_fiscal, 0) > 0 THEN NULL
        WHEN TRIM(f.motivos_desqualificacao_fiscal) = 'Elegível' THEN NULL
        ELSE f.motivos_desqualificacao_fiscal
      END AS motivo_desqualificacao,

      f.observacao_final,

      f.pontuacao_individual_fiscal,
      f.media_pontuacao_equipe,
      f.pontuacao_combinada_fiscal AS pontos_finais_atuais,

      COALESCE(f.pontuacao_combinada_anterior, 0) AS pontos_finais_anterior,
      (COALESCE(f.pontuacao_combinada_fiscal, 0) - COALESCE(f.pontuacao_combinada_anterior, 0)) AS delta_pontuacao,

      f.total_colaboradores_na_equipe,
      f.total_bonificados_equipe,

      f.faltas_fiscal AS FALTAS,
      f.atestados_fiscal AS ATESTADOS,
      f.advertencias_fiscal AS ADVERTENCIAS,
      f.alocacoes_indevidas_fiscal AS ALOCACAO_INDEVIDA,
      f.fiscal_atrasos AS ATRASOS,
      f.fiscal_declaracao_horas AS DECLARACAO_HORAS,

      f.quantidade_pedidos_expressos,
      f.quantidade_colaboradores_expressos,

      f.media_tempo_espera_express AS tempo_medio_expresso,

      f.saldo_da_carteira,

      IF(ro.matricula IS NOT NULL, TRUE, FALSE) AS reforco_operacao

    FROM Base_Historico_Fiscais f
    LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Organograma` o
      ON CAST(f.matricula_fiscal AS STRING) = CAST(o.MATRICULA AS STRING)
    LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.KPIs_OPERAÇÃO` kpi
      ON CAST(f.matricula_fiscal AS STRING) = CAST(kpi.MATRICULA AS STRING)
     AND f.data_inicio_periodo = kpi.data_inicio
    LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Assiduidade` a
      ON CAST(f.matricula_fiscal AS STRING) = CAST(a.Matricula AS STRING)
     AND f.data_inicio_periodo = a.data_inicio_periodo
    LEFT JOIN Supervisores_Detalhados sd
      ON CAST(f.matricula_fiscal AS STRING) = sd.matricula
     AND f.data_inicio_periodo = sd.data_inicio_periodo
    LEFT JOIN Reforco_Operacao ro
      ON CAST(f.matricula_fiscal AS STRING) = ro.matricula
  )

  SELECT *
  FROM Calculo_Final
  WHERE data_inicio = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais`
  );

END;
