-- Schema vazio — popular rodando calibracao_vel_ref_abastecimento.sql
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_vel_ref_abastecimento`
(
  n_visitas            INT64,
  vel_ref_congelado    FLOAT64,
  vel_ref_flv          FLOAT64,
  vel_ref_mercearia    FLOAT64,
  seg_por_item_cong    FLOAT64,
  seg_por_item_flv     FLOAT64,
  seg_por_item_merc    FLOAT64,
  pct_classificado     FLOAT64,
  pct_cong             FLOAT64,
  pct_flv              FLOAT64,
  pct_merc             FLOAT64,
  total_itens          INT64,
  total_horas          FLOAT64
);
