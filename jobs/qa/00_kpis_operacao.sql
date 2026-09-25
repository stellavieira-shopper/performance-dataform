-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
-- Última atualização: 24/09/2026
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
      -- [/AUTO:ind-zerados-mult]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-mult]
      -- [/AUTO:ind-parcial-mult]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-mult]
      WHEN MATRICULA IN ('17551', '19622', '10616', '19758', '18264', '19859', '19863') THEN 1.0
      WHEN MATRICULA IN ('19759', '19323', '19245', '19436', '19119') THEN 0.6
      WHEN MATRICULA IN ('11931', '19855', '19674') THEN 0.8
      WHEN MATRICULA IN ('8899', '10682', '17335', '13884', '14268', '14079', '11865', '16212', '15149', '16435', '14164') THEN 0.5
      WHEN MATRICULA IN ('19678', '19833') THEN 0.6
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
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO IN ('TARDE', 'NOITE') THEN 0.9
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO = 'MANHÃ' THEN 0.9
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'MANHÃ' THEN 0.8
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE' THEN 0.7
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE' THEN 0.6
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%' THEN 0.7
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.9
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO IN ('MANHÃ', 'TARDE') THEN 0.85
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.9
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE' THEN 0.9
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
      -- [/AUTO:ind-zerados-obs]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-obs]
      -- [/AUTO:ind-parcial-obs]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-obs]
      WHEN MATRICULA IN ('17551', '19622', '10616', '19758', '18264', '19859', '19863')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Colaboradores reincidentes nos 20% Piores com maior taxa de erro no Picking.'
      WHEN MATRICULA IN ('19759', '19323', '19245', '19436', '19119')
      THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'
      WHEN MATRICULA IN ('11931', '19855', '19674')
      THEN '-20% na Bonificação. Você apresentou uma alta taxa de erros no Picking, que supera o limite aceitável. Essa performance impactou diretamente os indicadores da área e gerou mais retrabalho para outras áreas.'
      WHEN MATRICULA IN ('8899', '10682', '17335', '13884', '14268', '14079', '11865', '16212', '15149', '16435', '14164')
      THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'
      WHEN MATRICULA IN ('19678', '19833')
      THEN '-40% na Bonificação. Na última semana, você esteve entre os 20% dos colaboradores de outros setores que apresentaram as maiores taxas de erro ao serem alocados para o Picking. Independentemente da área de atuação, é indispensável manter a alta produtividade e qualidade.'
      -- [/AUTO:fiscais-picking-obs]

      -- GE: Inventário — ATUALIZAR TODA SEMANA
      -- [AUTO:ge-obs]
      WHEN MATRICULA IN ('19439')
      THEN 'Você não atingiu o mínimo de posições nem a acuracidade mínima necessários para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('19175')
      THEN 'Você não atingiu o mínimo de posições necessário para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      WHEN MATRICULA IN ('19455', '19170')
      THEN 'Você não atingiu a acuracidade mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'
      -- [/AUTO:ge-obs]
      -- [/AUTO:ge-obs]

      -- 7. KPIs Setoriais — ATUALIZAR TODA SEMANA
      -- Mesma mecânica/ordem do bloco [AUTO:setoriais-mult] (ver comentário
      -- lá): Campinas especifico primeiro, depois a rede de segurança,
      -- depois FC1/FC2/FC3.
      -- [AUTO:setoriais-obs]
      WHEN AREA = 'CAMPINAS' THEN NULL
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO IN ('TARDE', 'NOITE')
      THEN '-10% na Bonificação. Os turnos da tarde e noite apresentaram uma piora no indicador de completos mercearia. A performance da reposição impactou negativamente o resultado.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' AND TURNO = 'MANHÃ'
      THEN '-10% na Bonificação. O turno da manhã apresentou uma baixa na eficiência de reposição, impactando negativamente o indicador de completos mercearia. É preciso atenção no processo para reverter o resultado.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'MANHÃ'
      THEN '-20% na Bonificação. O turno da manhã mantém boa regularidade na execução das atividades operacionais. No entanto, o indicador de completos mercearia segue distante da meta e precisa de maior atenção.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE'
      THEN '-30% na Bonificação. A baixa eficiência do turno da tarde na execução das atividades impactou negativamente os resultados de completos mercearia, rupturas e divergências de estoque. Além disso, o tempo de carregamento de SMD e o percentual de pedidos mapeados ficaram distantes da meta.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE'
      THEN '-40% na Bonificação. A baixa eficiência do turno da noite na reposição, evidenciada pela não conclusão de listas, impactou negativamente o resultado de completos mercearia. O indicador de divergências de estoque também permaneceu distante da meta.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%'
      THEN '-30% na Bonificação. Falhas no mapeamento dos produtos na reserva impactaram negativamente a divergência de estoque, as rupturas e o indicador de completos fresh. A disciplina no processo de endereçamento é crucial para reverter o impacto nesses indicadores e evitar faltantes nos pedidos.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
      THEN '-10% na Bonificação. As falhas operacionais na movimentação de produtos entre a reserva e a gôndola continuam impactando o indicador de completos fresh, que permanece abaixo da meta. Consequentemente, as rupturas por divergência de estoque também apresentaram resultado negativo.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO IN ('MANHÃ', 'TARDE')
      THEN '-15% na Bonificação. Erros operacionais na conferência e mapeamento impactaram o resultado de pedidos mapeados e aumentaram as divergências de estoque. Consequentemente, o indicador de completos mercearia ficou distante da meta e o de erros global piorou.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
      THEN '-10% na Bonificação. Erros operacionais na conferência e mapeamento impactaram negativamente o resultado de completos fresh e o percentual de pedidos mapeados. A falta de atenção nestas atividades também piorou os indicadores de divergência de estoque e rupturas.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE'
      THEN '-10% na Bonificação. Erros operacionais no mapeamento do turno da noite impactaram o resultado do percentual de pedidos mapeados. Este cenário contribuiu para um desempenho distante da meta nos indicadores de divergências de estoque e completos mercearia.'
      -- [/AUTO:setoriais-obs]

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
