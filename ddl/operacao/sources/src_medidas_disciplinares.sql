CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.src_medidas_disciplinares`
(
  MATRICULA       INT64,
  NOME            STRING,
  AREA            STRING,
  SETOR           STRING,
  ATRIBUICAO      STRING,
  TURNO           STRING,
  UNIDADE         STRING,
  GRAU_DA_MEDIDA  STRING,
  MOTIVO          STRING,
  JUSTIFICATIVA   STRING,
  DATA_OCORRENCIA DATE,
  DATA_SUSPENSAO  DATE,
  VALIDADE        DATE,
  STATUS          STRING,
  APLICADA        BOOL,
  INDEVIDA        BOOL
)
OPTIONS (
  description  = 'Medidas disciplinares por colaborador. External table do Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1ILfz2bTTkbvqESwVKkRER-tebXaJqXH9ehj8fwzhmXw/edit?gid=0#gid=0'],
  sheet_range  = 'Medidas!A2:P',
  skip_leading_rows = 0
);
