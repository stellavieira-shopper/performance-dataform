CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.operacao.src_assiduidade`
(
  Nome                STRING,
  Matricula           INT64,
  Cargo               STRING,
  Data_de_Adm         DATE,
  Localizacao         STRING,
  Area                STRING,
  Setor               STRING,
  Atribuicao          STRING,
  Turno               STRING,
  Periodo             STRING,
  Horas_Trabalhadas   STRING,
  Afastamentos        STRING,
  Ausencias           STRING,
  Direito_a_Premiacao STRING,
  data_inicio_periodo DATE
)
OPTIONS (
  description  = 'Controle de assiduidade por colaborador. External table do Google Sheets.',
  format       = 'GOOGLE_SHEETS',
  uris         = ['https://docs.google.com/spreadsheets/d/1VoNo2TgxqOzLRIhTzB1BR_d5rK328yVf1rpdrnADC-8/edit?gid=0#gid=0'],
  sheet_range  = 'Assiduidade!A2:O',
  skip_leading_rows = 0
);
