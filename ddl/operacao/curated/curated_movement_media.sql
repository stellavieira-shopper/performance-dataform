CREATE OR REPLACE VIEW `shopper-performance-prod.operacao.curated_movement_media`
OPTIONS (description = 'Média IQR por SKU e contexto de movimentação (REPOSICAO, RECEBIMENTO, PK).')
AS
WITH ValoresReposicao AS (
  SELECT
    SAFE_CAST(JSON_VALUE(details, '$.sku_id') AS INT64) AS sku_id,
    SAFE_CAST(value AS FLOAT64)                         AS qty,
    'REPOSICAO'                                         AS movement_group,
    JSON_VALUE(details, '$.restock_list_level')         AS restock_list_level,
    JSON_VALUE(details, '$.restock_list_type')          AS restock_list_type,
    CAST(NULL AS STRING)                                AS receivement_category,
    CAST(NULL AS BOOL)                                  AS is_receivement_fresh,
    CAST(NULL AS STRING)                                AS suggested_storage_receivement,
    CAST(NULL AS STRING)                                AS movement_type
  FROM `shopper-datalakehouse-prod.performance.raw_measures_n2`
  WHERE metric_code IN ('MOVEMENT_PICKUP', 'MOVEMENT_RESTOCK')
    AND SAFE_CAST(value AS FLOAT64) > 0
),
ValoresRecebimento AS (
  SELECT
    SAFE_CAST(JSON_VALUE(details, '$.sku_id') AS INT64)              AS sku_id,
    SAFE_CAST(JSON_VALUE(details, '$.total_items_qty') AS FLOAT64)   AS qty,
    'RECEBIMENTO'                                                     AS movement_group,
    CAST(NULL AS STRING)                                              AS restock_list_level,
    CAST(NULL AS STRING)                                              AS restock_list_type,
    JSON_VALUE(details, '$.receivement_category')                    AS receivement_category,
    SAFE_CAST(JSON_VALUE(details, '$.is_receivement_fresh') AS BOOL) AS is_receivement_fresh,
    JSON_VALUE(details, '$.suggested_storage_receivement')           AS suggested_storage_receivement,
    CAST(NULL AS STRING)                                              AS movement_type
  FROM `shopper-datalakehouse-prod.performance.raw_measures_n2`
  WHERE metric_code = 'STOCK_RECEIVEMENT'
    AND SAFE_CAST(JSON_VALUE(details, '$.total_items_qty') AS FLOAT64) > 0
),
ValoresPK AS (
  SELECT
    SAFE_CAST(JSON_VALUE(details, '$.sku_id') AS INT64) AS sku_id,
    SAFE_CAST(value AS FLOAT64)                         AS qty,
    'PK'                                                AS movement_group,
    CAST(NULL AS STRING)                                AS restock_list_level,
    CAST(NULL AS STRING)                                AS restock_list_type,
    CAST(NULL AS STRING)                                AS receivement_category,
    CAST(NULL AS BOOL)                                  AS is_receivement_fresh,
    CAST(NULL AS STRING)                                AS suggested_storage_receivement,
    JSON_VALUE(details, '$.movement_type')              AS movement_type
  FROM `shopper-datalakehouse-prod.performance.raw_measures_n2`
  WHERE metric_code IN ('MOVEMENT_PK', 'MOVEMENT_TRANSFER')
    AND SAFE_CAST(value AS FLOAT64) > 0
),
TodosValores AS (
  SELECT * FROM ValoresReposicao
  UNION ALL SELECT * FROM ValoresRecebimento
  UNION ALL SELECT * FROM ValoresPK
),
ComIQR AS (
  SELECT *,
    PERCENTILE_CONT(qty, 0.25) OVER (PARTITION BY movement_group) AS q1,
    PERCENTILE_CONT(qty, 0.75) OVER (PARTITION BY movement_group) AS q3
  FROM TodosValores
),
SemOutliers AS (
  SELECT sku_id, movement_group, restock_list_level, restock_list_type,
    receivement_category, is_receivement_fresh, suggested_storage_receivement, movement_type, qty
  FROM ComIQR
  WHERE qty >= q1 - 1.5*(q3-q1) AND qty <= q3 + 1.5*(q3-q1)
)
SELECT
  sku_id, movement_group, restock_list_level, restock_list_type,
  receivement_category, is_receivement_fresh, suggested_storage_receivement, movement_type,
  COUNT(*) AS total_registros,
  AVG(qty)  AS media_sem_outliers
FROM SemOutliers
GROUP BY sku_id, movement_group, restock_list_level, restock_list_type,
  receivement_category, is_receivement_fresh, suggested_storage_receivement, movement_type;
