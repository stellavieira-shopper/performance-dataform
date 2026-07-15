CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.src_afastamentos`
(
  Nome        STRING,
  MatrIcula   INT64,
  Motivo      STRING,
  Data_inicio DATE,
  Data_final  DATE
)
OPTIONS (
  description  = 'Afastamentos de colaboradores. External table do Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1F9dzbIUmahYUMJ0mIEnlSB27DtDiI9QpDUxZcY6jSAw/edit?gid=0#gid=0'],
  sheet_range  = 'AFASTAMENTOS!A2:E',
  skip_leading_rows = 0
);
