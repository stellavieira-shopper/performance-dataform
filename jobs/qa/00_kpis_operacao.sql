-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
-- Última atualização: 14/08/2026
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
      WHEN MATRICULA IN ('15647') THEN 0.0
      -- [/AUTO:ind-zerados-mult]

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
      WHEN MATRICULA IN ('15647') THEN 1.0
      -- [/AUTO:ind-zerados-setor-neut]

      -- ── Fiscais de Picking individual — ATUALIZAR TODA SEMANA ──
      -- [AUTO:fiscais-picking-mult]
      -- 0% zerado picking reincidente
      WHEN MATRICULA IN ('18458') THEN 0.0
      -- -50% reincidência picking
      WHEN MATRICULA IN ('14268') THEN 0.50
      -- -40% outros setores alocados no picking
      WHEN MATRICULA IN ('8899') THEN 0.60
      -- -40% picking
      WHEN MATRICULA IN ('18614', '18507', '18890') THEN 0.60
      -- [/AUTO:fiscais-picking-mult]

      -- ── Setoriais — ATUALIZAR TODA SEMANA ──
      -- [AUTO:setoriais-mult]
      -- FC1: Reposição Fresh (todos os turnos): -10%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1' THEN 0.90
      -- FC1: Recebimento Mercearia Tarde: -10%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO = 'TARDE' THEN 0.90
      -- FC1: Pré Expedição Fresh: -10%
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%')
           AND AREA = 'FRESH' AND FC = 'FC1' THEN 0.90
      -- FC2: Expedição (todos os turnos): -15%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2' THEN 0.85
      -- FC3: Reposição Fresh FLV: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.80
      -- FC3: Reposição Fresh Congelado e Refrigerado: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND (ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%' OR ATRIBUICAO_ORIGINAL LIKE '%REFRIGERADO%') THEN 0.70
      -- FC3: Reposição Mercearia Manhã e Tarde: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.70
      -- FC3: Reposição Mercearia Noite: -40%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE' THEN 0.60
      -- FC3: Recebimento Fresh (todos): -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.80
      -- FC3: Recebimento Mercearia (todos): -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' THEN 0.80
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
      WHEN MATRICULA IN ('15647')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Sua bonificação foi zerada porque a meta de acompanhamentos e vistorias não foi atingida por duas semanas consecutivas.'
      -- [/AUTO:ind-zerados-obs]

      -- 6. Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-obs]
      WHEN MATRICULA IN ('18458')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Colaboradores reincidentes nos 20% Piores com maior taxa de erro no Picking.'
      WHEN MATRICULA IN ('14268')
        THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'
      WHEN MATRICULA IN ('8899')
        THEN '-40% na Bonificação. Na última semana, você esteve entre os 20% dos colaboradores de outros setores que apresentaram as maiores taxas de erro ao serem alocados para o Picking. Independentemente da área de atuação, é indispensável manter a alta produtividade e qualidade.'
      WHEN MATRICULA IN ('18614', '18507', '18890')
        THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'
      -- [/AUTO:fiscais-picking-obs]

      -- GE: Inventário — ATUALIZAR TODA SEMANA
      -- [AUTO:ge-obs]
      WHEN MATRICULA IN ('11145', '13793')
        THEN 'Você não atingiu o mínimo de posições nem a acuracidade mínima necessários para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('13106', '14011')
        THEN 'Você não atingiu as posições mínimas necessárias para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('17470', '18464')
        THEN 'Você não atingiu o tempo médio mínimo necessário para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('16984', '9643', '12371')
        THEN 'Você não atingiu as contagens mínimas necessárias para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('17052', '16436')
        THEN '-100.000 pontos detratores na Performance. Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao baixo desempenho nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'
      -- [/AUTO:ge-obs]

      -- 7. KPIs Setoriais — ATUALIZAR TODA SEMANA
      -- [AUTO:setoriais-obs]
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
        THEN '-10% na Bonificação. Os completos fresh pioraram e seguem abaixo da meta, e as rupturas avançaram, embora permaneçam dentro do intervalo esperado. Precisamos melhorar a execução da reposição completa para recuperar os completos.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO = 'TARDE'
        THEN '-10% na Bonificação. No turno da tarde, os erros de movimentação e mapeamento de lotes geraram divergências de estoque e impactaram as rupturas, que pioraram na semana. Precisamos reduzir os erros de conferência para conter as divergências.'
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%')
           AND AREA = 'FRESH' AND FC = 'FC1'
        THEN '-10% na Bonificação. Os pedidos mapeados de mercearia e fresh pioraram na semana e ambos seguem abaixo da meta, com o percentual de mapeamento aquém do esperado. Precisamos recuperar o mapeamento para trazer os indicadores à meta.'
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2'
        THEN '-15% na Bonificação. O carregamento SMD e a leva A registraram melhora, mas o HR piorou e tanto o HR quanto o Fiorino seguem acima da meta com tempos não escaláveis. Precisamos trazer os tempos de HR e Fiorino para níveis sustentáveis.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
        THEN '-20% na Bonificação. Os completos fresh e o indicador de reposição FLV registraram leve piora, com erros operacionais continuando a impactar o KPI. Precisamos reduzir os erros para consolidar os completos dentro do intervalo esperado.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND (ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%' OR ATRIBUICAO_ORIGINAL LIKE '%REFRIGERADO%')
        THEN '-30% na Bonificação. A reposição de congelados e refrigerados piorou na semana, com erros operacionais continuando a impactar os completos fresh, que seguem longe do ideal. Precisamos reduzir os erros e melhorar a execução para aproximar os indicadores da meta.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-30% na Bonificação. Nos turnos da manhã e tarde, os completos de mercearia registraram leve piora e o setor segue impactando diretamente o KPI, com baixa efetividade na execução das atividades diárias. Precisamos melhorar a execução para recuperar os completos.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE'
        THEN '-40% na Bonificação. No turno da noite, os completos de mercearia seguem impactando diretamente o KPI, com baixa efetividade na execução da atividade C.1, a principal do turno. Precisamos melhorar a execução para recuperar os completos.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3'
        THEN '-20% na Bonificação. Os erros operacionais de conferência e mapeamento no recebimento fresh continuaram na semana, impactando os completos. Precisamos reduzir os erros de conferência e mapeamento para melhorar os indicadores.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
        THEN '-20% na Bonificação. Os erros operacionais de conferência e mapeamento no recebimento de mercearia persistiram na semana, mesmo com leve melhora nos completos. Precisamos eliminar os erros de conferência e mapeamento para sustentar a evolução.'
      -- [/AUTO:setoriais-obs]

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
