-- DDL: raw_erros_clientes_extra — erros de clientes via incidentes (complemento da planilha Drive)
-- Projeto: shopper-performance-prod | Dataset: darkstore
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_erros_clientes_extra`
(
  cod_pedido        STRING,
  data_entrega      STRING,
  erro              STRING,
  considerar        STRING,
  grave             STRING,
  responsabilidade  STRING,
  link_drive        STRING,
  produto           STRING,
  tratativa         STRING,
  valor_solicitacao STRING
);
