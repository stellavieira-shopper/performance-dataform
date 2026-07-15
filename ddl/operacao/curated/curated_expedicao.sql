CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.curated_expedicao`
(
  MATRICULA INT64,
  DATA      DATE,
  ROMANEIO  STRING,
  VOLUMES   STRING,
  E_SMD     BOOL
)
OPTIONS (
  description  = 'Expedição tratada com volumes por romaneio e flag SMD. External table do Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1dOW-CtDWStVwqGxIPb2dgJ4UX2pfkcE_5mti8gfw-vI/edit?gid=1207787385#gid=1207787385'],
  sheet_range  = 'Expedição 2.0!A2:E',
  skip_leading_rows = 0
);
