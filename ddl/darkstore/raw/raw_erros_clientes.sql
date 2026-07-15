CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.darkstore.raw_erros_clientes`
(
  cod_pedido        STRING OPTIONS (description = 'Código do Pedido'),
  data_entrega      STRING OPTIONS (description = 'Data entrega'),
  erro              STRING OPTIONS (description = 'Tipo de Erro'),
  considerar        STRING OPTIONS (description = 'Considerar?'),
  grave             STRING OPTIONS (description = 'Grave'),
  responsabilidade  STRING OPTIONS (description = 'Responsabilidade'),
  link_drive        STRING OPTIONS (description = 'Link Drive'),
  produto           STRING OPTIONS (description = 'Produto'),
  tratativa         STRING OPTIONS (description = 'Tratativa'),
  valor_solicitacao STRING OPTIONS (description = 'Valor da Solicitação')
)
OPTIONS (
  format            = 'GOOGLE_SHEETS',
  uris              = ['https://docs.google.com/spreadsheets/d/1FVFLC5W-pFg3facSgBhWzilY9-Lhrwgx8MAiLMUIwVU/edit'],
  skip_leading_rows = 1
);
