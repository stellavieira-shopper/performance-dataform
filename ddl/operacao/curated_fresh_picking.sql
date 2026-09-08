CREATE OR REPLACE VIEW `shopper-datalakehouse-qa.Ranking_Performance.curated_fresh_picking`
OPTIONS (description = 'Picking fresh e auditoria fresh em FC1/FC2/FC3: stage 21 (picking), stages 23/25 (fiscal audit).')
AS
WITH Ja_Na_Raw_Audit_Fresh AS (
  SELECT DISTINCT JSON_VALUE(details, '$.order_code') AS order_code
  FROM `shopper-datalakehouse-prod.performance.raw_measures_n2`
  WHERE metric_code = 'FRESH_CHECK_AUDIT'
),

Fiscal_Fresh AS (
  SELECT kdabra_order_id,
    COALESCE(
      MIN(IF(conveyor_stage_id = 23, executed_by, NULL)),
      MIN(IF(conveyor_stage_id = 25, executed_by, NULL))
    ) AS executed_by_fiscal,
    MIN(IF(conveyor_stage_id = 23, started_stage_at, NULL)) AS start_stage23,
    MIN(IF(conveyor_stage_id = 25, started_stage_at, NULL)) AS start_stage25,
    COALESCE(
      MAX(IF(conveyor_stage_id = 23, end_stage_at, NULL)),
      MAX(IF(conveyor_stage_id = 25, end_stage_at, NULL))
    ) AS activity_end_fiscal
  FROM `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_esteira_n2`
  WHERE conveyor_stage_id IN (23, 25)
  GROUP BY kdabra_order_id
),

Esteira_Picking AS (
  SELECT
    kdabra_order_id,
    MIN(started_stage_at)  AS inicio_picking,
    ANY_VALUE(executed_by) AS executed_by,
    ANY_VALUE(shift_date)  AS shift_date
  FROM `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_esteira_n2`
  WHERE conveyor_stage_id = 21
  GROUP BY kdabra_order_id
),

Esteira_Packing AS (
  SELECT kdabra_order_id, MAX(end_stage_at) AS fim_picking
  FROM `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_esteira_n2`
  WHERE conveyor_stage_id = 29
  GROUP BY kdabra_order_id
)

SELECT
  SAFE_CAST(u.registration_number AS INT64)                                       AS cod_matricula,
  u.user_name,
  p.order_code                                                                    AS cod_pedido,
  p.fulfillment_center_id,
  CAST(e21.shift_date AS DATE)                                                    AS reference_date,
  e21.inicio_picking                                                              AS activity_start,
  e29.fim_picking                                                                 AS activity_end,
  SUM(COALESCE(itens.item_picked_qty, 0))                                         AS qty,
  SUM(COALESCE(itens.item_picked_qty, 0)) * SAFE_CAST(pm.score_factor AS FLOAT64) AS points,
  'ITENS PICKADOS EM FRESH'                                                       AS metric_description,
  'PROMOTORA'                                                                     AS metric_type
FROM Esteira_Picking AS e21
INNER JOIN Esteira_Packing AS e29
  ON e21.kdabra_order_id = e29.kdabra_order_id
LEFT JOIN `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_n2` AS p
  ON e21.kdabra_order_id = p.kdabra_order_id
LEFT JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` AS u
  ON CAST(e21.executed_by AS INT64) = u.user_id
LEFT JOIN `shopper-datalakehouse-prod.operations.picking_and_packing_itens_pedidos_n2` AS itens
  ON itens.kdabra_order_id = e21.kdabra_order_id
  AND COALESCE(itens.is_replacement, 0) = 0
  AND itens.conveyor_type_id = 'F'
CROSS JOIN (
  SELECT score_factor
  FROM `shopper-datalakehouse-prod.performance.performance_metrics_n2`
  WHERE metric_description = 'ITENS PICKADOS EM FRESH'
  LIMIT 1
) AS pm
WHERE p.fulfillment_center_id IN (2, 3, 7)
GROUP BY 1, 2, 3, 4, 5, 6, 7, pm.score_factor

UNION ALL

SELECT
  SAFE_CAST(u.registration_number AS INT64)              AS cod_matricula,
  u.user_name,
  p.order_code                                           AS cod_pedido,
  p.fulfillment_center_id,
  CAST(ep.shift_date AS DATE)                            AS reference_date,
  COALESCE(
    IF(f.start_stage23 > ep.inicio_picking, f.start_stage23, NULL),
    IF(f.start_stage25 > ep.inicio_picking, f.start_stage25, NULL)
  )                                                      AS activity_start,
  f.activity_end_fiscal                                  AS activity_end,
  1                                                      AS qty,
  1.0                                                    AS points,
  'AUDITORIA DE CONFERENCIA FRESH'                       AS metric_description,
  'PROMOTORA'                                            AS metric_type
FROM Esteira_Picking AS ep
INNER JOIN Fiscal_Fresh AS f ON ep.kdabra_order_id = f.kdabra_order_id
LEFT JOIN `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_n2` AS p
  ON ep.kdabra_order_id = p.kdabra_order_id
LEFT JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` AS u
  ON CAST(f.executed_by_fiscal AS INT64) = u.user_id
WHERE f.executed_by_fiscal IS NOT NULL
  AND p.fulfillment_center_id IN (2, 3, 7)
  AND p.order_code NOT LIKE '%N'
  AND p.order_code NOT LIKE 'MK%'
  AND p.order_code NOT IN (SELECT order_code FROM Ja_Na_Raw_Audit_Fresh);
