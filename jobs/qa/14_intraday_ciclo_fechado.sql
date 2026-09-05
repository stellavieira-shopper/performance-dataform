-- ============================================================
-- 14 - Intraday do CICLO FECHADO (Totem + Intraday)
--
-- A Scheduled Query do BigQuery so processa o ciclo CORRENTE
-- (da ultima sexta ate hoje). Quando um ciclo fecha, a linha dele
-- congela e nenhuma rodada futura a atualiza. Se o extract_points
-- for reprocessado depois do fechamento, o Totem e o Intraday
-- continuam exibindo os numeros antigos.
--
-- Este job roda o MESMO MERGE apontado para o ultimo ciclo FECHADO.
-- A chave e (matricula, data_inicio_ciclo), entao ele atualiza as
-- linhas existentes sem duplicar, e zera as mensagens de IA para
-- serem regeradas no proximo acesso.
--
-- Para fixar um ciclo especifico, troque o DEFAULT de v_inicio por
-- uma data literal, ex: DECLARE v_inicio DATE DEFAULT DATE '2026-08-28';
-- O workflow tambem aceita o input data_inicio, que faz isso sozinho.
-- ============================================================

DECLARE v_inicio DATE DEFAULT DATE_SUB(
  DATE_SUB(CURRENT_DATE('America/Sao_Paulo'),
           INTERVAL MOD(EXTRACT(DAYOFWEEK FROM CURRENT_DATE('America/Sao_Paulo')) - 6 + 7, 7) DAY),
  INTERVAL 7 DAY);
DECLARE v_fim DATE DEFAULT DATE_ADD(v_inicio, INTERVAL 6 DAY);

-- ============================================================
-- Tabela_Intraday_Performance — BigQuery Scheduled Query
-- Roda 3x/dia: 06h30, 14h30 e 22h30 (horário SP)
-- Fontes:
--   pontos       → Ranking_Performance.performance_extract_points_table
--   ocorrências  → performance.performance_expected_points_daily_n2
--   colabs       → Ranking_Performance.Organograma  (Drive-linked)
-- ============================================================

