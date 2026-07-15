-- Passo 1: external table com strings brutas da planilha
CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.src_caixaria_raw`
(
  id_modelo STRING,
  caixaria  STRING,
  vazio     STRING,
  col4      STRING,
  col5      STRING
)
OPTIONS (
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1axXV-8mjz2izch5dTgGACyvZrEFHpNn8QXdtikJmea8/edit?gid=1287881795#gid=1287881795'],
  sheet_range  = 'Caixaria!A2:E',
  skip_leading_rows = 0
);

-- Passo 2: view com tipos corretos (remove vírgulas/espaços antes de castear)
CREATE OR REPLACE VIEW `shopper-performance-prod.operacao.curated_caixaria`
OPTIONS (description = 'Caixaria ideal por SKU. External table do Google Sheets.')
AS
SELECT
  SAFE_CAST(REGEXP_REPLACE(TRIM(id_modelo), r'[^0-9]', '') AS INT64) AS sku_id,
  SAFE_CAST(REGEXP_REPLACE(TRIM(caixaria),  r'[^0-9]', '') AS INT64) AS caixaria,
  vazio
FROM `shopper-performance-prod.operacao.src_caixaria_raw`
WHERE id_modelo IS NOT NULL
  AND TRIM(id_modelo) != '';
