-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
-- Última atualização: 31/07/2026
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

      -- 5. Picking zerado reincidente — ATUALIZAR TODA SEMANA (31/07/2026)
      WHEN MATRICULA IN ('18147', '16209') THEN 0.0

      -- 6. KPIs Individuais zerados por coordenadores — ATUALIZAR TODA SEMANA (31/07/2026)
      WHEN MATRICULA IN ('12596', '15907', '13356') THEN 0.0

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
      WHEN MATRICULA IN ('18147', '16209', '12596', '15907', '13356') THEN 1.0

      -- ── Picking individual — ATUALIZAR TODA SEMANA (31/07/2026) ──

      -- -50% reincidência picking
      WHEN MATRICULA IN ('17797', '13689', '15427', '15028', '15293', '14374', '15565', '16580', '12593') THEN 0.50

      -- -40% picking
      WHEN MATRICULA IN ('10682', '13212', '18467', '18337', '17739', '15579') THEN 0.60

      -- -20% picking
      WHEN MATRICULA IN ('17542', '16193', '16195', '14995', '10802', '17653') THEN 0.80

      -- KPI Individual -20% (coordenador) — ATUALIZAR TODA SEMANA (31/07/2026)
      WHEN MATRICULA IN ('9922', '18430') THEN 0.80

      -- ── Setoriais semana 31/07/2026 ──

      -- FC1: Expedição Manhã: -10%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA') THEN 0.90

      -- FC1: Reposição Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.80

      -- FC1: Reposição Mercearia Noite: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO = 'NOITE' THEN 0.70

      -- FC1: Recebimento Fresh Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.80

      -- FC1: Recebimento Fresh Noite: -60%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO = 'NOITE' THEN 0.40

      -- FC1: Reposição Fresh Congelado: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%' THEN 0.80

      -- FC1: Reposição Fresh FLV: -40%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.60

      -- FC1: Reposição Fresh Refrigerado: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND ATRIBUICAO_ORIGINAL LIKE '%REFRIGERADO%' THEN 0.80

      -- FC2: Recebimento Fresh Manhã: -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC2'
           AND TURNO IN ('MANHÃ', 'MANHA') THEN 0.70

      -- FC2: Recebimento Mercearia Manhã: -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC2'
           AND TURNO IN ('MANHÃ', 'MANHA') THEN 0.70

      -- FC2: Reposição Fresh Tarde: ZERADO
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC2'
           AND TURNO = 'TARDE' THEN 0.0

      -- FC2: Expedição Manhã e Tarde: -10%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.90

      -- FC3: Reposição Fresh Congelado: -60%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%' THEN 0.40

      -- FC3: Reposição Fresh FLV: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.80

      -- FC3: Reposição Fresh (demais atribuições): -60%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.40

      -- FC3: Recebimento Fresh (todos): -50%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.50

      -- FC3: Recebimento Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.80

      -- FC3: Reposição Mercearia Manhã e Tarde: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.70

      -- FC3: Reposição Mercearia Noite: -40%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE' THEN 0.60

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

      -- 5. Picking zerado reincidente — ATUALIZAR TODA SEMANA (31/07/2026)
      WHEN MATRICULA IN ('18147', '16209')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Você é reincidente nos 20% de colaboradores de Picking com maior taxa de erro e, por essa razão, a bonificação será zerada integralmente nesta semana.'

      -- 6. KPIs Individuais zerados por coordenadores — ATUALIZAR TODA SEMANA (31/07/2026)
      WHEN MATRICULA IN ('12596')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Sua bonificação foi zerada por descumprimento de processo identificado nesta semana.'
      WHEN MATRICULA IN ('15907')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Sua bonificação foi zerada devido à bipagem incorreta de um SKU nesta semana: um pack de 6 unidades foi bipado como unidade individual, gerando divergência de 20 itens no pedido final do cliente.'
      WHEN MATRICULA IN ('13356')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Sua bonificação foi zerada devido à etiquetagem trocada de pedidos nesta semana, o que gerou divergência no carregamento.'

      -- 7. PICKING INDIVIDUAL — ATUALIZAR TODA SEMANA (31/07/2026)

      -- -50% reincidência picking
      WHEN MATRICULA IN ('17797', '13689', '15427', '15028', '15293', '14374', '15565', '16580', '12593')
        THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'

      -- -40% picking
      WHEN MATRICULA IN ('10682', '13212', '18467', '18337', '17739', '15579')
        THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'

      -- -20% picking
      WHEN MATRICULA IN ('17542', '16193', '16195', '14995', '10802', '17653')
        THEN '-20% na Bonificação. Você apresentou uma alta taxa de erros no Picking, que supera o limite aceitável. Essa performance impactou diretamente os indicadores da área e gerou mais retrabalho para outras áreas.'

      -- KPI Individual -20% (coordenador) — ATUALIZAR TODA SEMANA (31/07/2026)
      WHEN MATRICULA IN ('9922', '18430')
        THEN '-20% na Bonificação. Sua bonificação teve um desconto de 20% pela montagem de pedidos MK em caixas de papelão em vez das caixas retornáveis exigidas pelo processo.'

      -- GE FC1: Não bateu contagem mínima (31/07/2026)
      WHEN MATRICULA IN ('11080')
        THEN 'Você não atingiu a contagem mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

      -- GE FC1: Não bateu acuracidade mínima (31/07/2026)
      WHEN MATRICULA IN ('11145')
        THEN 'Você não atingiu a acuracidade mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

      -- GE FC1: Detratores por desempenho ruim (31/07/2026)
      WHEN MATRICULA IN ('6975', '17828')
        THEN '-100.000 pontos detratores na Performance. Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao desempenho ruim nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'
      WHEN MATRICULA IN ('17421', '13232', '11258')
        THEN '-200.000 pontos detratores na Performance. Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao desempenho ruim nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'

      -- GE FC2: Detratores por baixo desempenho (31/07/2026)
      WHEN MATRICULA IN ('14033', '17434', '11558', '16819')
        THEN '-100.000 pontos detratores na Performance. Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao baixo desempenho nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'

      -- GE FC3: Não bateu contagem mínima (31/07/2026)
      WHEN MATRICULA IN ('18191', '8224')
        THEN 'Você não atingiu a contagem mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

      -- GE FC3: Não bateu acuracidade mínima (31/07/2026)
      WHEN MATRICULA IN ('18335')
        THEN 'Você não atingiu a acuracidade mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

      -- GE FC3: Detrator por desempenho ruim (31/07/2026)
      WHEN MATRICULA IN ('16436')
        THEN '-100.000 pontos detratores na Performance. Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao desempenho ruim nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'

      -- 8. KPIs SETORIAIS — ATUALIZAR MENSAGENS TODA SEMANA (31/07/2026)

      -- FC1: Expedição Manhã: -10%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA')
        THEN '-10% na Bonificação. O término da leva A no turno da manhã piorou na semana e segue acima da meta, assim como o HR que também piorou. Precisamos retomar o controle do tempo de leva A e do HR para que a expedição evolua nos indicadores.'

      -- FC1: Reposição Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-20% na Bonificação. Os completos de mercearia pioraram na semana, com problemas na execução das listas e no uso dos processos corretos comprometendo os indicadores. Precisamos garantir a conclusão das listas dentro do prazo e a aplicação correta dos processos para sustentar os resultados.'

      -- FC1: Reposição Mercearia Noite: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO = 'NOITE'
        THEN '-30% na Bonificação. Os completos de mercearia pioraram na semana, com baixa eficiência na reposição e erros na separação de cestas no turno da noite comprometendo os indicadores. Precisamos retomar a eficiência e eliminar os erros de separação de cestas para sustentar a recuperação dos completos.'

      -- FC1: Recebimento Fresh Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-20% na Bonificação. Os completos fresh pioraram na semana, e o recebimento fresh nos turnos da manhã e da tarde registrou produtos aceitos com qualidade ruim sem reporte, comprometendo os indicadores. Precisamos garantir a identificação e o reporte de problemas de qualidade no ato do recebimento para reduzir o impacto nos completos fresh.'

      -- FC1: Recebimento Fresh Noite: -60%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO = 'NOITE'
        THEN '-60% na Bonificação. No turno da noite, o recebimento fresh registrou produtos aceitos com qualidade ruim sem reporte no grupo e devoluções pendentes não realizadas, gerando impacto direto nos completos fresh que pioraram na semana. Precisamos garantir o reporte imediato de problemas de qualidade e a execução das devoluções pendentes para reverter a piora nos indicadores.'

      -- FC1: Reposição Fresh Congelado: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%'
        THEN '-20% na Bonificação. Os completos fresh de Ref&Cong melhoraram na semana, mas a não realização das listas de reposição congelados segue impactando os indicadores e freando a evolução. Precisamos garantir a execução completa das listas de congelados para consolidar a melhora dos completos fresh.'

      -- FC1: Reposição Fresh FLV: -40%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
        THEN '-40% na Bonificação. Os completos fresh pioraram na semana e os erros de FIFO na reposição FLV seguem como fator de impacto direto nos indicadores. Precisamos eliminar os erros de FIFO na reposição FLV para reverter a piora dos completos fresh.'

      -- FC1: Reposição Fresh Refrigerado: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND ATRIBUICAO_ORIGINAL LIKE '%REFRIGERADO%'
        THEN '-20% na Bonificação. Os completos fresh de Ref&Cong melhoraram na semana, mas a não realização das listas de reposição refrigerados segue impactando os indicadores e limitando a evolução. Precisamos garantir a execução completa das listas de refrigerados para consolidar a melhora dos completos fresh.'

      -- FC2: Recebimento Fresh Manhã: -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC2'
           AND TURNO IN ('MANHÃ', 'MANHA')
        THEN '-30% na Bonificação. Os completos fresh pioraram na semana, e o recebimento fresh no turno da manhã registrou erros na passagem de informações, principalmente na troca de turno, comprometendo os indicadores. Precisamos garantir a comunicação correta e completa nas trocas de turno para reduzir o impacto nos completos fresh.'

      -- FC2: Recebimento Mercearia Manhã: -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC2'
           AND TURNO IN ('MANHÃ', 'MANHA')
        THEN '-30% na Bonificação. Os completos de mercearia pioraram na semana, e o recebimento mercearia no turno da manhã registrou erros na passagem de informações na troca de turno, comprometendo os indicadores. Precisamos garantir a comunicação correta nas trocas de turno para reduzir o impacto nos completos de mercearia.'

      -- FC2: Reposição Fresh Tarde: ZERADO
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC2'
           AND TURNO = 'TARDE'
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. O setor Reposição Fresh do FC2 no turno da tarde terá a bonificação zerada integralmente nesta semana devido à falta de engajamento dos colaboradores na execução das atividades.'

      -- FC2: Expedição Manhã e Tarde: -10%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-10% na Bonificação. Os tempos de carregamento da expedição do FC2 seguem muito distantes da meta, com o carregamento SMD praticamente estável no patamar crítico e o HR piorando na semana. Precisamos evoluir urgentemente no carregamento SMD e controlar o HR para que a expedição avance nos indicadores.'

      -- FC3: Reposição Fresh Congelado: -60%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%'
        THEN '-60% na Bonificação. Os completos fresh pioraram significativamente na semana, com erros operacionais e de mapeamento na reposição congelados sendo fator de impacto direto nos indicadores. Precisamos eliminar os erros operacionais e de mapeamento na reposição congelados para reverter a piora dos completos fresh.'

      -- FC3: Reposição Fresh FLV: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
        THEN '-20% na Bonificação. Os completos fresh pioraram na semana, mas a reposição FLV registrou leve melhora, com alguns erros operacionais ainda persistentes que limitam a evolução dos indicadores. Precisamos eliminar os erros remanescentes na reposição FLV para sustentar a melhora e contribuir para a recuperação dos completos fresh.'

      -- FC3: Reposição Fresh (demais atribuições): -60%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
        THEN '-60% na Bonificação. Os completos fresh pioraram significativamente na semana com erros operacionais e de mapeamento na reposição fresh comprometendo os indicadores. Precisamos eliminar os erros operacionais e de mapeamento na execução da reposição fresh para reverter a piora dos completos.'

      -- FC3: Recebimento Fresh (todos): -50%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3'
        THEN '-50% na Bonificação. Os completos fresh pioraram na semana e o recebimento fresh registrou erros operacionais na conclusão de notas com devoluções pendentes não finalizadas, comprometendo os indicadores. Precisamos garantir a conclusão correta das notas e das devoluções pendentes no recebimento para reduzir o impacto nos completos fresh.'

      -- FC3: Recebimento Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-20% na Bonificação. Os completos de mercearia pioraram na semana e o recebimento mercearia nos turnos da manhã e da tarde registrou erros operacionais que comprometem os indicadores. Precisamos eliminar os erros operacionais no recebimento para reduzir o impacto nos completos de mercearia.'

      -- FC3: Reposição Mercearia Manhã e Tarde: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-30% na Bonificação. Os completos de mercearia pioraram na semana, com a não execução de processos e atrasos nas listas de reposição nos turnos da manhã e da tarde comprometendo os indicadores. Precisamos garantir a execução dos processos e a conclusão das listas dentro do prazo para reverter a piora dos completos.'

      -- FC3: Reposição Mercearia Noite: -40%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE'
        THEN '-40% na Bonificação. Os completos de mercearia pioraram na semana com a não execução de processos e atrasos expressivos nas listas de reposição no turno da noite, gerando impacto mais severo nos indicadores. Precisamos garantir a execução dos processos e eliminar os atrasos nas listas no turno da noite para recuperar os completos.'

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
