CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.curated_detratoras_stock`
(
  DATA           DATE,
  MATRICULA      INT64,
  FC             STRING,
  NOME           STRING,
  LOTE           STRING,
  DATA_MOV       STRING,
  CODIGO         STRING,
  PRODUTO        STRING,
  QTD            STRING,
  ATIVIDADE      STRING,
  QUEM_VERIFICOU STRING,
  DESC_ERRO      STRING,
  PROVA_ERRO     STRING,
  IMPACTO_ERRO   STRING,
  TURNO          STRING,
  AREA           STRING,
  SUBAREA        STRING,
  GESTOR         STRING,
  RUPTURA_SUB    STRING
)
OPTIONS (
  description  = 'Detratoras de gestão de estoque por colaborador. External table do Google Sheets (aba BASE).',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1lJUFqVyuK-7uqAD2EdhoTO-QmcPkq_1MW3GUIk9iUmc/edit?gid=0#gid=0'],
  sheet_range  = 'BASE!A194:T',
  skip_leading_rows = 0
);
