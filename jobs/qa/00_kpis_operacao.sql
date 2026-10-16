-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
-- Última atualização: 15/10/2026
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
        BETWEEN v_start_date AND v_end_date

  UNION DISTINCT

  -- Rupturas de stock não justificadas até sexta 14h após o fechamento do ranking
  SELECT DISTINCT
    SAFE_CAST(matricula AS STRING) AS MATRICULA,
    'RUPTURA' AS IMPACTO_ERRO,
    'RUPTURAS_STOCK' AS ORIGEM
  FROM `shopper-datalakehouse-qa.Ranking_Performance.vw_rupturas_zeramento`
  WHERE sexta_fechamento = DATE_ADD(v_end_date, INTERVAL 1 DAY)
    AND matricula IS NOT NULL;

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
      WHEN MATRICULA IN ('14367', '16623', '17198', '17801', '19377') THEN 0.0
      -- [/AUTO:ind-zerados-mult]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-mult]
      WHEN MATRICULA IN ('8642', '14228') THEN 0.9
      WHEN MATRICULA IN ('1030') THEN 0.5
      WHEN MATRICULA IN ('20616', '20106', '19632', '13420', '20669', '20382', '16329', '12966', '17331', '16904') THEN 0.8
      -- [/AUTO:ind-parcial-mult]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-mult]
      WHEN MATRICULA IN ('20122', '20128') THEN 1.0
      WHEN MATRICULA IN ('20201', '20166') THEN 0.6
      WHEN MATRICULA IN ('10457', '20160', '16618', '19245', '20160') THEN 0.5
      WHEN MATRICULA IN ('18919', '15015', '18983', '15719', '19860', '4990', '20137', '6552', '17849', '19245', '20655', '19266', '20203', '17463', '17551', '20510') THEN 0.8
      WHEN MATRICULA IN ('8511', '20589', '20689', '15425') THEN 0.6
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
      WHEN MATRICULA IN ('14367', '16623', '17198', '17801', '19377') THEN 1.0
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
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1' AND TURNO IN ('MANHÃ', 'TARDE') THEN 0.9
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO IN ('MANHÃ', 'NOITE') THEN 0.7
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1' THEN 0.8
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND FC = 'FC2' AND TURNO = 'NOITE' THEN 0.85
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'MANHÃ' THEN 0.75
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE' THEN 0.75
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE' THEN 0.7
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%' THEN 0.8
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.8
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.85
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO IN ('MANHÃ', 'TARDE') THEN 0.9
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
      WHEN IMPACTO_ERRO = 'RUPTURA' AND ORIGEM = 'RUPTURAS_STOCK'
        THEN 'VALOR DA BONIFICAÇÃO ZERADO. Foi identificada a decisão de ruptura em um item com estoque mapeado. Valide junto à sua coordenação.'
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
      WHEN MATRICULA IN ('17801')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Tempo morto comportamental — 3ª Reincidência ou mais (4 ocorrências na semana). Motivo(s): Ociosidade / pausa além do permitido, Demora para retomar após direcionamento; Demora para retomar após direcionamento; Ausência do posto sem justificativa. 1ª ocorr. em 11/10/2026 (Acumulado: Ociosidade / pausa além do permitido, Demora para retomar após direcionamento); 2ª ocorr. em 12/10/2026 (Acumulado: Demora para retomar após direcionamento); 3ª ocorr. em 13/10/2026 (Acumulado: Ausência do posto sem justificativa); 4ª ocorr. em 14/10/2026 (Acumulado: Ausência do posto sem justificativa). Ação: advertência formal.'
      WHEN MATRICULA IN ('14367')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Tempo morto comportamental — 2ª Reincidência (3 ocorrências na semana). Motivo(s): Ausência do posto sem justificativa; Ausência do posto sem justificativa, Ociosidade / pausa além do permitido. 1ª ocorr. em 09/10/2026 (Acumulado: Ausência do posto sem justificativa); 2ª ocorr. em 12/10/2026 (Acumulado: Ausência do posto sem justificativa, Ociosidade / pausa além do permitido); 3ª ocorr. em 13/10/2026 (Acumulado: Ausência do posto sem justificativa, Ociosidade / pausa além do permitido). Ação: bonificação zerada.'
      WHEN MATRICULA IN ('16623')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Tempo morto comportamental — 2ª Reincidência (3 ocorrências na semana). Motivo(s): Demora no início após direcionamento; Ausência do posto sem justificativa. 1ª ocorr. em 12/10/2026 (Dificuldade operacional — realizado alinhamento; Demora no i); 2ª ocorr. em 12/10/2026 (Acumulado: Ausência do posto sem justificativa); 3ª ocorr. em 13/10/2026 (Acumulado: Ausência do posto sem justificativa). Ação: bonificação zerada.'
      WHEN MATRICULA IN ('17198')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Tempo morto comportamental — 3ª Reincidência ou mais (5 ocorrências na semana). Motivo(s): Demora no início após direcionamento; Ausência do posto sem justificativa; Ociosidade / pausa além do permitido, Demora para retomar após direcionamento; Ausência do posto sem justificativa, Demora para retomar após direcionamento. 1ª ocorr. em 09/10/2026 (Acumulado: Ausência do posto sem justificativa); 2ª ocorr. em 11/10/2026 (Acumulado: Ociosidade / pausa além do permitido, Demora para retomar após direcionamento); 3ª ocorr. em 12/10/2026 (Acumulado: Ausência do posto sem justificativa); 4ª ocorr. em 14/10/2026 (Acumulado: Ausência do posto sem justificativa, Demora para retomar após direcionamento); 5ª ocorr. em 15/10/2026 (Demora no início após direcionamento (comportamental) — Cola). Ação: advertência formal.'
      WHEN MATRICULA IN ('19377')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Tempo morto comportamental — 2ª Reincidência (3 ocorrências na semana). Motivo(s): Demora no início após direcionamento; Ausência do posto sem justificativa. 1ª ocorr. em 11/10/2026 2ª ocorr. em 11/10/2026 (Acumulado: Ausência do posto sem justificativa); 3ª ocorr. em 12/10/2026 (Acumulado: Ausência do posto sem justificativa). Ação: bonificação zerada.'
      -- [/AUTO:ind-zerados-obs]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-obs]
      WHEN MATRICULA IN ('8642')
      THEN '0.1 na Bonificação. Supervisor não acompanhou atividade de check de temperatura no turno tarde e a mesma não foi executada dia 12/10'
      WHEN MATRICULA IN ('14228')
      THEN '0.1 na Bonificação. Fiscal não executou a atividade de check de temperatura dia 12/10'
      WHEN MATRICULA IN ('1030')
      THEN '0.5 na Bonificação. O supervisor realizou a subs de um produto sem autorização previamente alinhada com a coordenação.'
      WHEN MATRICULA IN ('20616')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo(s): Demora para retomar após direcionamento. 1ª ocorr. em 11/10/2026 (Acumulado: Demora para retomar após direcionamento); 2ª ocorr. em 12/10/2026 (Acumulado: Demora para retomar após direcionamento). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('20106')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo(s): Demora para retomar após direcionamento; Ociosidade / pausa além do permitido. 1ª ocorr. em 12/10/2026 (Acumulado: Demora para retomar após direcionamento); 2ª ocorr. em 13/10/2026 (Acumulado: Ociosidade / pausa além do permitido). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('19632')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo(s): Ausência do posto sem justificativa; Demora para retomar após direcionamento. 1ª ocorr. em 11/10/2026 (Acumulado: Ausência do posto sem justificativa); 2ª ocorr. em 12/10/2026 (Acumulado: Demora para retomar após direcionamento). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('13420')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo(s): Ausência do posto sem justificativa. 1ª ocorr. em 11/10/2026 (Acumulado: Ausência do posto sem justificativa); 2ª ocorr. em 14/10/2026 (Acumulado: Ausência do posto sem justificativa). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('20669')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo(s): Ausência do posto sem justificativa; Demora para retomar após direcionamento. 1ª ocorr. em 11/10/2026 (Acumulado: Ausência do posto sem justificativa); 2ª ocorr. em 12/10/2026 (Acumulado: Demora para retomar após direcionamento). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('20382')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo(s): Demora no início após direcionamento; Ausência do posto sem justificativa. 1ª ocorr. em 13/10/2026 (Demora no início após direcionamento (comportamental) — O co); 2ª ocorr. em 15/10/2026 (Acumulado: Ausência do posto sem justificativa). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('16329')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo(s): Ausência do posto sem justificativa, Demora para retomar após direcionamento; Demora para retomar após direcionamento. 1ª ocorr. em 12/10/2026 (Acumulado: Ausência do posto sem justificativa, Demora para retomar após direcionamento); 2ª ocorr. em 14/10/2026 (Acumulado: Demora para retomar após direcionamento). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('12966')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo(s): Demora no início após direcionamento. 1ª ocorr. em 13/10/2026 (Demora no início após direcionamento (comportamental)); 2ª ocorr. em 14/10/2026 (Demora no início após direcionamento (comportamental)). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('17331')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo(s): Ausência do posto sem justificativa. 1ª ocorr. em 09/10/2026 (Acumulado: Ausência do posto sem justificativa); 2ª ocorr. em 11/10/2026 (Acumulado: Ausência do posto sem justificativa). Ação: desconto de 20% na bonificação.'
      WHEN MATRICULA IN ('16904')
      THEN '0.2 na Bonificação. Tempo morto comportamental — 1ª Reincidência (2 ocorrências na semana). Motivo(s): Ausência do posto sem justificativa, Demora para retomar após direcionamento; Demora para retomar após direcionamento. 1ª ocorr. em 12/10/2026 (Acumulado: Ausência do posto sem justificativa, Demora para retomar após direcionamento); 2ª ocorr. em 14/10/2026 (Acumulado: Demora para retomar após direcionamento). Ação: desconto de 20% na bonificação.'
      -- [/AUTO:ind-parcial-obs]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-obs]
      WHEN MATRICULA IN ('20122', '20128')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Colaboradores reincidentes nos 20% Piores com maior taxa de erro no Picking.'
      WHEN MATRICULA IN ('20201', '20166')
      THEN '-40% na Bonificação. Na última semana, você esteve entre os 20% dos colaboradores de outros setores que apresentaram as maiores taxas de erro ao serem alocados para o Picking. Independentemente da área de atuação, é indispensável manter a alta produtividade e qualidade.'
      WHEN MATRICULA IN ('10457', '20160', '16618', '19245', '20160')
      THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'
      WHEN MATRICULA IN ('18919', '15015', '18983', '15719', '19860', '4990', '20137', '6552', '17849', '19245', '20655', '19266', '20203', '17463', '17551', '20510')
      THEN '-20% na Bonificação. Você apresentou uma alta taxa de erros no Picking, que supera o limite aceitável. Essa performance impactou diretamente os indicadores da área e gerou mais retrabalho para outras áreas.'
      WHEN MATRICULA IN ('8511', '20589', '20689', '15425')
      THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'
      -- [/AUTO:fiscais-picking-obs]

      -- GE: Inventário — ATUALIZAR TODA SEMANA
      -- [AUTO:ge-obs]
      WHEN MATRICULA IN ('11853', '10893', '7064', '7100', '17593', '12371', '18939', '17470', '16439', '16902', '19439', '19435', '19490', '19786', '20799', '19557', '19451', '20802', '20798', '18867')
      THEN 'Você não atingiu o mínimo de posições necessário para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('10208', '18644', '19030', '17434', '15643', '15209', '16993', '18138', '18617', '17667', '13879', '19871', '15478', '12893', '20020', '20019')
      THEN 'Você não atingiu a acuracidade mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('13793', '20031', '20026', '19978')
      THEN 'Você não atingiu o mínimo de posições nem a acuracidade mínima necessários para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      -- [/AUTO:ge-obs]
      -- [/AUTO:ge-obs]

      -- 7. KPIs Setoriais — ATUALIZAR TODA SEMANA
      -- Mesma mecânica/ordem do bloco [AUTO:setoriais-mult] (ver comentário
      -- lá): Campinas especifico primeiro, depois a rede de segurança,
      -- depois FC1/FC2/FC3.
      -- [AUTO:setoriais-obs]
      WHEN AREA = 'CAMPINAS' THEN NULL
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1' AND TURNO IN ('MANHÃ', 'TARDE')
      THEN '-10% na Bonificação. O resultado do tempo de carregamento SMD piorou e ficou distante da meta. Mesmo desconsiderando as levas B alocadas, o indicador não atingiria o objetivo.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO IN ('MANHÃ', 'NOITE')
      THEN '-30% na Bonificação. O indicador de completos mercearia apresentou nova queda nesta semana, permanecendo distante da meta. A piora nas rupturas não consultadas e nas divergências de estoque continua impactando diretamente este resultado.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC1'
      THEN '-20% na Bonificação. O alto volume de itens não encontrados nas reposições de congelados e resfriados impactou negativamente o indicador de completos fresh e aumentou as divergências de estoque. A baixa performance na reposição de FLV também prejudicou o resultado.'
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND FC = 'FC2' AND TURNO = 'NOITE'
      THEN '-15% na Bonificação. O tempo de término da leva A piorou, impactando diretamente a chegada do caminhão. O tempo de carregamento dos SMDs pelo turno da noite ficou distante da meta.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'MANHÃ'
      THEN '-25% na Bonificação. O resultado do turno da manhã em completos Mercearia ficou distante da meta devido à oscilação na performance da reposição. A consistência na execução das listas precisa ser o foco para melhorarmos o indicador.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE'
      THEN '-25% na Bonificação. O indicador de completos mercearia do turno da TARDE ficou abaixo da meta, impactado pela oscilação no desempenho da reposição. Precisamos manter a exigência e a consistência na execução das listas para reverter o resultado.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE'
      THEN '-30% na Bonificação. O indicador de completos mercearia do turno da noite ficou distante da meta, impactado pela oscilação no desempenho da reposição. É necessário manter a consistência e a exigência na execução das listas para melhorar o resultado.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%'
      THEN '-20% na Bonificação. O resultado de completos fresh ficou abaixo da meta, impactando o indicador principal. É fundamental maior consistência na execução das listas de reposição para que a evolução do setor se reflita na melhora dos completos fresh.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
      THEN '-20% na Bonificação. A baixa eficiência na reposição FLV impactou negativamente o resultado de Completos Fresh, além de aumentar as rupturas e a quantidade de produtos sem mapeamento. É fundamental elevar a consistência na execução das listas e garantir o correto mapeamento e movimentação dos produtos.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3'
      THEN '-15% na Bonificação. Foram identificadas divergências no mapeamento de pedidos e erros na conferência ao longo da semana, impactando o indicador de divergência de estoque. É necessário maior rigor no acompanhamento dos processos e na regularização das pendências de devolução.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO IN ('MANHÃ', 'TARDE')
      THEN '-10% na Bonificação. Os turnos da manhã e tarde apresentaram erros na conferência e divergências no mapeamento, o que impactou negativamente o indicador de Divergência de Estoque. O percentual de pedidos mapeados e os completos mercearia também ficaram distantes da meta devido a estas falhas.'
      -- [/AUTO:setoriais-obs]

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
