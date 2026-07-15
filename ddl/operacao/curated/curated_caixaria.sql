CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.curated_caixaria`
(
  sku_id   INT64,
  caixaria INT64,
  vazio    STRING,
  col4     STRING,
  col5     STRING
)
OPTIONS (
  description  = 'Caixaria ideal por SKU. External table do Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1axXV-8mjz2izch5dTgGACyvZrEFHpNn8QXdtikJmea8/edit?gid=1287881795#gid=1287881795'],
  sheet_range  = 'Caixaria!A2:E',
  skip_leading_rows = 0
);
