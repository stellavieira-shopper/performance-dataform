-- Snapshot de prod — recriar a cada semana via refresh_raws.py
CREATE OR REPLACE TABLE `shopper-performance-prod.darkstore.raw_pedidos` AS
WITH e21 AS (
  SELECT kdabra_order_id, MIN(started_stage_at) AS started_stage_at, MAX(end_stage_at) AS end_stage_at,
    ANY_VALUE(executed_by) AS executed_by, ANY_VALUE(shift_date) AS shift_date
  FROM `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_esteira_n2`
  WHERE conveyor_stage_id = 21 GROUP BY kdabra_order_id
),
e29 AS (
  SELECT kdabra_order_id, MAX(end_stage_at) AS end_stage_at
  FROM `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_esteira_n2`
  WHERE conveyor_stage_id = 29 GROUP BY kdabra_order_id
),
e31 AS (
  SELECT DISTINCT kdabra_order_id
  FROM `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_esteira_n2`
  WHERE conveyor_stage_id = 31
),
rup AS (
  SELECT DISTINCT kdabra_order_id
  FROM `shopper-datalakehouse-prod.operations.picking_and_packing_itens_pedidos_n2`
  WHERE has_collected = 0 AND COALESCE(is_replacement, 0) = 0
)
SELECT
  CASE p.fulfillment_center_id
    WHEN 6  THEN 'pamplona'        WHEN 8  THEN 'moema'
    WHEN 9  THEN 'pinheiros'       WHEN 10 THEN 'higienopolis'
    WHEN 11 THEN 'vila olimpia'    WHEN 12 THEN 'alto de pinheiros'
    WHEN 13 THEN 'barra funda'     WHEN 14 THEN 'morumbi'
    WHEN 15 THEN 'vila mariana'    WHEN 16 THEN 'brooklin'
    WHEN 17 THEN 'são caetano'     WHEN 18 THEN 'campinas'
    WHEN 19 THEN 'tatuapé'
    ELSE LOWER(TRIM(p.fulfillment_center))
  END                                                               AS store_code,
  p.order_code                                                      AS cod_pedido,
  CAST(p.fulfillment_center_id AS STRING)                           AS id_fulfillment_center,
  CAST(p.kdabra_order_status_id AS STRING)                          AS id_status_pedido,
  CAST(e21.executed_by AS STRING)                                   AS id_usr_executor,
  u.user_name                                                       AS nome,
  CAST(u.registration_number AS STRING)                             AS mat,
  CASE
    WHEN TIME(e21.started_stage_at) >= TIME '06:00:00' AND TIME(e21.started_stage_at) < TIME '14:00:00' THEN 'MANHA'
    WHEN TIME(e21.started_stage_at) >= TIME '14:00:00' AND TIME(e21.started_stage_at) < TIME '22:00:00' THEN 'TARDE'
    ELSE 'NOITE'
  END                                                               AS schedule,
  CAST('21' AS STRING)                                              AS etapa_picking,
  CAST(IF(e31.kdabra_order_id IS NOT NULL,'31',NULL) AS STRING)    AS etapa_esteira,
  IF(rup.kdabra_order_id IS NOT NULL,'1','0')                      AS teve_ruptura,
  IF(COALESCE(p.had_replacement,0)=1,'1','0')                      AS teve_substituicao,
  CAST(p.created_at AS STRING)                                      AS entrada_pedido_sistema,
  CAST(e21.started_stage_at AS STRING)                             AS inicio_picking,
  CAST(e21.end_stage_at AS STRING)                                 AS fim_picking,
  CAST(e29.end_stage_at AS STRING)                                 AS fim_packing,
  CAST(p.reservation_confirmed_at AS STRING)                        AS dt_confirmacao,
  CAST(p.created_at AS STRING)                                      AS dt_criacao,
  CAST(e21.shift_date AS STRING)                                    AS dt_turno,
  CAST(p.delivery_date AS STRING)                                   AS dt_previsao_entrega,
  CAST(p.delivery_time_frame_start AS STRING)                       AS delivery_time_frame_start,
  CAST(p.delivery_time_frame_end AS STRING)                         AS delivery_time_frame_end,
  CAST(CURRENT_TIMESTAMP() AS STRING)                               AS ingested_at
FROM e21
INNER JOIN e29 ON e21.kdabra_order_id = e29.kdabra_order_id
LEFT JOIN `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_n2` p ON e21.kdabra_order_id = p.kdabra_order_id
LEFT JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` u ON CAST(e21.executed_by AS INT64) = u.user_id
LEFT JOIN rup ON e21.kdabra_order_id = rup.kdabra_order_id
LEFT JOIN e31 ON e21.kdabra_order_id = e31.kdabra_order_id
WHERE p.fulfillment_center_id NOT IN (1, 2, 3, 7);
