-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
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

      -- 5. Picking reincidente zerado — ATUALIZAR TODA SEMANA
      WHEN MATRICULA IN ('15149') THEN 0.0

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
      WHEN MATRICULA IN ('15149') THEN 1.0

      -- ── Picking individual — ATUALIZAR TODA SEMANA ──

      -- -50% reincidência picking (FC1 + FC3)
      WHEN MATRICULA IN ('16877', '7553', '15649', '16193', '15565') THEN 0.50

      -- -40% piores picking (FC1)
      WHEN MATRICULA IN ('17797', '17818', '17655', '17758') THEN 0.60

      -- -40% alocados piores picking (FC1)
      WHEN MATRICULA IN ('9696', '13143') THEN 0.60

      -- -40% piores picking (FC3)
      WHEN MATRICULA IN ('17783', '14725') THEN 0.60

      -- -20% picking (FC3)
      WHEN MATRICULA IN ('13710') THEN 0.80

      -- ── Setoriais ──

      -- FC1: Reposição Mercearia Noite: -10%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO = 'NOITE' THEN 0.90

      -- FC1: Recebimento Fresh Noite: -40%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1' AND TURNO = 'NOITE' THEN 0.60

      -- FC1: Reposição Fresh (Refrigerado, Congelado, FLV): -15%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1' THEN 0.85

      -- FC3: Reposição FLV: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.70

      -- FC3: Reposição Refrigerado/Congelado: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND (ATRIBUICAO_ORIGINAL LIKE '%REFRIGERADO%' OR ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%') THEN 0.80

      -- FC3: Reposição Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.80

      -- FC3: Reposição Mercearia Noite: -40%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE' THEN 0.60

      -- FC3: Recebimento Fresh: -10%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.90

      -- FC3: Recebimento Mercearia: -10%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' THEN 0.90

      ELSE 1.0
    END AS MULT_SETOR,

    1.0 AS MULT_TURNO,
    1.0 AS MULT_ATRIBUICAO,
    1.0 AS MULT_FC,

    -- ══════════════════════════════════════════════
    -- OBSERVACAO_KPI — ATUALIZAR MENSAGENS TODA SEMANA
    -- ══════════════════════════════════════════════
    CASE

      -- 1. Erros de Gestão de Estoque: >3 erros → zerado
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

      -- 5. Picking reincidente zerado — ATUALIZAR TODA SEMANA
      WHEN MATRICULA IN ('15149')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Você é reincidente nos 20% de colaboradores de Picking com maior taxa de erro e, por essa razão, a bonificação será zerada integralmente nesta semana.'

      -- 6. PICKING INDIVIDUAL — ATUALIZAR TODA SEMANA

      -- -50% reincidência (FC1 + FC3)
      WHEN MATRICULA IN ('16877', '7553', '15649', '16193', '15565')
        THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'

      -- -40% piores picking (FC1)
      WHEN MATRICULA IN ('17797', '17818', '17655', '17758')
        THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'

      -- -40% alocados piores picking (FC1)
      WHEN MATRICULA IN ('9696', '13143')
        THEN '-40% na Bonificação. Na última semana, você esteve entre os 20% dos colaboradores de outros setores que apresentaram as maiores taxas de erro ao serem alocados para o Picking. Independentemente da área de atuação, é indispensável manter a alta produtividade e qualidade.'

      -- -40% piores picking (FC3)
      WHEN MATRICULA IN ('17783', '14725')
        THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'

      -- -20% picking (FC3)
      WHEN MATRICULA IN ('13710')
        THEN '-20% na Bonificação. Você apresentou uma alta taxa de erros no Picking, que supera o limite aceitável. Essa performance impactou diretamente os indicadores da área e gerou mais retrabalho para outras áreas.'

      -- 7. KPIs SETORIAIS — ATUALIZAR MENSAGENS TODA SEMANA

      -- FC1: Reposição Mercearia Noite: -10%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO = 'NOITE'
        THEN '-10% na Bonificação. A eficiência de reposição de mercearia no turno da noite seguiu abaixo do esperado, impactando os indicadores da área. Precisamos melhorar a execução da reposição no turno da noite para recuperar o indicador.'

      -- FC1: Recebimento Fresh Noite: -40%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1' AND TURNO = 'NOITE'
        THEN '-40% na Bonificação. O recebimento fresh no turno da noite registrou erros recorrentes de conferência e recebeu produtos com qualidade ruim, comprometendo os indicadores da área. Precisamos eliminar os erros de conferência e garantir a rejeição de produtos fora do padrão de qualidade.'

      -- FC1: Reposição Fresh (Refrigerado, Congelado, FLV): -15%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
        THEN '-15% na Bonificação. A reposição fresh de refrigerados, congelados e FLV registrou melhora, mas os indicadores ainda seguem abaixo do objetivo esperado. Precisamos manter a evolução e avançar na execução para atingir a meta.'

      -- FC3: Reposição FLV: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
        THEN '-30% na Bonificação. A reposição FLV não registrou evolução em relação à semana anterior e os indicadores seguem em patamar abaixo do esperado. Precisamos retomar a melhora na execução da reposição FLV para avançar nos resultados.'

      -- FC3: Reposição Refrigerado/Congelado: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND (ATRIBUICAO_ORIGINAL LIKE '%REFRIGERADO%' OR ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%')
        THEN '-20% na Bonificação. A reposição de refrigerados e congelados segue fora dos indicadores esperados, sem evolução suficiente na semana. Precisamos corrigir a execução da reposição para trazer o indicador de volta ao nível adequado.'

      -- FC3: Reposição Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-20% na Bonificação. A execução das listas de reposição de mercearia nos turnos da manhã e da tarde registrou melhora, mas os indicadores ainda estão longe do objetivo. Precisamos avançar na qualidade da execução para aproximar os resultados da meta.'

      -- FC3: Reposição Mercearia Noite: -40%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE'
        THEN '-40% na Bonificação. A execução das listas de reposição de mercearia no turno da noite segue muito abaixo do esperado, com indicadores distantes da meta. Precisamos melhorar urgentemente a execução da reposição no turno da noite para recuperar os resultados.'

      -- FC3: Recebimento Fresh: -10%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3'
        THEN '-10% na Bonificação. O recebimento fresh registrou muitos erros de conferência na semana, impactando diretamente os indicadores da área. Precisamos reduzir os erros de conferência no recebimento para recuperar a performance.'

      -- FC3: Recebimento Mercearia: -10%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
        THEN '-10% na Bonificação. O recebimento de mercearia registrou erros de conferência e mapeamento na semana, impactando os indicadores da área. Precisamos eliminar as falhas de conferência e mapeamento para estabilizar os resultados.'

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
