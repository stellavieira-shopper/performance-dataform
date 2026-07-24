-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
-- Última atualização: 23/07/2026
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

      -- 5. KPIs Individuais zerados por coordenadores — ATUALIZAR TODA SEMANA (23/07/2026)
      WHEN MATRICULA IN ('12368', '11961') THEN 0.0

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
      WHEN MATRICULA IN ('12368', '11961') THEN 1.0

      -- ── Picking individual — ATUALIZAR TODA SEMANA (23/07/2026) ──

      -- -50% reincidência picking
      WHEN MATRICULA IN ('11635', '16113', '11205', '16209', '16195') THEN 0.50

      -- -40% picking
      WHEN MATRICULA IN ('17551', '18132', '18181', '18147', '17496', '13996', '15762', '11422', '8317', '10616', '15582', '14440', '17826', '18139', '13138', '14995') THEN 0.60

      -- KPI Individual -20% (coordenador) — ATUALIZAR TODA SEMANA (23/07/2026)
      WHEN MATRICULA IN ('12081') THEN 0.80

      -- ── Setoriais semana 23/07/2026 ──

      -- FC1: Expedição Manhã: -10%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA') THEN 0.90

      -- FC1: Reposição Mercearia (todos): -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' THEN 0.70

      -- FC1: Recebimento Mercearia Tarde: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO = 'TARDE' THEN 0.80

      -- FC1: Recebimento Fresh Manhã e Noite: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA', 'NOITE') THEN 0.80

      -- FC1: Recebimento Fresh (demais turnos): -50%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1' THEN 0.50

      -- FC1: Reposição Fresh FLV: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.70

      -- FC1: Reposição Fresh (todas): -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1' THEN 0.80

      -- FC2: Expedição Manhã e Tarde: -10%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.90

      -- FC2: Faltantes Mercearia Noite: ZERADO
      WHEN SETOR_ORIGINAL LIKE '%FALTANTE%' AND AREA = 'MERCEARIA' AND FC = 'FC2'
           AND TURNO = 'NOITE' THEN 0.0

      -- FC3: Recebimento Fresh (todos): -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.70

      -- FC3: Recebimento Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE') THEN 0.80

      -- FC3: Recebimento Mercearia Noite: -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE' THEN 0.70

      -- FC3: Reposição Fresh FLV: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.70

      -- FC3: Reposição Fresh (todas): -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.80

      -- FC3: Fiscal Packer Operação Fresh e Fiscal Packing: -30%
      WHEN (SETOR_ORIGINAL LIKE '%PACKING%' OR SETOR_ORIGINAL LIKE '%PACKER%') AND FC = 'FC3' THEN 0.70

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

      -- 5. KPIs Individuais zerados por coordenadores — ATUALIZAR TODA SEMANA (23/07/2026)
      WHEN MATRICULA IN ('12368')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Sua bonificação foi zerada devido ao recebimento do SKU quiabo no dia 17/07 sem sinalização no grupo de FLV ao vivo, resultando em perda total do lote e impossibilitando a compra nas externas, o que causou ruptura ao cliente.'
      WHEN MATRICULA IN ('11961')
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Sua bonificação foi zerada devido ao envio de caixa vazia ao cliente nesta semana.'

      -- 6. PICKING INDIVIDUAL — ATUALIZAR TODA SEMANA (23/07/2026)

      -- -50% reincidência picking
      WHEN MATRICULA IN ('11635', '16113', '11205', '16209', '16195')
        THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'

      -- -40% picking
      WHEN MATRICULA IN ('17551', '18132', '18181', '18147', '17496', '13996', '15762', '11422', '8317', '10616', '15582', '14440', '17826', '18139', '13138', '14995')
        THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'

      -- KPI Individual -20% (coordenador) — ATUALIZAR TODA SEMANA (23/07/2026)
      WHEN MATRICULA IN ('12081')
        THEN '-20% na Bonificação. Sua bonificação teve um desconto de 20% porque a meta de vistorias não foi atingida durante o período de apuração.'

      -- 7. KPIs SETORIAIS — ATUALIZAR MENSAGENS TODA SEMANA (23/07/2026)

      -- FC1: Expedição Manhã: -10%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA')
        THEN '-10% na Bonificação. Os tempos de leva A e HR do turno da manhã pioraram na semana e ultrapassaram a meta, enquanto o carregamento SMD avançou e segue acima do objetivo. Precisamos retomar o controle dos tempos de leva A e HR no turno da manhã para recuperar o indicador.'

      -- FC1: Reposição Mercearia (todos): -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1'
        THEN '-30% na Bonificação. Os completos de mercearia melhoraram na semana, mas o processo de reposição está sendo burlado com jogadas em reservas não mapeadas, comprometendo a integridade dos indicadores. Precisamos garantir a execução correta da reposição nas posições mapeadas para que a melhora seja sustentável.'

      -- FC1: Recebimento Mercearia Tarde: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1'
           AND TURNO = 'TARDE'
        THEN '-20% na Bonificação. O turno da tarde do Recebimento Mercearia apresentou questões comportamentais e falta de senso de urgência que impactam o ritmo operacional e os indicadores da área. Precisamos retomar a postura adequada e a agilidade na execução das atividades para não comprometer os resultados do setor.'

      -- FC1: Recebimento Fresh Manhã e Noite: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1'
           AND TURNO IN ('MANHÃ', 'MANHA', 'NOITE')
        THEN '-20% na Bonificação. O recebimento fresh nos turnos da manhã e da noite registrou falhas de qualidade não reportadas no grupo, impactando os completos fresh que pioraram na semana. Precisamos garantir o reporte imediato de problemas de qualidade no recebimento para minimizar o impacto nos indicadores.'

      -- FC1: Recebimento Fresh (demais turnos): -50%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1'
        THEN '-50% na Bonificação. O recebimento fresh registrou falhas graves de qualidade sem reporte no grupo, gerando impacto direto no fracionamento e comprometendo os completos fresh. Precisamos garantir o reporte imediato e a rejeição de produtos fora do padrão para evitar o impacto em cadeia nos indicadores.'

      -- FC1: Reposição Fresh FLV: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
        THEN '-30% na Bonificação. Os completos fresh pioraram na semana e os erros de movimentação FLV cresceram expressivamente, sendo o principal fator de impacto no indicador. Precisamos retomar a eficiência e a qualidade na execução da reposição FLV para reverter a piora dos completos fresh.'

      -- FC1: Reposição Fresh (todas): -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
        THEN '-20% na Bonificação. Os completos fresh pioraram na semana com queda expressiva, impactada pela baixa eficiência e produtividade na execução da reposição fresh. Precisamos melhorar a eficiência da reposição para reverter a piora dos completos fresh.'

      -- FC2: Expedição Manhã e Tarde: -10%
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-10% na Bonificação. Os tempos de leva A e HR nos turnos da manhã e da tarde pioraram na semana e seguem muito acima da meta, enquanto o Fiorino registrou leve melhora. Precisamos retomar o controle dos tempos operacionais para que a expedição evolua nos indicadores.'

      -- FC2: Faltantes Mercearia Noite: ZERADO
      WHEN SETOR_ORIGINAL LIKE '%FALTANTE%' AND AREA = 'MERCEARIA' AND FC = 'FC2'
           AND TURNO = 'NOITE'
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. O setor Faltantes Mercearia Noite do FC2 terá a bonificação zerada integralmente nesta semana. Para mais informações sobre o motivo, consulte seu gestor direto.'

      -- FC3: Recebimento Fresh (todos): -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3'
        THEN '-30% na Bonificação. Os completos fresh melhoraram na semana, mas erros operacionais no recebimento fresh persistem e seguem comprometendo os indicadores da área. Precisamos eliminar os erros operacionais no recebimento para consolidar a melhora dos completos fresh.'

      -- FC3: Recebimento Mercearia Manhã e Tarde: -20%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO IN ('MANHÃ', 'MANHA', 'TARDE')
        THEN '-20% na Bonificação. Os completos de mercearia melhoraram na semana, mas os indicadores de recebimento mercearia nos turnos da manhã e da tarde seguem com impacto e as divergências de estoque aumentaram levemente. Precisamos reduzir o impacto do recebimento nos indicadores para sustentar a melhora dos completos.'

      -- FC3: Recebimento Mercearia Noite: -30%
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
           AND TURNO = 'NOITE'
        THEN '-30% na Bonificação. Os completos de mercearia melhoraram na semana, mas o recebimento mercearia no turno da noite segue com impacto nos indicadores e as divergências de estoque aumentaram levemente. Precisamos reduzir o impacto do recebimento no turno da noite para manter a evolução dos completos.'

      -- FC3: Reposição Fresh FLV: -30%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
           AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
        THEN '-30% na Bonificação. Os completos fresh melhoraram na semana, mas a reposição FLV segue com falhas operacionais e movimentações erradas que impedem uma evolução mais consistente dos indicadores. Precisamos eliminar as movimentações erradas na reposição FLV para sustentar a melhora dos completos fresh.'

      -- FC3: Reposição Fresh (todas): -20%
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
        THEN '-20% na Bonificação. Os completos fresh melhoraram na semana, mas os indicadores de reposição fresh seguem andando de lado, sem a evolução necessária para consolidar os resultados. Precisamos avançar na qualidade da execução da reposição fresh para manter a melhora dos completos.'

      -- FC3: Fiscal Packer Operação Fresh e Fiscal Packing: -30%
      WHEN (SETOR_ORIGINAL LIKE '%PACKING%' OR SETOR_ORIGINAL LIKE '%PACKER%') AND FC = 'FC3'
        THEN '-30% na Bonificação. O setor registrou divergências na liberação de pedidos com volumes trocados e notas fiscais incorretas, comprometendo os indicadores. Precisamos eliminar as divergências na liberação de pedidos para garantir a integridade das notas e dos volumes.'

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
