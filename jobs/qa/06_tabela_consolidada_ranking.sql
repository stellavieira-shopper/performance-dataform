CREATE OR REPLACE TABLE `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Consolidada_Ranking` AS

WITH
  -- ========================================================================
  -- GRUPO 1: LIDERANÇA OPERACIONAL (FISCAIS)
  -- ========================================================================
  DadosFiscais AS (
    SELECT
      f.data_inicio_periodo,
      f.MATRICULA_FISCAL AS MATRICULA,
      f.nome_fiscal AS NOME,
      f.FC,
      f.TURNO,
      f.SETOR,
      f.atribuicao_fiscal AS ATRIBUICAO,
      f.PONTUACAO_COMBINADA_FISCAL AS PONTUACAO_FINAL,

      CASE
        WHEN f.motivos_desqualificacao_fiscal IS NOT NULL
          AND f.motivos_desqualificacao_fiscal != ''
          THEN f.motivos_desqualificacao_fiscal
        WHEN f.VALOR_BONIFICACAO_FISCAL = 0
          THEN 'Pontuação Insuficiente ou Equipe sem Bonificados'
        ELSE NULL
      END AS MOTIVO_ORIGINAL,

      f.VALOR_FISCAL_ANTES_DO_KPI AS VALOR_ANTES_KPI,
      f.VALOR_BONIFICACAO_FISCAL AS VALOR_BONUS,

      CASE
        WHEN COALESCE(f.faltas_fiscal, 0) > 0
          OR COALESCE(f.atestados_fiscal, 0) > 0
          OR COALESCE(f.advertencias_fiscal, 0) > 0
          OR COALESCE(f.alocacoes_indevidas_fiscal, 0) > 0
          OR UPPER(f.motivos_desqualificacao_fiscal) LIKE '%ESCALA ZERADA%'
          OR UPPER(f.motivos_desqualificacao_fiscal) LIKE '%RANKING ZERADO%'
          OR UPPER(f.motivos_desqualificacao_fiscal) LIKE '%EQUIPE COM MENOS%'
          THEN 0
        ELSE 1
      END AS IS_APTO,

      'FISCAL' AS TIPO_CALCULO,
      CAST(NULL AS STRING) AS STATUS_ORIGINAL
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais` AS f
    WHERE NOT (
      DATE(f.data_inicio_periodo) >= DATE '2026-05-15'
      AND UPPER(TRIM(f.SETOR)) IN (
        'PACKING',
        'OPERAÇÃO FRESH',
        'OPERACAO FRESH'
      )
    )
  ),

  -- ========================================================================
  -- GRUPO 2: SUPERVISORES
  -- ========================================================================
  DadosSupervisores AS (
    SELECT
      s.data_inicio_periodo,
      s.MATRICULA_SUPERVISOR AS MATRICULA,
      s.nome_supervisor AS NOME,
      s.FC,
      s.TURNO,
      s.SETOR,
      s.atribuicao_supervisor AS ATRIBUICAO,
      s.PONTUACAO_COMBINADA_SUPERVISOR AS PONTUACAO_FINAL,

      CASE
        WHEN s.motivos_desqualificacao_supervisor IS NOT NULL
          AND s.motivos_desqualificacao_supervisor != ''
          THEN s.motivos_desqualificacao_supervisor
        WHEN s.VALOR_BONIFICACAO_SUPERVISOR = 0
          THEN 'Pontuação Insuficiente ou Setor sem Bonificados'
        ELSE NULL
      END AS MOTIVO_ORIGINAL,

      s.VALOR_SUPERVISOR_ANTES_DO_KPI AS VALOR_ANTES_KPI,
      s.VALOR_BONIFICACAO_SUPERVISOR AS VALOR_BONUS,

      CASE
        WHEN COALESCE(s.sup_contagem_faltas, 0) > 0
          OR COALESCE(s.sup_contagem_atestados, 0) > 0
          OR COALESCE(s.sup_contagem_advertencias, 0) > 0
          OR COALESCE(s.sup_contagem_alocacoes_indevidas, 0) > 0
          OR UPPER(s.motivos_desqualificacao_supervisor) LIKE '%ESCALA ZERADA%'
          OR UPPER(s.motivos_desqualificacao_supervisor) LIKE '%RANKING ZERADO%'
          THEN 0
        ELSE 1
      END AS IS_APTO,

      'SUPERVISOR' AS TIPO_CALCULO,
      CAST(NULL AS STRING) AS STATUS_ORIGINAL
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Supervisores` AS s
  ),

  -- ========================================================================
  -- GRUPO 3: NÃO MEDÍVEIS
  -- ========================================================================
  DadosNaoMediveis AS (
    SELECT
      n.data_inicio_periodo,
      n.MATRICULA,
      n.NOME,
      n.FC,
      n.TURNO,
      n.SETOR,
      n.ATRIBUICAO,
      n.PONTUACAO_ATRIBUIDA AS PONTUACAO_FINAL,

      CASE
        WHEN n.MOTIVO_DESQUALIFICACAO IS NOT NULL
          AND n.MOTIVO_DESQUALIFICACAO != ''
          THEN n.MOTIVO_DESQUALIFICACAO
        WHEN n.VALOR_BONIFICACAO = 0
          THEN 'Pontuação Insuficiente / Regra de Turno'
        ELSE NULL
      END AS MOTIVO_ORIGINAL,

      n.VALOR_A_RECEBER_ANTES_DO_KPI AS VALOR_ANTES_KPI,
      n.VALOR_BONIFICACAO AS VALOR_BONUS,

      CASE
        WHEN COALESCE(n.qtd_faltas, 0) > 0
          OR COALESCE(n.qtd_atestados, 0) > 0
          OR COALESCE(n.qtd_advertencias, 0) > 0
          OR UPPER(n.MOTIVO_DESQUALIFICACAO) LIKE '%ALOCAÇÃO%'
          OR UPPER(n.MOTIVO_DESQUALIFICACAO) LIKE '%ESCALA ZERADA%'
          OR UPPER(n.MOTIVO_DESQUALIFICACAO) LIKE '%RANKING ZERADO%'
          OR UPPER(n.MOTIVO_DESQUALIFICACAO) LIKE '%SEM PRODUÇÃO%'
          THEN 0
        ELSE 1
      END AS IS_APTO,

      'NAO_MEDIVEL' AS TIPO_CALCULO,
      CAST(NULL AS STRING) AS STATUS_ORIGINAL
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Colaboradores Nao Mediveis` AS n
  ),

  -- ========================================================================
  -- GRUPO 4: COLABORADORES OPERACIONAIS (MEDÍVEIS)
  -- ========================================================================
  DadosColaboradores AS (
    SELECT
      r.data_inicio_periodo,
      CAST(r.MATRICULA AS INT64) AS MATRICULA,
      COALESCE(p.NOME, CAST(r.MATRICULA AS STRING)) AS NOME,
      r.FC,
      r.TURNO,
      r.SETOR_PRINCIPAL AS SETOR,
      r.ATRIBUICAO,
      r.PONTUACAO_FINAL AS PONTUACAO_FINAL,

      CASE
        WHEN UPPER(r.status_ranking) LIKE '%(IA RECEBER)%'
          OR UPPER(r.status_ranking) LIKE '%(NÃO IA RECEBER)%'
          THEN r.status_ranking
        WHEN r.MOTIVO_DESQUALIFICACAO IS NOT NULL
          AND r.MOTIVO_DESQUALIFICACAO != ''
          THEN r.MOTIVO_DESQUALIFICACAO
        WHEN r.VALOR_BONIFICACAO = 0
          THEN 'Pontuação Insuficiente'
        ELSE NULL
      END AS MOTIVO_ORIGINAL,

      r.VALOR_A_RECEBER_ANTES_DO_KPI AS VALOR_ANTES_KPI,
      r.VALOR_BONIFICACAO AS VALOR_BONUS,

      CASE
        WHEN COALESCE(r.FALTAS, 0) > 0
          OR COALESCE(r.ATESTADOS, 0) > 0
          OR COALESCE(r.ADVERTENCIAS, 0) > 0
          OR COALESCE(r.ALOCACAO_INDEVIDA, 0) > 0
          OR UPPER(r.MOTIVO_DESQUALIFICACAO) LIKE '%SUSPENSÃO%'
          OR UPPER(r.MOTIVO_DESQUALIFICACAO) LIKE '%ESCALA ZERADA%'
          OR UPPER(r.MOTIVO_DESQUALIFICACAO) LIKE '%RANKING ZERADO%'
          THEN 0
        ELSE 1
      END AS IS_APTO,

      'MEDIVEL' AS TIPO_CALCULO,
      CAST(r.status_ranking AS STRING) AS STATUS_ORIGINAL
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Ranking Semanal` AS r
    LEFT JOIN (
      SELECT
        MATRICULA,
        NOME,
        ROW_NUMBER() OVER (
          PARTITION BY MATRICULA
          ORDER BY DATA_ADM DESC
        ) AS rn
      FROM `shopper-datalakehouse-qa.Ranking_Performance.Organograma`
    ) AS p
      ON CAST(r.MATRICULA AS INT64) = CAST(p.MATRICULA AS INT64)
     AND p.rn = 1
    WHERE
      (
        -- Regra antiga antes de 15/05/2026:
        -- remove todos os fiscais e supervisores dos medíveis.
        (
          DATE(r.data_inicio_periodo) < DATE '2026-05-15'
          AND UPPER(TRIM(r.ATRIBUICAO)) NOT LIKE '%FISCAL%'
          AND UPPER(TRIM(r.ATRIBUICAO)) NOT LIKE '%SUPERVISOR%'
        )

        OR

        -- Regra nova a partir de 15/05/2026:
        -- supervisor continua fora;
        -- fiscal só entra como medível se for de PACKING ou OPERAÇÃO FRESH.
        (
          DATE(r.data_inicio_periodo) >= DATE '2026-05-15'
          AND UPPER(TRIM(r.ATRIBUICAO)) NOT LIKE '%SUPERVISOR%'
          AND NOT (
            UPPER(TRIM(r.ATRIBUICAO)) LIKE '%FISCAL%'
            AND UPPER(TRIM(r.SETOR_PRINCIPAL)) NOT IN (
              'PACKING',
              'OPERAÇÃO FRESH',
              'OPERACAO FRESH'
            )
          )
        )
      )

      AND CAST(r.MATRICULA AS INT64) NOT IN (
        SELECT CAST(MATRICULA AS INT64)
        FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Colaboradores Nao Mediveis`
        WHERE MATRICULA IS NOT NULL
          AND data_inicio_periodo = r.data_inicio_periodo
      )

      AND (
        DATE(r.data_inicio_periodo) >= DATE '2026-05-15'
        AND UPPER(TRIM(r.ATRIBUICAO)) LIKE '%FISCAL%'
        AND UPPER(TRIM(r.SETOR_PRINCIPAL)) IN (
          'PACKING',
          'OPERAÇÃO FRESH',
          'OPERACAO FRESH'
        )
        OR CAST(r.MATRICULA AS INT64) NOT IN (
          SELECT CAST(MATRICULA_FISCAL AS INT64)
          FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Fiscais`
          WHERE MATRICULA_FISCAL IS NOT NULL
            AND data_inicio_periodo = r.data_inicio_periodo
        )
      )

      AND CAST(r.MATRICULA AS INT64) NOT IN (
        SELECT CAST(MATRICULA_SUPERVISOR AS INT64)
        FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Supervisores`
        WHERE MATRICULA_SUPERVISOR IS NOT NULL
          AND data_inicio_periodo = r.data_inicio_periodo
      )
  ),

  BaseUnificada AS (
    SELECT * FROM DadosColaboradores
    UNION ALL
    SELECT * FROM DadosFiscais
    UNION ALL
    SELECT * FROM DadosSupervisores
    UNION ALL
    SELECT * FROM DadosNaoMediveis
  ),

  -- ========================================================================
  -- GRUPO 5: AGRUPAMENTO DE OCORRÊNCIAS SEMANAIS
  -- ========================================================================
  OcorrenciasAgrupadas AS (
    SELECT
      CAST(MATRICULA AS INT64) AS MATRICULA,
      DATA_INICIO AS data_inicio_periodo,
      STRING_AGG(TIPO_OCORRENCIA, ' | ') AS TIPOS_OCORRENCIA,
      STRING_AGG(
        CONCAT(
          TIPO_OCORRENCIA,
          ' (',
          CAST(QTD_OCORRENCIAS AS STRING),
          '): ',
          LISTA_DETALHES
        ),
        ' || '
      ) AS LISTA_TODAS_OCORRENCIAS
    FROM `shopper-datalakehouse-qa.Ranking_Performance.View_Detalhe_Ocorrencias_Semanal`
    GROUP BY MATRICULA, DATA_INICIO
  )

-- ========================================================================
-- CÁLCULO FINAL - STATUS RANKING MATEMÁTICO ESTRITO
-- ========================================================================
SELECT
  CAST(b.data_inicio_periodo AS DATE) AS data_inicio_periodo,
  CAST(b.MATRICULA AS INT64) AS MATRICULA,
  CAST(b.NOME AS STRING) AS NOME,
  CAST(b.FC AS STRING) AS FC,
  CAST(b.TURNO AS STRING) AS TURNO,
  CAST(b.SETOR AS STRING) AS SETOR,
  CAST(b.ATRIBUICAO AS STRING) AS ATRIBUICAO,
  CAST(b.PONTUACAO_FINAL AS FLOAT64) AS PONTUACAO_FINAL,

  CAST(COALESCE(ass.Direito_a_Premiacao, 'NÃO INFORMADO') AS STRING) AS ASSIDUIDADE,

  CAST(COALESCE(b.VALOR_ANTES_KPI, b.VALOR_BONUS, 0) AS FLOAT64) AS VALOR_A_RECEBER_ANTES_DO_KPI,
  CAST(COALESCE(b.VALOR_BONUS, 0) AS FLOAT64) AS VALOR_BONIFICACAO,

  CAST(
    IF(
      COALESCE(b.VALOR_ANTES_KPI, b.VALOR_BONUS, 0) > COALESCE(b.VALOR_BONUS, 0),
      ROUND(
        COALESCE(b.VALOR_ANTES_KPI, b.VALOR_BONUS, 0)
        - COALESCE(b.VALOR_BONUS, 0),
        2
      ),
      0
    ) AS FLOAT64
  ) AS DELTA_BONIFICACAO_KPI,

  CAST(COALESCE(oc.TIPOS_OCORRENCIA, b.MOTIVO_ORIGINAL) AS STRING) AS MOTIVO_DESQUALIFICACAO,

  CAST(oc.LISTA_TODAS_OCORRENCIAS AS STRING) AS LISTA_TODAS_OCORRENCIAS,

  CAST(
    CASE
      WHEN b.VALOR_BONUS > 0 THEN 'BONIFICADO'

      WHEN UPPER(b.MOTIVO_ORIGINAL) LIKE '%(IA RECEBER)%'
        OR UPPER(b.STATUS_ORIGINAL) LIKE '%(IA RECEBER)%'
        THEN 'BONIFICAÇÃO ZERADA POR ERRO CLIENTE/RUPTURA (IA RECEBER)'

      WHEN UPPER(b.MOTIVO_ORIGINAL) LIKE '%(NÃO IA RECEBER)%'
        OR UPPER(b.STATUS_ORIGINAL) LIKE '%(NÃO IA RECEBER)%'
        THEN 'BONIFICAÇÃO ZERADA POR ERRO CLIENTE/RUPTURA (NÃO IA RECEBER)'

      WHEN b.IS_APTO = 1
        AND COALESCE(b.VALOR_ANTES_KPI, b.VALOR_BONUS, 0) > 0
        AND COALESCE(b.VALOR_BONUS, 0) = 0
        THEN 'BONIFICAÇÃO ZERADA POR ERRO CLIENTE/RUPTURA (IA RECEBER)'

      WHEN b.IS_APTO = 1 THEN 'ELEGÍVEL'

      ELSE 'DESQUALIFICADO'
    END AS STRING
  ) AS STATUS_RANKING,

  CAST(
    CASE
      WHEN UPPER(b.MOTIVO_ORIGINAL) LIKE '%(IA RECEBER)%'
        OR UPPER(b.STATUS_ORIGINAL) LIKE '%(IA RECEBER)%'
        OR UPPER(b.MOTIVO_ORIGINAL) LIKE '%(NÃO IA RECEBER)%'
        OR UPPER(b.STATUS_ORIGINAL) LIKE '%(NÃO IA RECEBER)%'
        OR (
          b.IS_APTO = 1
          AND COALESCE(b.VALOR_ANTES_KPI, b.VALOR_BONUS, 0) > 0
          AND COALESCE(b.VALOR_BONUS, 0) = 0
        )
        THEN TRUE
      ELSE FALSE
    END AS BOOL
  ) AS IS_ZERADO_ERRO_CLIENTE_RUPTURA,

  CAST(
    CASE
      WHEN (
        COALESCE(b.VALOR_ANTES_KPI, b.VALOR_BONUS, 0)
        - COALESCE(b.VALOR_BONUS, 0)
      ) > 0.01
        AND b.VALOR_BONUS > 0
        THEN TRUE
      ELSE FALSE
    END AS BOOL
  ) AS IS_REDUZIDO_KPI,

  CAST(b.IS_APTO AS INT64) AS IS_APTO,
  CAST(b.TIPO_CALCULO AS STRING) AS TIPO_CALCULO

FROM BaseUnificada b

LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.Assiduidade` ass
  ON CAST(b.MATRICULA AS INT64) = CAST(ass.Matricula AS INT64)
 AND b.data_inicio_periodo = ass.data_inicio_periodo

LEFT JOIN OcorrenciasAgrupadas oc
  ON CAST(b.MATRICULA AS INT64) = oc.MATRICULA
 AND b.data_inicio_periodo = oc.data_inicio_periodo

WHERE DATE(b.data_inicio_periodo) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY);
