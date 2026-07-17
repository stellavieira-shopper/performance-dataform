-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
-- Última atualização: 16/07/2026
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

      -- 5. Picking reincidente zerado — ATUALIZAR TODA SEMANA (16/07/2026)
      WHEN MATRICULA IN ('15649') THEN 0.0

      -- 6. KPIs Individuais zerados por coordenadores — ATUALIZAR TODA SEMANA (16/07/2026)
      WHEN MATRICULA IN ('198', '12081') THEN 0.0

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
      WHEN MATRICULA IN ('15649', '198', '12081') THEN 1.0

      -- ── Picking individual — ATUALIZAR TODA SEMANA (16/07/2026) ──

      -- -50% reincidência picking (FC1)
      WHEN MATRICULA IN ('16667', '16610', '16402') THEN 0.50

      -- -40% alocados piores picking (FC1)
      WHEN MATRICULA IN ('13689', '14492') THEN 0.60

      -- -50% reincidência picking (FC3)
      WHEN MATRICULA IN ('16707', '14521', '13306') THEN 0.50

      -- -40% piores picking (FC3)
      WHEN MATRICULA IN ('14791', '16856', '17653', '10802', '17750', '13347', '16611') THEN 0.60

      -- -20% picking (FC3)
      WHEN MATRICULA IN ('17791') THEN 0.80

      -- ── Setoriais semana 16/07/2026 ──

      -- FC1: Recebimento Fresh Manhã e Noite: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA', 'NOITE') THEN 0.80

      -- FC1: Reposição Fresh FLV: -15%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.85

      -- FC1: Recebimento Mercearia Tarde: -50%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO = 'TARDE' THEN 0.50

      -- FC1: Expedição Fresh: -15%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND AREA = 'FRESH' AND FC = 'FC1' THEN 0.85

      -- FC2: Expedição: -20%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2' THEN 0.80

      -- FC3: Faltantes Mercearia Noite: ZERADO
      WHEN SETOR_ORIGINAL LIKE '%FALTANTE%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE' THEN 0.0

      -- FC3: Reposição Mercearia Noite: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE' THEN 0.70

      -- FC3: Reposição Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.80

      -- FC3: Reposição Fresh (todas): -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.80

      -- FC3: Fiscal Packing e Fiscal Packer Operação Fresh: -40%
      WHEN (SETOR_ORIGINAL LIKE '%PACKING%' OR SETOR_ORIGINAL LIKE '%PACKER%') AND FC = 'FC3' THEN 0.60

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

      -- 5. Picking reincidente zerado — ATUALIZAR TODA SEMANA (16/07/2026)
      WHEN MATRICULA IN ('15649')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Você é reincidente nos 20% de colaboradores de Picking com maior taxa de erro e, por essa razão, a bonificação será zerada integralmente nesta semana.'

      -- 6. KPIs Individuais zerados por coordenadores — ATUALIZAR TODA SEMANA (16/07/2026)
      WHEN MATRICULA IN ('198')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Erro na verificação da qualidade para os itens recebidos do fornecedor Batista, causando perda no fracionamento e ruptura ao cliente.'
      WHEN MATRICULA IN ('12081')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Reincidência no não cumprimento das metas estabelecidas.'

      -- 7. PICKING INDIVIDUAL — ATUALIZAR TODA SEMANA (16/07/2026)

      -- -50% reincidência picking (FC1)
      WHEN MATRICULA IN ('16667', '16610', '16402')
        THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'

      -- -40% alocados piores picking (FC1)
      WHEN MATRICULA IN ('13689', '14492')
        THEN '-40% na Bonificação. Na última semana, você esteve entre os 20% dos colaboradores de outros setores que apresentaram as maiores taxas de erro ao serem alocados para o Picking. Independentemente da área de atuação, é indispensável manter a alta produtividade e qualidade.'

      -- -50% reincidência picking (FC3)
      WHEN MATRICULA IN ('16707', '14521', '13306')
        THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'

      -- -40% piores picking (FC3)
      WHEN MATRICULA IN ('14791', '16856', '17653', '10802', '17750', '13347', '16611')
        THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'

      -- -20% picking (FC3)
      WHEN MATRICULA IN ('17791')
        THEN '-20% na Bonificação. Você apresentou uma alta taxa de erros no Picking, que supera o limite aceitável. Essa performance impactou diretamente os indicadores da área e gerou mais retrabalho para outras áreas.'

      -- 8. KPIs SETORIAIS — ATUALIZAR MENSAGENS TODA SEMANA (16/07/2026)

      -- FC1: Recebimento Fresh Manhã e Noite: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA', 'NOITE')
        THEN '-20% na Bonificação. O recebimento fresh nos turnos da manhã e da noite registrou erros de conferência e produtos com qualidade ruim não sendo reportados corretamente, comprometendo os indicadores. Precisamos garantir que erros de conferência e produtos fora do padrão sejam identificados e registrados no recebimento.'

      -- FC1: Reposição Fresh FLV: -15%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
        THEN '-15% na Bonificação. Os completos fresh melhoraram na semana, mas a não execução das listas de reposição FLV segue impactando os indicadores e freando a evolução mais consistente do setor. Precisamos garantir a execução completa das listas FLV para sustentar a melhora dos completos fresh.'

      -- FC1: Recebimento Mercearia Tarde: -50%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO = 'TARDE'
        THEN '-50% na Bonificação. O turno da tarde do Recebimento Mercearia apresentou comportamentos inadequados que prejudicam o ambiente de trabalho e o ritmo operacional, incluindo atrasos nas atividades e uso indevido do coletor. Precisamos retomar a postura adequada e o cumprimento das rotinas para não comprometer o desempenho do setor.'

      -- FC1: Expedição Fresh: -15%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND AREA = 'FRESH' AND FC = 'FC1'
        THEN '-15% na Bonificação. Os indicadores de expedição fresh registraram melhora — SMD, leva A e HR avançaram — mas o Fiorino segue acima da meta e o setor tem espaço para uma evolução mais expressiva. Precisamos manter o ritmo de melhora e reduzir o tempo do Fiorino para que todos os indicadores se consolidem dentro das metas.'

      -- FC2: Expedição: -20%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2'
        THEN '-20% na Bonificação. O carregamento SMD caiu na semana e segue muito distante da meta, enquanto o HR piorou e o Fiorino registrou leve melhora. Precisamos avançar urgentemente no carregamento SMD e reverter a piora do HR para que a expedição evolua.'

      -- FC3: Faltantes Mercearia Noite: ZERADO
      WHEN SETOR_ORIGINAL LIKE '%FALTANTE%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE'
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Uma caixa foi enviada ao cliente contendo apenas o brinde, sem os demais itens do pedido. O ocorrido configura erro grave no processo de separação de faltantes e, por essa razão, o setor Faltantes Mercearia Noite do FC3 terá a bonificação zerada integralmente nesta semana.'

      -- FC3: Reposição Mercearia Noite: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE'
        THEN '-30% na Bonificação. Os completos de mercearia melhoraram na semana, mas a baixa efetividade na execução das listas de reposição no turno da noite segue impactando os indicadores e freando a evolução do setor. Precisamos aumentar a efetividade das listas no turno da noite para sustentar a melhora dos completos.'

      -- FC3: Reposição Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-20% na Bonificação. Os completos de mercearia registraram melhora na semana, mas os indicadores de reposição nos turnos da manhã e da tarde ainda seguem com impacto e há espaço para evoluir. Precisamos manter a melhora na execução da reposição para que os completos de mercearia se consolidem acima da meta.'

      -- FC3: Reposição Fresh (todas): -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
        THEN '-20% na Bonificação. Os completos fresh melhoraram na semana e avançaram dentro da faixa da meta, mas o indicador de reposição fresh ainda apresenta impacto. Precisamos manter a evolução na execução da reposição para consolidar os completos fresh de forma consistente acima da meta.'

      -- FC3: Fiscal Packing e Fiscal Packer Operação Fresh: -40%
      WHEN (SETOR_ORIGINAL LIKE '%PACKING%' OR SETOR_ORIGINAL LIKE '%PACKER%') AND FC = 'FC3'
        THEN '-40% na Bonificação. O setor registrou divergências na liberação de pedidos com volumes trocados e notas fiscais incorretas, comprometendo a operação e gerando retrabalho para outras áreas. Precisamos eliminar as divergências na liberação de pedidos para garantir a integridade das notas e dos volumes entregues.'

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
