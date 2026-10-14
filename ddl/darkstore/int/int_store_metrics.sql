-- DDL: int_store_metrics — métricas agregadas por loja/semana
-- Projeto: shopper-performance-prod | Dataset: darkstore
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.int_store_metrics`
(
  store_code           STRING,
  year_ref             INT64,
  week_ref             INT64,
  pedidos_total        INT64,
  pedidos_sla_scope    INT64,
  pedidos_dentro_sla   INT64,
  taxa_separacao_loja  FLOAT64,
  pedidos_completos    INT64,
  taxa_completo_loja   FLOAT64,
  pedidos_com_ruptura  INT64,
  rupturas_itens       INT64
)
PARTITION BY RANGE_BUCKET(year_ref, GENERATE_ARRAY(2024, 2030, 1));
