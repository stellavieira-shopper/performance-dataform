-- Lê de shopper-datalakehouse-qa.Ranking_Performance.pedidos_ifood
-- Recriar a cada semana via refresh_raws.py
CREATE OR REPLACE TABLE `shopper-performance-prod.darkstore.raw_base_turbos` AS
SELECT
  i.cod_pedido                                    AS order_code,
  CASE
    WHEN UPPER(i.tipo) IN ('TURBO', 'EXPRESS')                      THEN 'EXPRESS'
    WHEN UPPER(i.tipo) IN ('FAST_DELIVERY','FAST_DELIVERY_OVERLAP')  THEN 'FAST_DELIVERY'
    ELSE 'DEFAULT'
  END                                             AS modo_entrega,
  i.data                                          AS created_at,
  CASE p.fulfillment_center_id
    WHEN 6  THEN 'pamplona'        WHEN 8  THEN 'moema'
    WHEN 9  THEN 'pinheiros'       WHEN 10 THEN 'higienopolis'
    WHEN 11 THEN 'vila olimpia'    WHEN 12 THEN 'alto de pinheiros'
    WHEN 13 THEN 'barra funda'     WHEN 14 THEN 'morumbi'
    WHEN 15 THEN 'vila mariana'    WHEN 16 THEN 'brooklin'
    WHEN 17 THEN 'são caetano'     WHEN 18 THEN 'campinas'
    WHEN 19 THEN 'tatuapé'
    ELSE LOWER(TRIM(p.fulfillment_center))
  END                                             AS store_code
FROM `shopper-datalakehouse-qa.Ranking_Performance.pedidos_ifood` i
LEFT JOIN `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_n2` p
  ON i.cod_pedido = p.order_code
WHERE p.fulfillment_center_id NOT IN (1, 2, 3, 7)
   OR p.fulfillment_center_id IS NULL;
