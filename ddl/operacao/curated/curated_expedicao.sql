CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.Ranking_Performance.expedicao_raw`
(
  matricula  INT64,
  romaneio   STRING,
  bipagem_1  TIMESTAMP,
  bipagem_2  TIMESTAMP,
  data       DATE
)
OPTIONS (
  description  = 'Expedição raw — Atividades por Romaneio da planilha Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1cJ73I0ySUaY_udx7bNpMGiN-xhxPuAOmwJDAOQVtGIc/edit'],
  sheet_range  = 'Atividades por Romaneio!A2:E',
  skip_leading_rows = 1
);
