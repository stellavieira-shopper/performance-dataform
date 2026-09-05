DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.performance_extract_points_table`
WHERE reference_date >= DATE_SUB(CURRENT_DATE('America/Sao_Paulo'), INTERVAL 8 DAY);

INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.performance_extract_points_table`

WITH base AS (
  SELECT
    GENERATE_UUID() AS row_id,
    u.registration_number,
    u.user_name,
    COALESCE(
      SAFE_CAST(rm.start_timestamp AS TIMESTAMP),
      SAFE.PARSE_TIMESTAMP('%Y/%m/%d %H:%M:%S', rm.start_timestamp),
      SAFE.PARSE_TIMESTAMP('%a %b %d %Y %H:%M:%S GMT%z', REGEXP_REPLACE(rm.start_timestamp, r' \([^)]*\)$', ''))
    ) AS start_ts,
    COALESCE(
      SAFE_CAST(rm.end_timestamp AS TIMESTAMP),
      SAFE.PARSE_TIMESTAMP('%Y/%m/%d %H:%M:%S', rm.end_timestamp),
      SAFE.PARSE_TIMESTAMP('%a %b %d %Y %H:%M:%S GMT%z', REGEXP_REPLACE(rm.end_timestamp, r' \([^)]*\)$', ''))
    ) AS end_ts,
    rm.source_system, pm.metric_type, pm.metric_code,
    CASE WHEN rm.metric_code = 'STOCK_RECEIVEMENT'
      THEN SAFE_CAST(JSON_VALUE(rm.details, '$.total_items_qty') AS FLOAT64)
      ELSE CAST(rm.value AS FLOAT64) END AS qty_raw,
    JSON_VALUE(rm.details, '$.order_code') AS order_code,
    SAFE_CAST(JSON_VALUE(rm.details, '$.sku_id') AS INT64) AS sku_id,
    JSON_VALUE(rm.details, '$.restock_list_level') AS restock_list_level,
    JSON_VALUE(rm.details, '$.restock_list_type') AS restock_list_type,
    JSON_VALUE(rm.details, '$.receivement_category') AS receivement_category,
    SAFE_CAST(JSON_VALUE(rm.details, '$.is_receivement_fresh') AS BOOL) AS is_receivement_fresh,
    JSON_VALUE(rm.details, '$.suggested_storage_receivement') AS suggested_storage_receivement,
    JSON_VALUE(rm.details, '$.movement_type') AS movement_type,
    CASE WHEN rm.metric_code = 'STOCK_RECEIVEMENT' THEN JSON_VALUE(rm.details, '$.batch_id') ELSE NULL END AS batch_id_raw,
    prod.sku_code AS product_code,
    p.is_same_day, p.sales_channel_id AS canal_venda, p.pack_mode,
    CASE
      WHEN rm.metric_code IN ('MOVEMENT_PICKUP', 'MOVEMENT_RESTOCK') THEN
        CASE
          WHEN JSON_VALUE(rm.details, '$.restock_list_type') = 'Reposição - Mercearia'
            THEN CONCAT('REPOSIÇÃO MERCEARIA: ', UPPER(JSON_VALUE(rm.details, '$.restock_list_level')))
          WHEN JSON_VALUE(rm.details, '$.restock_list_type') IN ('Retorno Picking Secos', 'Picking Secos') THEN 'REPOSIÇÃO PICKING SECOS'
          WHEN JSON_VALUE(rm.details, '$.restock_list_type') IN ('Check-in - Mercearia', 'Check-in - Fresh') THEN 'REPOSIÇÃO CHECKIN'
          WHEN JSON_VALUE(rm.details, '$.restock_list_type') = 'Transferência' THEN 'REPOSIÇÃO TRANSFERÊNCIA'
          WHEN JSON_VALUE(rm.details, '$.restock_list_type') = 'Reposição - Fresh' THEN 'REPOSIÇÃO FRESH'
          ELSE 'REPOSIÇÃO'
        END
      WHEN rm.metric_code IN ('MOVEMENT_PK', 'MOVEMENT_TRANSFER') THEN
        CASE WHEN JSON_VALUE(rm.details, '$.movement_type') IS NULL THEN 'REPOSIÇÃO TRANSFERÊNCIA RECEBIDA' ELSE 'REPOSIÇÃO PK' END
      WHEN pm.metric_description = 'SEGUNDA CONFERENCIA FRESCOS'   THEN 'REBIPAGEM FRESH'
      WHEN pm.metric_description = 'SEGUNDA CONFERENCIA MERCEARIA' THEN 'REBIPAGEM MERCEARIA'
      ELSE pm.metric_description
    END AS metric_description,
    SAFE_CAST(pm.score_factor AS FLOAT64) AS score_factor,
    CASE
      WHEN rm.metric_code LIKE '%PICKING%' THEN
        ARRAY(SELECT SAFE_CAST(JSON_VALUE(item, '$.sku_id') AS INT64) FROM UNNEST(JSON_QUERY_ARRAY(rm.details, '$.order_items')) AS item WHERE JSON_VALUE(item, '$.sku_id') IS NOT NULL)
      WHEN rm.metric_code LIKE '%CHECK%' THEN
        ARRAY(SELECT SAFE_CAST(JSON_VALUE(item, '$.model_id') AS INT64) FROM UNNEST(JSON_QUERY_ARRAY(rm.details, '$.order_items')) AS item WHERE JSON_VALUE(item, '$.model_id') IS NOT NULL)
      WHEN rm.metric_code = 'STOCK_FRACTION' THEN
        IF(JSON_VALUE(rm.details, '$.sku_id') IS NOT NULL, [SAFE_CAST(JSON_VALUE(rm.details, '$.sku_id') AS INT64)], CAST([] AS ARRAY<INT64>))
      WHEN rm.metric_code = 'INCLUDED_ITEMS' THEN
        ARRAY(SELECT SAFE_CAST(JSON_VALUE(item, '$.sku_id') AS INT64) FROM UNNEST(JSON_QUERY_ARRAY(rm.details, '$.order_items')) AS item WHERE JSON_VALUE(item, '$.sku_id') IS NOT NULL)
      ELSE CAST([] AS ARRAY<INT64>)
    END AS sku_ids
  FROM `shopper-datalakehouse-prod.performance.raw_measures_n2` AS rm
  INNER JOIN `shopper-datalakehouse-prod.performance.performance_metrics_n2` AS pm ON pm.metric_code = rm.metric_code
  INNER JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` AS u ON u.uuid = rm.operator_uuid
  LEFT JOIN `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_n2` AS p ON p.order_code = JSON_VALUE(rm.details, '$.order_code')
  LEFT JOIN `shopper-datalakehouse-prod.shared.purchase_automation_produtos_n3` AS prod ON prod.sku_id = SAFE_CAST(JSON_VALUE(rm.details, '$.sku_id') AS INT64)
  WHERE COALESCE(
      SAFE_CAST(rm.start_timestamp AS TIMESTAMP),
      SAFE.PARSE_TIMESTAMP('%Y/%m/%d %H:%M:%S', rm.start_timestamp),
      SAFE.PARSE_TIMESTAMP('%a %b %d %Y %H:%M:%S GMT%z', REGEXP_REPLACE(rm.start_timestamp, r' \([^)]*\)$', ''))
    ) >= TIMESTAMP(DATE_TRUNC(DATE_SUB(CURRENT_DATE('America/Sao_Paulo'), INTERVAL 1 MONTH), MONTH), 'America/Sao_Paulo')
),

base2 AS (
  SELECT b.*,
    DATETIME(b.start_ts) AS activity_start,
    DATETIME(b.end_ts)   AS activity_end,
    TIMESTAMP_DIFF(b.end_ts, b.start_ts, SECOND) / 3600.0 AS activity_worked_hours,
    DATE(CASE
      WHEN EXTRACT(HOUR FROM DATETIME(b.start_ts)) < 6
        THEN DATETIME_SUB(DATETIME(b.start_ts), INTERVAL 1 DAY)
      ELSE DATETIME(b.start_ts)
    END) AS reference_date
  FROM base b WHERE b.start_ts IS NOT NULL AND b.end_ts IS NOT NULL
),

calc_score AS (
  SELECT b.*, m.factor AS modifier_factor, cwf.score_factor AS cwf_score_factor,
    CASE
      WHEN b.metric_code IN ('MOVEMENT_PICKUP','MOVEMENT_RESTOCK') THEN
        LEAST(2.0, SAFE_DIVIDE(b.qty_raw, COALESCE(med_repos.media_sem_outliers,1.0))
          * CASE WHEN cx.caixaria IS NULL THEN 1.0 WHEN b.qty_raw=cx.caixaria THEN 1.5
              ELSE GREATEST(1.0,1.5-(0.5*SAFE_DIVIDE(ABS(b.qty_raw-cx.caixaria),cx.caixaria))) END)
      WHEN b.metric_code = 'STOCK_RECEIVEMENT' THEN
        LEAST(2.0, SAFE_DIVIDE(b.qty_raw, COALESCE(med_receb.media_sem_outliers,1.0))
          * CASE WHEN cx.caixaria IS NULL THEN 1.0 WHEN b.qty_raw=cx.caixaria THEN 1.5
              ELSE GREATEST(1.0,1.5-(0.5*SAFE_DIVIDE(ABS(b.qty_raw-cx.caixaria),cx.caixaria))) END)
      WHEN b.metric_code IN ('MOVEMENT_PK','MOVEMENT_TRANSFER') THEN
        LEAST(2.0, SAFE_DIVIDE(b.qty_raw, COALESCE(med_pk.media_sem_outliers,1.0))
          * CASE WHEN cx.caixaria IS NULL THEN 1.0 WHEN b.qty_raw=cx.caixaria THEN 1.5
              ELSE GREATEST(1.0,1.5-(0.5*SAFE_DIVIDE(ABS(b.qty_raw-cx.caixaria),cx.caixaria))) END)
      ELSE NULL
    END AS score_movimentacao
  FROM base2 AS b
  LEFT JOIN `shopper-datalakehouse-prod.performance.modifiers_picking_pack` AS m ON m.metric_code=b.metric_code AND b.qty_raw BETWEEN m.start_range_qty AND m.end_range_qty
  LEFT JOIN `shopper-datalakehouse-prod.performance.curated_weight_fractionation` AS cwf ON cwf.product_code=b.product_code
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.curated_movement_media` AS med_repos ON med_repos.sku_id=b.sku_id AND med_repos.movement_group='REPOSICAO' AND med_repos.restock_list_level=b.restock_list_level AND med_repos.restock_list_type=b.restock_list_type AND b.metric_code IN ('MOVEMENT_PICKUP','MOVEMENT_RESTOCK')
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.curated_movement_media` AS med_receb ON med_receb.sku_id=b.sku_id AND med_receb.movement_group='RECEBIMENTO' AND med_receb.receivement_category=b.receivement_category AND med_receb.is_receivement_fresh=b.is_receivement_fresh AND med_receb.suggested_storage_receivement=b.suggested_storage_receivement AND b.metric_code='STOCK_RECEIVEMENT'
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.curated_movement_media` AS med_pk ON med_pk.sku_id=b.sku_id AND med_pk.movement_group='PK' AND med_pk.movement_type IS NOT DISTINCT FROM b.movement_type AND b.metric_code IN ('MOVEMENT_PK','MOVEMENT_TRANSFER')
  LEFT JOIN `shopper-datalakehouse-qa.Ranking_Performance.curated_caixaria` AS cx ON cx.sku_id=b.sku_id AND b.metric_code IN ('MOVEMENT_PICKUP','MOVEMENT_RESTOCK','STOCK_RECEIVEMENT','MOVEMENT_PK','MOVEMENT_TRANSFER')
  WHERE b.metric_code NOT IN ('MOVEMENT_PICKUP','MOVEMENT_RESTOCK','STOCK_RECEIVEMENT')
    AND b.metric_description NOT IN (
      'VOLUMES EXPEDIDOS',
      'ITENS NÃO PICKADOS EM FRESH MAS COM ESTOQUE POSITIVO'
    )
    AND NOT (CAST(b.is_same_day AS BOOL) IS TRUE AND b.metric_description IN (
      'ITENS NÃO PICKADOS EM MERCEARIA',
      'ITENS NÃO PICKADOS EM FRESH',
      'ITENS NÃO PICKADOS EM MERCEARIA MAS COM ESTOQUE POSITIVO'
    ))
    AND NOT (COALESCE(LOWER(TRIM(b.pack_mode)), '') = 'express' AND b.metric_type = 'DETRATORA' AND UPPER(TRIM(b.metric_description)) LIKE '%NÃO CONFERIDO%')
    AND NOT (
      b.order_code IS NOT NULL
      AND LOWER(b.order_code) LIKE 'mk%'
      AND b.qty_raw > 10
      AND b.metric_type = 'DETRATORA'
      AND b.metric_description IN (
        'ITENS NÃO PICKADOS EM MERCEARIA',
        'ITENS NÃO PICKADOS EM FRESH'
      )
    )
    AND NOT (
      b.order_code IS NOT NULL
      AND LOWER(b.order_code) LIKE 'mk%'
      AND b.metric_description IN (
        'ITENS CONFERIDOS MERCEARIA EXT',
        'ITENS CONFERIDOS FRESH EXT'
      )
    )
    AND NOT (
      b.metric_description = 'ITENS INCLUIDOS'
      AND b.qty_raw > 100
    )
  QUALIFY ROW_NUMBER() OVER (PARTITION BY b.row_id ORDER BY (m.end_range_qty-m.start_range_qty) ASC, m.start_range_qty ASC) = 1
),

