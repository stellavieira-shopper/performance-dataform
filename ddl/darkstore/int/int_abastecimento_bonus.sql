-- DDL: int_abastecimento_bonus — score semanal de abastecimento por colaborador
-- Projeto: shopper-performance-prod | Dataset: darkstore
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.int_abastecimento_bonus`
(
  store_code                       STRING,
  year_ref                         INT64,
  week_ref                         INT64,
  nome                             STRING,
  mat                              STRING,
  turno_bucket                     STRING,
  dias_no_gate                     INT64,
  score_individual_semana          FLOAT64,
  score_coletivo_semana            FLOAT64,
  nota_abastecimento_final         FLOAT64,
  pct_pagamento_tier_abastecimento FLOAT64
)
PARTITION BY RANGE_BUCKET(year_ref, GENERATE_ARRAY(2024, 2030, 1));
