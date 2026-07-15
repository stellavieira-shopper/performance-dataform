CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.src_organograma`
(
  MATRICULA  INT64,
  NOME       STRING,
  AREA       STRING,
  SETOR      STRING,
  ATRIBUICAO STRING,
  TURNO      STRING,
  CRACHA     STRING,
  ARMARIO    STRING,
  HORARIO    STRING,
  GESTOR     STRING,
  FOLGA_FIXA STRING,
  FC         STRING,
  DOM        STRING,
  DATA_ADM   DATE
)
OPTIONS (
  description  = 'Organograma de colaboradores. External table do Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1dOW-CtDWStVwqGxIPb2dgJ4UX2pfkcE_5mti8gfw-vI/edit?gid=0#gid=0'],
  sheet_range  = 'Organograma!A1:N',
  skip_leading_rows = 0
);
