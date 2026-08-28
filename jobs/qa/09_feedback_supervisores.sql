BEGIN

  ALTER TABLE `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Supervisores`
  ADD COLUMN IF NOT EXISTS reforco_operacao BOOL;

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Supervisores`
  WHERE data_inicio = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Supervisores`
  );

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Supervisores`
  WITH Base_Historico_Supervisores AS (
    SELECT
      ps.*,
      LAG(ps.pontuacao_combinada_supervisor) OVER (
        PARTITION BY ps.matricula_supervisor
        ORDER BY ps.data_inicio_periodo
      ) AS pontuacao_combinada_anterior
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Supervisores` ps
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
      s.data_inicio_periodo AS data_inicio,
      s.data_fim_periodo AS data_final,
      CAST(o.CRACHA AS STRING) AS CRACHA,
      s.matricula_supervisor AS MATRICULA,
      s.nome_supervisor AS NOME,

      s.turno AS TURNO,
      s.setor AS SETOR,
      s.atribuicao_supervisor AS ATRIBUICAO,

      s.FC AS FC,
      a.Direito_a_Premiacao AS assiduidade_status,

      CASE
        WHEN COALESCE(s.valor_bonificacao_supervisor, 0) > 0 THEN 'BONIFICADO'
        WHEN s.motivos_desqualificacao_supervisor IS NULL
          OR TRIM(s.motivos_desqualificacao_supervisor) = ''
          OR TRIM(s.motivos_desqualificacao_supervisor) = 'Elegível' THEN 'ELEGÍVEL'
        ELSE 'DESQUALIFICADO'
      END AS status_ranking,

      kpi.OBSERVACAO_KPI AS observacao_kpi,

      CASE
        WHEN COALESCE(s.valor_bonificacao_supervisor, 0) > 0 THEN NULL
        WHEN TRIM(s.motivos_desqualificacao_supervisor) = 'Elegível' THEN NULL
        ELSE s.motivos_desqualificacao_supervisor
      END AS motivo_desqualificacao,

      s.pontuacao_individual_supervisor,
      s.media_pontuacao_setor AS media_pontuacao_equipe,
      s.pontuacao_combinada_supervisor AS pontos_finais_atuais,

      COALESCE(s.pontuacao_combinada_anterior, 0) AS pontos_finais_anterior,
      (COALESCE(s.pontuacao_combinada_supervisor, 0) - COALESCE(s.pontuacao_combinada_anterior, 0)) AS delta_pontuacao,

      s.total_pessoas_setor,
      s.total_fiscais_setor,
      s.total_colaboradores_setor,
      s.total_bonificados_setor,

      s.sup_contagem_faltas AS FALTAS,
      s.sup_contagem_atestados AS ATESTADOS,
      s.sup_contagem_advertencias AS ADVERTENCIAS,
      s.sup_contagem_alocacoes_indevidas AS ALOCACAO_INDEVIDA,
      s.sup_atrasos AS ATRASOS,
      s.sup_declaracao_horas AS DECLARACAO_HORAS,

      s.saldo_da_carteira,

      IF(ro.matricula IS NOT NULL, TRUE, FALSE) AS reforco_operacao

    FROM Base_Historico_Supervisores s
    LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Organograma` o
      ON CAST(s.matricula_supervisor AS STRING) = CAST(o.MATRICULA AS STRING)
    LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.KPIs_OPERAÇÃO` kpi
      ON CAST(s.matricula_supervisor AS STRING) = CAST(kpi.MATRICULA AS STRING)
     AND s.data_inicio_periodo = kpi.data_inicio
    LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Assiduidade` a
      ON CAST(s.matricula_supervisor AS STRING) = CAST(a.Matricula AS STRING)
     AND s.data_inicio_periodo = a.data_inicio_periodo
    LEFT JOIN Reforco_Operacao ro
      ON CAST(s.matricula_supervisor AS STRING) = ro.matricula
  )

  SELECT *
  FROM Calculo_Final
  WHERE data_inicio = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Supervisores`
  );

END;