calc AS (
  SELECT s.registration_number, s.user_name, s.activity_start, s.activity_end, s.source_system, s.metric_type,
    CASE WHEN UPPER(TRIM(s.metric_description)) LIKE '%AUDITORIA%' THEN 1.0 WHEN s.metric_code IN ('MOVEMENT_PICKUP','MOVEMENT_RESTOCK','STOCK_RECEIVEMENT','MOVEMENT_PK','MOVEMENT_TRANSFER') THEN s.score_movimentacao ELSE s.qty_raw END AS qty,
    s.order_code, s.sku_id, CAST(s.is_same_day AS BOOL) AS is_same_day, s.canal_venda, s.metric_description,
    s.restock_list_level, s.restock_list_type, s.receivement_category, s.is_receivement_fresh, s.suggested_storage_receivement, s.movement_type, s.score_movimentacao,
    CASE WHEN UPPER(TRIM(s.metric_description)) LIKE '%AUDITORIA%' THEN 1.0 WHEN s.metric_code='STOCK_FRACTION' THEN s.qty_raw*COALESCE(s.cwf_score_factor,1.0)*s.score_factor WHEN s.metric_code IN ('MOVEMENT_PICKUP','MOVEMENT_RESTOCK','STOCK_RECEIVEMENT','MOVEMENT_PK','MOVEMENT_TRANSFER') THEN s.score_movimentacao*s.score_factor ELSE COALESCE(s.modifier_factor,1)*s.qty_raw*s.score_factor END AS points,
    s.activity_worked_hours, s.reference_date, COALESCE(s.batch_id_raw, CAST(NULL AS STRING)) AS batch_id,
    s.pack_mode, s.sku_ids
  FROM calc_score AS s
),

