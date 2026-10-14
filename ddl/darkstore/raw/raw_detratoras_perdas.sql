-- DDL: raw_detratoras_perdas — planilha RC de detratoras de perdas
-- Projeto: shopper-performance-prod | Dataset: darkstore
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_detratoras_perdas`
(
  Data                 DATE,
  Cracha               STRING,
  Operador             STRING,
  Lancamentos_Erroneos INT64,
  Total_Lancamentos    INT64
);