MERGE `shopper-datalakehouse-qa.Ranking_Performance.Tabela_Intraday_Performance` T
USING (

  WITH
  org AS (
    SELECT DISTINCT
      CAST(MATRICULA AS STRING)            AS matricula,
      UPPER(TRIM(NOME))                    AS nome,
      UPPER(TRIM(FC))                      AS fc,
      UPPER(TRIM(COALESCE(SETOR, AREA)))   AS setor_principal,
      UPPER(TRIM(TURNO))                   AS turno_principal,
      UPPER(TRIM(ATRIBUICAO))              AS atribuicao_principal,
      UPPER(TRIM(CRACHA))                  AS cracha
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Organograma`
    WHERE MATRICULA IS NOT NULL
      AND UPPER(TRIM(COALESCE(SETOR, AREA))) NOT IN ('ENFERMARIA', 'COMPRAS EXTERNAS')
      AND NOT (
        (UPPER(TRIM(SETOR)) = 'MANUTENÇÃO' AND UPPER(TRIM(ATRIBUICAO)) = 'AUX. MANUTENÇÃO')
        OR (UPPER(TRIM(SETOR)) = 'PRÉ OPERAÇÃO' AND UPPER(TRIM(ATRIBUICAO)) IN ('AUXILIAR','IMPRESSÃO DE NOTA','INSUMOS'))
        OR (UPPER(TRIM(SETOR)) = 'RECEBIMENTO' AND UPPER(TRIM(ATRIBUICAO)) IN ('AUXILIAR NF','AUXILIAR NFE'))
        OR (UPPER(TRIM(SETOR)) IN ('PRÉ EXPEDIÇÃO','EXPEDIÇÃO') AND UPPER(TRIM(ATRIBUICAO)) IN ('AUXILIAR NF','AUXILIAR NFE','IMPRESSÃO DE NOTA','IMPRESSÃO DE ROMANEIO','IMPRESSÃO DE NOTAS'))
        OR (UPPER(TRIM(SETOR)) = 'BRINDE' AND UPPER(TRIM(ATRIBUICAO)) IN ('BRINDE','BODAS'))
        OR (UPPER(TRIM(SETOR)) = 'GESTÃO DE ESTOQUE' AND UPPER(TRIM(ATRIBUICAO)) IN ('GESTÃO DE ESTOQUE','INSUMOS','FALTANTES'))
        OR (UPPER(TRIM(SETOR)) = 'LOGISTICA' AND UPPER(TRIM(ATRIBUICAO)) IN ('IMPRESSÃO DE ROMANEIO','AUX. ROMANEIO'))
        OR (UPPER(TRIM(SETOR)) = 'OPERAÇÃO FRESH' AND UPPER(TRIM(ATRIBUICAO)) = 'INSUMOS')
        OR (UPPER(TRIM(SETOR)) = 'LIMPEZA' AND UPPER(TRIM(ATRIBUICAO)) = 'LIMPEZA')
        OR (UPPER(TRIM(SETOR)) = 'EXPEDIÇÃO CAMPINAS' AND UPPER(TRIM(ATRIBUICAO)) IN ('AUX. EXPEDIÇÃO CAMPINAS','FISCAL - CAMPINAS'))
        OR UPPER(TRIM(ATRIBUICAO)) IN ('RONDA/REPOSITOR FLV','PICADOS')
        OR (UPPER(TRIM(FC)) = 'FC2' AND UPPER(TRIM(ATRIBUICAO)) = 'INVENTÁRIO')
        OR (
          (UPPER(TRIM(ATRIBUICAO)) LIKE '%FISCAL%' OR UPPER(TRIM(ATRIBUICAO)) LIKE '%SUPERVISOR%')
          AND UPPER(TRIM(SETOR)) IN ('MANUTENÇÃO','PRÉ OPERAÇÃO','BRINDE','GESTÃO DE ESTOQUE','LOGISTICA','LIMPEZA')
          AND UPPER(TRIM(ATRIBUICAO)) NOT IN (
            'FISCAL - PERDAS MERCEARIA','FISCAL - PERDAS/DESFAZER PEDIDOS FRESH',
            'FISCAL - PERDAS','FISCAL - INVENTÁRIO','FISCAL PERDAS MERCEARIA',
            'FISCAL PERDAS/DESFAZER PEDIDOS FRESH','PERDAS FISCAL PERDAS','FISCAL INVENTÁRIO')
        )
      )
    QUALIFY ROW_NUMBER() OVER (PARTITION BY MATRICULA ORDER BY MATRICULA) = 1
  ),

  pontos_agg AS (
    SELECT
      CAST(registration_number AS STRING) AS matricula,
      metric_type, metric_description,
      SUM(pontos_ponderados) AS pts
    FROM `shopper-datalakehouse-qa.Ranking_Performance.performance_extract_points_table`
    WHERE reference_date >= v_inicio
      AND reference_date <= v_fim
      AND registration_number IS NOT NULL AND metric_type IS NOT NULL
    GROUP BY 1,2,3
  ),
  pontos_ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY matricula, metric_type ORDER BY pts DESC) AS rn
    FROM pontos_agg
  ),
  pontos_final AS (
    SELECT
      matricula,
      SUM(IF(metric_type='PROMOTORA', pts, 0))                            AS pontos_promotoras,
      SUM(IF(metric_type='DETRATORA', pts, 0))                            AS pontos_detratoras,
      SUM(pts)                                                             AS pontos_liquidos,
      MAX(IF(metric_type='PROMOTORA' AND rn=1, metric_description, NULL)) AS top_promotora_1,
      MAX(IF(metric_type='PROMOTORA' AND rn=1, pts, NULL))                AS top_promotora_1_pts,
      MAX(IF(metric_type='PROMOTORA' AND rn=2, metric_description, NULL)) AS top_promotora_2,
      MAX(IF(metric_type='PROMOTORA' AND rn=2, pts, NULL))                AS top_promotora_2_pts,
      MAX(IF(metric_type='PROMOTORA' AND rn=3, metric_description, NULL)) AS top_promotora_3,
      MAX(IF(metric_type='PROMOTORA' AND rn=3, pts, NULL))                AS top_promotora_3_pts,
      MAX(IF(metric_type='DETRATORA' AND rn=1, metric_description, NULL)) AS top_detratora_1,
      MAX(IF(metric_type='DETRATORA' AND rn=1, ABS(pts), NULL))           AS top_detratora_1_pts
    FROM pontos_ranked GROUP BY matricula
  ),
  dias_ativ AS (
    SELECT
      CAST(registration_number AS STRING) AS matricula,
      COUNT(DISTINCT reference_date) AS dias_com_atividade,
      MAX(reference_date)            AS ultima_ref_date
    FROM `shopper-datalakehouse-qa.Ranking_Performance.performance_extract_points_table`
    WHERE reference_date >= v_inicio
      AND reference_date <= v_fim
      AND registration_number IS NOT NULL
    GROUP BY 1
  ),
  ocorr AS (
    SELECT
      CAST(registration_number AS STRING) AS matricula,
      COUNTIF(absence IS NOT NULL) AS qtd_faltas,
      STRING_AGG(IF(absence IS NOT NULL, FORMAT_DATE('%d/%m', reference_date), NULL), ' | ' ORDER BY reference_date) AS lista_faltas,
      COUNTIF(medical_certificate IS NOT NULL) AS qtd_atestados,
      STRING_AGG(IF(medical_certificate IS NOT NULL, FORMAT_DATE('%d/%m', reference_date), NULL), ' | ' ORDER BY reference_date) AS lista_atestados,
      COUNTIF(delay IS NOT NULL AND CAST(delay AS STRING) > '00:10:00') AS qtd_atrasos,
      STRING_AGG(IF(delay IS NOT NULL AND CAST(delay AS STRING) > '00:10:00', CONCAT(FORMAT_DATE('%d/%m', reference_date), ' (', SUBSTR(CAST(delay AS STRING),1,5), ')'), NULL), ' | ' ORDER BY reference_date) AS lista_atrasos,
      COUNTIF(hours_declaration IS NOT NULL AND CAST(hours_declaration AS STRING) > '00:00:00') AS qtd_declaracoes,
      STRING_AGG(IF(hours_declaration IS NOT NULL AND CAST(hours_declaration AS STRING) > '00:00:00', CONCAT(FORMAT_DATE('%d/%m', reference_date), ' (', SUBSTR(CAST(hours_declaration AS STRING),1,5), ')'), NULL), ' | ' ORDER BY reference_date) AS lista_declaracoes,
      COUNTIF(vacation IS NOT NULL) AS qtd_ferias,
      STRING_AGG(IF(vacation IS NOT NULL, FORMAT_DATE('%d/%m', reference_date), NULL), ' | ' ORDER BY reference_date) AS lista_ferias
    FROM `shopper-datalakehouse-qa.performance.performance_expected_points_daily_n2`
    WHERE reference_date >= v_inicio
      AND reference_date <= v_fim
      AND registration_number IS NOT NULL
    GROUP BY 1
  )

  SELECT
    o.matricula, o.nome, o.fc, o.setor_principal, o.turno_principal,
    o.atribuicao_principal, o.cracha,
    v_inicio AS data_inicio_ciclo,
    COALESCE(p.pontos_promotoras, 0)                             AS pontos_promotoras,
    COALESCE(p.pontos_detratoras, 0)                             AS pontos_detratoras,
    COALESCE(p.pontos_liquidos, 0)                               AS pontos_liquidos,
    ROUND(COALESCE(p.pontos_liquidos, 0) / 1000000.0 * 100, 2)  AS pct_meta,
    GREATEST(0, 1000000 - COALESCE(p.pontos_liquidos, 0))       AS falta_para_meta,
    p.top_promotora_1, p.top_promotora_1_pts,
    p.top_promotora_2, p.top_promotora_2_pts,
    p.top_promotora_3, p.top_promotora_3_pts,
    p.top_detratora_1, p.top_detratora_1_pts,
    COALESCE(oc.qtd_faltas, 0)       AS qtd_faltas,      oc.lista_faltas,
    COALESCE(oc.qtd_atestados, 0)    AS qtd_atestados,   oc.lista_atestados,
    COALESCE(oc.qtd_atrasos, 0)      AS qtd_atrasos,     oc.lista_atrasos,
    COALESCE(oc.qtd_declaracoes, 0)  AS qtd_declaracoes, oc.lista_declaracoes,
    COALESCE(oc.qtd_ferias, 0)       AS qtd_ferias,      oc.lista_ferias,
    COALESCE(d.dias_com_atividade, 0) AS dias_com_atividade,
    d.ultima_ref_date,
    CURRENT_DATETIME('America/Sao_Paulo') AS updated_at
  FROM org o
  LEFT JOIN pontos_final p ON o.matricula = p.matricula
  LEFT JOIN dias_ativ d    ON o.matricula = d.matricula
  LEFT JOIN ocorr oc       ON o.matricula = oc.matricula

) S
ON T.matricula = S.matricula AND T.data_inicio_ciclo = S.data_inicio_ciclo

WHEN MATCHED THEN UPDATE SET
  nome=S.nome, fc=S.fc, setor_principal=S.setor_principal,
  turno_principal=S.turno_principal, atribuicao_principal=S.atribuicao_principal,
  cracha=S.cracha,
  pontos_promotoras=S.pontos_promotoras, pontos_detratoras=S.pontos_detratoras,
  pontos_liquidos=S.pontos_liquidos, pct_meta=S.pct_meta, falta_para_meta=S.falta_para_meta,
  top_promotora_1=S.top_promotora_1, top_promotora_1_pts=S.top_promotora_1_pts,
  top_promotora_2=S.top_promotora_2, top_promotora_2_pts=S.top_promotora_2_pts,
  top_promotora_3=S.top_promotora_3, top_promotora_3_pts=S.top_promotora_3_pts,
  top_detratora_1=S.top_detratora_1, top_detratora_1_pts=S.top_detratora_1_pts,
  qtd_faltas=S.qtd_faltas, lista_faltas=S.lista_faltas,
  qtd_atestados=S.qtd_atestados, lista_atestados=S.lista_atestados,
  qtd_atrasos=S.qtd_atrasos, lista_atrasos=S.lista_atrasos,
  qtd_declaracoes=S.qtd_declaracoes, lista_declaracoes=S.lista_declaracoes,
  qtd_ferias=S.qtd_ferias, lista_ferias=S.lista_ferias,
  dias_com_atividade=S.dias_com_atividade, ultima_ref_date=S.ultima_ref_date,
  updated_at=S.updated_at,
  -- Limpa mensagens IA para regeneração na próxima consulta do totem
  mensagem_ia_resumo=NULL, mensagem_ia_detalhe=NULL, mensagem_ia_gerado_em=NULL

WHEN NOT MATCHED THEN INSERT (
  matricula, nome, fc, setor_principal, turno_principal, atribuicao_principal, cracha,
  data_inicio_ciclo, pontos_promotoras, pontos_detratoras, pontos_liquidos, pct_meta, falta_para_meta,
  top_promotora_1, top_promotora_1_pts, top_promotora_2, top_promotora_2_pts,
  top_promotora_3, top_promotora_3_pts, top_detratora_1, top_detratora_1_pts,
  qtd_faltas, lista_faltas, qtd_atestados, lista_atestados,
  qtd_atrasos, lista_atrasos, qtd_declaracoes, lista_declaracoes,
  qtd_ferias, lista_ferias, dias_com_atividade, ultima_ref_date, updated_at
)
VALUES (
  S.matricula, S.nome, S.fc, S.setor_principal, S.turno_principal, S.atribuicao_principal, S.cracha,
  S.data_inicio_ciclo, S.pontos_promotoras, S.pontos_detratoras, S.pontos_liquidos, S.pct_meta, S.falta_para_meta,
  S.top_promotora_1, S.top_promotora_1_pts, S.top_promotora_2, S.top_promotora_2_pts,
  S.top_promotora_3, S.top_promotora_3_pts, S.top_detratora_1, S.top_detratora_1_pts,
  S.qtd_faltas, S.lista_faltas, S.qtd_atestados, S.lista_atestados,
  S.qtd_atrasos, S.lista_atrasos, S.qtd_declaracoes, S.lista_declaracoes,
  S.qtd_ferias, S.lista_ferias, S.dias_com_atividade, S.ultima_ref_date, S.updated_at
);
