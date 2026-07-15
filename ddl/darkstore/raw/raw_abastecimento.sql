-- VIEW — lê live de prod, sem refresh
-- Depende de: raw_sku_classificacao
-- Executar antes: DROP TABLE IF EXISTS `shopper-performance-prod.darkstore.raw_abastecimento`;
CREATE OR REPLACE VIEW `shopper-performance-prod.darkstore.raw_abastecimento` AS
WITH Operadores AS (
  SELECT visit_list_id, ANY_VALUE(operator_id) AS operator_id
  FROM `shopper-datalakehouse-prod.darkstores.wss_market_store_visit_list_operator_n2`
  GROUP BY visit_list_id
),
Itens AS (
  SELECT
    i.market_store_visit_list_id,
    COUNT(DISTINCT i.sku_id)                                                                      AS qtd_sku,
    SUM(CAST(i.input_qty AS INT64))                                                               AS qtd_itens,
    SUM(CASE WHEN COALESCE(c.tipo_sku,'mercearia')='congelado_refrigerado' THEN CAST(i.input_qty AS INT64) ELSE 0 END) AS itens_congelado,
    SUM(CASE WHEN COALESCE(c.tipo_sku,'mercearia')='flv'                   THEN CAST(i.input_qty AS INT64) ELSE 0 END) AS itens_flv,
    SUM(CASE WHEN COALESCE(c.tipo_sku,'mercearia')='mercearia'             THEN CAST(i.input_qty AS INT64) ELSE 0 END) AS itens_merc
  FROM `shopper-datalakehouse-prod.darkstores.wss_market_store_visit_list_items_n2` i
  LEFT JOIN `shopper-performance-prod.darkstore.raw_sku_classificacao` c
    ON SAFE_CAST(i.sku_id AS INT64) = c.id_modelo
  GROUP BY i.market_store_visit_list_id
),
StoreMap AS (
  SELECT
    market_store_name,
    partner_id AS fulfillment_center_id,
    CASE LOWER(TRIM(REGEXP_REPLACE(partner_name, r'(?i)^LJ\s+', '')))
      WHEN 'tatuape'     THEN 'tatuapé'
      WHEN 'sao caetano' THEN 'são caetano'
      ELSE LOWER(TRIM(REGEXP_REPLACE(partner_name, r'(?i)^LJ\s+', '')))
    END AS store_code
  FROM `shopper-datalakehouse-prod.darkstores.market_integration_stores_n3`
  WHERE partner_name LIKE 'LJ %'
)
SELECT
  EXTRACT(ISOYEAR FROM v.started_at)                             AS iso_year_ref,
  EXTRACT(ISOWEEK  FROM v.started_at)                            AS iso_week_ref,
  DATE(v.started_at)                                             AS data_ref,
  CASE
    WHEN TIME(v.started_at) >= TIME '06:00:00' AND TIME(v.started_at) < TIME '14:00:00' THEN 'MANHA'
    WHEN TIME(v.started_at) >= TIME '14:00:00' AND TIME(v.started_at) < TIME '22:00:00' THEN 'TARDE'
    ELSE 'NOITE'
  END                                                            AS turno,
  sm.store_code,
  v.market_store_name                                            AS store_name,
  u.user_name                                                    AS nome,
  CAST(op.operator_id AS STRING)                                 AS id_usuario,
  CAST(sm.fulfillment_center_id AS STRING)                       AS id_fulfillment_center,
  v.order_code,
  COALESCE(i.qtd_sku, 0)                                         AS qtd_sku,
  COALESCE(i.qtd_itens, 0)                                       AS qtd_itens,
  COALESCE(i.itens_congelado, 0)                                 AS itens_congelado,
  COALESCE(i.itens_flv, 0)                                       AS itens_flv,
  COALESCE(i.itens_merc, 0)                                      AS itens_merc,
  v.started_at                                                   AS started_dt,
  v.finished_at                                                  AS finished_dt,
  DATETIME_DIFF(v.finished_at, v.started_at, SECOND)            AS tempo_abastecimento_segundos
FROM `shopper-datalakehouse-prod.darkstores.wss_market_store_visit_list_n2` v
INNER JOIN StoreMap sm ON v.market_store_name = sm.market_store_name
LEFT JOIN Operadores op ON v.visit_id = op.visit_list_id
LEFT JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` u
  ON op.operator_id = u.user_id
LEFT JOIN Itens i ON v.visit_id = i.market_store_visit_list_id
WHERE v.visit_type_name        = 'RESTOCK'
  AND v.visit_list_status_name = 'FINALIZADO'
  AND TRIM(COALESCE(v.order_code, '')) != '';
