-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
-- Última atualização: 10/09/2026
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
      WHEN MATRICULA IN ('13410', '9881') THEN 0.0
      -- [/AUTO:ind-zerados-mult]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-mult]
      WHEN MATRICULA IN ('13075') THEN 0.7
      WHEN MATRICULA IN ('14079', '14367', '19357', '10871', '12386', '13210', '14223', '19468', '13806', '12966', '16559', '10714', '13808', '10675', '17248', '14489', '16735', '17429', '18978', '11371', '12486') THEN 0.8
      -- [/AUTO:ind-parcial-mult]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-mult]
      WHEN MATRICULA IN ('19266', '19640', '18983', '18264', '19448', '19357', '19483') THEN 0.6
      WHEN MATRICULA IN ('16618', '13154', '11205', '17122', '10625', '11422', '6669', '11635', '16167', '16193') THEN 0.5
      WHEN MATRICULA IN ('15322', '17551', '18803', '17502', '19622', '17335', '11323', '17021', '13280', '15381', '11601', '10338', '10682', '19674', '19436', '13808', '19078', '12486', '12122', '15768') THEN 0.8
      WHEN MATRICULA IN ('19325', '13008', '14503', '13995', '18168', '17815', '18297', '11599', '16799', '14402', '17870', '19482', '19355', '13420', '19383', '15907', '19261', '18909', '18154', '17782', '17880', '18903', '18550', '18879', '12880') THEN 0.6
      WHEN MATRICULA IN ('11273', '18111') THEN 1.0
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
      WHEN MATRICULA IN ('13410', '9881') THEN 1.0
      -- [/AUTO:ind-zerados-setor-neut]

      -- ── Setoriais — ATUALIZAR TODA SEMANA ──
      -- Este bloco e' reescrito por inteiro toda semana pelo dashboard_fc_auto.py.
      -- Ele SEMPRE gera, nesta ordem: (1) qualquer linha de "Visão FC1/FC2/FC3"
      -- cujo SETOR digitado seja "Campinas" — identifica por AREA = 'CAMPINAS'
      -- em vez de FC, e vem primeiro; (2) a linha de segurança logo abaixo
      -- ("WHEN AREA = 'CAMPINAS' THEN 1.0") — cai aqui quem for de Campinas e
      -- NÃO tiver uma linha especifica acima nesta semana, então nunca é pego
      -- por engano pelas regras (3) de FC1/FC2/FC3 que vem depois, que não
      -- verificam AREA. Bug real que motivou isto (2026-09): mat 11428,
      -- 15488, 5509 penalizadas em -10% pelo desconto de EXPEDIÇÃO/FC1/MANHÃ
      -- sem nenhuma relacao com a operacao do FC1. A ordem importa: um CASE
      -- para na primeira condição que bate — Campinas especifico tem que vir
      -- antes da rede de segurança, que tem que vir antes de FC1/FC2/FC3.
      -- [AUTO:setoriais-mult]
      WHEN AREA = 'CAMPINAS' THEN 1.0
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO = 'MANHÃ' THEN 0.9
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO = 'TARDE' THEN 0.9
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1' THEN 0.5
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND FC = 'FC1' THEN 0.5
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2' AND TURNO IN ('MANHÃ', 'TARDE') THEN 0.9
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'MANHÃ' THEN 0.85
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE' THEN 0.7
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE' THEN 0.7
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.8
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.9
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' THEN 0.9
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
      WHEN MATRICULA IN ('13410')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Não esta  sendo executadas suas atividades como fiscal  conforme o esperado. É necessário maior atuação e acompanhamento das rotinas e garantir a execução dos processo'
      WHEN MATRICULA IN ('9881')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Tempo morto comportamental — 2ª Reincidência (3 ocorrências na semana). Motivo: Demora no início após direcionamento. 1ª ocorr. em 08/09/2026 (Demora no início após direcionamento (comportamental)); 2ª ocorr. em 09/09/2026 (Demora no início após direcionamento (comportamental) — oper); 3ª ocorr. em 10/09/2026 (Demora no início após direcionamento (comportamental)). Ação: bonificação zerada.'
      -- [/AUTO:ind-zerados-obs]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-obs]
      WHEN MATRICULA IN ('13075')
      THEN '0.3 na Bonificação. Não esta  sendo executadas suas atividades como fiscal  conforme o esperado. É necessário maior atuação e acompanhamento das rotinas e garantir a execução dos processo'
      WHEN MATRICULA IN ('14079')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo: Demora no início após direcionamento. 1ª ocorr. em 05/09/2026 (Demora no início após direcionamento (comportamental) — O co); 2ª ocorr. em 07/09/2026 (Demora no início após direcionamento (comportamental) — O co). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('14367')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo: Demora no início após direcionamento. 1ª ocorr. em 08/09/2026 (Demora no início após direcionamento (comportamental) — Supe); 2ª ocorr. em 10/09/2026 (Demora no início após direcionamento (comportamental) — Cola). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('19357')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dia: 04/09/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('10871')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: FRACIONAMENTO. Dia: 10/09/2026 (executou OPERAÇÃO FRESH) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('12386')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dia: 08/09/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('13210')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 05/09/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('14223')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 04/09/2026 (executou PACKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('19468')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: FRACIONAMENTO. Dia: 04/09/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('13806')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dia: 06/09/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('12966')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dia: 08/09/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('16559')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dia: 05/09/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('10714')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: FRACIONAMENTO. Dia: 05/09/2026 (executou OPERAÇÃO FRESH) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('13808')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: PACKING. Dia: 04/09/2026 (executou PICKING) — sem nenhuma alocação registrada no QLP. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('10675')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: FRACIONAMENTO. Dia: 10/09/2026 (executou OPERAÇÃO FRESH) — alocado em AUX. FRACIONAMENTO / 5S [alocações do dia: 5S, AUX. FRACIONAMENTO]. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('17248')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: FRACIONAMENTO. Dia: 09/09/2026 (executou OPERAÇÃO FRESH) — alocado em 5S. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('14489')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: PICKING. Dia: 05/09/2026 (executou PACKING) — alocado em 5S. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('16735')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: PICKING. Dia: 04/09/2026 (executou OPERAÇÃO FRESH) — alocado em 5S. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('17429')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dia: 04/09/2026 (executou PACKING) — alocado em SEPARAÇÃO [alocações do dia: FRESH PICKER/PACKER, SEPARAÇÃO]. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('18978')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PICKING sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dia: 04/09/2026 (executou PICKING) — alocado em FRESH PICKER/PACKER / 5S [alocações do dia: 5S, FRESH PICKER/PACKER]. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('11371')
      THEN '0.2 na Bonificação. Furo de alocação — Executou PACKING sem alocação no QLP. Setor de origem: OPERAÇÃO FRESH. Dia: 05/09/2026 (executou PACKING) — alocado em 5S [alocações do dia: FRESH PICKER/PACKER, 5S]. Desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('12486')
      THEN '0.2 na Bonificação. Furo de alocação — Executou OPERAÇÃO FRESH sem alocação no QLP. Setor de origem: PACKING. Dia: 08/09/2026 (executou OPERAÇÃO FRESH) — alocado em CHECKOUT [alocações do dia: CHECKOUT, SEPARAÇÃO]. Desconto de 20% na bonificação.'
      -- [/AUTO:ind-parcial-obs]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-obs]
      WHEN MATRICULA IN ('19266', '19640', '18983', '18264', '19448', '19357', '19483')
      THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'
      WHEN MATRICULA IN ('16618', '13154', '11205', '17122', '10625', '11422', '6669', '11635', '16167', '16193')
      THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'
      WHEN MATRICULA IN ('15322', '17551', '18803', '17502', '19622', '17335', '11323', '17021', '13280', '15381', '11601', '10338', '10682', '19674', '19436', '13808', '19078', '12486', '12122', '15768')
      THEN '-20% na Bonificação. Você apresentou uma alta taxa de erros no Picking, que supera o limite aceitável. Essa performance impactou diretamente os indicadores da área e gerou mais retrabalho para outras áreas.'
      WHEN MATRICULA IN ('19325', '13008', '14503', '13995', '18168', '17815', '18297', '11599', '16799', '14402', '17870', '19482', '19355', '13420', '19383', '15907', '19261', '18909', '18154', '17782', '17880', '18903', '18550', '18879', '12880')
      THEN '-40% na Bonificação. Na última semana, você esteve entre os 20% dos colaboradores de outros setores que apresentaram as maiores taxas de erro ao serem alocados para o Picking. Independentemente da área de atuação, é indispensável manter a alta produtividade e qualidade.'
      WHEN MATRICULA IN ('11273', '18111')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Colaboradores reincidentes nos 20% Piores com maior taxa de erro no Picking.'
      -- [/AUTO:fiscais-picking-obs]

      -- GE: Inventário — ATUALIZAR TODA SEMANA
      -- [AUTO:ge-obs]
      WHEN MATRICULA IN ('5728', '7064', '11080', '12003', '13106', '16439', '18200', '17451', '19327', '16902', '13793', '17320', '17247')
      THEN 'Você não atingiu o mínimo de posições necessário para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('10893', '11145', '13232', '8869', '16984', '19712', '18138', '18437', '16436', '12893')
      THEN 'Você não atingiu o mínimo de posições nem a acuracidade mínima necessários para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('18925', '19030', '13794', '14033', '15209', '18335', '15643', '16750', '13727', '15259', '15478')
      THEN 'Você não atingiu a acuracidade mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('13869', '13879', '17052', '18445')
      THEN 'Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao baixo desempenho nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'
      -- [/AUTO:ge-obs]

      -- 7. KPIs Setoriais — ATUALIZAR TODA SEMANA
      -- Mesma mecânica/ordem do bloco [AUTO:setoriais-mult] (ver comentário
      -- lá): Campinas especifico primeiro, depois a rede de segurança,
      -- depois FC1/FC2/FC3.
      -- [AUTO:setoriais-obs]
      WHEN AREA = 'CAMPINAS' THEN NULL
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO = 'MANHÃ'
      THEN '-10% na Bonificação. O turno da manhã apresentou erros na alocação de produtos CONG/REFRI em destinos divergentes, impactando o mapeamento. Essa falha no processo influenciou negativamente os resultados de divergências e o percentual de pedidos mapeados.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO = 'TARDE'
      THEN '-10% na Bonificação. O turno da tarde apresentou erros na alocação de produtos refrigerados e congelados em destinos divergentes. Esta falha impactou negativamente os resultados de divergências e o percentual de pedidos mapeados.'
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1'
      THEN '-50% na Bonificação. O resultado foi impactado pelos tempos de carregamento de SMD, HR e Fiorino, que ficaram distantes da meta. O atraso no término da leva A e a performance dos pedidos mapeados também contribuíram para o resultado da semana.'
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND FC = 'FC1'
      THEN '-50% na Bonificação. O resultado foi impactado pela performance no tempo de carregamento SMD e no percentual de pedidos mapeados. Os tempos de carregamento para HR e Fiorino, além do horário de término da leva A, continuam sendo pontos de atenção.'
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2' AND TURNO IN ('MANHÃ', 'TARDE')
      THEN '-10% na Bonificação. Os tempos de carregamento de SMD, HR e Fiorino ficaram distantes da meta. O tempo de término da leva A também apresentou piora, afetando o indicador de pedidos mapeados.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'MANHÃ'
      THEN '-15% na Bonificação. O turno da manhã manteve o resultado da semana anterior, porém o indicador de completos mercearia permanece distante da meta. Precisamos focar na melhoria deste processo para evitar perdas futuras.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE'
      THEN '-30% na Bonificação. A baixa eficiência do turno da tarde na execução das atividades impactou negativamente nossos indicadores de completos mercearia e rupturas. O resultado de divergência de estoque também ficou distante da meta, reforçando a necessidade de maior atenção aos processos.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE'
      THEN '-30% na Bonificação. A baixa eficiência do turno da noite na execução das atividades diárias manteve o resultado do indicador de completos mercearia distante da meta. A não conclusão recorrente da Lista C.1 foi o principal fator para este resultado.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
      THEN '-20% na Bonificação. Observamos uma melhora no resultado de Erros - Global, indicando evolução nos processos. No entanto, o indicador de Completos Fresh - KPI permaneceu distante da meta.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3'
      THEN '-10% na Bonificação. Erros operacionais na conferência e mapeamento impactaram o indicador de pedidos mapeados e aumentaram as divergências de estoque. Essa performance nos deixou distantes da meta de completos fresh.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
      THEN '-10% na Bonificação. Erros operacionais durante a conferência e o mapeamento impactaram o resultado de divergências de estoque e o percentual de pedidos mapeados. A atenção ao processo é fundamental para a melhora dos completos mercearia.'
      -- [/AUTO:setoriais-obs]

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