espelho AS (
  SELECT
    CAST(pv.registration_number   AS INT64)    AS registration_number,
    CAST(u.user_name              AS STRING)   AS user_name,
    CAST(pv.activity_start        AS DATETIME) AS activity_start,
    CAST(pv.activity_end          AS DATETIME) AS activity_end,
    CAST(pv.source_system         AS STRING)   AS source_system,
    CAST(pv.metric_type           AS STRING)   AS metric_type,
    CAST(pv.qty                   AS FLOAT64)  AS qty,
    CAST(NULL AS STRING)                       AS order_code,
    CAST(NULL AS INT64)                        AS sku_id,
    CAST(NULL AS BOOL)                         AS is_same_day,
    CAST(NULL AS INT64)                        AS canal_venda,
    CAST(pv.metric_description    AS STRING)   AS metric_description,
    CAST(NULL AS STRING)                       AS restock_list_level,
    CAST(NULL AS STRING)                       AS restock_list_type,
    CAST(NULL AS STRING)                       AS receivement_category,
    CAST(NULL AS BOOL)                         AS is_receivement_fresh,
    CAST(NULL AS STRING)                       AS suggested_storage_receivement,
    CAST(NULL AS STRING)                       AS movement_type,
    CAST(NULL AS FLOAT64)                      AS score_movimentacao,
    CAST(pv.points                AS FLOAT64)  AS points,
    CAST(pv.activity_worked_hours AS FLOAT64)  AS activity_worked_hours,
    CAST(pv.reference_date        AS DATE)     AS reference_date,
    CAST(NULL AS STRING)                       AS batch_id,
    CAST([] AS ARRAY<INT64>)                   AS sku_ids
  FROM `shopper-datalakehouse-prod.performance.performance_extract_points_n2` pv
  LEFT JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` u ON u.uuid = pv.employee_uuid
  WHERE pv.metric_description IN ('INICIO DO EXPEDIENTE','ENTRADA PARA INTERVALO','VOLTA DO INTERVALO','FIM DO EXPEDIENTE')
),

expedicao AS (
  SELECT
    CAST(ex.registration_number AS INT64),
    CAST(ex.user_name           AS STRING),
    CAST(ex.activity_start      AS DATETIME),
    CAST(ex.activity_end        AS DATETIME),
    'EXPEDICAO_TABLE',
    CAST(ex.metric_type         AS STRING),
    CAST(ex.qty                 AS FLOAT64),
    CAST(NULL AS STRING), CAST(NULL AS INT64), CAST(NULL AS BOOL), CAST(NULL AS INT64),
    CAST(ex.metric_description  AS STRING),
    CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS BOOL),
    CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS FLOAT64),
    CAST(ex.qty AS FLOAT64) * 1.0,
    CAST(NULL AS FLOAT64),
    CAST(ex.reference_date      AS DATE),
    CAST(NULL AS STRING),
    CAST([] AS ARRAY<INT64>)
  FROM `shopper-datalakehouse-qa.Ranking_Performance.vw_expedicao_curated` AS ex
  WHERE ex.reference_date >= DATE_SUB(CURRENT_DATE('America/Sao_Paulo'), INTERVAL 15 DAY)
),

pre_expedicao AS (
  SELECT
    CAST(pe.registration_number AS INT64),
    CAST(pe.user_name           AS STRING),
    CAST(pe.activity_start      AS DATETIME),
    CAST(pe.activity_end        AS DATETIME),
    'PRE_EXPEDICAO_TABLE',
    CAST(pe.metric_type         AS STRING),
    CAST(pe.qty                 AS FLOAT64),
    CAST(NULL AS STRING), CAST(NULL AS INT64), CAST(NULL AS BOOL), CAST(NULL AS INT64),
    CAST(pe.metric_description  AS STRING),
    CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS BOOL),
    CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS FLOAT64),
    CAST(pe.qty AS FLOAT64) * 1.0,
    CAST(NULL AS FLOAT64),
    CAST(pe.reference_date      AS DATE),
    CAST(NULL AS STRING),
    CAST([] AS ARRAY<INT64>)
  FROM `shopper-datalakehouse-qa.Ranking_Performance.vw_pre_expedicao_curated` AS pe
  WHERE pe.reference_date >= DATE_SUB(CURRENT_DATE('America/Sao_Paulo'), INTERVAL 15 DAY)
),

perdas AS (
  SELECT SAFE_CAST(pr.Matricula AS INT64), CAST(u.user_name AS STRING), CAST(NULL AS DATETIME), CAST(NULL AS DATETIME), 'PERFORMANCE_PERDAS_TABLE', UPPER(TRIM(pr.Metric_Type)), CAST(ABS(SAFE_CAST(pr.Value AS FLOAT64)) AS FLOAT64), CAST(NULL AS STRING), CAST(NULL AS INT64), CAST(NULL AS BOOL), CAST(NULL AS INT64), TRIM(pr.Descricao_Atividade), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS BOOL), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS FLOAT64), CAST(ABS(SAFE_CAST(pr.Value AS FLOAT64)) AS FLOAT64)*1.0, CAST(NULL AS FLOAT64), CAST(pr.Data AS DATE), CAST(NULL AS STRING), CAST([] AS ARRAY<INT64>)
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Perdas` AS pr
  LEFT JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` AS u ON u.registration_number=SAFE_CAST(pr.Matricula AS INT64)
  WHERE pr.Matricula IS NOT NULL AND pr.Data IS NOT NULL
),

inventario AS (
  SELECT
    SAFE_CAST(inv.cod_matricula AS INT64), CAST(u.user_name AS STRING),
    CAST(NULL AS DATETIME), CAST(NULL AS DATETIME),
    'DADOS_INVENTARIO_TABLE', UPPER(TRIM(inv.metric_type)),
    CAST(ABS(SAFE_CAST(inv.qtd_inventario AS FLOAT64)) AS FLOAT64),
    CAST(NULL AS STRING), CAST(NULL AS INT64), CAST(NULL AS BOOL), CAST(NULL AS INT64),
    TRIM(inv.metric_description),
    CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS BOOL),
    CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS FLOAT64),
    CAST(ABS(SAFE_CAST(inv.qtd_inventario AS FLOAT64)) AS FLOAT64)*1.0,
    CAST(NULL AS FLOAT64), CAST(inv.Data AS DATE), CAST(NULL AS STRING), CAST([] AS ARRAY<INT64>)
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Dados_Inventario` AS inv
  LEFT JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` AS u ON u.registration_number=SAFE_CAST(inv.cod_matricula AS INT64)
  WHERE inv.cod_matricula IS NOT NULL AND inv.Data IS NOT NULL
),

novo_inventario AS (
  SELECT
    SAFE_CAST(inv.MATRICULA AS INT64) AS registration_number,
    CAST(inv.NOME AS STRING) AS user_name,
    CAST(NULL AS DATETIME) AS activity_start,
    CAST(NULL AS DATETIME) AS activity_end,
    'INVENTARIO_NOVO' AS source_system,
    CASE
      WHEN UPPER(TRIM(inv.DESCRICAO)) LIKE 'ASSERTIVIDADE DE ENDEREÇOS%' THEN 'PROMOTORA'
      WHEN UPPER(TRIM(inv.DESCRICAO)) LIKE 'ENDEREÇOS COM DIVERGÊNCIA%' THEN 'DETRATORA'
      ELSE 'INDEFINIDA'
    END AS metric_type,
    CAST(inv.QUANTIDADE AS FLOAT64) AS qty,
    CAST(NULL AS STRING) AS order_code,
    CAST(NULL AS INT64) AS sku_id,
    CAST(NULL AS BOOL) AS is_same_day,
    CAST(NULL AS INT64) AS canal_venda,
    CAST(inv.DESCRICAO AS STRING) AS metric_description,
    CAST(NULL AS STRING) AS restock_list_level,
    CAST(NULL AS STRING) AS restock_list_type,
    CAST(NULL AS STRING) AS receivement_category,
    CAST(NULL AS BOOL) AS is_receivement_fresh,
    CAST(NULL AS STRING) AS suggested_storage_receivement,
    CAST(NULL AS STRING) AS movement_type,
    CAST(NULL AS FLOAT64) AS score_movimentacao,
    SAFE_CAST(
      REPLACE(
        REGEXP_REPLACE(CAST(inv.PONTOS AS STRING), r'[^\d,-]', ''),
        ',', '.'
      ) AS FLOAT64
    ) AS points,
    CAST(NULL AS FLOAT64) AS activity_worked_hours,
    CAST(inv.DATAS AS DATE) AS reference_date,
    CAST(NULL AS STRING) AS batch_id,
    CAST([] AS ARRAY<INT64>) AS sku_ids
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Inventario` AS inv
  WHERE inv.MATRICULA IS NOT NULL AND inv.DATAS IS NOT NULL
),

