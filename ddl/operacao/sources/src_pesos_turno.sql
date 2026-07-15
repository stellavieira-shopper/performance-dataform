CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.src_pesos_turno`
(
  METRIC_DESCRIPTION STRING,
  METRIC_TYPE        STRING,
  FC1_MANHA          FLOAT64,
  FC1_TARDE          FLOAT64,
  FC1_NOITE          FLOAT64,
  FC2_MANHA          FLOAT64,
  FC2_TARDE          FLOAT64,
  FC2_INTERMEDIARIO  FLOAT64,
  FC2_NOITE          FLOAT64,
  FC3_MANHA          FLOAT64,
  FC3_TARDE          FLOAT64,
  FC3_NOITE          FLOAT64,
  DATA_INICIAL       DATE,
  DATA_FINAL         DATE
)
OPTIONS (
  description  = 'Pesos por turno e FC para cada métrica. External table do Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1R-CpFzAQu3Hn69v4Q3SO6d7pH3m3La0uWDHqNLSJjAo/edit?gid=1444521241#gid=1444521241'],
  sheet_range  = 'pesos_turno!A2:N',
  skip_leading_rows = 0
);
