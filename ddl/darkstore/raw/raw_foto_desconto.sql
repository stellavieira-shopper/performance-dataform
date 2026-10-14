-- DDL: raw_foto_desconto — override manual de desconto de foto por loja/semana
-- Projeto: shopper-performance-prod | Dataset: darkstore
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_foto_desconto`
(
  store_code    STRING,
  year_ref      INT64,
  week_ref      INT64,
  pct_desconto  FLOAT64
);
