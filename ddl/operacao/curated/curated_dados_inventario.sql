CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.curated_dados_inventario`
(
  Data               DATE,
  cod_matricula      INT64,
  qtd_inventario     FLOAT64,
  metric_description STRING,
  metric_type        STRING
)
OPTIONS (
  description  = 'Dados de inventário por colaborador. External table do Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1dOW-CtDWStVwqGxIPb2dgJ4UX2pfkcE_5mti8gfw-vI/edit#gid=681218563'],
  sheet_range  = 'Inventário',
  skip_leading_rows = 0
);
