-- Snapshot de prod — recriar a cada semana via refresh_raws.py
CREATE OR REPLACE TABLE `shopper-performance-prod.darkstore.raw_rupturas` AS
SELECT
  p.fulfillment_center_id                          AS id_fulfillment_center,
  p.order_code                                     AS cod_pedido,
  prod.sku_code                                    AS cod_produto,
  '2'                                              AS issue_type,
  IF(
    ist.status = 'Resolvido',
    CAST(CURRENT_TIMESTAMP() AS STRING),
    NULL
  )                                                AS resolved_at
FROM `shopper-datalakehouse-prod.operations.picking_and_packing_orders_issues_not_consulted_n2` oinc
INNER JOIN `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_n2` p
  ON p.kdabra_order_id = oinc.kdabra_order_id
INNER JOIN `shopper-datalakehouse-prod.shared.purchase_automation_produtos_n3` prod
  ON prod.sku_id = oinc.original_sku_id
LEFT JOIN `shopper-datalakehouse-prod.operations.picking_and_packing_issues_not_consulted_types_n3` it
  ON it.id = oinc.issue_type
LEFT JOIN `shopper-datalakehouse-prod.operations.picking_and_packing_issues_not_consulted_status_n3` ist
  ON ist.id = oinc.issue_status
WHERE p.fulfillment_center_id NOT IN (1, 2, 3, 7)
  AND it.issue_type = 'Ruptura';
