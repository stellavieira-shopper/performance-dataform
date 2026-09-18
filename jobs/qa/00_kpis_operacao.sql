-- ██████████ SCRIPT FINAL CONSOLIDADO: KPIs OPERAÇÃO ██████████
-- Atualizar semanalmente após geração das mensagens FC (skill dashboard-fc-mensagens)
-- Última atualização: 17/09/2026
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
      WHEN MATRICULA IN ('11961', '14134', '18746') THEN 0.0
      -- [/AUTO:ind-zerados-mult]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-mult]
      WHEN MATRICULA IN ('10537') THEN 0.9
      -- [/AUTO:ind-parcial-mult]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-mult]
      WHEN MATRICULA IN ('19266', '18983', '13995', '13008', '19357', '18264') THEN 0.0
      WHEN MATRICULA IN ('19622', '17463', '19747', '19758', '19859', '19662', '19443') THEN 0.6
      WHEN MATRICULA IN ('17551', '15381', '9696', '15028', '10616', '17655', '10363', '16763', '17715') THEN 0.5
      WHEN MATRICULA IN ('11371', '17436', '19247', '7001', '17526', '19863', '19692', '10580') THEN 0.6
      WHEN MATRICULA IN ('4990', '17528', '17207', '17508', '15719', '19762', '18820', '15819') THEN 0.8
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
      WHEN MATRICULA IN ('11961', '14134', '18746') THEN 1.0
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
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1' THEN 0.8
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1' AND ATRIBUICAO_ORIGINAL LIKE '%MAPEAMENTO%' AND TURNO = 'TARDE' THEN 0.8
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2' AND TURNO IN ('MANHÃ', 'TARDE') THEN 0.9
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'MANHÃ' THEN 0.8
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE' THEN 0.65
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE' THEN 0.5
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%' THEN 0.5
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%FLV%' THEN 0.8
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3' THEN 0.9
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' THEN 0.9
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
      WHEN MATRICULA IN ('14134')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Substituição de SKU OVO CAIPIRA ORGÂNICO JUMBO RAIAR ORGÂNICOS - Mapeado em reserva Pedido:1789525967_5484583_P - SKU: CT199763 Evidência : https://drive.google.com/file/d/1KWmlDnsLuIrK7BwSzE0vd_sxlyuhvi8n/view?usp=drivesdk'
      WHEN MATRICULA IN ('11961')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Evidencias da CAIXA VAZIA enviada ao cliente   https://drive.google.com/drive/folders/1ELUVRfzT3x662ZXetB2G1WloI3uzLpNC?usp=drive_link'
      WHEN MATRICULA IN ('18746')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Executando atividade simultanea https://docs.google.com/spreadsheets/d/1AIZN92t5wZBCNBvTEbtZFkcyBGKkOf78s6UOstN-7JY/edit?gid=0#gid=0'
      -- [/AUTO:ind-zerados-obs]

      -- 5b. KPIs Individuais parciais — ATUALIZAR TODA SEMANA
      -- [AUTO:ind-parcial-obs]
      WHEN MATRICULA IN ('10537')
      THEN '0.1 na Bonificação. Fiscal não fez a exclusão da lista de reposição completa no horário combinado 19H, causando atraso na  execução da lista de reposição geral'
      -- [/AUTO:ind-parcial-obs]

      -- 6. Vistoria Picking + Fiscais de Picking individual — ATUALIZAR TODA SEMANA
      -- [AUTO:fiscais-picking-obs]
      WHEN MATRICULA IN ('19266', '18983', '13995', '13008', '19357', '18264')
      THEN 'VALOR DA BONIFICAÇÃO ZERADO. Colaboradores reincidentes nos 20% Piores com maior taxa de erro no Picking.'
      WHEN MATRICULA IN ('19622', '17463', '19747', '19758', '19859', '19662', '19443')
      THEN '-40% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada.'
      WHEN MATRICULA IN ('17551', '15381', '9696', '15028', '10616', '17655', '10363', '16763', '17715')
      THEN '-50% na Bonificação. Você está entre os 20% dos colaboradores de Picking que mais cometeu erros na última semana com uma taxa muito acima da esperada. (Inclui -10% de acréscimo por reincidência alternada nas listas de erro)'
      WHEN MATRICULA IN ('11371', '17436', '19247', '7001', '17526', '19863', '19692', '10580')
      THEN '-40% na Bonificação. Na última semana, você esteve entre os 20% dos colaboradores de outros setores que apresentaram as maiores taxas de erro ao serem alocados para o Picking. Independentemente da área de atuação, é indispensável manter a alta produtividade e qualidade.'
      WHEN MATRICULA IN ('4990', '17528', '17207', '17508', '15719', '19762', '18820', '15819')
      THEN '-20% na Bonificação. Você apresentou uma alta taxa de erros no Picking, que supera o limite aceitável. Essa performance impactou diretamente os indicadores da área e gerou mais retrabalho para outras áreas.'
      -- [/AUTO:fiscais-picking-obs]

      -- GE: Inventário — ATUALIZAR TODA SEMANA
      -- [AUTO:ge-obs]
     WHEN MATRICULA IN ('11145', '13232', '13106', '19069', '13793', '15259', '16436', '17320')
    THEN 'Você não atingiu o mínimo de posições nem a acuracidade mínima necessários para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

