-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
-- Última atualização: 08/10/2026
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
      WHEN MATRICULA IN ('13410', '19225', '19617') THEN 0.0
      -- [/AUTO:ind-zerados-mult]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-mult]
      WHEN MATRICULA IN ('16024', '16298', '7382') THEN 0.8
      -- [/AUTO:ind-parcial-mult]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-mult]
      WHEN MATRICULA IN ('17551', '10682', '18983', '17053', '14268') THEN 0.5
      WHEN MATRICULA IN ('20203', '20108', '19678', '19870') THEN 1.0
      WHEN MATRICULA IN ('20431', '20564', '20477') THEN 0.6
      WHEN MATRICULA IN ('18930', '20589', '17463', '20411', '11934', '17502', '19968', '20476', '18934', '6669', '17335', '20610', '10625', '7001', '19980', '20166') THEN 0.8
      WHEN MATRICULA IN ('20137', '20128', '18469', '20202', '20122') THEN 0.6
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
      WHEN MATRICULA IN ('13410', '19225', '19617') THEN 1.0
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
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' THEN 0.7
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND FC = 'FC2' AND TURNO = 'NOITE' THEN 0.85
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'MANHÃ' THEN 0.8
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE' THEN 0.8
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE' THEN 0.8
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%' THEN 0.8
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.75
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.9
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
      WHEN MATRICULA IN ('19225')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Bonificação zerada devido ao alto número de rupturas de itens com estoque mapeado, impactando diretamente o cliente, que deixa de receber produtos disponíveis em estoque.'
      WHEN MATRICULA IN ('19617')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Bonificação zerada devido ao alto número de rupturas de itens com estoque mapeado, impactando diretamente o cliente, que deixa de receber produtos disponíveis em estoque.'
      WHEN MATRICULA IN ('13410')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Durante a semana, constatamos que o fiscal não acompanhou nem executou alguns dos processos orientados pelo supervisor.'
      -- [/AUTO:ind-zerados-obs]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-obs]
      WHEN MATRICULA IN ('16024')
      THEN '0.2 na Bonificação. Operador de faltantes não realizou a alteração de volumes para incluir a segunda unidade, e seguiu com a inclusaõ de apenas 1 unidade. Cliente reportou . 1790720682_5602215_M'
      WHEN MATRICULA IN ('16298')
      THEN '0.2 na Bonificação. Ficou claro que a mesa fechou o volume faltante com espaço de apenas 1 galão de 5L Pedido:1790720682_5602215_M'
      WHEN MATRICULA IN ('7382')
      THEN '0.2 na Bonificação. O Fiscal não se atentou no erro do packer/hellper, e acabou localizando um produto trocado de forma incorreta. Pedido: 1791123474_5644060_P'
      -- [/AUTO:ind-parcial-obs]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-obs]
      WHEN MATRICULA IN ('17551', '10682', '18983', '17053', '14268')
      THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'
      WHEN MATRICULA IN ('20203', '20108', '19678', '19870')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Colaboradores reincidentes nos 20% Piores com maior taxa de erro no Picking.'
      WHEN MATRICULA IN ('20431', '20564', '20477')
      THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'
      WHEN MATRICULA IN ('18930', '20589', '17463', '20411', '11934', '17502', '19968', '20476', '18934', '6669', '17335', '20610', '10625', '7001', '19980', '20166')
      THEN '-20% na Bonificação. Você apresentou uma alta taxa de erros no Picking, que supera o limite aceitável. Essa performance impactou diretamente os indicadores da área e gerou mais retrabalho para outras áreas.'
      WHEN MATRICULA IN ('20137', '20128', '18469', '20202', '20122')
      THEN '-40% na Bonificação. Na última semana, você esteve entre os 20% dos colaboradores de outros setores que apresentaram as maiores taxas de erro ao serem alocados para o Picking. Independentemente da área de atuação, é indispensável manter a alta produtividade e qualidade.'
      -- [/AUTO:fiscais-picking-obs]

      -- GE: Inventário — ATUALIZAR TODA SEMANA
      -- [AUTO:ge-obs]
      WHEN MATRICULA IN ('5728', '18644', '14033', '17434', '13639', '15209', '15643', '16993', '18138', '18103', '16750', '19439', '18854', '20023', '20019')
      THEN 'Você não atingiu a acuracidade mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('10893', '7064', '7100', '12003', '17391', '4648', '16447', '13106', '19069', '19338', '19046', '17470', '16439', '17073', '13927', '15506', '19455', '19435', '19156', '19786', '19451')
      THEN 'Você não atingiu o mínimo de posições necessário para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('18986', '19030', '20111', '18939', '18437', '16902', '13793', '13879', '14855', '15478', '13869', '20020', '20004', '20031', '20026', '20029')
      THEN 'Você não atingiu o mínimo de posições nem a acuracidade mínima necessários para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('19490')
      THEN 'Você não pontuou pela atividade de inventário de Gestão de Estoque nesta semana, pois o tempo por contagem esteve acima do esperado. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      -- [/AUTO:ge-obs]
      -- [/AUTO:ge-obs]

      -- 7. KPIs Setoriais — ATUALIZAR TODA SEMANA
      -- Mesma mecânica/ordem do bloco [AUTO:setoriais-mult] (ver comentário
      -- lá): Campinas especifico primeiro, depois a rede de segurança,
      -- depois FC1/FC2/FC3.
      -- [AUTO:setoriais-obs]
      WHEN AREA = 'CAMPINAS' THEN NULL
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC1' AND TURNO IN ('MANHÃ', 'TARDE')
      THEN '-10% na Bonificação. O resultado do tempo de carregamento SMD ficou distante da meta. Mesmo desconsiderando as cargas de leva B alocadas, o indicador permaneceria abaixo do esperado.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1'
      THEN '-30% na Bonificação. O indicador de completos mercearia apresentou quedas recorrentes e segue distante da meta. A performance na reposição é crucial para reverter o resultado e o indicador de rupturas.'
      WHEN (SETOR_ORIGINAL LIKE '%PRÉ%EXPED%' OR SETOR_ORIGINAL LIKE '%PRE%EXPED%') AND FC = 'FC2' AND TURNO = 'NOITE'
      THEN '-15% na Bonificação. O tempo para o término da leva A do turno da noite foi o principal ponto de atenção da semana, impactado pelo aumento no tempo de chegada do caminhão em Campinas. O tempo de carregamento dos SMDs, HR e Fiorino também se mantiveram como pontos de atenção.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'MANHÃ'
      THEN '-20% na Bonificação. O KPI de completos mercearia do turno da manhã ficou distante da meta, impactado pela oscilação da reposição. É necessário manter a consistência na execução das listas para reverter o resultado.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE'
      THEN '-20% na Bonificação. O turno da TARDE teve um desempenho nos pedidos completos de mercearia distante da meta, com a reposição oscilando durante a semana. A execução das listas precisa de maior consistência para atingirmos o desempenho ideal.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE'
      THEN '-20% na Bonificação. O resultado de completos mercearia do turno da noite ficou abaixo da meta, impactado pela oscilação na reposição. O desempenho permanece distante do ideal, exigindo maior consistência e rigor na execução das listas.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%'
      THEN '-20% na Bonificação. A taxa de completos fresh ficou abaixo do esperado, impactada pelo resultado da reposição. Precisamos de mais consistência na execução das listas para garantir que a evolução da reposição se reflita no aumento da taxa de completos.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
      THEN '-25% na Bonificação. O indicador de completos fresh ficou distante da meta devido à baixa eficiência na execução das listas de reposição, resultando em um aumento dos itens não encontrados. É preciso elevar a consistência na movimentação dos produtos para garantir a acuracidade do estoque e melhorar os resultados.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC3'
      THEN '-10% na Bonificação. Foram identificados erros durante a conferência e divergências no mapeamento dos lotes, o que nos distanciou das metas de pedidos mapeados Fresh e de divergência de estoque. É fundamental maior atenção ao processo para reverter o resultado dos erros e das rupturas.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO IN ('MANHÃ', 'TARDE')
      THEN '-10% na Bonificação. Os turnos da manhã e tarde apresentaram erros na conferência e divergências no mapeamento, impactando o indicador de pedidos mapeados. Essas falhas também mantiveram distantes da meta os resultados de completos mercearia e de divergência de estoque.'
      -- [/AUTO:setoriais-obs]

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
