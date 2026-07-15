-- Passo 1: external table com o schema bruto da planilha
CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.src_caixaria_raw`
(
  id_modelo STRING,
  caixaria  STRING,
  vazio     STRING,
  col4      STRING,
  col5      STRING
)
OPTIONS (
  description  = 'Raw caixaria do Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1axXV-8mjz2izch5dTgGACyvZrEFHpNn8QXdtikJmea8/edit?gid=1287881795#gid=1287881795'],
  sheet_range  = 'Caixaria!A2:E',
  skip_leading_rows = 0
);

-- Passo 2: view com colunas tipadas (sku_id + caixaria)
CREATE OR REPLACE VIEW `shopper-performance-prod.operacao.curated_caixaria`
OPTIONS (description = 'Caixaria ideal por SKU. Lê da external table src_caixaria_raw.')
AS
SELECT
  SAFE_CAST(id_modelo AS INT64) AS sku_id,
  SAFE_CAST(caixaria  AS INT64) AS caixaria,
  vazio
FROM `shopper-performance-prod.operacao.src_caixaria_raw`
WHERE id_modelo IS NOT NULL;
