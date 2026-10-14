-- DDL: int_person_metrics — métricas por colaborador/semana
-- Projeto: shopper-performance-prod | Dataset: darkstore
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.int_person_metrics`
(
  store_code                STRING,
  year_ref                  INT64,
  week_ref                  INT64,
  nome                      STRING,
  turno_bucket              STRING,
  funcao_bucket             STRING,
  mat                       STRING,
  taxa_separacao_person     FLOAT64,
  taxa_completo_person      FLOAT64,
  rupturas_person           INT64,
  taxa_separacao_turno      FLOAT64,
  taxa_completo_turno       FLOAT64,
  rupturas_turno            INT64,
  taxa_separacao_loja       FLOAT64,
  taxa_completo_loja        FLOAT64,
  rupturas_loja             INT64,
  taxa_separacao_individual FLOAT64,
  taxa_completo_individual  FLOAT64,
  rupturas_count            INT64,
  erros_normais             INT64,
  erros_graves              INT64
)
PARTITION BY RANGE_BUCKET(year_ref, GENERATE_ARRAY(2024, 2030, 1));
