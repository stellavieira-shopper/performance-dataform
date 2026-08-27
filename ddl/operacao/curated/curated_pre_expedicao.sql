CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.Ranking_Performance.pre_expedicao_raw`
(
  matricula  INT64,
  nome       STRING,
  cage       STRING,
  data_hora  TIMESTAMP,
  data       DATE
)
OPTIONS (
  description  = 'Pré-expedição raw — Pedidos Mapeados da planilha Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1YqPaDGKeZelm9w0RKZPo1JVVwy9cEyc031kgIxbe6OQ/edit'],
  sheet_range  = 'Pedidos Mapeados!A3:E',
  skip_leading_rows = 1
);