c_reposicao AS (
  SELECT SAFE_CAST(r.cod_matricula AS INT64), CAST(r.user_name AS STRING), DATETIME(r.start_ts), DATETIME(r.end_ts), CAST(r.source_system AS STRING), 'PROMOTORA', CAST(r.score_movimentacao AS FLOAT64), CAST(NULL AS STRING), CAST(r.sku_id AS INT64), CAST(NULL AS BOOL), CAST(NULL AS INT64), CAST(r.descricao_atividade AS STRING), CAST(r.restock_list_level AS STRING), CAST(r.restock_list_type AS STRING), CAST(NULL AS STRING), CAST(NULL AS BOOL), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(r.score_movimentacao AS FLOAT64), CAST(r.score_movimentacao AS FLOAT64)*SAFE_CAST(pm.score_factor AS FLOAT64), TIMESTAMP_DIFF(r.end_ts,r.start_ts,SECOND)/3600.0,
    DATE(CASE
      WHEN EXTRACT(HOUR FROM DATETIME(r.start_ts)) < 6
        THEN DATETIME_SUB(DATETIME(r.start_ts), INTERVAL 1 DAY)
      ELSE DATETIME(r.start_ts)
    END),
    CAST(NULL AS STRING), CAST([] AS ARRAY<INT64>)
  FROM (SELECT *, COALESCE(SAFE_CAST(start_timestamp AS TIMESTAMP),SAFE.PARSE_TIMESTAMP('%Y/%m/%d %H:%M:%S',start_timestamp),SAFE.PARSE_TIMESTAMP('%a %b %d %Y %H:%M:%S GMT%z',REGEXP_REPLACE(start_timestamp,r' \([^)]*\)$',''))) AS start_ts, COALESCE(SAFE_CAST(end_timestamp AS TIMESTAMP),SAFE.PARSE_TIMESTAMP('%Y/%m/%d %H:%M:%S',end_timestamp),SAFE.PARSE_TIMESTAMP('%a %b %d %Y %H:%M:%S GMT%z',REGEXP_REPLACE(end_timestamp,r' \([^)]*\)$',''))) AS end_ts FROM `shopper-datalakehouse-qa.Ranking_Performance.curated_reposicao` WHERE start_timestamp IS NOT NULL AND end_timestamp IS NOT NULL) AS r
  INNER JOIN `shopper-datalakehouse-prod.performance.performance_metrics_n2` AS pm ON pm.metric_code=r.metric_code
),

c_recebimento AS (
  SELECT SAFE_CAST(r.cod_matricula AS INT64), CAST(r.user_name AS STRING), DATETIME(r.start_ts), DATETIME(r.end_ts), CAST(r.source_system AS STRING), 'PROMOTORA', CAST(r.score_recebimento AS FLOAT64), CAST(NULL AS STRING), CAST(r.sku_id AS INT64), CAST(NULL AS BOOL), CAST(NULL AS INT64), CAST(r.descricao_atividade AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(r.categoria_recebimento AS STRING), CAST(r.e_fresh AS BOOL), CAST(r.armazenamento_sugerido AS STRING), CAST(NULL AS STRING), CAST(r.score_recebimento AS FLOAT64), CAST(r.score_recebimento AS FLOAT64)*SAFE_CAST(pm.score_factor AS FLOAT64), TIMESTAMP_DIFF(r.end_ts,r.start_ts,SECOND)/3600.0,
    DATE(CASE
      WHEN EXTRACT(HOUR FROM DATETIME(r.start_ts)) < 6
        THEN DATETIME_SUB(DATETIME(r.start_ts), INTERVAL 1 DAY)
      ELSE DATETIME(r.start_ts)
    END),
    CAST(r.batch_id AS STRING), CAST([] AS ARRAY<INT64>)
  FROM (SELECT *, COALESCE(SAFE_CAST(start_timestamp AS TIMESTAMP),SAFE.PARSE_TIMESTAMP('%Y/%m/%d %H:%M:%S',start_timestamp),SAFE.PARSE_TIMESTAMP('%a %b %d %Y %H:%M:%S GMT%z',REGEXP_REPLACE(start_timestamp,r' \([^)]*\)$',''))) AS start_ts, COALESCE(SAFE_CAST(end_timestamp AS TIMESTAMP),SAFE.PARSE_TIMESTAMP('%Y/%m/%d %H:%M:%S',end_timestamp),SAFE.PARSE_TIMESTAMP('%a %b %d %Y %H:%M:%S GMT%z',REGEXP_REPLACE(end_timestamp,r' \([^)]*\)$',''))) AS end_ts FROM `shopper-datalakehouse-qa.Ranking_Performance.curated_recebimento` WHERE start_timestamp IS NOT NULL AND end_timestamp IS NOT NULL) AS r
  INNER JOIN `shopper-datalakehouse-prod.performance.performance_metrics_n2` AS pm ON pm.metric_code='STOCK_RECEIVEMENT'
),

c_lote AS (
  SELECT
    SAFE_CAST(l.cod_matricula AS INT64),
    CAST(l.user_name AS STRING),
    DATETIME(l.end_ts),
    DATETIME(l.end_ts),
    'MOVIMENTACAO_LOTE',
    'PROMOTORA',
    CAST(l.score_movimentacao AS FLOAT64),
    CAST(NULL AS STRING),
    CAST(l.sku_id AS INT64),
    CAST(NULL AS BOOL),
    CAST(NULL AS INT64),
    CAST(l.descricao_atividade AS STRING),
    CAST(NULL AS STRING),
    CAST(NULL AS STRING),
    CAST(NULL AS STRING),
    CAST(NULL AS BOOL),
    CAST(NULL AS STRING),
    CAST(NULL AS STRING),
    CAST(l.score_movimentacao AS FLOAT64),
    CAST(l.score_movimentacao AS FLOAT64) * 1.0,
    CAST(NULL AS FLOAT64),
    DATE(CASE
      WHEN EXTRACT(HOUR FROM DATETIME(l.end_ts)) < 6
        THEN DATETIME_SUB(DATETIME(l.end_ts), INTERVAL 1 DAY)
      ELSE DATETIME(l.end_ts)
    END),
    CAST(l.batch_id AS STRING),
    CAST([] AS ARRAY<INT64>)
  FROM (
    SELECT *,
      COALESCE(
        SAFE_CAST(end_timestamp AS TIMESTAMP),
        SAFE.PARSE_TIMESTAMP('%Y/%m/%d %H:%M:%S', end_timestamp),
        SAFE.PARSE_TIMESTAMP('%a %b %d %Y %H:%M:%S GMT%z', REGEXP_REPLACE(end_timestamp, r' \([^)]*\)$', ''))
      ) AS end_ts
    FROM `shopper-datalakehouse-qa.Ranking_Performance.curated_lote`
    WHERE end_timestamp IS NOT NULL AND score_movimentacao IS NOT NULL
  ) AS l
),

c_dark_store AS (
  SELECT SAFE_CAST(d.cod_matricula AS INT64), CAST(d.user_name AS STRING), CAST(d.activity_start AS DATETIME), CAST(d.activity_end AS DATETIME), 'DARK_STORE', CAST(d.metric_type AS STRING), CAST(d.qty AS FLOAT64), CAST(d.cod_pedido AS STRING), CAST(NULL AS INT64), CAST(NULL AS BOOL), CAST(NULL AS INT64), CAST(d.metric_description AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS BOOL), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS FLOAT64), CAST(d.qty AS FLOAT64)*d.score_factor, TIMESTAMP_DIFF(CAST(d.activity_end AS TIMESTAMP),CAST(d.activity_start AS TIMESTAMP),SECOND)/3600.0, CAST(d.reference_date AS DATE), CAST(NULL AS STRING), CAST([] AS ARRAY<INT64>)
  FROM `shopper-datalakehouse-qa.Ranking_Performance.curated_dark_store` AS d WHERE d.cod_matricula IS NOT NULL
),

