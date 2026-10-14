-- DDL: pedidos_ifood_cache — cache de classificação de pedidos iFood (tipo_de_pedido)
-- Projeto: shopper-performance-prod | Dataset: darkstore
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.pedidos_ifood_cache`
(
  cod_pedido      STRING,
  tipo            STRING,
  data            DATE,
  ingested_at     TIMESTAMP
);
