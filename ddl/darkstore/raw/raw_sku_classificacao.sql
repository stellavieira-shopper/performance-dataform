-- Tabela estática — importar dados do projeto origem:
-- INSERT INTO `shopper-performance-prod.darkstore.raw_sku_classificacao`
-- SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_sku_classificacao`
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_sku_classificacao`
(
  id_modelo       INT64,
  cod_produto     STRING,
  desc_produto    STRING,
  categoria_raw   STRING,
  tipo_sku        STRING
);
