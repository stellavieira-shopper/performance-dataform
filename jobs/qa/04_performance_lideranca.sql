-- ██████████ SCRIPT FINAL UNIFICADO: PERFORMANCE LIDERANÇA + DETALHADA ██████████
BEGIN

  DECLARE v_start_date DATE;
  DECLARE v_end_date DATE;

  SET (v_start_date, v_end_date) = (
    SELECT AS STRUCT
      CASE
        WHEN dow IN (4, 5) THEN anchor_friday
        ELSE DATE_SUB(anchor_friday, INTERVAL 7 DAY)
      END,
      CASE
        WHEN dow IN (4, 5) THEN DATE_ADD(anchor_friday, INTERVAL 6 DAY)
        ELSE DATE_SUB(anchor_friday, INTERVAL 1 DAY)
      END
    FROM (
      SELECT
        current_dt,
        EXTRACT(DAYOFWEEK FROM current_dt) AS dow,
        DATE_SUB(current_dt, INTERVAL MOD(EXTRACT(DAYOFWEEK FROM current_dt) - 6 + 7, 7) DAY) AS anchor_friday
      FROM (SELECT CURRENT_DATE('America/Sao_Paulo') AS current_dt)
    )
  );

  CREATE OR REPLACE TEMP TABLE tmp_DadosAfastamentos AS
  SELECT
    SAFE_CAST(Matricula AS INT64) AS MATRICULA,
    STRING_AGG(DISTINCT Motivo, ', ') AS motivo_afastamento
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Afastamentos`
  WHERE Data_inicio <= v_end_date
    AND Data_final >= v_start_date
    AND UPPER(TRIM(Motivo)) IN (
      'AFASTAMENTO INSS',
      'AFASTAMENTO NÃO REMUNERADO',
      'LICENÇA MATERNIDADE',
      'FÉRIAS'
    )
  GROUP BY 1;

  CREATE OR REPLACE TEMP TABLE tmp_DadosPonto AS
  SELECT
    SAFE_CAST(registration_number AS INT64) AS MATRICULA,
    COUNTIF(absence IS NOT NULL) AS FALTAS,
    COUNTIF(medical_certificate IS NOT NULL) AS ATESTADOS
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Expected Points Tratada`
  WHERE reference_date BETWEEN v_start_date AND v_end_date
  GROUP BY 1;

  CREATE OR REPLACE TEMP TABLE tmp_DadosMedidas AS
  SELECT
    SAFE_CAST(MATRICULA AS INT64) AS MATRICULA,
    COUNT(*) AS ADVERTENCIAS
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Medidas Disciplinares `
  WHERE DATA_OCORRENCIA BETWEEN v_start_date AND v_end_date
    AND APLICADA IS TRUE
    AND INDEVIDA IS FALSE
  GROUP BY 1;

  CREATE OR REPLACE TEMP TABLE tmp_PessoasUnicas AS
  SELECT * EXCEPT(rn)
  FROM (
    SELECT
      SAFE_CAST(MATRICULA AS INT64) AS MATRICULA,
      UPPER(TRIM(NOME)) AS NOME,
      UPPER(TRIM(AREA)) AS AREA,
      UPPER(TRIM(TURNO)) AS TURNO,
      UPPER(TRIM(FC)) AS FC,
      UPPER(TRIM(GESTOR)) AS GESTOR,
      UPPER(TRIM(ATRIBUICAO)) AS ATRIBUICAO,
      UPPER(TRIM(SETOR)) AS SETOR_ORIGINAL,
      CASE
        WHEN UPPER(TRIM(ATRIBUICAO)) IN ('INCLUIR FALTANTES', 'CHECK-IN') THEN
          CASE
            WHEN UPPER(TRIM(AREA)) = 'FRESH' THEN 'OPERAÇÃO FRESH'
            WHEN UPPER(TRIM(AREA)) = 'MERCEARIA' THEN 'PACKING'
            ELSE UPPER(TRIM(SETOR))
          END
        WHEN UPPER(TRIM(ATRIBUICAO)) = 'REBIPAGEM'
          OR UPPER(TRIM(SETOR)) = 'REBIPAGEM' THEN
          CASE
            WHEN UPPER(TRIM(AREA)) = 'MERCEARIA' THEN 'PACKING'
            WHEN UPPER(TRIM(AREA)) = 'FRESH' THEN 'OPERAÇÃO FRESH'
            ELSE UPPER(TRIM(SETOR))
          END
        ELSE UPPER(TRIM(SETOR))
      END AS SETOR,
      ROW_NUMBER() OVER (PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) AS rn
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Organograma`
  )
  WHERE rn = 1
    AND MATRICULA IS NOT NULL;

  CREATE OR REPLACE TEMP TABLE tmp_KPI_Calc AS
  SELECT
    SAFE_CAST(MATRICULA AS STRING) AS MATRICULA,
    ANY_VALUE(
      COALESCE(MULT_MATRICULA, 1.0)
      * COALESCE(MULT_TURNO, 1.0)
      * COALESCE(MULT_SETOR, 1.0)
      * COALESCE(MULT_ATRIBUICAO, 1.0)
      * COALESCE(MULT_FC, 1.0)
    ) AS kpi_val,
    ANY_VALUE(OBSERVACAO_KPI) AS kpi_obs
  FROM `shopper-datalakehouse-qa.Ranking_Performance.KPIs_OPERAÇÃO`
  WHERE data_inicio = v_start_date
  GROUP BY 1;

  CREATE OR REPLACE TEMP TABLE tmp_MaxGlobal AS
  SELECT
    FC,
    MAX(pontuacao_final) AS max_pts
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Ranking Semanal`
  WHERE data_inicio_periodo = v_start_date
  GROUP BY 1;

  CREATE OR REPLACE TEMP TABLE tmp_Carteira AS
  SELECT
    SAFE_CAST(matricula AS INT64) AS MATRICULA,
    CAST(saldo_pos_bonificacao AS STRING) AS SALDO
  FROM `shopper-datalakehouse-qa.Ranking_Performance.carteira_operação`
  WHERE data_inicio_ranking < v_start_date
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY SAFE_CAST(matricula AS INT64)
    ORDER BY data_inicio_ranking DESC, update_at DESC, report_at DESC
  ) = 1;

  CREATE OR REPLACE TEMP TABLE tmp_GlobalRanking AS
  SELECT
    SAFE_CAST(r.MATRICULA AS INT64) AS MATRICULA,
    r.FC,
    r.status_ranking,
    r.pontuacao_final AS pts_reais,
    COALESCE(r.FALTAS, 0) AS FALTAS,
    COALESCE(r.ADVERTENCIAS, 0) AS ADVERTENCIAS,
    0 AS ALOCACAO_INDEVIDA,
    COALESCE(r.ATESTADOS, 0) AS ATESTADOS,
    COALESCE(r.pontuacao_potencial, r.pontuacao_final) AS pts_para_media,
    COALESCE(k.kpi_val, 1.0) AS mult_kpi,
    k.kpi_obs,
    m.max_pts AS p_max_fc
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Ranking Semanal` r
  LEFT JOIN tmp_MaxGlobal m ON r.FC = m.FC
  LEFT JOIN tmp_KPI_Calc k ON CAST(r.MATRICULA AS STRING) = k.MATRICULA
  WHERE data_inicio_periodo = v_start_date;

  CREATE OR REPLACE TEMP TABLE tmp_Pontuacao_Setor_Base AS
  SELECT
    SAFE_CAST(registration_number AS INT64) AS MATRICULA,
    CASE
      WHEN UPPER(TRIM(metric_description)) LIKE '%CAIXARIAS%'
        OR UPPER(TRIM(metric_description)) LIKE '%RECEBIMENTO%'
        OR UPPER(TRIM(metric_description)) IN ('DEVOLUÇÃO FLV','ITENS RECEBIDOS')
        THEN 'RECEBIMENTO'
      WHEN UPPER(TRIM(metric_description)) LIKE 'PERDAS:%'
        OR UPPER(TRIM(metric_description)) LIKE 'DUPLICADO: PERDAS%'
        THEN 'GESTÃO DE ESTOQUE'
      WHEN UPPER(TRIM(metric_description)) IN (
          'ENDEREÇOS COM DIVERGÊNCIA DE INVENTÁRIO',
          'ENDEREÇOS COM DIVERGÊNCIA DE INVENTÁRIO FRESH',
          'ASSERTIVIDADE DE ENDEREÇOS',
          'ASSERTIVIDADE DE ENDEREÇOS FRESH'
        ) THEN 'GESTÃO DE ESTOQUE'
      WHEN UPPER(TRIM(metric_description)) LIKE '%CONFERIDOS EM MERCEARIA%'
        OR UPPER(TRIM(metric_description)) LIKE '%CONFERIDOS MERCEARIA%'
        OR UPPER(TRIM(metric_description)) LIKE '%SAME-DAY NÃO MAPEADO EM MERCEARIA%'
        OR UPPER(TRIM(metric_description)) IN (
          'FALTANTE','FALTANTES','ITENS INCLUIDOS','REBIPAGEM HOSPITAL','REBIPAGEM',
          'ITENS CONFERIDOS NO CHECK-IN EM MERCEARIA',
          'LISTA DE PEDIDOS CONFERIDOS NO CHECK-IN EM MERCEARIA',
          'SEGUNDA CONFERENCIA MERCEARIA',
          'AUDITORIA DE CONFERENCIA MERCEARIA',
          'AUDITORIA DE CONFERENCIA MERCEARIA EXPRESS',
          'AUDITORIA DE CONFERENCIA MERCEARIA SMD'
        ) THEN 'PACKING'
      WHEN UPPER(TRIM(metric_description)) LIKE '%CONFERIDOS FRESH%'
        OR UPPER(TRIM(metric_description)) LIKE '%CONFERIDOS EM FRESH%'
        OR UPPER(TRIM(metric_description)) IN (
          'ITENS PICKADOS EM FRESH',
          'LISTA DE PEDIDOS CONFERIDOS NO CHECK-IN EM FRESH',
          'SEGUNDA CONFERENCIA FRESCOS',
          'AUDITORIA DE CONFERENCIA FRESH',
          'AUDITORIA DE CONFERENCIA FRESH EXPRESS',
          'AUDITORIA DE CONFERENCIA FRESH SMD'
        ) THEN 'OPERAÇÃO FRESH'
      WHEN UPPER(TRIM(metric_description)) LIKE '%LISTA FRESH%'
        OR UPPER(TRIM(metric_description)) LIKE '%PÁGINA FRESH%'
        OR UPPER(TRIM(metric_description)) LIKE '%LISTA PRIORIDADE%'
        OR UPPER(TRIM(metric_description)) LIKE '%PÁGINA PRIORIDADE%'
        OR UPPER(TRIM(metric_description)) LIKE '%REPOSIÇÃO%'
        OR UPPER(TRIM(metric_description)) LIKE '%REPOSICAO%'
        OR UPPER(TRIM(metric_description)) IN (
          'ERRO DE FIFO','ERRO DE MOVIMENTAÇÃO','ERRO DE REPOSIÇÃO',
          'ERRO EXECUÇÃO DE PROCESSO','PERDA',
          'INFORMAÇÕES DA PÁGINA DE REPOSIÇÃO',
          'ITENS COLETADOS NA RESERVA','ITENS REPOSTOS NA GÔNDULA','REPOSIÇÃO CHECKIN'
        ) THEN 'REPOSIÇÃO'
      WHEN UPPER(TRIM(metric_description)) IN (
          'ITENS PICKADOS EM MERCEARIA','ITENS NÃO PICKADOS EM MERCEARIA',
          'ITENS PICKADOS MERCEARIA SMD','ITENS PICKADOS MERCEARIA SELECT',
          'ITENS PICKADOS MERCEARIA EXT'
        ) THEN 'PICKING'
      WHEN UPPER(TRIM(metric_description)) IN (
          'ITENS NÃO PICKADOS EM FRESH','PEDIDO SAME-DAY NÃO MAPEADO EM FRESH'
        ) THEN 'OPERAÇÃO FRESH'
      WHEN UPPER(TRIM(metric_description)) IN (
          'PEDIDOS MAPEADOS','VOLUMES EXPEDIDOS','VOLUMES SMD EXPEDIDOS',
          'VOLUMES DEVOLVIDOS','GAIOLA MOVIMENTADA'
        ) THEN 'EXPEDIÇÃO'
      WHEN UPPER(TRIM(metric_description)) = 'PACKS FRACIONADOS' THEN 'FRACIONAMENTO'
      ELSE 'OUTROS'
    END AS SETOR_ATIVIDADE,
    SUM(pontos_ponderados) AS pts_setor
  FROM `shopper-datalakehouse-qa.Ranking_Performance.performance_extract_points_table`
  WHERE reference_date BETWEEN v_start_date AND v_end_date
    AND pontos_ponderados IS NOT NULL
    AND pontos_ponderados <> 0
  GROUP BY 1, 2;

  CREATE OR REPLACE TEMP TABLE tmp_ResumoGeral AS
  SELECT
    pu.FC, pu.TURNO, pu.SETOR,
    CASE
      WHEN pu.SETOR IN ('RECEBIMENTO','REPOSIÇÃO','REPOSICAO','PICKING','FRACIONAMENTO') THEN pu.AREA
      WHEN pu.SETOR IN ('EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO') THEN 'GERAL'
      ELSE 'GERAL'
    END AS AREA,
    AVG(COALESCE(ps.pts_setor, 0)) AS media_pts,
    SUM(COALESCE(ps.pts_setor, 0)) AS soma_pts,
    COUNT(*) AS total_colabs,
    COUNTIF(rk.status_ranking = 'BONIFICADO' AND rk.mult_kpi > 0) AS total_bonificados
  FROM tmp_PessoasUnicas pu
  JOIN tmp_GlobalRanking rk ON pu.MATRICULA = rk.MATRICULA
  LEFT JOIN tmp_Pontuacao_Setor_Base ps
    ON pu.MATRICULA = ps.MATRICULA
   AND ps.SETOR_ATIVIDADE = CASE
     WHEN pu.SETOR IN ('PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO','CAMPINAS') THEN 'EXPEDIÇÃO'
     ELSE pu.SETOR
   END
  WHERE pu.ATRIBUICAO NOT LIKE '%FISCAL%'
    AND pu.ATRIBUICAO NOT LIKE '%SUPERVISOR%'
  GROUP BY 1, 2, 3, 4;

  CREATE OR REPLACE TEMP TABLE tmp_EquipesResumo AS
  WITH MapeamentoFinal AS (
    SELECT
      f.NOME AS fiscal_nome,
      c.MATRICULA AS colab_matricula
    FROM tmp_PessoasUnicas f
    JOIN tmp_PessoasUnicas c
      ON f.FC = c.FC
     AND (
       f.TURNO = c.TURNO
       OR f.ATRIBUICAO IN ('FISCAL - PERDAS','PERDAS FISCAL PERDAS','FISCAL PERDAS')
     )
    WHERE f.SETOR IN ('GESTÃO DE ESTOQUE','GESTAO DE ESTOQUE')
      AND f.ATRIBUICAO IN (
        'FISCAL - INVENTÁRIO','FISCAL - PERDAS MERCEARIA',
        'FISCAL - PERDAS/DESFAZER PEDIDOS FRESH','FISCAL - PERDAS',
        'FISCAL INVENTÁRIO','FISCAL PERDAS MERCEARIA',
        'FISCAL PERDAS/DESFAZER PEDIDOS FRESH','PERDAS FISCAL PERDAS','FISCAL PERDAS'
      )
      AND (
        (f.ATRIBUICAO IN ('FISCAL - INVENTÁRIO','FISCAL INVENTÁRIO') AND c.ATRIBUICAO = 'INVENTÁRIO')
        OR (f.ATRIBUICAO IN ('FISCAL - PERDAS MERCEARIA','FISCAL PERDAS MERCEARIA') AND c.ATRIBUICAO = 'PERDAS MERCEARIA')
        OR (f.ATRIBUICAO IN ('FISCAL - PERDAS/DESFAZER PEDIDOS FRESH','FISCAL PERDAS/DESFAZER PEDIDOS FRESH') AND c.ATRIBUICAO = 'PERDAS/DESFAZER PEDIDOS FRESH')
        OR (f.ATRIBUICAO IN ('PERDAS FISCAL PERDAS','FISCAL - PERDAS','FISCAL PERDAS') AND c.ATRIBUICAO IN ('PERDAS MERCEARIA','PERDAS/DESFAZER PEDIDOS FRESH','PERDAS'))
      )
  )
  SELECT
    m.fiscal_nome,
    AVG(COALESCE(ps.pts_setor, 0)) AS media_pts,
    SUM(COALESCE(ps.pts_setor, 0)) AS soma_pts,
    COUNT(DISTINCT m.colab_matricula) AS total_colabs,
    COUNTIF(r.status_ranking = 'BONIFICADO' AND r.mult_kpi > 0) AS total_bonificados
  FROM MapeamentoFinal m
  LEFT JOIN tmp_GlobalRanking r ON m.colab_matricula = r.MATRICULA
  LEFT JOIN tmp_PessoasUnicas pu ON m.colab_matricula = pu.MATRICULA
  LEFT JOIN tmp_Pontuacao_Setor_Base ps
    ON m.colab_matricula = ps.MATRICULA
   AND ps.SETOR_ATIVIDADE = CASE
     WHEN pu.SETOR IN ('PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO','CAMPINAS') THEN 'EXPEDIÇÃO'
     ELSE pu.SETOR
   END
  GROUP BY 1;

  CREATE OR REPLACE TEMP TABLE tmp_Fiscais_Calculados_Final AS
  WITH PreCalc AS (
    SELECT
      pu.*,
      COALESCE(ps_f.pts_setor, 0) AS individual_pts,
      COALESCE(rk.mult_kpi, kc.kpi_val, 1.0) AS mult_kpi,
      COALESCE(rk.kpi_obs, kc.kpi_obs) AS kpi_obs,
      COALESCE(dp.FALTAS, rk.FALTAS, 0) AS FALTAS,
      COALESCE(dm.ADVERTENCIAS, rk.ADVERTENCIAS, 0) AS ADVERTENCIAS,
      0 AS ALOCACAO_INDEVIDA,
      COALESCE(dp.ATESTADOS, rk.ATESTADOS, 0) AS ATESTADOS,
      COALESCE(rk.p_max_fc, mg.max_pts, 3000000) AS p_max_fc,
      af.motivo_afastamento,
      cart.SALDO AS saldo_da_carteira,
      CASE
        WHEN pu.ATRIBUICAO NOT IN ('FISCAL','FISCAL - PACKER') THEN FALSE
        WHEN pu.SETOR IN ('REPOSIÇÃO','RECEBIMENTO','EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO','PICKING','FRACIONAMENTO') THEN TRUE
        ELSE FALSE
      END AS is_avalia_turno,
      CASE
        WHEN pu.SETOR IN ('GESTÃO DE ESTOQUE','GESTAO DE ESTOQUE') THEN TRUE
        WHEN pu.ATRIBUICAO IN ('FISCAL','FISCAL - PACKER')
          AND pu.SETOR IN ('REPOSIÇÃO','RECEBIMENTO','EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO','PICKING','FRACIONAMENTO')
          THEN TRUE
        ELSE FALSE
      END AS is_isento_minimo_equipe,
      COALESCE(cfg_min.qtd_minima_equipe, 4) AS limite_minimo_equipe,
      cfg.valor_minimo AS c_min,
      cfg.valor_maximo AS c_max,
      tr.media_pts AS tr_media,
      tr.soma_pts AS tr_soma,
      tr.total_colabs AS tr_total,
      tr.total_bonificados AS tr_bonificados,
      eq.media_pts AS eq_media,
      eq.soma_pts AS eq_soma,
      eq.total_colabs AS eq_total,
      eq.total_bonificados AS eq_total_bonificados
    FROM tmp_PessoasUnicas pu
    LEFT JOIN tmp_GlobalRanking rk ON pu.MATRICULA = rk.MATRICULA
    LEFT JOIN tmp_KPI_Calc kc ON CAST(pu.MATRICULA AS STRING) = kc.MATRICULA
    LEFT JOIN tmp_MaxGlobal mg ON pu.FC = mg.FC
    LEFT JOIN tmp_Pontuacao_Setor_Base ps_f
      ON pu.MATRICULA = ps_f.MATRICULA
     AND ps_f.SETOR_ATIVIDADE = CASE
       WHEN pu.SETOR IN ('PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO','CAMPINAS') THEN 'EXPEDIÇÃO'
       ELSE pu.SETOR
     END
    LEFT JOIN tmp_DadosAfastamentos af ON pu.MATRICULA = af.MATRICULA
    LEFT JOIN tmp_DadosPonto dp ON pu.MATRICULA = dp.MATRICULA
    LEFT JOIN tmp_DadosMedidas dm ON pu.MATRICULA = dm.MATRICULA
    LEFT JOIN tmp_EquipesResumo eq ON pu.NOME = eq.fiscal_nome
    LEFT JOIN tmp_ResumoGeral tr
      ON pu.FC = tr.FC
     AND pu.TURNO = tr.TURNO
     AND pu.SETOR = tr.SETOR
     AND (
       CASE
         WHEN pu.SETOR IN ('RECEBIMENTO','REPOSIÇÃO','REPOSICAO','PICKING','FRACIONAMENTO') THEN pu.AREA
         WHEN pu.SETOR IN ('EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO') THEN 'GERAL'
         ELSE 'GERAL'
       END
     ) = tr.AREA
    LEFT JOIN tmp_Carteira cart ON pu.MATRICULA = cart.MATRICULA
    LEFT JOIN (
      SELECT
        UPPER(TRIM(fc)) AS fc,
        UPPER(TRIM(setor)) AS setor,
        UPPER(TRIM(turno)) AS turno,
        ANY_VALUE(qtd_minima_equipe) AS qtd_minima_equipe
      FROM `shopper-datalakehouse-qa.Ranking_Performance.Config_Minimo_Equipe`
      GROUP BY 1, 2, 3
    ) cfg_min ON pu.FC = cfg_min.fc AND pu.SETOR = cfg_min.setor AND pu.TURNO = cfg_min.turno
    CROSS JOIN (
      SELECT valor_minimo, valor_maximo
      FROM `shopper-datalakehouse-qa.Ranking_Performance.Config_Bonificacao_Ranking`
      LIMIT 1
    ) cfg
    WHERE (
      (
        pu.ATRIBUICAO IN ('FISCAL','FISCAL - PACKER')
        AND pu.SETOR IN ('REPOSIÇÃO','RECEBIMENTO','EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO','PICKING','FRACIONAMENTO')
      )
      OR (
        pu.SETOR IN ('GESTÃO DE ESTOQUE','GESTAO DE ESTOQUE')
        AND pu.ATRIBUICAO IN (
          'FISCAL - INVENTÁRIO','FISCAL - PERDAS MERCEARIA',
          'FISCAL - PERDAS/DESFAZER PEDIDOS FRESH','FISCAL - PERDAS',
          'FISCAL INVENTÁRIO','FISCAL PERDAS MERCEARIA',
          'FISCAL PERDAS/DESFAZER PEDIDOS FRESH','PERDAS FISCAL PERDAS','FISCAL PERDAS'
        )
      )
      OR (
        eq.fiscal_nome IS NOT NULL
        AND COALESCE(eq.total_colabs, 0) >= COALESCE(cfg_min.qtd_minima_equipe, 4)
      )
    )
    AND pu.ATRIBUICAO NOT LIKE '%SUPERVISOR%'
  )
  SELECT
    *,
    IF(is_avalia_turno, tr_media, eq_media) AS f_media_f,
    IF(is_avalia_turno, tr_soma, eq_soma) AS f_soma_f,
    IF(is_avalia_turno, tr_total, eq_total) AS f_total_f,
    IF(is_avalia_turno, tr_bonificados, eq_total_bonificados) AS f_bonif_f,
    COALESCE(
      SAFE_DIVIDE(
        (IF(is_avalia_turno, tr_soma, eq_soma) * 2) + COALESCE(individual_pts, 0),
        GREATEST(1, IF(is_avalia_turno, tr_total, eq_total))
      ),
      0
    ) AS pts_combinados
  FROM PreCalc;

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais`
  WHERE data_inicio_periodo = v_start_date;

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais` (
    data_inicio_periodo, data_fim_periodo,
    matricula_fiscal, nome_fiscal, atribuicao_fiscal, turno, setor, area, fc,
    supervisor_responsavel,
    media_pontuacao_equipe, pontuacao_individual_fiscal, pontuacao_combinada_fiscal,
    valor_bonificacao_fiscal,
    total_colaboradores_na_equipe, total_bonificados_equipe,
    observacao_final, motivos_desqualificacao_fiscal,
    VALOR_FISCAL_ANTES_DO_KPI,
    quantidade_pedidos_expressos, quantidade_colaboradores_expressos,
    media_tempo_espera_express, saldo_da_carteira
  )
  SELECT
    v_start_date, v_end_date,
    MATRICULA, NOME, ATRIBUICAO, TURNO, SETOR, AREA, FC, GESTOR,
    ROUND(COALESCE(f_media_f, 0), 2),
    ROUND(individual_pts, 2),
    ROUND(pts_combinados, 2),

    GREATEST(0.00, LEAST(350.0, ROUND(COALESCE(
      IF(
        motivo_afastamento IS NOT NULL
        OR mult_kpi = 0
        OR FALTAS > 0
        OR ADVERTENCIAS > 0
        OR ATESTADOS > 0
        OR COALESCE(f_bonif_f, 0) = 0
        OR (is_isento_minimo_equipe = FALSE AND COALESCE(f_total_f, 0) < limite_minimo_equipe),
        0.00,
        (
          CASE
            WHEN pts_combinados <= 0 THEN 0.00
            WHEN pts_combinados <= 1000000 THEN (pts_combinados / 1000000) * c_min
            ELSE c_min + ((pts_combinados - 1000000) / GREATEST(1, COALESCE(p_max_fc, 3000000) - 1000000)) * (c_max - c_min)
          END
        ) * mult_kpi
      ),
      0.00
    ), 2))) AS v_bonus,

    COALESCE(f_total_f, 0),
    COALESCE(f_bonif_f, 0),

    CASE
      WHEN is_avalia_turno THEN 'ANALISADO POR TURNO INTEIRO'
      WHEN COALESCE(f_total_f, 0) = 0 THEN 'SEM EQUIPE MAPEADA'
      WHEN is_isento_minimo_equipe = FALSE AND COALESCE(f_total_f, 0) < limite_minimo_equipe THEN CONCAT('Equipe com menos de ', limite_minimo_equipe)
      ELSE 'MAPEAMENTO VALIDO'
    END AS observacao_final,

    CASE
      WHEN (
        motivo_afastamento IS NOT NULL
        OR mult_kpi = 0
        OR FALTAS > 0
        OR ADVERTENCIAS > 0
        OR ATESTADOS > 0
        OR COALESCE(f_bonif_f, 0) = 0
        OR (is_isento_minimo_equipe = FALSE AND COALESCE(f_total_f, 0) < limite_minimo_equipe)
      ) THEN
        CASE
          WHEN motivo_afastamento IS NOT NULL THEN motivo_afastamento
          WHEN FALTAS > 0 THEN 'Falta'
          WHEN ADVERTENCIAS > 0 THEN 'Advertência'
          WHEN ATESTADOS > 0 THEN 'Atestado'
          WHEN mult_kpi = 0 THEN COALESCE(kpi_obs, 'KPI Unidade Zerado')
          WHEN COALESCE(f_bonif_f, 0) = 0 THEN 'Sem bonificados elegíveis'
          WHEN is_isento_minimo_equipe = FALSE AND COALESCE(f_total_f, 0) < limite_minimo_equipe THEN 'Mínimo de equipe não atingido'
          ELSE 'Nota insuficiente'
        END
      ELSE NULL
    END AS motivos,

    GREATEST(0.00, LEAST(350.0, ROUND(COALESCE(
      IF(
        motivo_afastamento IS NOT NULL
        OR FALTAS > 0
        OR ADVERTENCIAS > 0
        OR ATESTADOS > 0
        OR COALESCE(f_bonif_f, 0) = 0
        OR (is_isento_minimo_equipe = FALSE AND COALESCE(f_total_f, 0) < limite_minimo_equipe),
        0.00,
        CASE
          WHEN pts_combinados <= 0 THEN 0.00
          WHEN pts_combinados <= 1000000 THEN (pts_combinados / 1000000) * c_min
          ELSE c_min + ((pts_combinados - 1000000) / GREATEST(1, COALESCE(p_max_fc, 3000000) - 1000000)) * (c_max - c_min)
        END
      ),
      0.00
    ), 2))) AS VALOR_FISCAL_ANTES_DO_KPI,

    0, 0, 0.0,
    COALESCE(saldo_da_carteira, '0')
  FROM tmp_Fiscais_Calculados_Final
  QUALIFY ROW_NUMBER() OVER (PARTITION BY MATRICULA ORDER BY pts_combinados DESC) = 1;

  CREATE OR REPLACE TEMP TABLE tmp_ResumoGeral_Sup AS
  WITH Operacionais AS (
    SELECT
      pu.FC, pu.TURNO,
      CASE
        WHEN pu.SETOR IN ('EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO') THEN 'EXPEDICAO_UNIFICADA'
        ELSE pu.SETOR
      END AS SETOR,
      CASE
        WHEN pu.SETOR IN ('RECEBIMENTO','REPOSIÇÃO','REPOSICAO') THEN pu.AREA
        ELSE 'GERAL'
      END AS AREA,
      COALESCE(ps.pts_setor, 0) AS pts,
      IF(rk.status_ranking = 'BONIFICADO' AND rk.mult_kpi > 0, 1, 0) AS is_bonificado,
      1 AS is_colab,
      0 AS is_fiscal
    FROM tmp_PessoasUnicas pu
    JOIN tmp_GlobalRanking rk ON pu.MATRICULA = rk.MATRICULA
    LEFT JOIN tmp_Pontuacao_Setor_Base ps
      ON pu.MATRICULA = ps.MATRICULA
     AND ps.SETOR_ATIVIDADE = CASE
       WHEN pu.SETOR IN ('PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO','CAMPINAS') THEN 'EXPEDIÇÃO'
       ELSE pu.SETOR
     END
    WHERE pu.ATRIBUICAO NOT LIKE '%SUPERVISOR%'
      AND NOT (
        pu.ATRIBUICAO LIKE '%FISCAL%'
        AND pu.SETOR NOT IN ('PACKING','OPERAÇÃO FRESH','OPERACAO FRESH')
      )
  ),
  Fiscais AS (
    SELECT
      fc AS FC, turno AS TURNO,
      CASE
        WHEN SETOR IN ('EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO') THEN 'EXPEDICAO_UNIFICADA'
        ELSE SETOR
      END AS SETOR,
      CASE
        WHEN SETOR IN ('RECEBIMENTO','REPOSIÇÃO','REPOSICAO') THEN AREA
        ELSE 'GERAL'
      END AS AREA,
      pontuacao_combinada_fiscal AS pts,
      IF(valor_bonificacao_fiscal > 0, 1, 0) AS is_bonificado,
      0 AS is_colab,
      1 AS is_fiscal
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais`
    WHERE data_inicio_periodo = v_start_date
      AND UPPER(TRIM(setor)) NOT IN ('PACKING','OPERAÇÃO FRESH','OPERACAO FRESH')
  ),
  Todos_Supervisionados AS (
    SELECT * FROM Operacionais
    UNION ALL
    SELECT * FROM Fiscais
  )
  SELECT
    FC, TURNO, SETOR, AREA,
    AVG(pts) AS media_pts,
    SUM(pts) AS soma_pts,
    COUNT(*) AS total_pessoas,
    SUM(is_colab) AS total_colabs,
    SUM(is_fiscal) AS total_fiscais,
    SUM(is_bonificado) AS total_bonificados
  FROM Todos_Supervisionados
  GROUP BY 1, 2, 3, 4;

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Supervisores`
  WHERE data_inicio_periodo = v_start_date;

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Performance Supervisores` (
    data_inicio_periodo, data_fim_periodo,
    matricula_supervisor, nome_supervisor, atribuicao_supervisor,
    turno, setor, area, FC,
    media_pontuacao_setor, pontuacao_individual_supervisor, pontuacao_combinada_supervisor,
    valor_bonificacao_supervisor,
    total_pessoas_setor, total_fiscais_setor, total_colaboradores_setor, total_bonificados_setor,
    motivos_desqualificacao_supervisor,
    VALOR_SUPERVISOR_ANTES_DO_KPI, saldo_da_carteira
  )
  WITH SupBase AS (
    SELECT
      pu.*,
      COALESCE(ps_sup.pts_setor, 0) AS individual_pts,
      COALESCE(rk.mult_kpi, kc.kpi_val, 1.0) AS mult_kpi,
      COALESCE(rk.kpi_obs, kc.kpi_obs) AS kpi_obs,
      COALESCE(dp.FALTAS, rk.FALTAS, 0) AS FALTAS,
      COALESCE(dm.ADVERTENCIAS, rk.ADVERTENCIAS, 0) AS ADVERTENCIAS,
      0 AS ALOCACAO_INDEVIDA,
      COALESCE(dp.ATESTADOS, rk.ATESTADOS, 0) AS ATESTADOS,
      COALESCE(rk.p_max_fc, mg.max_pts, 3000000) AS p_max_fc,
      af.motivo_afastamento,
      SUM(tr.soma_pts) OVER (PARTITION BY pu.MATRICULA) AS soma_total,
      SUM(tr.total_pessoas) OVER (PARTITION BY pu.MATRICULA) AS pessoas_total,
      SUM(tr.total_colabs) OVER (PARTITION BY pu.MATRICULA) AS colabs_total,
      SUM(tr.total_fiscais) OVER (PARTITION BY pu.MATRICULA) AS fiscais_total,
      SUM(tr.total_bonificados) OVER (PARTITION BY pu.MATRICULA) AS bonificados_total,
      cart.SALDO AS saldo_da_carteira,
      cfg.valor_minimo AS c_min,
      cfg.valor_maximo AS c_max
    FROM tmp_PessoasUnicas pu
    LEFT JOIN tmp_GlobalRanking rk ON pu.MATRICULA = rk.MATRICULA
    LEFT JOIN tmp_KPI_Calc kc ON CAST(pu.MATRICULA AS STRING) = kc.MATRICULA
    LEFT JOIN tmp_MaxGlobal mg ON pu.FC = mg.FC
    LEFT JOIN tmp_Pontuacao_Setor_Base ps_sup
      ON pu.MATRICULA = ps_sup.MATRICULA
     AND ps_sup.SETOR_ATIVIDADE = CASE
       WHEN pu.SETOR IN ('PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO','CAMPINAS') THEN 'EXPEDIÇÃO'
       ELSE pu.SETOR
     END
    LEFT JOIN tmp_DadosAfastamentos af ON pu.MATRICULA = af.MATRICULA
    LEFT JOIN tmp_DadosPonto dp ON pu.MATRICULA = dp.MATRICULA
    LEFT JOIN tmp_DadosMedidas dm ON pu.MATRICULA = dm.MATRICULA
    LEFT JOIN tmp_Carteira cart ON pu.MATRICULA = cart.MATRICULA
    LEFT JOIN tmp_ResumoGeral_Sup tr
      ON pu.FC = tr.FC
     AND pu.TURNO = tr.TURNO
     AND (
       CASE
         WHEN pu.SETOR IN ('EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO') THEN 'EXPEDICAO_UNIFICADA'
         ELSE pu.SETOR
       END
     ) = tr.SETOR
     AND (
       CASE
         WHEN pu.SETOR IN ('RECEBIMENTO','REPOSIÇÃO','REPOSICAO') THEN pu.AREA
         ELSE 'GERAL'
       END
     ) = tr.AREA
    CROSS JOIN (
      SELECT valor_minimo, valor_maximo
      FROM `shopper-datalakehouse-qa.Ranking_Performance.Config_Bonificacao_Ranking`
      LIMIT 1
    ) cfg
    WHERE pu.ATRIBUICAO LIKE '%SUPERVISOR%'
  ),
  SupPontuacaoDobrada AS (
    SELECT
      *,
      COALESCE(
        SAFE_DIVIDE(
          (COALESCE(soma_total, 0) * 2) + COALESCE(individual_pts, 0),
          GREATEST(1, COALESCE(pessoas_total, 0))
        ),
        0
      ) AS pontuacao_combinada_final
    FROM SupBase
  ),
  SupComValor AS (
    SELECT
      *,
      GREATEST(0.00, LEAST(350.0, ROUND(COALESCE(
        IF(
          motivo_afastamento IS NOT NULL
          OR mult_kpi = 0
          OR COALESCE(pessoas_total, 0) = 0
          OR COALESCE(bonificados_total, 0) = 0
          OR FALTAS > 0
          OR ADVERTENCIAS > 0
          OR ATESTADOS > 0,
          0.00,
          (
            CASE
              WHEN pontuacao_combinada_final <= 0 THEN 0.00
              WHEN pontuacao_combinada_final <= 1000000 THEN (pontuacao_combinada_final / 1000000) * c_min
              ELSE c_min + ((pontuacao_combinada_final - 1000000) / GREATEST(1, COALESCE(p_max_fc, 3000000) - 1000000)) * (c_max - c_min)
            END
          ) * mult_kpi
        ),
        0.00
      ), 2))) AS valor_bonificacao_supervisor,

      GREATEST(0.00, LEAST(350.0, ROUND(COALESCE(
        IF(
          motivo_afastamento IS NOT NULL
          OR COALESCE(pessoas_total, 0) = 0
          OR COALESCE(bonificados_total, 0) = 0
          OR FALTAS > 0
          OR ADVERTENCIAS > 0
          OR ATESTADOS > 0,
          0.00,
          CASE
            WHEN pontuacao_combinada_final <= 0 THEN 0.00
            WHEN pontuacao_combinada_final <= 1000000 THEN (pontuacao_combinada_final / 1000000) * c_min
            ELSE c_min + ((pontuacao_combinada_final - 1000000) / GREATEST(1, COALESCE(p_max_fc, 3000000) - 1000000)) * (c_max - c_min)
          END
        ),
        0.00
      ), 2))) AS VALOR_SUPERVISOR_ANTES_DO_KPI
    FROM SupPontuacaoDobrada
  )
  SELECT
    v_start_date, v_end_date,
    MATRICULA, NOME, ATRIBUICAO, TURNO, SETOR, AREA, FC,
    ROUND(SAFE_DIVIDE(soma_total, GREATEST(1, pessoas_total)), 2),
    ROUND(individual_pts, 2),
    ROUND(pontuacao_combinada_final, 2),
    valor_bonificacao_supervisor,
    COALESCE(pessoas_total, 0),
    COALESCE(fiscais_total, 0),
    COALESCE(colabs_total, 0),
    COALESCE(bonificados_total, 0),
    CASE
      WHEN valor_bonificacao_supervisor > 0 THEN NULL
      WHEN motivo_afastamento IS NOT NULL THEN motivo_afastamento
      WHEN FALTAS > 0 THEN 'Falta'
      WHEN ADVERTENCIAS > 0 THEN 'Advertência'
      WHEN ATESTADOS > 0 THEN 'Atestado'
      WHEN mult_kpi = 0 OR UPPER(kpi_obs) LIKE '%ZERADO%' THEN
        IF(
          UPPER(kpi_obs) LIKE '%RUPTURA%' OR UPPER(kpi_obs) LIKE '%CLIENTE%',
          IF(COALESCE(bonificados_total, 0) > 0, 'PENALIZADO POR KPI (IA RECEBER)', 'PENALIZADO POR KPI (NÃO IA RECEBER)'),
          COALESCE(kpi_obs, 'KPI Zerado')
        )
      WHEN COALESCE(bonificados_total, 0) = 0 THEN 'Sem bonificados na equipe'
      ELSE 'Nota insuficiente'
    END AS motivos_desqualificacao_supervisor,
    VALOR_SUPERVISOR_ANTES_DO_KPI,
    COALESCE(saldo_da_carteira, '0')
  FROM SupComValor
  QUALIFY ROW_NUMBER() OVER (PARTITION BY MATRICULA ORDER BY pontuacao_combinada_final DESC) = 1;

  CREATE OR REPLACE TEMP TABLE tmp_SupervisoresMapeados_Detalhada AS
  SELECT
    FC, TURNO,
    CASE
      WHEN SETOR IN ('EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO') THEN 'EXPEDICAO_UNIFICADA'
      ELSE SETOR
    END AS SETOR_AGRUPADO,
    CASE
      WHEN SETOR IN ('RECEBIMENTO','REPOSIÇÃO','REPOSICAO') THEN AREA
      ELSE NULL
    END AS AREA,
    STRING_AGG(DISTINCT UPPER(TRIM(NOME)), ' / ') AS supervisor_nome
  FROM tmp_PessoasUnicas
  WHERE ATRIBUICAO LIKE '%SUPERVISOR%'
  GROUP BY 1, 2, 3, 4;

  CREATE OR REPLACE TEMP TABLE tmp_Colab_Fiscal_Map_Detalhada AS
  WITH Mapeamento AS (
    SELECT
      SAFE_CAST(c.MATRICULA AS INT64) AS colab_matricula,
      f.NOME AS fiscal_nome
    FROM tmp_PessoasUnicas f
    JOIN tmp_PessoasUnicas c
      ON f.FC = c.FC
     AND (
       f.TURNO = c.TURNO
       OR f.ATRIBUICAO IN ('FISCAL - PERDAS','PERDAS FISCAL PERDAS','FISCAL PERDAS')
     )
    WHERE f.SETOR IN ('GESTÃO DE ESTOQUE','GESTAO DE ESTOQUE')
      AND f.ATRIBUICAO IN (
        'FISCAL - INVENTÁRIO','FISCAL - PERDAS MERCEARIA',
        'FISCAL - PERDAS/DESFAZER PEDIDOS FRESH','FISCAL - PERDAS',
        'FISCAL INVENTÁRIO','FISCAL PERDAS MERCEARIA',
        'FISCAL PERDAS/DESFAZER PEDIDOS FRESH','PERDAS FISCAL PERDAS','FISCAL PERDAS'
      )
      AND (
        (f.ATRIBUICAO IN ('FISCAL - INVENTÁRIO','FISCAL INVENTÁRIO') AND c.ATRIBUICAO = 'INVENTÁRIO')
        OR (f.ATRIBUICAO IN ('FISCAL - PERDAS MERCEARIA','FISCAL PERDAS MERCEARIA') AND c.ATRIBUICAO = 'PERDAS MERCEARIA')
        OR (f.ATRIBUICAO IN ('FISCAL - PERDAS/DESFAZER PEDIDOS FRESH','FISCAL PERDAS/DESFAZER PEDIDOS FRESH') AND c.ATRIBUICAO = 'PERDAS/DESFAZER PEDIDOS FRESH')
        OR (f.ATRIBUICAO IN ('PERDAS FISCAL PERDAS','FISCAL - PERDAS','FISCAL PERDAS') AND c.ATRIBUICAO IN ('PERDAS MERCEARIA','PERDAS/DESFAZER PEDIDOS FRESH','PERDAS'))
      )
  )
  SELECT
    colab_matricula,
    STRING_AGG(DISTINCT fiscal_nome, ' / ') AS fiscal_nome_agrupado
  FROM Mapeamento
  GROUP BY 1;

  CREATE OR REPLACE TEMP TABLE tmp_RankingDaSemana AS
  SELECT
    SAFE_CAST(MATRICULA AS STRING) AS MATRICULA,
    fc, status_ranking, pontuacao_final, posicao_ranking_fc, motivo_desqualificacao,
    valor_bonificacao AS Valor_Bonificacao_Colab,
    COALESCE(ITENS_PICKING, 0) AS ITENS_PICKING,
    COALESCE(ITENS_PACKING, 0) AS ITENS_PACKING,
    COALESCE(ITENS_SAMEDAY, 0) AS ITENS_SAMEDAY,
    COALESCE(ITENS_SHOPPER_BR, 0) AS ITENS_SHOPPER_BR,
    COALESCE(ITENS_FRESH, 0) AS ITENS_FRESH,
    COALESCE(PACKS_FRACIONADOS, 0) AS PACKS_FRACIONADOS,
    COALESCE(VOLUMES_EXPEDIDOS, 0) AS VOLUMES_EXPEDIDOS,
    COALESCE(VOLUMES_SMD_EXPEDIDOS, 0) AS VOLUMES_SMD_EXPEDIDOS,
    COALESCE(PEDIDOS_MAPEADOS, 0) AS PEDIDOS_MAPEADOS,
    COALESCE(ERROS_PICKING, 0) AS ERROS_PICKING,
    COALESCE(ERROS_PACKING, 0) AS ERROS_PACKING,
    COALESCE(ERROS_FRESH, 0) AS ERROS_FRESH,
    (COALESCE(ERRO_RECEBIMENTO_MERCEARIA,0)+COALESCE(ERRO_RECEBIMENTO_FRESH,0)+COALESCE(DIVERGENCIA_RECEBIMENTO_MERCEARIA,0)+COALESCE(DIVERGENCIA_RECEBIMENTO_FRESH,0)) AS TOTAL_ERROS_RECEBIMENTO,
    (COALESCE(ERRO_REPOSICAO_MERCEARIA,0)+COALESCE(ERRO_REPOSICAO_FRESH,0)+COALESCE(ERRO_REPOSICAO_PICKING_SECOS,0)+COALESCE(ERRO_REPOSICAO_PK,0)+COALESCE(ERRO_REPOSICAO_TRANSFERENCIA,0)+COALESCE(FALHA_REPOSICAO_MERCEARIA,0)+COALESCE(FALHA_REPOSICAO_FRESH,0)) AS TOTAL_ERROS_REPOSICAO,
    (COALESCE(CAIXARIAS_RECEBIMENTO_GAIOLA,0)+COALESCE(CAIXARIAS_RECEBIMENTO_PALLET,0)+COALESCE(CAIXARIAS_RECEBIMENTO_FRESH,0)+COALESCE(CAIXARIAS_RECEBIMENTO_FLV,0)+COALESCE(MAPEAMENTO_LOTE,0)) AS TOTAL_ITENS_RECEBIMENTO,
    (COALESCE(REPOSICAO_MERCEARIA_CHAO,0)+COALESCE(REPOSICAO_MERCEARIA_ESCADA,0)+COALESCE(REPOSICAO_MERCEARIA_EMPILHADEIRA,0)+COALESCE(REPOSICAO_MERCEARIA_SALA_C,0)+COALESCE(REPOSICAO_PICKING_SECOS,0)+COALESCE(REPOSICAO_CHECKIN,0)+COALESCE(REPOSICAO_TRANSFERENCIA,0)+COALESCE(REPOSICAO_FRESH,0)+COALESCE(REPOSICAO_PK,0)) AS TOTAL_ITENS_REPOSICAO,
    (COALESCE(DIVERGENCIA_INVENTARIO,0)+COALESCE(DIVERGENCIA_INVENTARIO_FRESH,0)+COALESCE(DUPLICADO_PERDAS,0)) AS TOTAL_ERROS_ESTOQUE,
    (COALESCE(ASSERTIVIDADE_ENDERECOS,0)+COALESCE(ASSERTIVIDADE_ENDERECOS_FRESH,0)+COALESCE(LANCAMENTOS,0)+COALESCE(PERDAS_MERCEARIA,0)+COALESCE(PERDAS_CONGELADOS_REFRIGERADOS,0)+COALESCE(PERDAS_RETORNOS,0)+COALESCE(PERDAS_FLV,0)+COALESCE(PERDAS_PQV,0)) AS TOTAL_ITENS_ESTOQUE
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Ranking Semanal`
  WHERE data_inicio_periodo = v_start_date;

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Detalhada`
  WHERE data_inicio_periodo = v_start_date;

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Performance Detalhada` (
    data_inicio_periodo, data_fim_periodo,
    matricula_colaborador, nome_colaborador, setor_colaborador, area_colaborador,
    turno_colaborador, atribuicao_colaborador, fc_colaborador,
    fiscal_responsavel, supervisor_responsavel,
    pontuacao_final, quantidade_itens_setor, quantidade_erros_setor, taxa_erros_setor,
    posicao_ranking_final, valor_bonificacao_final, status_ranking_final, motivos_desqualificacao
  )
  SELECT
    v_start_date, v_end_date,
    p.MATRICULA, p.NOME, p.SETOR, p.AREA, p.TURNO, p.ATRIBUICAO, p.FC,

    CASE
      WHEN p.ATRIBUICAO IN (
        'FISCAL','FISCAL - PACKER','FISCAL - INVENTÁRIO','FISCAL - PERDAS MERCEARIA',
        'FISCAL - PERDAS/DESFAZER PEDIDOS FRESH','FISCAL - PERDAS',
        'FISCAL INVENTÁRIO','FISCAL PERDAS MERCEARIA',
        'FISCAL PERDAS/DESFAZER PEDIDOS FRESH','PERDAS FISCAL PERDAS','FISCAL PERDAS'
      ) THEN NULL
      ELSE COALESCE(
        IF(
          p.SETOR IN ('REPOSIÇÃO','RECEBIMENTO','EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO','PICKING','FRACIONAMENTO'),
          CONCAT('FISCAIS ', p.SETOR, ' ', p.TURNO),
          fisc_map.fiscal_nome_agrupado
        ),
        'SEM FISCAL'
      )
    END AS fiscal_responsavel,

    CASE
      WHEN p.ATRIBUICAO LIKE '%SUPERVISOR%' THEN NULL
      ELSE COALESCE(sup.supervisor_nome, 'SEM SUPERVISOR')
    END AS supervisor_responsavel,

    COALESCE(rank_fisc.pontuacao_combinada_fiscal, rank_sup.pontuacao_combinada_supervisor, r.pontuacao_final, 0.0),

    CAST(
      CASE
        WHEN p.SETOR = 'PACKING' THEN r.ITENS_PACKING + r.ITENS_SAMEDAY + r.ITENS_SHOPPER_BR
        WHEN p.SETOR = 'FRACIONAMENTO' THEN r.PACKS_FRACIONADOS
        WHEN p.SETOR = 'PICKING' THEN r.ITENS_PICKING
        WHEN p.SETOR = 'OPERAÇÃO FRESH' THEN r.ITENS_FRESH
        WHEN p.SETOR IN ('EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO') THEN r.VOLUMES_EXPEDIDOS + r.VOLUMES_SMD_EXPEDIDOS + r.PEDIDOS_MAPEADOS
        WHEN p.SETOR = 'REPOSIÇÃO' THEN r.TOTAL_ITENS_REPOSICAO
        WHEN p.SETOR = 'RECEBIMENTO' THEN r.TOTAL_ITENS_RECEBIMENTO
        WHEN p.SETOR IN ('GESTÃO DE ESTOQUE','GESTAO DE ESTOQUE') THEN r.TOTAL_ITENS_ESTOQUE
        ELSE 0
      END AS INT64
    ) AS quantidade_itens_setor,

    CAST(
      CASE
        WHEN p.SETOR = 'PACKING' THEN r.ERROS_PACKING
        WHEN p.SETOR = 'PICKING' THEN r.ERROS_PICKING
        WHEN p.SETOR = 'OPERAÇÃO FRESH' THEN r.ERROS_FRESH
        WHEN p.SETOR = 'RECEBIMENTO' THEN r.TOTAL_ERROS_RECEBIMENTO
        WHEN p.SETOR = 'REPOSIÇÃO' THEN r.TOTAL_ERROS_REPOSICAO
        WHEN p.SETOR IN ('GESTÃO DE ESTOQUE','GESTAO DE ESTOQUE') THEN r.TOTAL_ERROS_ESTOQUE
        ELSE 0
      END AS INT64
    ) AS quantidade_erros_setor,

    ROUND(
      SAFE_DIVIDE(
        CASE
          WHEN p.SETOR = 'PACKING' THEN r.ERROS_PACKING
          WHEN p.SETOR = 'PICKING' THEN r.ERROS_PICKING
          WHEN p.SETOR = 'OPERAÇÃO FRESH' THEN r.ERROS_FRESH
          WHEN p.SETOR = 'RECEBIMENTO' THEN r.TOTAL_ERROS_RECEBIMENTO
          WHEN p.SETOR = 'REPOSIÇÃO' THEN r.TOTAL_ERROS_REPOSICAO
          WHEN p.SETOR IN ('GESTÃO DE ESTOQUE','GESTAO DE ESTOQUE') THEN r.TOTAL_ERROS_ESTOQUE
          ELSE 0
        END,
        NULLIF(
          CASE
            WHEN p.SETOR = 'PACKING' THEN r.ITENS_PACKING + r.ITENS_SAMEDAY + r.ITENS_SHOPPER_BR
            WHEN p.SETOR = 'FRACIONAMENTO' THEN r.PACKS_FRACIONADOS
            WHEN p.SETOR = 'PICKING' THEN r.ITENS_PICKING
            WHEN p.SETOR = 'OPERAÇÃO FRESH' THEN r.ITENS_FRESH
            WHEN p.SETOR IN ('EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO') THEN r.VOLUMES_EXPEDIDOS + r.VOLUMES_SMD_EXPEDIDOS + r.PEDIDOS_MAPEADOS
            WHEN p.SETOR = 'REPOSIÇÃO' THEN r.TOTAL_ITENS_REPOSICAO
            WHEN p.SETOR = 'RECEBIMENTO' THEN r.TOTAL_ITENS_RECEBIMENTO
            WHEN p.SETOR IN ('GESTÃO DE ESTOQUE','GESTAO DE ESTOQUE') THEN r.TOTAL_ITENS_ESTOQUE
            ELSE 0
          END,
          0
        )
      ),
      4
    ) AS taxa_erros_setor,

    CASE
      WHEN r.status_ranking LIKE 'DESQUALIFICADO%' THEN 'Desqualificado'
      ELSE CAST(r.posicao_ranking_fc AS STRING)
    END AS posicao_ranking_final,

    COALESCE(rank_sup.valor_bonificacao_supervisor, rank_fisc.valor_bonificacao_fiscal, r.Valor_Bonificacao_Colab, 0.00),

    CASE
      WHEN rank_sup.matricula_supervisor IS NOT NULL THEN
        CASE
          WHEN rank_sup.valor_bonificacao_supervisor > 0 THEN 'BONIFICADO'
          WHEN UPPER(rank_sup.motivos_desqualificacao_supervisor) LIKE '%KPI ZERADO%' THEN 'KPI ZERADO'
          WHEN UPPER(rank_sup.motivos_desqualificacao_supervisor) LIKE '%PENALIZADO POR KPI%' THEN 'BONIFICAÇÃO ZERADA POR ERRO CLIENTE/RUPTURA'
          WHEN rank_sup.motivos_desqualificacao_supervisor IS NOT NULL THEN 'DESQUALIFICADO'
          ELSE 'ELEGÍVEL'
        END
      WHEN rank_fisc.matricula_fiscal IS NOT NULL THEN
        CASE
          WHEN rank_fisc.valor_bonificacao_fiscal > 0 THEN 'BONIFICADO'
          WHEN UPPER(rank_fisc.motivos_desqualificacao_fiscal) LIKE '%KPI UNIDADE ZERADO%'
            OR UPPER(rank_fisc.motivos_desqualificacao_fiscal) LIKE '%KPI ZERADO%' THEN 'KPI ZERADO'
          WHEN UPPER(rank_fisc.motivos_desqualificacao_fiscal) LIKE '%PENALIZADO POR KPI%' THEN 'BONIFICAÇÃO ZERADA POR ERRO CLIENTE/RUPTURA'
          WHEN rank_fisc.motivos_desqualificacao_fiscal IS NOT NULL THEN 'DESQUALIFICADO'
          ELSE 'ELEGÍVEL'
        END
      ELSE COALESCE(UPPER(TRIM(r.status_ranking)), 'ELEGÍVEL')
    END AS status_ranking_final,

    COALESCE(rank_sup.motivos_desqualificacao_supervisor, rank_fisc.motivos_desqualificacao_fiscal, r.motivo_desqualificacao)

  FROM tmp_PessoasUnicas p
  LEFT JOIN tmp_RankingDaSemana r ON CAST(p.MATRICULA AS STRING) = r.MATRICULA
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais` rank_fisc
    ON CAST(p.MATRICULA AS STRING) = CAST(rank_fisc.matricula_fiscal AS STRING)
   AND rank_fisc.data_inicio_periodo = v_start_date
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Performance Supervisores` rank_sup
    ON CAST(p.MATRICULA AS STRING) = CAST(rank_sup.matricula_supervisor AS STRING)
   AND rank_sup.data_inicio_periodo = v_start_date
  LEFT JOIN tmp_Colab_Fiscal_Map_Detalhada fisc_map ON p.MATRICULA = fisc_map.colab_matricula
  LEFT JOIN tmp_SupervisoresMapeados_Detalhada sup
    ON p.FC = sup.FC
   AND p.TURNO = sup.TURNO
   AND (
     CASE
       WHEN p.SETOR IN ('EXPEDIÇÃO','PRÉ EXPEDIÇÃO','PRÉ-EXPEDIÇÃO') THEN 'EXPEDICAO_UNIFICADA'
       ELSE p.SETOR
     END
   ) = sup.SETOR_AGRUPADO
   AND (sup.AREA IS NULL OR p.AREA = sup.AREA)
  WHERE p.NOME != 'Férias'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY p.MATRICULA ORDER BY p.MATRICULA) = 1;

END;