c_erros_gestao AS (
  SELECT
    eg.registration_number, CAST(eg.user_name AS STRING),
    CAST(NULL AS DATETIME), CAST(NULL AS DATETIME),
    'ERROS_GESTAO_ESTOQUE', 'DETRATORA',
    CAST(eg.qtd_erros AS FLOAT64),
    CAST(NULL AS STRING), CAST(NULL AS INT64), CAST(NULL AS BOOL), CAST(NULL AS INT64),
    'ERRO GESTÃO DE ESTOQUE',
    CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS BOOL),
    CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS FLOAT64),
    eg.penalidade_pts,
    CAST(NULL AS FLOAT64), eg.reference_date, CAST(NULL AS STRING), CAST([] AS ARRAY<INT64>)
  FROM `shopper-datalakehouse-qa.Ranking_Performance.curated_erros_gestao_estoque` AS eg
  WHERE eg.zerado = FALSE
    AND eg.penalidade_pts IS NOT NULL
    AND eg.reference_date >= DATE_TRUNC(DATE_SUB(CURRENT_DATE('America/Sao_Paulo'), INTERVAL 1 MONTH), MONTH)
),

check_enderecos AS (
  SELECT
    CAST(ce.matricula          AS INT64)    AS registration_number,
    CAST(NULL                  AS STRING)   AS user_name,
    CAST(NULL                  AS DATETIME) AS activity_start,
    CAST(NULL                  AS DATETIME) AS activity_end,
    'CHECK_ENDERECOS'                       AS source_system,
    'PROMOTORA'                             AS metric_type,
    CAST(ce.qty_enderecos      AS FLOAT64)  AS qty,
    CAST(NULL                  AS STRING)   AS order_code,
    CAST(NULL                  AS INT64)    AS sku_id,
    CAST(NULL                  AS BOOL)     AS is_same_day,
    CAST(NULL                  AS INT64)    AS canal_venda,
    CAST(ce.metric_description AS STRING)   AS metric_description,
    CAST(NULL                  AS STRING)   AS restock_list_level,
    CAST(NULL                  AS STRING)   AS restock_list_type,
    CAST(NULL                  AS STRING)   AS receivement_category,
    CAST(NULL                  AS BOOL)     AS is_receivement_fresh,
    CAST(NULL                  AS STRING)   AS suggested_storage_receivement,
    CAST(NULL                  AS STRING)   AS movement_type,
    CAST(NULL                  AS FLOAT64)  AS score_movimentacao,
    CAST(ce.qty_enderecos      AS FLOAT64)  AS points,
    CAST(NULL                  AS FLOAT64)  AS activity_worked_hours,
    CAST(ce.reference_date     AS DATE)     AS reference_date,
    CAST(NULL                  AS STRING)   AS batch_id,
    ce.sku_ids
  FROM `shopper-datalakehouse-qa.Ranking_Performance.vw_check_enderecos_curated` AS ce
  WHERE ce.reference_date >= DATE_SUB(CURRENT_DATE('America/Sao_Paulo'), INTERVAL 15 DAY)
),

grocery_check AS (
  SELECT
    CAST(gc.matricula          AS INT64)    AS registration_number,
    CAST(gc.user_name          AS STRING)   AS user_name,
    CAST(gc.activity_start     AS DATETIME) AS activity_start,
    CAST(gc.activity_end       AS DATETIME) AS activity_end,
    'GROCERY_CHECK_CURATED'                 AS source_system,
    'PROMOTORA'                             AS metric_type,
    CAST(gc.qty                AS FLOAT64)  AS qty,
    CAST(gc.order_code         AS STRING)   AS order_code,
    CAST(NULL                  AS INT64)    AS sku_id,
    CAST(NULL                  AS BOOL)     AS is_same_day,
    CAST(NULL                  AS INT64)    AS canal_venda,
    CAST(gc.metric_description AS STRING)   AS metric_description,
    CAST(NULL                  AS STRING)   AS restock_list_level,
    CAST(NULL                  AS STRING)   AS restock_list_type,
    CAST(NULL                  AS STRING)   AS receivement_category,
    CAST(NULL                  AS BOOL)     AS is_receivement_fresh,
    CAST(NULL                  AS STRING)   AS suggested_storage_receivement,
    CAST(NULL                  AS STRING)   AS movement_type,
    CAST(NULL                  AS FLOAT64)  AS score_movimentacao,
    CAST(gc.points             AS FLOAT64)  AS points,
    CAST(NULL                  AS FLOAT64)  AS activity_worked_hours,
    CAST(gc.reference_date     AS DATE)     AS reference_date,
    CAST(NULL                  AS STRING)   AS batch_id,
    CAST([]                    AS ARRAY<INT64>) AS sku_ids
  FROM `shopper-datalakehouse-qa.Ranking_Performance.vw_grocery_check_curated` AS gc
  WHERE gc.reference_date >= DATE_SUB(CURRENT_DATE('America/Sao_Paulo'), INTERVAL 15 DAY)
    AND gc.matricula IS NOT NULL
),

