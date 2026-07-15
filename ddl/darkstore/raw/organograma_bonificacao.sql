CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.darkstore.organograma_bonificacao`
(
  mat   INT64,
  nome  STRING,
  dark  STRING,
  cargo STRING,
  turno STRING,
  QTD   INT64,
  Obs   STRING
)
OPTIONS (
  format            = 'GOOGLE_SHEETS',
  uris              = ['https://docs.google.com/spreadsheets/d/1auKP9YvHOXcBFuq_fJVcQck_eIUK5rKdM48CBevDE8M'],
  sheet_range       = 'Organograma',
  skip_leading_rows = 1
);
