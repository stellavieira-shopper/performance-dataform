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
      WHEN MATRICULA IN ('8511', '8899', '18970', '17551', '12925', '10503', '10349', '15322', '8170', '17286', '10887', '16796', '10871', '12388', '12832', '13451', '17430', '9049', '17406', '18202', '18818', '17041', '19357', '18570', '18483', '16212', '14489', '13210', '14467', '14223', '15649', '15635', '15378', '18613', '15790', '15819', '16435', '16193', '18820', '14197', '5922', '5463') THEN 1.2
      -- [/AUTO:ind-parcial-mult]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-mult]
      WHEN MATRICULA IN ('18914', '18970', '18764') THEN 0.6
      WHEN MATRICULA IN ('17551', '17827') THEN 1.0
      WHEN MATRICULA IN ('19266', '18930', '19004', '19245', '18993', '14489') THEN 0.8
      WHEN MATRICULA IN ('11273', '6204', '18529', '18778', '18634', '17715', '15281') THEN 0.6
      WHEN MATRICULA IN ('17192', '18666', '18890', '16195', '16103') THEN 0.5
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
      WHEN MATRICULA IN ('8511')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: PICKING. Dia: 25/08/2026 (executou OPERAÇÃO FRESH) — alocado em SEPARAÇÃO. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('8899')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: PACKING. Dia: 24/08/2026 (executou OPERAÇÃO FRESH) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('18970')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('17551')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('12925')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dias: 21/08/2026 (executou PACKING) — alocado em SEPARAÇÃO; 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('10503')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dias: 21/08/2026 (executou PACKING) — alocado em FRESH PICKER/PACKER; 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('10349')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dia: 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('15322')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dia: 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('8170')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dia: 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('17286')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dia: 22/08/2026 (executou PACKING) — alocado em FRESH PICKER/PACKER. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('10887')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dia: 22/08/2026 (executou PACKING) — alocado em FRESH PICKER/PACKER. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('16796')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dia: 22/08/2026 (executou PACKING) — alocado em FRESH PICKER/PACKER. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('10871')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: FRACIONAMENTO. Dias: 23/08/2026 (executou OPERAÇÃO FRESH) — alocado em AUX. FRACIONAMENTO; 25/08/2026 (executou OPERAÇÃO FRESH) — alocado em AUX. FRACIONAMENTO; 27/08/2026 (executou OPERAÇÃO FRESH) — alocado em 5S. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('12388')
      THEN '0.2 na Bonificação. Furo de alocação — Executou FRACIONAMENTO sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dias: 24/08/2026 (executou FRACIONAMENTO) — sem nenhuma alocação registrada no QLP; 25/08/2026 (executou FRACIONAMENTO) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('12832')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dia: 22/08/2026 (executou PICKING) — alocado em CHECKOUT. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('13451')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: FRACIONAMENTO. Dia: 21/08/2026 (executou OPERAÇÃO FRESH) — alocado em AUX. FRACIONAMENTO. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('17430')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo: Demora no início após direcionamento. 1ª ocorr. em 25/08/2026 (Demora no início após direcionamento (comportamental) — Alin); 2ª ocorr. em 26/08/2026 (Demora no início após direcionamento (comportamental) — Oper). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('9049')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo: Demora no início após direcionamento. 1ª ocorr. em 21/08/2026 (Demora no início após direcionamento (comportamental) — Conv); 2ª ocorr. em 26/08/2026 (Demora no início após direcionamento (comportamental)). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('17406')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('18202')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: PACKING. Dia: 27/08/2026 (executou OPERAÇÃO FRESH) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('18818')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dias: 21/08/2026 (executou PACKING) — alocado em SEPARAÇÃO; 22/08/2026 (executou PACKING) — alocado em SEPARAÇÃO; 27/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('17041')
      THEN '0.2 na Bonificação. Furo de alocação — Executou FRACIONAMENTO sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dia: 24/08/2026 (executou FRACIONAMENTO) — alocado em FRESH PICKER/PACKER. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('19357')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dias: 25/08/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP; 27/08/2026 (executou PICKING) — alocado em 5S. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('18570')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dias: 23/08/2026 (executou PICKING) — alocado em CHECKOUT; 24/08/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP; 25/08/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('18483')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dia: 27/08/2026 (executou PICKING) — alocado em CHECKOUT. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('16212')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 27/08/2026 (executou PACKING) — alocado em INCLUIR FALTANTES (MERCEARIA). Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('14489')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('13210')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('14467')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('14223')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('15649')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 22/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('15635')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH/PACKING sem alocação no QLP. Setor de origem: FRACIONAMENTO. Dias: 21/08/2026 (executou OPERAÇÃO FRESH) — sem nenhuma alocação registrada no QLP; 22/08/2026 (executou OPERAÇÃO FRESH) — sem nenhuma alocação registrada no QLP; 23/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP; 24/08/2026 (executou OPERAÇÃO FRESH) — sem nenhuma alocação registrada no QLP; 25/08/2026 (executou OPERAÇÃO FRESH) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('15378')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: FRACIONAMENTO. Dias: 24/08/2026 (executou OPERAÇÃO FRESH) — sem nenhuma alocação registrada no QLP; 25/08/2026 (executou OPERAÇÃO FRESH) — sem nenhuma alocação registrada no QLP; 27/08/2026 (executou OPERAÇÃO FRESH) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('18613')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: FRACIONAMENTO. Dia: 21/08/2026 (executou OPERAÇÃO FRESH) — alocado em AUX. FRACIONAMENTO. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('15790')
      THEN '0.2 na Bonificação. Furo de alocação — Executou FRACIONAMENTO sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dias: 21/08/2026 (executou FRACIONAMENTO) — sem nenhuma alocação registrada no QLP; 24/08/2026 (executou FRACIONAMENTO) — sem nenhuma alocação registrada no QLP; 27/08/2026 (executou FRACIONAMENTO) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('15819')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dia: 24/08/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('16435')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dia: 23/08/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('16193')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dias: 23/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP; 24/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('18820')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 24/08/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('14197')
      THEN '0.2 na Bonificação. Furo de alocação — Executou FRACIONAMENTO sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dia: 25/08/2026 (executou FRACIONAMENTO) — alocado em FRESH PICKER/PACKER. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('5922')
      THEN '0.2 na Bonificação. Não realizou adequadamente as alocações da equipe.'
      WHEN MATRICULA IN ('5463')
      THEN '0.2 na Bonificação. Não realizou adequadamente as alocações da equipe.'
      -- [/AUTO:ind-parcial-obs]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-obs]
      WHEN MATRICULA IN ('18914', '18970', '18764')
      THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'
      WHEN MATRICULA IN ('17551', '17827')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Colaboradores reincidentes nos 20% Piores com maior taxa de erro no Picking.'
      WHEN MATRICULA IN ('19266', '18930', '19004', '19245', '18993', '14489')
      THEN '-20% na Bonificação. Você apresentou uma alta taxa de erros no Picking, que supera o limite aceitável. Essa performance impactou diretamente os indicadores da área e gerou mais retrabalho para outras áreas.'
      WHEN MATRICULA IN ('11273', '6204', '18529', '18778', '18634', '17715', '15281')
      THEN '-40% na Bonificação. Na última semana, você esteve entre os 20% dos colaboradores de outros setores que apresentaram as maiores taxas de erro ao serem alocados para o Picking. Independentemente da área de atuação, é indispensável manter a alta produtividade e qualidade.'
      WHEN MATRICULA IN ('17192', '18666', '18890', '16195', '16103')
      THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'
      -- [/AUTO:fiscais-picking-obs]

      -- GE: Inventário — ATUALIZAR TODA SEMANA
      -- [AUTO:ge-obs]
      WHEN MATRICULA IN ('12003', '13232', '11569', '18335', '16993', '18437', '16750', '17052')
      THEN 'Você não atingiu a acuracidade mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('11145', '8033', '8869', '18939', '18138', '16902', '13793', '15643')
      THEN 'Você não atingiu o mínimo de posições nem a acuracidade mínima necessários para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('18149', '16439', '13495', '16421', '17255', '18200', '17451', '16886', '14855')
      THEN 'Você não atingiu o mínimo de posições necessário para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('9758', '17251', '13879', '18445', '16436')
      THEN 'Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao baixo desempenho nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'
      WHEN MATRICULA IN ('19116')
      THEN 'Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana por não atingir o mínimo de posições nem a acuracidade mínima. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'
      -- [/AUTO:ge-obs]

      -- 7. KPIs Setoriais — ATUALIZAR TODA SEMANA
      -- [AUTO:setoriais-obs]
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
      THEN '-10% na Bonificação. Nosso resultado de completos fresh piorou e ficou distante da meta, impactado pelo grande volume de transferências realizadas ao longo da semana.'
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1' AND TURNO = 'MANHÃ'
      THEN '-10% na Bonificação. O time da manhã apresentou atraso no término da leva A, ficando distante da meta. O tempo de carregamento dos SMD também precisa de atenção para garantir as saídas no horário.'
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND AREA = 'MERCEARIA' AND FC = 'FC1'
      THEN '-10% na Bonificação. O percentual de pedidos mapeados Mercearia ficou distante da meta, impactando o resultado da semana. A baixa performance no mapeamento afetou diretamente o tempo de carregamento dos SMD.'
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND AREA = 'FRESH' AND FC = 'FC1'
      THEN '-20% na Bonificação. O percentual de pedidos mapeados Fresh ficou distante da meta, sendo o principal motivo do desconto. Este resultado impactou negativamente o tempo de carregamento dos SMD.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE'
      THEN '-30% na Bonificação. A baixa eficiência na execução das atividades do turno da tarde impactou negativamente o indicador de completos mercearia. Esse cenário nos manteve distantes da meta, refletindo diretamente na taxa de pedidos completos.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE'
      THEN '-40% na Bonificação. O resultado de completos mercearia ficou distante da meta devido à baixa eficiência da reposição mercearia no turno da noite. É fundamental melhorar a eficiência na execução da lista C.1.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
      THEN '-20% na Bonificação. Apresentamos uma leve melhora no desempenho com a redução dos Erros - Global. Porém, a taxa de Completos Fresh permanece abaixo do esperado, mostrando que temos margem para continuar evoluindo na execução.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
      THEN '-20% na Bonificação. Foram identificados erros operacionais na conferência e mapeamento que nos deixaram distantes da meta de erros globais e de pedidos mapeados. Essa performance impactou diretamente os resultados de completos mercearia e divergência de estoque.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3'
      THEN '-20% na Bonificação. Erros operacionais na conferência e mapeamento impactaram negativamente os indicadores de pedidos mapeados e aumentaram as divergências de estoque. Consequentemente, o resultado de completos fresh piorou e o de rupturas ficou distante da meta.'
      -- [/AUTO:setoriais-obs]

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