-- ==========================================================================
-- BACKFILL TEMPORARIO - ITENS PICKADOS EM FRESH, 31/08 a 03/09/2026
-- Motivo: deploy em 31/08 (12h51) parou de emitir o evento de picking fresh
--   em raw_measures_n2 nos FC1/FC2/FC3.
-- Origem: picking_and_packing_itens_pedidos_n2 (conveyor_type_id = F),
--   executor do estagio 21 (FRESH - EXECUTANDO CONFERENCIA), 4 dias agregados.
-- Limitacoes aceitas na decisao de 04/09/2026:
--   - sem quebra por dia: tudo lancado em 2026-09-03. O job 03 soma o ciclo
--     inteiro por pessoa, entao o total semanal fica correto; so o feedback
--     diario fica achatado.
--   - sem granularidade de evento: no lugar do modifier_factor usa-se a media
--     historica de pontos brutos por item de cada FC, medida de 14 a 30/08.
--   - quantidades usadas como vieram, sem fator de conversao de escala.
--   - 43 itens sem executor registrado foram descartados.
-- REMOVER quando a origem for corrigida.
-- ==========================================================================
fresh_backfill_raw AS (
  SELECT * FROM UNNEST([
    STRUCT<matricula STRING, fc STRING, itens INT64>
    ('10190','FC1',18),
    ('10363','FC1',6),
    ('10448','FC1',235),
    ('10503','FC1',542),
    ('10568','FC1',409),
    ('10625','FC1',195),
    ('10675','FC1',42),
    ('10802','FC3',59),
    ('10871','FC1',237),
    ('10887','FC1',635),
    ('10902','FC1',337),
    ('10983','FC1',798),
    ('11016','FC1',70),
    ('11095','FC1',477),
    ('11232','FC1',433),
    ('11250','FC1',73),
    ('11261','FC1',512),
    ('11273','FC1',457),
    ('11323','FC1',195),
    ('11342','FC1',1059),
    ('11371','FC1',956),
    ('11399','FC1',979),
    ('11405','FC1',227),
    ('11429','FC1',369),
    ('11601','FC1',667),
    ('11605','FC1',1040),
    ('11635','FC1',73),
    ('11684','FC1',419),
    ('11854','FC1',36),
    ('11890','FC1',2),
    ('11892','FC1',52),
    ('11922','FC1',36),
    ('11931','FC1',55),
    ('11943','FC1',81),
    ('12082','FC1',52),
    ('12122','FC3',105),
    ('12186','FC3',1318),
    ('12191','FC3',849),
    ('12192','FC3',1284),
    ('12204','FC3',704),
    ('12303','FC3',1198),
    ('12311','FC3',1739),
    ('12367','FC2',35),
    ('12386','FC1',15),
    ('12476','FC2',343),
    ('12482','FC3',246),
    ('12486','FC3',89),
    ('12511','FC3',25),
    ('12624','FC3',28),
    ('12829','FC1',122),
    ('12880','FC1',9),
    ('12925','FC1',594),
    ('13008','FC1',1),
    ('13064','FC1',75),
    ('13143','FC1',667),
    ('13154','FC1',23),
    ('13155','FC3',106),
    ('13158','FC1',46),
    ('13212','FC1',113),
    ('13278','FC2',114),
    ('13280','FC1',7),
    ('13287','FC1',17),
    ('13310','FC2',7),
    ('13384','FC1',15),
    ('13420','FC3',58),
    ('13451','FC2',19),
    ('13623','FC3',705),
    ('13756','FC1',834),
    ('13778','FC1',5),
    ('13786','FC3',87),
    ('13788','FC2',114),
    ('13799','FC3',362),
    ('13808','FC3',96),
    ('13974','FC3',92),
    ('13998','FC1',181),
    ('14054','FC1',44),
    ('14079','FC1',21),
    ('14125','FC3',17),
    ('14135','FC2',24),
    ('14155','FC2',29),
    ('14177','FC3',1556),
    ('14197','FC3',1093),
    ('14198','FC3',638),
    ('14247','FC1',35),
    ('14338','FC2',27),
    ('14341','FC3',961),
    ('14345','FC3',874),
    ('14367','FC3',63),
    ('14374','FC3',11),
    ('14402','FC3',1136),
    ('14405','FC1',13),
    ('14416','FC3',901),
    ('14421','FC1',771),
    ('14492','FC1',74),
    ('14503','FC1',1690),
    ('14566','FC1',586),
    ('14751','FC1',26),
    ('14762','FC1',30),
    ('14764','FC1',284),
    ('14791','FC3',338),
    ('14853','FC3',46),
    ('14858','FC3',287),
    ('14995','FC3',347),
    ('15006','FC3',21),
    ('15028','FC1',43),
    ('15049','FC3',360),
    ('15124','FC1',73),
    ('15150','FC1',18),
    ('15158','FC2',370),
    ('15172','FC1',15),
    ('15180','FC1',4),
    ('15269','FC1',74),
    ('15278','FC1',99),
    ('15293','FC3',64),
    ('15381','FC1',23),
    ('15415','FC1',9),
    ('15420','FC3',945),
    ('15425','FC1',3),
    ('15445','FC3',1255),
    ('15463','FC1',72),
    ('15467','FC1',11),
    ('15503','FC3',20),
    ('15579','FC3',22),
    ('15582','FC3',731),
    ('15587','FC1',646),
    ('15662','FC1',43),
    ('15665','FC1',31),
    ('15675','FC3',293),
    ('15736','FC1',95),
    ('15737','FC1',1061),
    ('15738','FC1',329),
    ('15759','FC1',1046),
    ('15762','FC1',38),
    ('15767','FC1',295),
    ('15768','FC3',847),
    ('15825','FC3',654),
    ('15831','FC3',60),
    ('15832','FC3',142),
    ('15833','FC3',118),
    ('15834','FC3',53),
    ('15835','FC3',23),
    ('15836','FC3',41),
    ('15838','FC3',19),
    ('15840','FC3',1),
    ('15842','FC3',11),
    ('15843','FC3',15),
    ('15844','FC3',28),
    ('15845','FC3',34),
    ('15847','FC1',215),
    ('15848','FC1',213),
    ('15849','FC1',42),
    ('15902','FC3',540),
    ('15907','FC3',84),
    ('15918','FC1',41),
    ('15919','FC1',86),
    ('15924','FC1',344),
    ('15991','FC3',63),
    ('15997','FC1',300),
    ('16000','FC1',18),
    ('16001','FC1',120),
    ('16002','FC1',74),
    ('16004','FC3',3),
    ('16006','FC3',33),
    ('16007','FC3',14),
    ('16008','FC3',68),
    ('16014','FC3',592),
    ('16027','FC2',407),
    ('16070','FC1',1049),
    ('16083','FC1',21),
    ('16113','FC1',2),
    ('16117','FC2',5),
    ('16141','FC1',836),
    ('16160','FC1',33),
    ('16167','FC1',764),
    ('16170','FC1',2),
    ('16196','FC1',37),
    ('16197','FC3',259),
    ('16209','FC3',171),
    ('16239','FC2',1230),
    ('16298','FC2',9),
    ('16335','FC3',162),
    ('16352','FC1',861),
    ('16394','FC3',204),
    ('16417','FC1',646),
    ('16451','FC1',85),
    ('16452','FC1',70),
    ('16453','FC1',310),
    ('16454','FC1',31),
    ('16455','FC1',73),
    ('16459','FC1',112),
    ('16460','FC1',47),
    ('16464','FC3',74),
    ('16467','FC1',288),
    ('16470','FC1',69),
    ('16477','FC3',39),
    ('16479','FC1',99),
    ('16483','FC1',89),
    ('16487','FC3',30),
    ('16496','FC1',86),
    ('16503','FC3',20),
    ('16504','FC1',98),
    ('16506','FC1',60),
    ('16507','FC3',28),
    ('16514','FC1',17),
    ('16520','FC1',12),
    ('16521','FC1',14),
    ('16522','FC1',237),
    ('16530','FC2',385),
    ('16559','FC1',66),
    ('16595','FC2',389),
    ('16603','FC1',295),
    ('16618','FC1',50),
    ('16623','FC3',49),
    ('16648','FC1',614),
    ('16673','FC2',297),
    ('16679','FC3',1192),
    ('16691','FC1',631),
    ('16700','FC3',781),
    ('16756','FC1',27),
    ('16763','FC1',80),
    ('16778','FC1',410),
    ('16796','FC1',288),
    ('16799','FC1',24),
    ('16799','FC3',1053),
    ('16856','FC3',379),
    ('16892','FC3',169),
    ('17021','FC1',452),
    ('17088','FC3',192),
    ('17091','FC3',585),
    ('17100','FC1',77),
    ('17106','FC1',856),
    ('17117','FC3',501),
    ('17122','FC1',604),
    ('17144','FC1',30),
    ('17144','FC3',584),
    ('17147','FC3',12),
    ('17171','FC3',347),
    ('17178','FC3',672),
    ('17182','FC3',386),
    ('17187','FC3',72),
    ('17207','FC1',125),
    ('17239','FC3',1115),
    ('17248','FC2',445),
    ('17254','FC1',16),
    ('17254','FC3',571),
    ('17255','FC2',60),
    ('17286','FC1',479),
    ('17293','FC1',403),
    ('17302','FC2',312),
    ('17335','FC1',31),
    ('17360','FC1',552),
    ('17419','FC2',32),
    ('17429','FC1',554),
    ('17430','FC2',260),
    ('17436','FC1',106),
    ('17463','FC1',45),
    ('17474','FC2',383),
    ('17492','FC3',162),
    ('17502','FC1',55),
    ('17508','FC1',382),
    ('17513','FC3',405),
    ('17514','FC3',22),
    ('17517','FC3',337),
    ('17521','FC3',701),
    ('17526','FC3',809),
    ('17527','FC3',531),
    ('17528','FC1',90),
    ('17529','FC3',651),
    ('17538','FC1',90),
    ('17551','FC1',33),
    ('17564','FC1',20),
    ('17564','FC3',261),
    ('17567','FC3',993),
    ('17570','FC3',1285),
    ('17581','FC3',653),
    ('17600','FC3',1171),
    ('17623','FC2',351),
    ('17636','FC1',838),
    ('17637','FC3',69),
    ('17653','FC3',202),
    ('17702','FC3',521),
    ('17715','FC3',410),
    ('17721','FC3',41),
    ('17724','FC3',625),
    ('17727','FC3',8),
    ('17737','FC3',96),
    ('17740','FC3',40),
    ('17777','FC3',220),
    ('17782','FC3',249),
    ('17801','FC3',97),
    ('17808','FC1',81),
    ('17827','FC1',70),
    ('17841','FC2',91),
    ('17867','FC1',404),
    ('17870','FC3',114),
    ('18111','FC3',399),
    ('18123','FC1',161),
    ('18168','FC1',5),
    ('18195','FC3',596),
    ('18202','FC2',317),
    ('18251','FC3',594),
    ('18297','FC1',15),
    ('18331','FC1',598),
    ('18424','FC2',482),
    ('18442','FC2',388),
    ('18453','FC2',315),
    ('18457','FC2',123),
    ('18469','FC1',137),
    ('18490','FC3',17),
    ('18541','FC2',351),
    ('18551','FC3',619),
    ('18552','FC2',373),
    ('18610','FC3',632),
    ('18620','FC3',1771),
    ('18621','FC3',499),
    ('18628','FC1',455),
    ('18631','FC3',170),
    ('18651','FC3',893),
    ('18761','FC3',284),
    ('18765','FC3',439),
    ('18767','FC3',168),
    ('18778','FC1',51),
    ('18786','FC1',101),
    ('18794','FC1',460),
    ('18796','FC1',102),
    ('18803','FC1',35),
    ('18809','FC2',307),
    ('18815','FC2',399),
    ('18876','FC3',21),
    ('18879','FC1',14),
    ('18879','FC3',963),
    ('18881','FC3',456),
    ('18885','FC3',649),
    ('18889','FC3',55),
    ('18890','FC3',58),
    ('18895','FC3',5),
    ('18903','FC1',6),
    ('18903','FC3',1490),
    ('18905','FC1',30),
    ('18909','FC3',365),
    ('18930','FC1',60),
    ('18932','FC1',520),
    ('18970','FC1',9),
    ('18978','FC1',601),
    ('18983','FC1',160),
    ('18988','FC3',298),
    ('18993','FC3',23),
    ('19000','FC3',730),
    ('19078','FC3',538),
    ('19091','FC1',839),
    ('19112','FC2',261),
    ('19119','FC3',48),
    ('19135','FC3',566),
    ('19234','FC1',195),
    ('19238','FC1',219),
    ('19245','FC1',6),
    ('19247','FC1',117),
    ('19272','FC3',771),
    ('19283','FC3',40),
    ('19325','FC1',295),
    ('19349','FC2',52),
    ('19353','FC1',422),
    ('19355','FC3',684),
    ('19363','FC3',272),
    ('19366','FC3',81),
    ('19369','FC3',528),
    ('19370','FC3',512),
    ('19383','FC3',223),
    ('19477','FC3',224),
    ('19482','FC3',280),
    ('19489','FC3',352),
    ('19503','FC1',27),
    ('19506','FC3',402),
    ('19508','FC1',444),
    ('19513','FC1',198),
    ('2006','FC1',92),
    ('4326','FC1',121),
    ('4711','FC1',146),
    ('6204','FC1',48),
    ('6688','FC1',424),
    ('7061','FC3',6),
    ('7394','FC1',546),
    ('7526','FC1',214),
    ('7553','FC1',43),
    ('7764','FC1',950),
    ('8170','FC1',188),
    ('8317','FC1',13),
    ('8511','FC1',55),
    ('8863','FC1',63),
    ('8899','FC1',144),
    ('9177','FC1',109),
    ('9194','FC3',1206),
    ('9198','FC3',18),
    ('9296','FC1',20),
    ('9501','FC1',11),
    ('9522','FC1',261),
    ('9803','FC2',111),
    ('9845','FC1',135),
    ('9881','FC2',607),
    ('9896','FC1',132),
    ('9922','FC2',27)
  ])
),

