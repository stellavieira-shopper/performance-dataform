-- DDL: int_foto_gate — gate de foto por loja/semana
-- Projeto: shopper-performance-prod | Dataset: darkstore
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.int_foto_gate`
(
  store_code      STRING,
  year_ref        INT64,
  week_ref        INT64,
  taxa_foto_loja  FLOAT64,
  gate_foto_flag  BOOL
)
PARTITION BY RANGE_BUCKET(year_ref, GENERATE_ARRAY(2024, 2030, 1));
