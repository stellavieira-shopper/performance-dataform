-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
-- Última atualização: 27/08/2026
-- ATENÇÃO: Não rodar sem antes atualizar as matrículas e mensagens da semana

BEGIN

  -- 1. CONFIGURAÇÃO DE DATAS AUTOMÁTICA (Sexta a Quinta)
  DECLARE v_start_date DATE;
  DECLARE v_end_date DATE;

  SET (v_start_date, v_end_date) = (
    SELECT AS STRUCT
      CASE
        WHEN dow IN (4, 5) THEN anchor_friday
        ELSE DATE_SUB(anchor_friday, INTERVAL 7 DAY)
      END AS DS_START_DATE,
      CASE
        WHEN dow IN (4, 5) THEN DATE_ADD(anchor_friday, INTERVAL 6 DAY)
        ELSE DATE_SUB(anchor_friday, INTERVAL 1 DAY)
      END AS DS_END_DATE
    FROM (
      SELECT
        current_dt,
        EXTRACT(DAYOFWEEK FROM current_dt) as dow,
        DATE_SUB(current_dt, INTERVAL MOD(EXTRACT(DAYOFWEEK FROM current_dt) - 6 + 7, 7) DAY) as anchor_friday
      FROM (SELECT CURRENT_DATE('America/Sao_Paulo') as current_dt)
    )
  );

  -- 2. MAPEAMENTO DE DETRATORES (Ruptura, Perda, Erro Cliente e Gestão de Estoque)
  CREATE OR REPLACE TEMP TABLE tmp_Detratores AS
  SELECT DISTINCT
    SAFE_CAST(MATRICULA AS STRING) AS MATRICULA,
    UPPER(TRIM(IMPACTO_ERRO)) AS IMPACTO_ERRO,
    'GESTAO_ESTOQUE' AS ORIGEM
  FROM `shopper-datalakehouse-qa.Ranking_Performance.DETRATORAS GESTÃO DE ESTOQUE`
  WHERE DATA BETWEEN v_start_date AND v_end_date

  UNION DISTINCT

  SELECT DISTINCT
    SAFE_CAST(MATRICULA AS STRING) AS MATRICULA,
    'ERRO_CLIENTE' AS IMPACTO_ERRO,
    'FEEDBACK_ERROS' AS ORIGEM
  FROM `shopper-datalakehouse-qa.Ranking_Performance.FEEDBACK ERROS`
  WHERE COALESCE(SAFE.PARSE_DATE('%d/%m/%Y', SUBSTR(TRIM(DATA_ADICAO_PLANILHA), 1, 10)),
                  SAFE.PARSE_DATE('%Y-%m-%d', SUBSTR(TRIM(DATA_ADICAO_PLANILHA), 1, 10)))
        BETWEEN v_start_date AND v_end_date;

  -- 3. BASE UNIFICADA
  CREATE OR REPLACE TABLE `shopper-datalakehouse-qa.Ranking_Performance.KPIs_OPERAÇÃO` AS
  WITH CalculoBase AS (
    SELECT
      SAFE_CAST(org.MATRICULA AS STRING) AS MATRICULA,
      UPPER(TRIM(org.NOME)) AS NOME,
      UPPER(TRIM(org.AREA)) AS AREA,
      UPPER(TRIM(org.TURNO)) AS TURNO,
      UPPER(TRIM(org.FC)) AS FC,
      UPPER(TRIM(org.SETOR)) AS SETOR_ORIGINAL,
      UPPER(TRIM(org.ATRIBUICAO)) AS ATRIBUICAO_ORIGINAL,
      CAST(NULL AS FLOAT64) AS REPRESENTATIVIDADE_PRINCIPAL,
      CAST(NULL AS STRING) AS ATIVIDADE_PRINCIPAL,
      dt.IMPACTO_ERRO,
      dt.ORIGEM,
      org.DATA_ADM,

      -- Flag de zerado por erros de gestão de estoque (>3 erros na semana)
      COALESCE(ge.zerado, FALSE) AS zerado_gestao_estoque,
      COALESCE(ge.qtd_erros, 0) AS qtd_erros_gestao_estoque,

      -- IS_NAO_MEDIVEL
      CASE
        WHEN UPPER(TRIM(org.SETOR)) = 'BRINDE' THEN TRUE
        WHEN UPPER(TRIM(org.SETOR)) = 'GESTÃO DE ESTOQUE'
             AND UPPER(TRIM(org.ATRIBUICAO)) IN ('FALTANTES', 'INSUMOS') THEN TRUE
        WHEN (UPPER(TRIM(org.SETOR)) = 'MANUTENÇÃO' AND UPPER(TRIM(org.ATRIBUICAO)) = 'AUX. MANUTENÇÃO')
          OR (UPPER(TRIM(org.SETOR)) = 'PRÉ OPERAÇÃO' AND UPPER(TRIM(org.ATRIBUICAO)) IN ('AUXILIAR', 'IMPRESSÃO DE NOTA', 'INSUMOS'))
          OR (UPPER(TRIM(org.SETOR)) = 'LIMPEZA' AND UPPER(TRIM(org.ATRIBUICAO)) = 'LIMPEZA')
          OR UPPER(TRIM(org.ATRIBUICAO)) IN ('RONDA/REPOSITOR FLV', 'PICADOS')
          OR (UPPER(TRIM(org.SETOR)) LIKE '%FRESH%' AND UPPER(TRIM(org.ATRIBUICAO)) IN ('INSUMOS', 'REPOSITOR FLV'))
        THEN TRUE ELSE FALSE
      END AS IS_NAO_MEDIVEL,

      UPPER(TRIM(org.SETOR)) AS SETOR_FINAL,
      UPPER(TRIM(org.ATRIBUICAO)) AS ATRIBUICAO_FINAL

    FROM `shopper-datalakehouse-qa.Ranking_Performance.Organograma` org
    LEFT JOIN tmp_Detratores dt ON SAFE_CAST(org.MATRICULA AS STRING) = dt.MATRICULA
    LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.curated_erros_gestao_estoque` ge
      ON SAFE_CAST(org.MATRICULA AS STRING) = SAFE_CAST(ge.registration_number AS STRING)
      AND ge.reference_date = v_end_date
  )

  SELECT
    MATRICULA, NOME, AREA, TURNO, FC,
    SETOR_FINAL AS SETOR,
    ATRIBUICAO_FINAL AS ATRIBUICAO,
    IS_NAO_MEDIVEL,
    REPRESENTATIVIDADE_PRINCIPAL,
    ATIVIDADE_PRINCIPAL,
    SETOR_ORIGINAL,
    ATRIBUICAO_ORIGINAL,

    -- ══════════════════════════════════════════════
    -- MULT_MATRICULA
    -- Prioridade: GE Curated > Ruptura/Perda > Erro Cliente > GE Não-Mensurável > Faltantes Zerado
    -- ══════════════════════════════════════════════
    CASE
      -- 1. Erros de Gestão de Estoque: >3 erros na semana → zerado
      WHEN zerado_gestao_estoque = TRUE THEN 0.0

      -- 2. Ruptura ou Perda
      WHEN IMPACTO_ERRO IN ('RUPTURA', 'PERDA') THEN 0.0

      -- 3. Erro Cliente
      WHEN IMPACTO_ERRO = 'ERRO_CLIENTE' THEN 0.0

      -- 4. GE: atribuição não-mensurável com falha registrada
      WHEN ORIGEM = 'GESTAO_ESTOQUE' AND IS_NAO_MEDIVEL = TRUE THEN 0.0

      -- 5. KPIs Individuais zerados por coordenadores — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-zerados-mult]
      WHEN MATRICULA IN ('18550') THEN 0.0
      -- [/AUTO:ind-zerados-mult]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-mult]
      -- [/AUTO:ind-parcial-mult]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-mult]
      -- [/AUTO:fiscais-picking-mult]

      ELSE 1.0
    END AS MULT_MATRICULA,

    -- ══════════════════════════════════════════════
    -- MULT_SETOR — ATUALIZAR DESCONTOS TODA SEMANA
    -- ══════════════════════════════════════════════
    CASE
      -- Neutraliza quando já zerado pelo MULT_MATRICULA
      WHEN zerado_gestao_estoque = TRUE THEN 1.0
      WHEN IMPACTO_ERRO IN ('RUPTURA', 'PERDA', 'ERRO_CLIENTE') THEN 1.0
      WHEN ORIGEM = 'GESTAO_ESTOQUE' AND IS_NAO_MEDIVEL = TRUE THEN 1.0
      -- [AUTO:ind-zerados-setor-neut]
      WHEN MATRICULA IN ('18550') THEN 1.0
      -- [/AUTO:ind-zerados-setor-neut]

      -- ── Setoriais — ATUALIZAR TODA SEMANA ──
      -- [AUTO:setoriais-mult]
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1' THEN 0.9
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1' AND TURNO = 'MANHÃ' THEN 0.9
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND AREA = 'MERCEARIA' AND FC = 'FC1' THEN 0.9
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND AREA = 'FRESH' AND FC = 'FC1' THEN 0.8
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE' THEN 0.7
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE' THEN 0.6
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.8
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' THEN 0.8
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.8
      -- [/AUTO:setoriais-mult]

      ELSE 1.0
    END AS MULT_SETOR,

    1.0 AS MULT_TURNO,
    1.0 AS MULT_ATRIBUICAO,
    1.0 AS MULT_FC,

    -- ══════════════════════════════════════════════
    -- OBSERVACAO_KPI — ATUALIZAR MENSAGENS TODA SEMANA
    -- ══════════════════════════════════════════════
    CASE

      -- 1. Erros de Gestão de Estoque: >3 erros → zerado (prioridade máxima)
      WHEN zerado_gestao_estoque = TRUE
        THEN CONCAT(
          'VALOR DA BONIFICAÇÃO ZERADO. Você acumulou ',
          CAST(qtd_erros_gestao_estoque AS STRING),
          ' erros de gestão de estoque nesta semana, ultrapassando o limite de 3 erros permitidos. ',
          'Consulte a Gestão de Estoque para entender os erros registrados e evitar reincidências.'
        )

      -- 2. Ruptura ou Perda
      WHEN IMPACTO_ERRO = 'RUPTURA'
        THEN 'VALOR DA BONIFICAÇÃO ZERADO DEVIDO AO COLABORADOR TER DADO RUPTURA EM UM SKU MAPEADO EM ESTOQUE. CONSULTE O FEEDBACK DE ERROS PARA DETALHES.'
      WHEN IMPACTO_ERRO = 'PERDA'
        THEN 'VALOR DA BONIFICAÇÃO ZERADO DEVIDO AO COLABORADOR TER SIDO IDENTIFICADO COM PERDA OPERACIONAL REGISTRADA PELA GESTÃO DE ESTOQUE. CONSULTE O FEEDBACK DE ERROS PARA DETALHES.'

      -- 3. Erro Cliente
      WHEN IMPACTO_ERRO = 'ERRO_CLIENTE'
        THEN 'VALOR DA BONIFICAÇÃO ZERADO DEVIDO AO COLABORADOR TER SIDO RESPONSÁVEL POR UM ERRO REPORTADO POR CLIENTE. CONSULTE O FEEDBACK DE ERROS PARA DETALHES.'

      -- 4. GE não-mensurável com falha
      WHEN ORIGEM = 'GESTAO_ESTOQUE' AND IS_NAO_MEDIVEL = TRUE
           AND IMPACTO_ERRO NOT IN ('RUPTURA', 'PERDA')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO DEVIDO A FALHA OPERACIONAL IDENTIFICADA PELA GESTÃO DE ESTOQUE. CONSULTE O FEEDBACK DE ERROS PARA DETALHES.'

      -- 5. KPIs Individuais zerados por coordenadores — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-zerados-obs]
      WHEN MATRICULA IN ('18550')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Sua bonificação foi descontada em 100% devido Recebimento de uma demanda e não comunicar gestor, gerando perda desse item '
      -- [/AUTO:ind-zerados-obs]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-obs]
      -- [/AUTO:ind-parcial-obs]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-obs]
      -- [/AUTO:fiscais-picking-obs]

      -- GE: Inventário — ATUALIZAR TODA SEMANA
      -- [AUTO:ge-obs]
      -- [/AUTO:ge-obs]

      -- 7. KPIs Setoriais — ATUALIZAR TODA SEMANA
      -- [AUTO:setoriais-obs]
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
      THEN '-10% na Bonificação.
      O nosso indicador de completos fresh ficou distante da meta, um resultado diretamente impactado pelo alto volume de transferências para outro centro de distribuição. Precisamos de atenção para reverter a tendência de queda deste indicador.'
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1' AND TURNO = 'MANHÃ'
      THEN '-10% na Bonificação. O turno da MANHÃ apresentou atraso no indicador de Término leva A. Precisamos focar na agilidade do processo para garantir os horários de saída dos veículos SMD e Fiorino.'
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND AREA = 'MERCEARIA' AND FC = 'FC1'
      THEN '-10% na Bonificação. O resultado do percentual de pedidos mapeados Mercearia ficou distante da meta. Esse desempenho impactou negativamente o tempo de carregamento dos SMD.'
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND AREA = 'FRESH' AND FC = 'FC1'
      THEN '-20% na Bonificação.
      O índice de pedidos mapeados Fresh ficou distante da meta.
      Este resultado impactou diretamente o tempo de carregamento dos SMD.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE'
      THEN '-30% na Bonificação. A baixa eficiência do turno da TARDE na reposição impactou negativamente o resultado de completos mercearia. Este desempenho também piorou os indicadores de rupturas e divergências de estoque.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE'
      THEN '-40% na Bonificação. A baixa eficiência do turno da noite impactou negativamente o indicador de completos mercearia, que ficou distante da meta. É fundamental melhorar a execução da lista C.1 para reverter este resultado.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
      THEN '-20% na Bonificação.
      Apresentamos uma leve melhora no desempenho, com redução dos erros de processo.
      Porém, o indicador de completos fresh ainda permanece abaixo do esperado, mostrando que temos margem para continuar evoluindo e melhorar a execução.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
      THEN '-20% na Bonificação. Foram identificados erros operacionais na conferência e mapeamento que impactaram o percentual de pedidos mapeados e a divergência de estoque. Consequentemente, o resultado de completos mercearia e rupturas não consultadas ficou distante da meta.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3'
      THEN '-20% na Bonificação.
      Foram identificados erros operacionais na conferência e mapeamento que impactaram negativamente os resultados de divergências, rupturas e o percentual de pedidos mapeados.
      A falta de acuracidade no processo comprometeu o indicador de completos fresh.'
      -- [/AUTO:setoriais-obs]

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