fresh_backfill AS (
  SELECT
    SAFE_CAST(f.matricula AS INT64),
    CAST(u.user_name AS STRING),
    CAST(NULL AS DATETIME),
    CAST(NULL AS DATETIME),
    'FRESH_BACKFILL_31AGO_03SET',
    'PROMOTORA',
    CAST(f.itens AS FLOAT64),
    CAST(NULL AS STRING), CAST(NULL AS INT64), CAST(NULL AS BOOL), CAST(NULL AS INT64),
    'ITENS PICKADOS EM FRESH',
    CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
    CAST(NULL AS BOOL), CAST(NULL AS STRING), CAST(NULL AS STRING),
    CAST(NULL AS FLOAT64),
    CAST(f.itens AS FLOAT64) * CASE f.fc
      WHEN 'FC1' THEN 385.85
      WHEN 'FC2' THEN 444.66
      WHEN 'FC3' THEN 349.55
      ELSE 0.0 END,
    CAST(NULL AS FLOAT64),
    DATE '2026-09-03',
    CAST(NULL AS STRING),
    CAST([] AS ARRAY<INT64>)
  FROM fresh_backfill_raw AS f
  LEFT JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` AS u
    ON u.registration_number = SAFE_CAST(f.matricula AS INT64)
),

eventos_unificados AS (
  SELECT registration_number, user_name, activity_start, activity_end, source_system, metric_type, qty, order_code, sku_id, is_same_day, canal_venda,
    CASE WHEN metric_description='AUDITORIA DE CONFERENCIA MERCEARIA' AND LOWER(TRIM(pack_mode))='express' THEN 'AUDITORIA DE CONFERENCIA MERCEARIA EXPRESS' WHEN metric_description='AUDITORIA DE CONFERENCIA FRESH' AND LOWER(TRIM(pack_mode))='express' THEN 'AUDITORIA DE CONFERENCIA FRESH EXPRESS' ELSE metric_description END AS metric_description,
    restock_list_level, restock_list_type, receivement_category, is_receivement_fresh, suggested_storage_receivement, movement_type, score_movimentacao, points, activity_worked_hours, reference_date, batch_id, sku_ids
  FROM calc
  UNION ALL SELECT * FROM espelho
  UNION ALL SELECT * FROM expedicao
  UNION ALL SELECT * FROM pre_expedicao
  UNION ALL SELECT * FROM perdas
  UNION ALL SELECT * FROM inventario
  UNION ALL SELECT * FROM novo_inventario
  UNION ALL SELECT * FROM c_reposicao
  UNION ALL SELECT * FROM c_recebimento
  UNION ALL SELECT * FROM c_lote
  UNION ALL SELECT * FROM c_dark_store
  UNION ALL SELECT * FROM c_erros_gestao
  UNION ALL SELECT * FROM check_enderecos
  UNION ALL SELECT * FROM grocery_check
  UNION ALL SELECT * FROM fresh_backfill
),

pesos_turno_cache AS (
  SELECT UPPER(TRIM(METRIC_DESCRIPTION)) AS metric_key, FC1_MANHA, FC1_TARDE, FC1_NOITE, FC2_MANHA, FC2_TARDE, FC2_NOITE, FC2_INTERMEDIARIO, FC3_MANHA, FC3_TARDE, FC3_NOITE, FC4_MANHA, FC4_TARDE, FC4_NOITE
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Pesos_turno`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(METRIC_DESCRIPTION)) ORDER BY DATA_INICIAL DESC) = 1
),

