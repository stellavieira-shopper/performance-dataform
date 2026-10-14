-- DDL: raw_pedidos_desconsiderar — pedidos excluídos manualmente do cálculo semanal
-- Projeto: shopper-performance-prod | Dataset: darkstore
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_pedidos_desconsiderar`
(
  order_code STRING,
  year_ref   INT64,
  week_ref   INT64,
  motivo     STRING
);
