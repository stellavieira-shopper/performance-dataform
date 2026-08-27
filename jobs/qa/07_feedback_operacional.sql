BEGIN

  ALTER TABLE `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Operacional`
  ADD COLUMN IF NOT EXISTS reforco_operacao BOOL;

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Operacional`
  WHERE data_inicio = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Ranking Semanal`
  );

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Base_Feedback_Operacional`

  WITH Base_Padronizada AS (
    SELECT
      CAST(registration_number AS STRING) AS MATRICULA_STR,
      DATE_TRUNC(reference_date, WEEK(FRIDAY)) AS semana,
      pontos_ponderados,
      qty AS quantidade_pontuada,

      CASE
        WHEN UPPER(TRIM(metric_description)) IN (
          'REPOSIÇÃO TRANSFERÊNCIA RECEBIDA',
          'REPOSIÇÃO TRANFERÊNCIA RECEBIDA'
        ) THEN 'REPOSIÇÃO TRANSFERÊNCIA RECEBIDA'

        WHEN UPPER(TRIM(metric_description)) LIKE '%REBIPAGEM HOSPITAL%'
          OR UPPER(TRIM(metric_description)) LIKE 'ITENS REBIPAGEM%'
          THEN 'ITENS BIPADOS NA REBIPAGEM'

        WHEN UPPER(TRIM(metric_description)) IN (
          'ITENS CONFERIDOS EM MERCEARIA',
          'ITENS CONFERIDOS MERCEARIA EXT',
          'ITENS CONFERIDOS MERCEARIA EXPRESS',
          'ITENS CONFERIDOS MERCEARIA SELECT',
          'ITENS BIPADOS NO PACKING'
        ) THEN 'ITENS BIPADOS NO PACKING'

        WHEN UPPER(TRIM(metric_description)) IN (
          'ITENS PICKADOS EM MERCEARIA',
          'ITENS PICKADOS MERCEARIA SELECT',
          'ITENS PICKADOS MERCEARIA EXT'
        ) THEN 'ITENS COLETADOS NO PICKING'

        WHEN UPPER(TRIM(metric_description)) IN (
          'ITENS PICKADOS EM FRESH',
          'ITENS CONFERIDOS FRESH SMD',
          'ITENS CONFERIDOS FRESH EXT',
          'ITENS CONFERIDOS FRESH EXPRESS'
        ) THEN 'ITENS COLETADOS E BIPADOS EM FRESH'

        WHEN UPPER(TRIM(metric_description)) IN (
          'ITENS INCLUIDOS',
          'FALTANTES'
        ) THEN 'ITENS INCLUÍDOS EM FALTANTES'

        WHEN UPPER(TRIM(metric_description)) IN (
          'CHECKIN',
          'ITENS CONFERIDOS NO CHECK-IN EM MERCEARIA',
          'ITENS CONFERIDOS NO CHECK-IN EM FRESH',
          'LISTA DE PEDIDOS CONFERIDOS NO CHECK-IN EM FRESH',
          'LISTA DE PEDIDOS CONFERIDOS NO CHECK-IN EM MERCEARIA'
        ) THEN 'ITENS BIPADOS NO CHECK-IN'

        WHEN UPPER(TRIM(metric_description)) IN (
          'AUDITORIA DE CONFERENCIA MERCEARIA',
          'AUDITORIA DE CONFERENCIA FRESH',
          'AUDITORIA DE CONFERENCIA MERCEARIA EXPRESS',
          'AUDITORIA DE CONFERENCIA FRESH EXPRESS'
        ) THEN UPPER(TRIM(metric_description))

        WHEN UPPER(TRIM(metric_description)) = 'VOLUMES EXPEDIDOS'
          THEN 'VOLUMES EXPEDIDOS'

        WHEN UPPER(TRIM(metric_description)) = 'VOLUMES SMD EXPEDIDOS'
          THEN 'VOLUMES SMD EXPEDIDOS'

        WHEN UPPER(TRIM(metric_description)) = 'PACKS FRACIONADOS'
          THEN 'PACKS FRACIONADOS'

        WHEN UPPER(TRIM(metric_description)) LIKE 'MAPEAMENTO DE LOTE REPOSIÇÃO%'
          THEN REPLACE(UPPER(TRIM(metric_description)), 'REPOSIÇÃO', 'REPOSICAO')

        WHEN UPPER(TRIM(metric_description)) LIKE 'MAPEAMENTO DE LOTE REPOSICAO%'
          THEN UPPER(TRIM(metric_description))

        WHEN UPPER(TRIM(metric_description)) LIKE 'MAPEAMENTO DE LOTE RECEBIMENTO%'
          THEN UPPER(TRIM(metric_description))

        WHEN UPPER(TRIM(metric_description)) LIKE 'REPOSIÇÃO%'
          THEN REPLACE(UPPER(TRIM(metric_description)), 'REPOSIÇÃO', 'REPOSICAO')

        WHEN UPPER(TRIM(metric_description)) LIKE 'REPOSICAO%'
          THEN UPPER(TRIM(metric_description))

        ELSE UPPER(TRIM(metric_description))
      END AS atividade_padronizada

    FROM `shopper-datalakehouse-qa.Ranking_Performance.performance_extract_points_table`
    WHERE UPPER(TRIM(metric_description)) NOT IN (
        'ITENS RECEBIDOS',
        'ITENS REPOSTOS NA GÔNDULA',
        'ITENS COLETADOS NA RESERVA'
      )
      AND qty > 0
  ),

  Check_Reposicao AS (
    SELECT
      MATRICULA_STR,
      semana,
      LOGICAL_OR(
        atividade_padronizada LIKE 'REPOSICAO%'
        OR atividade_padronizada LIKE 'REPOSIÇÃO%'
      ) AS fez_reposicao
    FROM Base_Padronizada
    GROUP BY 1, 2
  ),

  Check_Recebimento AS (
    SELECT
      MATRICULA_STR,
      semana,
      LOGICAL_OR(
        (
          atividade_padronizada LIKE '%CAIXARIAS%'
          OR atividade_padronizada LIKE '%RECEBIDA%'
          OR atividade_padronizada LIKE '%RECEBIMENTO%'
        )
        AND UPPER(atividade_padronizada) NOT LIKE '%MAPEAMENTO%'
      ) AS fez_recebimento
    FROM Base_Padronizada
    GROUP BY 1, 2
  ),

  Pontos_Atividade AS (
    SELECT
      MATRICULA_STR,
      atividade_padronizada AS descricao_atividade,
      semana,
      SUM(pontos_ponderados) AS total_pontos,
      SUM(quantidade_pontuada) AS total_itens,
      SAFE_DIVIDE(SUM(pontos_ponderados), SUM(quantidade_pontuada)) AS peso_real
    FROM Base_Padronizada
    WHERE pontos_ponderados > 0
    GROUP BY 1, 2, 3
  ),

  Atividade_Principal AS (
    SELECT
      MATRICULA_STR,
      semana,
      peso_real
    FROM Pontos_Atividade
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY MATRICULA_STR, semana
      ORDER BY total_pontos DESC
    ) = 1
  ),

  Totais_Gerais AS (
    SELECT
      MATRICULA_STR,
      semana,
      SAFE_DIVIDE(SUM(pontos_ponderados), SUM(quantidade_pontuada)) AS peso_medio_geral,
      COUNT(1) AS total_movimentacoes_reais
    FROM Base_Padronizada
    WHERE pontos_ponderados > 0
    GROUP BY 1, 2
  ),

  Ranking_Pre AS (
    SELECT
      r.*,

      CASE
        WHEN UPPER(TRIM(r.FC)) = 'FC2'
          AND UPPER(TRIM(r.turno)) IN ('TARDE', 'INTERMEDIÁRIO', 'INTERMEDIARIO')
          THEN 'TARDE + INTERMEDIÁRIO'
        ELSE UPPER(TRIM(r.turno))
      END AS turno_top1,

      LAG(r.pontuacao_final) OVER (
        PARTITION BY CAST(r.MATRICULA AS STRING)
        ORDER BY r.data_inicio_periodo
      ) AS pontos_finais_anterior,

      LAG(r.valid_points * r.EXPECTED_FACTOR) OVER (
        PARTITION BY CAST(r.MATRICULA AS STRING)
        ORDER BY r.data_inicio_periodo
      ) AS pontos_producao_anterior,

      MAX(
        CASE
          WHEN r.pontuacao_final >= 1000000
            AND r.motivo_desqualificacao IS NULL
            AND UPPER(COALESCE(r.status_ranking, '')) NOT LIKE '%LIDERANÇA%'
          THEN r.pontuacao_final
          ELSE NULL
        END
      ) OVER (
        PARTITION BY r.FC, r.data_inicio_periodo
      ) AS max_pontos_setor_turno_semana

    FROM (
      SELECT *
      FROM `shopper-datalakehouse-qa.Ranking_Performance.Ranking Semanal`
      QUALIFY ROW_NUMBER() OVER (
        PARTITION BY MATRICULA, data_inicio_periodo
        ORDER BY pontuacao_final DESC
      ) = 1
    ) r
    WHERE UPPER(TRIM(r.atribuicao)) NOT LIKE '%SUPERVISOR%'
      AND NOT (
        UPPER(TRIM(r.atribuicao)) LIKE '%FISCAL%'
        AND UPPER(TRIM(r.setor_principal)) NOT IN (
          'PACKING',
          'OPERAÇÃO FRESH',
          'OPERACAO FRESH'
        )
      )
  ),

  Maior_Buraco AS (
    SELECT
      curr.MATRICULA_STR,
      curr.semana,
      curr.descricao_atividade,
      COALESCE(prev.total_itens, 0) - curr.total_itens AS gap_itens,
      (COALESCE(prev.total_itens, 0) - curr.total_itens) * curr.peso_real AS gap_pontos
    FROM Pontos_Atividade curr
    LEFT JOIN Pontos_Atividade prev
      ON curr.MATRICULA_STR = prev.MATRICULA_STR
     AND curr.descricao_atividade = prev.descricao_atividade
     AND prev.semana = DATE_SUB(curr.semana, INTERVAL 1 WEEK)
    WHERE COALESCE(prev.total_itens, 0) - curr.total_itens > 0
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY MATRICULA_STR, semana
      ORDER BY gap_itens DESC
    ) = 1
  ),

  Ocorrencias_Desqualificantes AS (
    SELECT
      CAST(CRACHA AS STRING) AS CRACHA_STR,
      CAST(DATA_INICIO AS DATE) AS data_inicio,
      STRING_AGG(DISTINCT TIPO_OCORRENCIA, ', ') AS motivos_ocorrencia
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Ocorrencias_Semana`
    GROUP BY 1, 2
  ),

  Reforco_Operacao AS (
    SELECT DISTINCT
      CAST(TRIM(CAST(matricula AS STRING)) AS STRING) AS matricula
    FROM `shopper-datalakehouse-qa.Ranking_Performance.reforco_operacao`
    WHERE matricula IS NOT NULL
      AND TRIM(CAST(matricula AS STRING)) <> ''
  ),

  Calculo_Final AS (
    SELECT
      r.data_inicio_periodo AS data_inicio,
      r.data_fim_periodo AS data_final,
      CAST(o.CRACHA AS STRING) AS CRACHA,
      r.MATRICULA,
      o.NOME,
      o.TURNO,
      o.SETOR AS setor,
      r.atribuicao,
      a.Direito_a_Premiacao AS assiduidade_status,
      r.FC,
      r.status_ranking,
      kpi.OBSERVACAO_KPI AS observacao_kpi,
      COALESCE(od.motivos_ocorrencia, r.motivo_desqualificacao) AS motivo_desqualificacao,
      r.saldo_da_carteira,

      r.pontuacao_final AS pontos_finais_atuais,
      COALESCE(r.pontos_finais_anterior, 0) AS pontos_finais_anterior,
      r.pontuacao_final - COALESCE(r.pontos_finais_anterior, 0) AS delta_pontuacao,

      du.data_admissao,

      COALESCE(r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1) AS pontos_conquistados_ponderados,
      ABS(COALESCE(r.PONTOS_NEGATIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1)) AS pontos_perdidos,

      mb.descricao_atividade AS atividade_queda_real,
      COALESCE(mb.gap_pontos, 0) AS pontos_perdidos_gap,
      COALESCE(ap.peso_real, 1) AS peso_atividade_principal,

      IF(
        cr.fez_reposicao OR crec.fez_recebimento,
        COALESCE(tg.peso_medio_geral, ap.peso_real, 1),
        0
      ) AS peso_medio_geral,

      GREATEST(
        0,
        1000000 - (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
      ) AS quanto_falta_1m,

      GREATEST(
        0,
        1500000 - (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
      ) AS pontos_faltantes_1_5m,

      CEIL(
        COALESCE(
          SAFE_DIVIDE(
            GREATEST(
              0,
              1000000 - (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
            ),
            COALESCE(ap.peso_real, 1)
          ),
          0
        )
      ) AS itens_faltantes_1m,

      CEIL(
        COALESCE(
          SAFE_DIVIDE(
            GREATEST(
              0,
              1500000 - (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
            ),
            COALESCE(ap.peso_real, 1)
          ),
          0
        )
      ) AS itens_faltantes_1_5m,

      CEIL(
        COALESCE(
          ABS(
            (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
            - COALESCE(
                r.pontos_producao_anterior,
                (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
              )
          ) / COALESCE(ap.peso_real, 1),
          0
        )
      ) AS itens_proximos_para_ritmo,

      IF(
        cr.fez_reposicao,
        CEIL(
          COALESCE(
            SAFE_DIVIDE(
              GREATEST(
                0,
                1000000 - (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
              ),
              COALESCE(tg.peso_medio_geral, ap.peso_real, 1)
            ),
            0
          )
        ),
        0
      ) AS movimentacoes_faltantes_1m,

      IF(
        cr.fez_reposicao,
        CEIL(
          COALESCE(
            SAFE_DIVIDE(
              GREATEST(
                0,
                1500000 - (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
              ),
              COALESCE(tg.peso_medio_geral, ap.peso_real, 1)
            ),
            0
          )
        ),
        0
      ) AS movimentacoes_faltantes_1_5m,

      IF(
        cr.fez_reposicao,
        CEIL(
          COALESCE(
            SAFE_DIVIDE(
              GREATEST(
                0,
                r.max_pontos_setor_turno_semana
                  - (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
              ),
              COALESCE(tg.peso_medio_geral, ap.peso_real, 1)
            ),
            0
          )
        ),
        0
      ) AS movimentacoes_faltantes_top1,

      IF(cr.fez_reposicao, COALESCE(tg.total_movimentacoes_reais, 0), 0) AS total_movimentacoes_reais,

      CAST(
        IF(
          crec.fez_recebimento,
          CEIL(
            COALESCE(
              SAFE_DIVIDE(
                GREATEST(
                  0,
                  1000000 - (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
                ),
                COALESCE(tg.peso_medio_geral, ap.peso_real, 1)
              ),
              0
            )
          ),
          0
        ) AS INT64
      ) AS recebimentos_faltantes_1m,

      CAST(
        IF(
          crec.fez_recebimento,
          CEIL(
            COALESCE(
              SAFE_DIVIDE(
                GREATEST(
                  0,
                  1500000 - (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
                ),
                COALESCE(tg.peso_medio_geral, ap.peso_real, 1)
              ),
              0
            )
          ),
          0
        ) AS INT64
      ) AS recebimentos_faltantes_1_5m,

      CAST(
        IF(
          crec.fez_recebimento,
          CEIL(
            COALESCE(
              SAFE_DIVIDE(
                GREATEST(
                  0,
                  r.max_pontos_setor_turno_semana
                    - (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
                ),
                COALESCE(tg.peso_medio_geral, ap.peso_real, 1)
              ),
              0
            )
          ),
          0
        ) AS INT64
      ) AS recebimentos_faltantes_top1,

      CAST(
        IF(crec.fez_recebimento, COALESCE(tg.total_movimentacoes_reais, 0), 0) AS INT64
      ) AS total_recebimentos_reais,

      IF(
        r.max_pontos_setor_turno_semana <= 1000000,
        cfg.valor_minimo,
        cfg.valor_minimo
          + (
            (
              (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
              - 1000000
            ) / NULLIF(r.max_pontos_setor_turno_semana - 1000000, 0)
          ) * (cfg.valor_maximo - cfg.valor_minimo)
      ) AS valor_r_atual_simulado,

      LEAST(
        cfg.valor_maximo,
        IF(
          r.max_pontos_setor_turno_semana <= 1000000,
          cfg.valor_minimo,
          cfg.valor_minimo
            + (
              (
                (
                  (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
                  + COALESCE(mb.gap_pontos, 0)
                ) - 1000000
              ) / NULLIF(r.max_pontos_setor_turno_semana - 1000000, 0)
            ) * (cfg.valor_maximo - cfg.valor_minimo)
        )
      ) AS valor_r_simulado_queda,

      LEAST(
        cfg.valor_maximo,
        IF(
          r.max_pontos_setor_turno_semana <= 1000000,
          cfg.valor_minimo,
          cfg.valor_minimo
            + (
              (
                (
                  (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
                  + ABS(COALESCE(r.PONTOS_NEGATIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
                ) - 1000000
              ) / NULLIF(r.max_pontos_setor_turno_semana - 1000000, 0)
            ) * (cfg.valor_maximo - cfg.valor_minimo)
        )
      ) AS valor_r_sem_erros,

      LEAST(
        cfg.valor_maximo,
        IF(
          r.max_pontos_setor_turno_semana <= 1000000,
          cfg.valor_minimo,
          cfg.valor_minimo
            + (
              (
                (
                  (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
                  + (COALESCE(r.PONTOS_POSITIVOS, 0) * 0.20 * COALESCE(r.EXPECTED_FACTOR, 1))
                ) - 1000000
              ) / NULLIF(r.max_pontos_setor_turno_semana - 1000000, 0)
            ) * (cfg.valor_maximo - cfg.valor_minimo)
        )
      ) AS valor_r_mais_20_pct,

      LEAST(
        cfg.valor_maximo,
        IF(
          r.max_pontos_setor_turno_semana <= 1000000,
          cfg.valor_minimo,
          cfg.valor_minimo
            + (
              (
                (
                  (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
                  + GREATEST(
                      0,
                      (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
                      - COALESCE(
                          r.pontos_producao_anterior,
                          (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
                        )
                    )
                ) - 1000000
              ) / NULLIF(r.max_pontos_setor_turno_semana - 1000000, 0)
            ) * (cfg.valor_maximo - cfg.valor_minimo)
        )
      ) AS valor_r_projetado_delta_pos,

      LEAST(
        cfg.valor_maximo,
        IF(
          r.max_pontos_setor_turno_semana <= 1000000,
          cfg.valor_minimo,
          cfg.valor_minimo
            + (
              (
                GREATEST(
                  (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1)),
                  COALESCE(
                    r.pontos_producao_anterior,
                    (COALESCE(r.valid_points, r.PONTOS_POSITIVOS, 0) * COALESCE(r.EXPECTED_FACTOR, 1))
                  )
                ) - 1000000
              ) / NULLIF(r.max_pontos_setor_turno_semana - 1000000, 0)
            ) * (cfg.valor_maximo - cfg.valor_minimo)
        )
      ) AS valor_r_projetado_delta_neg,

      IF(ro.matricula IS NOT NULL, TRUE, FALSE) AS reforco_operacao

    FROM Ranking_Pre r
    LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Organograma` o
      ON CAST(r.MATRICULA AS STRING) = CAST(o.MATRICULA AS STRING)
    LEFT JOIN Maior_Buraco mb
      ON CAST(r.MATRICULA AS STRING) = mb.MATRICULA_STR
     AND r.data_inicio_periodo = mb.semana
    LEFT JOIN Atividade_Principal ap
      ON CAST(r.MATRICULA AS STRING) = ap.MATRICULA_STR
     AND r.data_inicio_periodo = ap.semana
    LEFT JOIN Totais_Gerais tg
      ON CAST(r.MATRICULA AS STRING) = tg.MATRICULA_STR
     AND r.data_inicio_periodo = tg.semana
    LEFT JOIN Check_Reposicao cr
      ON CAST(r.MATRICULA AS STRING) = cr.MATRICULA_STR
     AND r.data_inicio_periodo = cr.semana
    LEFT JOIN Check_Recebimento crec
      ON CAST(r.MATRICULA AS STRING) = crec.MATRICULA_STR
     AND r.data_inicio_periodo = crec.semana
    LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Assiduidade` a
      ON TRIM(CAST(r.MATRICULA AS STRING)) = TRIM(CAST(a.Matricula AS STRING))
     AND CAST(r.data_inicio_periodo AS DATE) = CAST(a.data_inicio_periodo AS DATE)
    LEFT JOIN Ocorrencias_Desqualificantes od
      ON CAST(o.CRACHA AS STRING) = od.CRACHA_STR
     AND CAST(r.data_inicio_periodo AS DATE) = CAST(od.data_inicio AS DATE)
    LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.KPIs_OPERAÇÃO` kpi
      ON CAST(r.MATRICULA AS STRING) = CAST(kpi.MATRICULA AS STRING)
     AND CAST(r.data_inicio_periodo AS DATE) = CAST(kpi.data_inicio AS DATE)
    LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Dados Usuários` du
      ON TRIM(CAST(r.MATRICULA AS STRING)) = TRIM(CAST(du.matricula AS STRING))
    LEFT JOIN Reforco_Operacao ro
      ON TRIM(CAST(r.MATRICULA AS STRING)) = TRIM(CAST(ro.matricula AS STRING))
    CROSS JOIN (
      SELECT valor_minimo, valor_maximo
      FROM `shopper-datalakehouse-qa.Ranking_Performance.Config_Bonificacao_Ranking`
      LIMIT 1
    ) cfg
  )

  SELECT
    * EXCEPT(
      data_admissao,
      saldo_da_carteira,
      peso_medio_geral,
      movimentacoes_faltantes_1m,
      movimentacoes_faltantes_1_5m,
      movimentacoes_faltantes_top1,
      total_movimentacoes_reais,
      recebimentos_faltantes_1m,
      recebimentos_faltantes_1_5m,
      recebimentos_faltantes_top1,
      total_recebimentos_reais,
      reforco_operacao
    ),

    ROUND(SAFE_DIVIDE(valor_r_simulado_queda - valor_r_atual_simulado, valor_r_atual_simulado), 4) AS perda_queda_perc_financeira,
    ROUND(SAFE_DIVIDE(valor_r_sem_erros - valor_r_atual_simulado, valor_r_atual_simulado), 4) AS perda_erros_perc_financeira,
    ROUND(SAFE_DIVIDE(valor_r_mais_20_pct - valor_r_atual_simulado, valor_r_atual_simulado), 4) AS projecao_aumento_perc_financeira,
    ROUND(SAFE_DIVIDE(valor_r_projetado_delta_pos - valor_r_atual_simulado, valor_r_atual_simulado), 4) AS projecao_delta_pos_perc,
    ROUND(SAFE_DIVIDE(valor_r_projetado_delta_neg - valor_r_atual_simulado, valor_r_atual_simulado), 4) AS perda_delta_neg_perc,

    saldo_da_carteira,
    peso_medio_geral,
    movimentacoes_faltantes_1m,
    movimentacoes_faltantes_1_5m,
    movimentacoes_faltantes_top1,
    total_movimentacoes_reais,
    recebimentos_faltantes_1m,
    recebimentos_faltantes_1_5m,
    recebimentos_faltantes_top1,
    total_recebimentos_reais,

    (
      pontos_finais_anterior > 0
      AND delta_pontuacao >= 200000
      AND pontos_finais_atuais >= 700000
      AND pontos_finais_atuais < 1000000
      AND UPPER(COALESCE(status_ranking, '')) NOT LIKE '%ZERAD%'
      AND UPPER(COALESCE(status_ranking, '')) NOT LIKE '%DESQUALIFICAD%'
    ) AS boa_evolucao,

    (
      pontos_finais_atuais = MAX(pontos_finais_atuais) OVER (
        PARTITION BY
          data_inicio,
          FC,
          setor,
          CASE
            WHEN UPPER(TRIM(FC)) = 'FC2'
              AND UPPER(TRIM(TURNO)) IN ('TARDE', 'INTERMEDIÁRIO', 'INTERMEDIARIO')
              THEN 'TARDE + INTERMEDIÁRIO'
            ELSE UPPER(TRIM(TURNO))
          END
      )
      AND pontos_finais_atuais > 0
      AND UPPER(TRIM(setor)) IN (
        'PACKING',
        'PICKING',
        'OPERAÇÃO FRESH',
        'OPERACAO FRESH',
        'EXPEDIÇÃO',
        'EXPEDICAO'
      )
      AND UPPER(COALESCE(status_ranking, '')) NOT LIKE '%ZERAD%'
      AND UPPER(COALESCE(status_ranking, '')) NOT LIKE '%DESQUALIFICAD%'
    ) AS top_1_setor,

    (
      CAST(data_admissao AS DATE) >= CAST(data_inicio AS DATE)
      AND CAST(data_admissao AS DATE) <= CAST(data_final AS DATE)
      AND pontos_finais_atuais > 500000
      AND UPPER(COALESCE(status_ranking, '')) NOT LIKE '%ZERAD%'
      AND UPPER(COALESCE(status_ranking, '')) NOT LIKE '%DESQUALIFICAD%'
    ) AS bom_comeco,

    reforco_operacao

  FROM Calculo_Final
  WHERE data_inicio = (
    SELECT MAX(data_inicio_periodo)
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Ranking Semanal`
  );

END;
