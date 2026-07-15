-- Schema vazio — popular rodando rodar_assiduidade.py
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_bonificacao_faltas`
(
  store_code           STRING,
  nome                 STRING,
  mat                  STRING,
  year_ref             INT64,
  week_ref             INT64,
  periodo_inicio       DATE,
  periodo_fim          DATE,
  assiduidade_any_flag BOOL,
  faltas_num           INT64,
  atestados_num        INT64,
  advertencias_num     INT64,
  suspensoes_num       INT64,
  motivo               STRING,
  tem_direito          STRING
);
