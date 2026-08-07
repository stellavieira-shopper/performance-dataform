-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
-- Última atualização: 07/08/2026
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

      -- Fraude crachá expedição — PRIORIDADE MÁXIMA (31/07/2026)
      WHEN MATRICULA IN ('6244', '16320', '14456', '16671', '16726', '9584', '17119') THEN 0.0

      -- 5. KPIs Individuais zerados por coordenadores — ATUALIZAR TODA SEMANA (07/08/2026)
      WHEN MATRICULA IN ('11681') THEN 0.0

      -- 6. KPIs Individuais desconto parcial — ATUALIZAR TODA SEMANA (07/08/2026)
      WHEN MATRICULA IN ('330') THEN 0.70
      WHEN MATRICULA IN ('15647') THEN 0.60

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
      WHEN MATRICULA IN ('6244', '16320', '14456', '16671', '16726', '9584', '17119', '11681', '330', '15647') THEN 1.0

      -- ── Picking individual — ATUALIZAR TODA SEMANA (07/08/2026) ──

      -- -50% reincidência picking
      WHEN MATRICULA IN ('17797', '13689', '15427', '15028', '15293', '14374', '15565', '16580', '12593') THEN 0.50

      -- -40% picking
      WHEN MATRICULA IN ('10682', '13212', '18467', '18337', '17739', '15579') THEN 0.60

      -- -20% picking
      WHEN MATRICULA IN ('17542', '16193', '16195', '14995', '10802', '17653') THEN 0.80

      -- ── Setoriais semana 07/08/2026 ──

      -- FC1: Reposição Mercearia (todos os turnos): -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' THEN 0.80

      -- FC1: Recebimento Mercearia Noite: -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO = 'NOITE' THEN 0.70

      -- FC1: Reposição Fresh Noite: -60%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO = 'NOITE' THEN 0.40

      -- FC1: Reposição Fresh Manhã e Tarde: -40%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.60

      -- FC1: Recebimento Fresh Manhã: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA') THEN 0.80

      -- FC1: Expedição Manhã: -25%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA') THEN 0.75

      -- FC1: Expedição Tarde: -30%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1'
           AND TURNO = 'TARDE' THEN 0.70

      -- FC1: Pré Expedição Mercearia: -20%
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%')
           AND AREA = 'MERCEARIA' AND FC = 'FC1' THEN 0.80

      -- FC1: Pré Expedição Fresh: -30%
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%')
           AND AREA = 'FRESH' AND FC = 'FC1' THEN 0.70

      -- FC1: Picking Noite (setorial): -20%
      WHEN SETOR_ORIGINAL = 'PICKING' AND FC = 'FC1' AND TURNO = 'NOITE' THEN 0.80

      -- FC2: Picking Noite (setorial): -20%
      WHEN SETOR_ORIGINAL = 'PICKING' AND FC = 'FC2' AND TURNO = 'NOITE' THEN 0.80

      -- FC3: Reposição Fresh FLV: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.80

      -- FC3: Reposição Fresh (todos): -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.70

      -- FC3: Recebimento Fresh (todos): -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.70

      -- FC3: Recebimento Mercearia Noite: -40%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE' THEN 0.60

      -- FC3: Recebimento Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.80

      -- FC3: Reposição Mercearia Manhã e Tarde: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.70

      -- FC3: Expedição Manhã: -10%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA') THEN 0.90

      -- FC3: Expedição Tarde: -15%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC3'
           AND TURNO = 'TARDE' THEN 0.85

      -- FC3: Pré Expedição Mercearia: -20%
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%')
           AND AREA = 'MERCEARIA' AND FC = 'FC3' THEN 0.80

      -- FC3: Pré Expedição Fresh: -10%
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%')
           AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.90

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

      -- FRAUDE crachá expedição — PRIORIDADE MÁXIMA (31/07/2026)
      WHEN MATRICULA IN ('6244', '16320', '14456', '16671', '16726')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Foi identificada uma fraude no uso de crachá nesta semana, com concentração irregular de volumes em um único colaborador, incluindo registros realizados em dia de folga. Por comprometer a integridade do processo de carregamento e a confiabilidade dos dados, todos os envolvidos no turno terão a bonificação zerada integralmente.'
      WHEN MATRICULA IN ('9584')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Foi identificada uma fraude no uso de crachá nesta semana, com concentração irregular de volumes em um único colaborador, incluindo registros realizados em dia de folga. Como líder responsável pelo turno, a ocorrência reflete diretamente na gestão do processo e na supervisão da equipe, resultando no zeramento integral da bonificação.'
      WHEN MATRICULA IN ('17119')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Foi identificada uma fraude no uso de crachá nesta semana, com volumes registrados em seu nome em dia de folga, caracterizando uso indevido de credencial e manipulação dos dados de carregamento. A ocorrência está sendo apurada e está sujeita a medidas disciplinares.'

      -- 5. KPIs Individuais zerados por coordenadores — ATUALIZAR TODA SEMANA (07/08/2026)
      WHEN MATRICULA IN ('11681')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Sua bonificação foi zerada devido ao baixo rendimento nas atividades de inventário e a erros recorrentes identificados nesta semana.'

      -- 6. KPIs Individuais desconto parcial — ATUALIZAR TODA SEMANA (07/08/2026)
      WHEN MATRICULA IN ('330')
        THEN '-30% na Bonificação. Sua bonificação teve um desconto de 30% devido ao ajuste incorreto da Banana Prata Verde nesta semana, que gerou uma substituição indevida e impactou diretamente a experiência do cliente, que recebeu um produto diferente do solicitado.'
      WHEN MATRICULA IN ('15647')
        THEN '-40% na Bonificação. Sua bonificação teve um desconto de 40% porque a meta de acompanhamentos não foi atingida durante o período de apuração.'

      -- 6. PICKING INDIVIDUAL — ATUALIZAR TODA SEMANA (07/08/2026)

      -- -50% reincidência picking
      WHEN MATRICULA IN ('17797', '13689', '15427', '15028', '15293', '14374', '15565', '16580', '12593')
        THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'

      -- -40% picking
      WHEN MATRICULA IN ('10682', '13212', '18467', '18337', '17739', '15579')
        THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'

      -- -20% picking
      WHEN MATRICULA IN ('17542', '16193', '16195', '14995', '10802', '17653')
        THEN '-20% na Bonificação. Você apresentou uma alta taxa de erros no Picking, que supera o limite aceitável. Essa performance impactou diretamente os indicadores da área e gerou mais retrabalho para outras áreas.'

      -- GE: Não bateu acuracidade mínima e tempo (07/08/2026)
      WHEN MATRICULA IN ('10893')
        THEN 'Você não atingiu a acuracidade mínima nem o tempo médio das contagens necessários para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

      -- GE: Não bateu o tempo médio das contagens (07/08/2026)
      WHEN MATRICULA IN ('11853')
        THEN 'Você não atingiu o tempo médio das contagens necessário para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

      -- GE: Não bateu acuracidade mínima (07/08/2026)
      WHEN MATRICULA IN ('11145', '17421', '6975', '18335', '16902', '14011')
        THEN 'Você não atingiu a acuracidade mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

      -- GE: Não atingiu contagem mínima (07/08/2026)
      WHEN MATRICULA IN ('13106', '13232', '7872', '5786', '10919', '17784', '17592', '17470', '8224', '18138')
        THEN 'Você não atingiu a contagem mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

      -- GE: Não atingiu contagem mínima e acuracidade mínima (07/08/2026)
      WHEN MATRICULA IN ('13793')
        THEN 'Você não atingiu a contagem mínima nem a acuracidade mínima necessárias para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

      -- GE: Alto número de contagens com baixa acuracidade (07/08/2026)
      WHEN MATRICULA IN ('15643')
        THEN 'Você registrou um alto número de contagens com baixa acuracidade nesta semana, comprometendo sua pontuação na atividade de inventário de Gestão de Estoque. Valide junto às suas lideranças dentro de Gestão de Estoque.'

      -- GE: Detrator por desempenho ruim e baixa performance (07/08/2026)
      WHEN MATRICULA IN ('11681')
        THEN '-100.000 pontos detratores na Performance. Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao desempenho ruim e baixa performance nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'

      -- GE: Porcentagem de erros nas contagens (07/08/2026)
      WHEN MATRICULA IN ('12644')
        THEN '-100.000 pontos detratores na Performance. Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido à sua porcentagem de erros nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'

      -- GE: Detrator por baixa performance (07/08/2026)
      WHEN MATRICULA IN ('13869', '16781', '16055', '13879', '13727', '15259', '16436', '17837', '16365')
        THEN '-100.000 pontos detratores na Performance. Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao baixo desempenho nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'

      -- 7. KPIs SETORIAIS — ATUALIZAR MENSAGENS TODA SEMANA (07/08/2026)

      -- FC1: Reposição Mercearia (todos os turnos): -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1'
        THEN '-20% na Bonificação. Os completos de mercearia pioraram na semana, com as rupturas e divergências de estoque também subindo e comprometendo os indicadores. Precisamos reduzir as rupturas e as divergências para sustentar a performance dos completos de mercearia.'

      -- FC1: Recebimento Mercearia Noite: -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO = 'NOITE'
        THEN '-30% na Bonificação. Os completos de mercearia pioraram na semana, e o recebimento mercearia no turno da noite registrou lotes e pallets desmapeados, comprometendo as divergências de estoque e os indicadores. Precisamos garantir o mapeamento correto de lotes e pallets no recebimento para reduzir o impacto nas divergências e nos completos.'

      -- FC1: Reposição Fresh Noite: -60%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO = 'NOITE'
        THEN '-60% na Bonificação. Os completos fresh pioraram significativamente na semana e saíram da faixa ideal, e o turno da noite deixou de realizar as listas de reposição, focando apenas em faltantes, o que não é o processo correto. Precisamos retomar a execução completa das listas de reposição para reverter a queda dos completos fresh.'

      -- FC1: Reposição Fresh Manhã e Tarde: -40%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-40% na Bonificação. Os completos fresh pioraram significativamente na semana e saíram da faixa ideal, com a reposição fresh nos turnos da manhã e da tarde sendo fator de impacto direto nos indicadores. Precisamos retomar a qualidade e a eficiência na reposição para reverter a queda dos completos fresh.'

      -- FC1: Recebimento Fresh Manhã: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA')
        THEN '-20% na Bonificação. Os completos fresh pioraram na semana, e o recebimento fresh no turno da manhã registrou falta de senso de urgência no apoio operacional, comprometendo o ritmo e os indicadores da área. Precisamos retomar o engajamento e a agilidade no apoio operacional para contribuir com a recuperação dos completos fresh.'

      -- FC1: Expedição Manhã: -25%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA')
        THEN '-25% na Bonificação. O carregamento SMD piorou na semana e segue muito abaixo da meta, e o tempo de leva A também piorou no turno da manhã. Precisamos avançar no carregamento SMD e retomar o controle do tempo de leva A para evoluir nos indicadores de expedição.'

      -- FC1: Expedição Tarde: -30%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1'
           AND TURNO = 'TARDE'
        THEN '-30% na Bonificação. O carregamento SMD piorou na semana e segue muito abaixo da meta, comprometendo os indicadores de expedição no turno da tarde. Precisamos evoluir urgentemente no carregamento SMD para que a expedição avance nos resultados.'

      -- FC1: Pré Expedição Mercearia: -20%
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%')
           AND AREA = 'MERCEARIA' AND FC = 'FC1'
        THEN '-20% na Bonificação. Os pedidos mapeados de mercearia pioraram na semana e seguem abaixo da meta, com divergências de mapeamento e nota fiscal comprometendo os indicadores. Precisamos eliminar as divergências de mapeamento e nota fiscal para recuperar os pedidos mapeados e atingir a meta.'

      -- FC1: Pré Expedição Fresh: -30%
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%')
           AND AREA = 'FRESH' AND FC = 'FC1'
        THEN '-30% na Bonificação. Os pedidos mapeados de fresh pioraram na semana e seguem abaixo da meta, comprometendo os indicadores de pré expedição. Precisamos melhorar o mapeamento dos pedidos fresh para atingir a meta e sustentar os resultados da expedição.'

      -- FC1: Picking Noite (setorial): -20%
      WHEN SETOR_ORIGINAL = 'PICKING' AND FC = 'FC1' AND TURNO = 'NOITE'
        THEN '-20% na Bonificação. A média de erros do Picking no turno da noite ficou acima da taxa ideal na semana, impactando os indicadores do setor. Precisamos reduzir a taxa de erros no turno da noite para retomar os resultados esperados.'

      -- FC2: Picking Noite (setorial): -20%
      WHEN SETOR_ORIGINAL = 'PICKING' AND FC = 'FC2' AND TURNO = 'NOITE'
        THEN '-20% na Bonificação. O turno da noite do Picking registrou uma quantidade acima do normal de faltantes na semana, comprometendo os indicadores do setor. Precisamos reduzir os faltantes no turno da noite para retomar os resultados esperados.'

      -- FC3: Reposição Fresh FLV: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
        THEN '-20% na Bonificação. Os completos fresh pioraram na semana, e a reposição FLV registrou erros operacionais que seguem impactando os indicadores. Precisamos eliminar os erros operacionais na reposição FLV para contribuir com a recuperação dos completos fresh.'

      -- FC3: Reposição Fresh (todos): -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
        THEN '-30% na Bonificação. Os completos fresh seguem na faixa mínima da meta e pioraram na semana, com muitos erros de processos na reposição fresh comprometendo os indicadores. Precisamos eliminar os erros de processos na reposição para sustentar os completos fresh dentro da meta.'

      -- FC3: Recebimento Fresh (todos): -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3'
        THEN '-30% na Bonificação. Os completos fresh pioraram na semana, e o recebimento fresh registrou erros de conferência com processos que não estão sendo cumpridos, comprometendo os indicadores. Precisamos garantir o cumprimento correto dos processos de conferência no recebimento para reduzir o impacto nos completos fresh.'

      -- FC3: Recebimento Mercearia Noite: -40%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE'
        THEN '-40% na Bonificação. Os completos de mercearia pioraram na semana, e o recebimento mercearia no turno da noite registrou baixa produtividade com indicadores muito distantes do ideal. Precisamos elevar a produtividade e a qualidade no recebimento do turno da noite para reduzir o impacto nos completos de mercearia.'

      -- FC3: Recebimento Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-20% na Bonificação. Os completos de mercearia pioraram na semana, e o recebimento mercearia nos turnos da manhã e da tarde registrou erros de conferência com processos não cumpridos, comprometendo os indicadores. Precisamos garantir o cumprimento dos processos de conferência no recebimento para reduzir o impacto nos completos de mercearia.'

      -- FC3: Reposição Mercearia Manhã e Tarde: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-30% na Bonificação. Os completos de mercearia pioraram na semana, com baixa produtividade e listas não concluídas na reposição mercearia nos turnos da manhã e da tarde comprometendo os indicadores. Precisamos melhorar a produtividade e garantir a conclusão das listas dentro do prazo para reverter a piora dos completos.'

      -- FC3: Expedição Manhã: -10%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA')
        THEN '-10% na Bonificação. O carregamento SMD piorou na semana e o tempo de HR também piorou no turno da manhã, ambos se distanciando das metas. Precisamos retomar o controle do SMD e do HR para sustentar os indicadores de expedição dentro da meta.'

      -- FC3: Expedição Tarde: -15%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC3'
           AND TURNO = 'TARDE'
        THEN '-15% na Bonificação. O carregamento SMD piorou na semana e se afastou da meta, comprometendo os indicadores de expedição no turno da tarde. Precisamos retomar a evolução no carregamento SMD para sustentar os resultados dentro da meta.'

      -- FC3: Pré Expedição Mercearia: -20%
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%')
           AND AREA = 'MERCEARIA' AND FC = 'FC3'
        THEN '-20% na Bonificação. Os pedidos mapeados de mercearia pioraram na semana e seguem abaixo da meta, com divergências de mapeamento com nota fiscal comprometendo os indicadores. Precisamos eliminar as divergências de mapeamento e nota fiscal para recuperar os pedidos mapeados e atingir a meta.'

      -- FC3: Pré Expedição Fresh: -10%
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%')
           AND AREA = 'FRESH' AND FC = 'FC3'
        THEN '-10% na Bonificação. Os pedidos mapeados de fresh pioraram levemente na semana, com divergências de mapeamento com nota fiscal comprometendo os indicadores. Precisamos eliminar as divergências de mapeamento e nota fiscal para manter os pedidos mapeados acima da meta.'

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
