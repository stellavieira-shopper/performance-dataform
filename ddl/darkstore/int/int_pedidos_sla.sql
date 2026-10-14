-- DDL: int_pedidos_sla — pedidos enriquecidos com categoria e SLA
-- Projeto: shopper-performance-prod | Dataset: darkstore
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.int_pedidos_sla`
(
  store_code       STRING,
  year_ref         INT64,
  week_ref         INT64,
  cod_pedido       STRING,
  nome             STRING,
  turno_bucket     STRING,
  categoria_pedido STRING,
  sla_segundos     INT64,
  is_sla_5m_scope  BOOL,
  is_sla_5m        BOOL,
  mat              STRING
)
PARTITION BY RANGE_BUCKET(year_ref, GENERATE_ARRAY(2024, 2030, 1));
