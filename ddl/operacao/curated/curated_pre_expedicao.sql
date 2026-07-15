CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.curated_pre_expedicao`
(
  Data                 DATE,
  NOME                 STRING,
  Matricula            INT64,
  Qtd_pedidos_mapeados INT64,
  metric_type          STRING
)
OPTIONS (
  description  = 'Pré-expedição — pedidos mapeados por colaborador. External table do Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1dOW-CtDWStVwqGxIPb2dgJ4UX2pfkcE_5mti8gfw-vI/edit?gid=1471731246#gid=1471731246'],
  sheet_range  = 'Pré-Expedição!A2:E',
  skip_leading_rows = 0
);