organograma_cache AS (
  SELECT CAST(MATRICULA AS STRING) AS matricula, UPPER(TRIM(NOME)) AS nome, UPPER(TRIM(AREA)) AS area, UPPER(TRIM(SETOR)) AS setor_principal, UPPER(TRIM(ATRIBUICAO)) AS atribuicao_principal, UPPER(TRIM(TURNO)) AS turno_principal, UPPER(TRIM(FC)) AS fc, GESTOR, CRACHA, FOLGA_FIXA, DATA_ADM
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Organograma`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) = 1
)

SELECT
  eu.registration_number, eu.user_name, COALESCE(org.nome,eu.user_name) AS nome,
  org.area, org.setor_principal, org.gestor, org.atribuicao_principal, org.turno_principal, org.cracha, org.folga_fixa, org.fc, org.data_adm,
  eu.activity_start, eu.activity_end, eu.source_system, eu.metric_type, eu.qty, eu.order_code, eu.sku_id, eu.is_same_day, eu.canal_venda,
  eu.metric_description, eu.restock_list_level, eu.restock_list_type, eu.receivement_category, eu.is_receivement_fresh, eu.suggested_storage_receivement,
  eu.movement_type, eu.score_movimentacao, eu.points, eu.activity_worked_hours, eu.reference_date, eu.batch_id,
  CAST(
    CASE
      WHEN eu.source_system = 'INVENTARIO_NOVO' THEN eu.points
      ELSE eu.points * COALESCE(
        CASE
          WHEN org.fc='FC1' AND org.turno_principal='MANHÃ' THEN pt.FC1_MANHA
          WHEN org.fc='FC1' AND org.turno_principal='TARDE' THEN pt.FC1_TARDE
          WHEN org.fc='FC1' AND org.turno_principal='NOITE' THEN pt.FC1_NOITE
          WHEN org.fc='FC2' AND org.turno_principal='MANHÃ' THEN pt.FC2_MANHA
          WHEN org.fc='FC2' AND org.turno_principal='TARDE' THEN pt.FC2_TARDE
          WHEN org.fc='FC2' AND org.turno_principal='NOITE' THEN pt.FC2_NOITE
          WHEN org.fc='FC2' AND org.turno_principal LIKE '%INTERMEDI%' THEN pt.FC2_INTERMEDIARIO
          WHEN org.fc='FC3' AND org.turno_principal='MANHÃ' THEN pt.FC3_MANHA
          WHEN org.fc='FC3' AND org.turno_principal='TARDE' THEN pt.FC3_TARDE
          WHEN org.fc='FC3' AND org.turno_principal='NOITE' THEN pt.FC3_NOITE
          WHEN org.fc='FC4' AND org.turno_principal='MANHÃ' THEN pt.FC4_MANHA
          WHEN org.fc='FC4' AND org.turno_principal='TARDE' THEN pt.FC4_TARDE
          WHEN org.fc='FC4' AND org.turno_principal='NOITE' THEN pt.FC4_NOITE
        END, 1.0) * CASE WHEN eu.metric_type='DETRATORA' THEN -1.0 ELSE 1.0 END
    END AS FLOAT64
  ) AS pontos_ponderados,
  eu.sku_ids
FROM eventos_unificados AS eu
INNER JOIN organograma_cache AS org ON CAST(eu.registration_number AS STRING) = org.matricula
LEFT JOIN pesos_turno_cache AS pt ON UPPER(TRIM(
  CASE
    WHEN eu.source_system = 'DARK_STORE' THEN 'ITENS PICKADOS EM FRESH'
    WHEN eu.metric_description = 'VOLUMES EXPEDIDOS' AND org.area = 'CAMPINAS' THEN 'VOLUMES EXPEDIDOS EM CAMPINAS'
    ELSE eu.metric_description
  END
)) = pt.metric_key
WHERE eu.reference_date >= DATE_SUB(CURRENT_DATE('America/Sao_Paulo'), INTERVAL 8 DAY)
  -- Alta de temperatura na semana de 28/08 a 03/09/2026: os chocolates foram
  -- marcados como faltante em massa nos pedidos do FC2. As inclusoes geradas
  -- por essa decisao nao devem pontuar. REMOVER quando o ciclo sair da janela.
  AND NOT (
    org.fc = 'FC2'
    AND eu.reference_date BETWEEN '2026-08-28' AND '2026-09-03'
    AND eu.metric_description = 'ITENS INCLUIDOS'
    AND EXISTS (
      SELECT 1
      FROM UNNEST(eu.sku_ids) AS s
      JOIN `shopper-datalakehouse-prod.shared.purchase_automation_produtos_n3` AS pr
        ON pr.sku_id = s
      WHERE UPPER(pr.sku_name) LIKE 'CHOCOLATE%'
    )
  );
