CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.curated_performance_perdas`
(
  Data                DATE,
  Data_Hora           STRING,
  Matricula           INT64,
  Nome                STRING,
  Cracha              STRING,
  Value               NUMERIC,
  Metric_Type         STRING,
  Descricao_Atividade STRING,
  FC                  STRING
)
OPTIONS (
  description  = 'Perdas consolidadas por colaborador. External table do Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1P5oy3W7N3AANFfoP6AoZKzcBE7_lvpfexlUC1ZSke-c/edit?gid=1208367035#gid=1208367035'],
  sheet_range  = 'CONSOLIDADO PERDAS GERAL!A02:I',
  skip_leading_rows = 0
);