WHEN MATRICULA IN ('11080', '10919', '4648', '10537', '17771', '18939', '17470')
    THEN 'Você não atingiu o mínimo de posições necessário para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

WHEN MATRICULA IN ('18644', '14011', '15643', '15209', '16993', '18437', '18138', '13727', '16750', '17809', '13879', '15478', '14855', '17667')
    THEN 'Você não atingiu a acuracidade mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque.'

WHEN MATRICULA = '17511'
    THEN 'Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao baixo desempenho nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação.'

WHEN MATRICULA = '19407'
    THEN 'Você recebeu uma detratora pela atividade de reposição nesta semana devido ao baixo desempenho nas movimentações. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade.'

-- [/AUTO:ge-obs]
      -- [/AUTO:ge-obs]

      -- 7. KPIs Setoriais — ATUALIZAR TODA SEMANA
      -- Mesma mecânica/ordem do bloco [AUTO:setoriais-mult] (ver comentário
      -- lá): Campinas especifico primeiro, depois a rede de segurança,
      -- depois FC1/FC2/FC3.
      -- [AUTO:setoriais-obs]
      WHEN AREA = 'CAMPINAS' THEN NULL
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC1'
      THEN '-20% na Bonificação. Os recorrentes erros de itens não encontrados e a reposição em locais divergentes impactaram negativamente o indicador de completos mercearia. Consequentemente, o resultado de divergência de estoque ficou distante da meta.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'FRESH' AND FC = 'FC1' AND ATRIBUICAO_ORIGINAL LIKE '%MAPEAMENTO%' AND TURNO = 'TARDE'
      THEN '-20% na Bonificação. O turno da tarde não está realizando as baixas simultaneamente, impactando os indicadores de completos fresh e divergências de estoque. A prática de dar baixa apenas no final do turno é incorreta e prejudica a meta de pedidos mapeados.'
      WHEN SETOR_ORIGINAL IN ('EXPEDIÇÃO', 'EXPEDICAO') AND FC = 'FC2' AND TURNO IN ('MANHÃ', 'TARDE')
      THEN '-10% na Bonificação. O tempo de carregamento de SMD e Fiorino ficou distante da meta nesta semana. O percentual de pedidos mapeados também precisa de atenção para atingirmos o objetivo.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'MANHÃ'
      THEN '-20% na Bonificação. O turno da manhã mantém boa regularidade no término da leva A e no tempo de carregamento de SMD. No entanto, o resultado de completos mercearia segue distante da meta, exigindo maior atenção do time na reposição.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'TARDE'
      THEN '-35% na Bonificação. A baixa eficiência do turno da tarde impactou negativamente os resultados de completos mercearia e divergências de estoque. As rupturas não consultadas e o tempo de carregamento do SMD também ficaram distantes da meta.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'MERCEARIA' AND FC = 'FC3' AND TURNO = 'NOITE'
      THEN '-50% na Bonificação. A baixa eficiência do turno da noite na execução das atividades, com falhas recorrentes na conclusão de listas, deixou o indicador de completos mercearia distante da meta. A falta de reposição impacta diretamente o resultado do FC.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%CONGELADO%'
      THEN '-50% na Bonificação. Falhas no mapeamento de produtos na reserva impactaram negativamente o resultado de completos fresh e aumentaram as rupturas por divergência de estoque. A disciplina no endereçamento de todos os itens é fundamental para reverter o cenário e melhorar a performance.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3' AND ATRIBUICAO_ORIGINAL LIKE '%FLV%'
      THEN '-20% na Bonificação. As falhas operacionais na movimentação de produtos entre a reserva e a gôndola impactaram diretamente o resultado. Devido a isso, nosso indicador de completos fresh permaneceu distante da meta.'
      WHEN SETOR_ORIGINAL LIKE '%RECEBIMENTO%' AND AREA = 'MERCEARIA' AND FC = 'FC3'
      THEN '-10% na Bonificação. Os erros operacionais na conferência e mapeamento impactaram o indicador de pedidos mapeados e aumentaram a divergência de estoque. Consequentemente, o resultado de rupturas não consultadas e completos mercearia ficou distante da meta.'
      WHEN SETOR_ORIGINAL IN ('REPOSIÇÃO', 'REPOSICAO') AND AREA = 'FRESH' AND FC = 'FC3'
      THEN '-10% na Bonificação. Os erros operacionais na conferência e mapeamento impactaram negativamente os resultados de completos fresh e aumentaram as divergências de estoque. A performance de pedidos mapeados ficou distante da meta, contribuindo para o aumento de rupturas.'
      -- [/AUTO:setoriais-obs]

      ELSE NULL
    END AS OBSERVACAO_KPI,

    v_start_date AS data_inicio,
    v_end_date AS data_final

  FROM CalculoBase
  QUALIFY ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1;

END;
