-- ============================================================
-- SETUP COMPLETO + BACKFILL — shopper-performance-prod.darkstore
-- ============================================================
-- Rodar no BigQuery console (projeto: shopper-performance-prod)
-- Executar bloco a bloco ou como script multi-statement
-- ⚠️  raw_erros_clientes e organograma_bonificacao são Drive-linked
--     → criar separadamente via setup_raw_new_project.sql
-- ============================================================


-- ════════════════════════════════════════════════════════════
-- PARTE 1 — DDL: criação das tabelas
-- ════════════════════════════════════════════════════════════

-- ── raw: sku_classificacao ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_sku_classificacao`
(
  id_modelo       INT64,
  cod_produto     STRING,
  desc_produto    STRING,
  categoria_raw   STRING,
  tipo_sku        STRING
);

-- ── raw: pedidos_desconsiderar ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_pedidos_desconsiderar`
(
  order_code STRING,
  year_ref   INT64,
  week_ref   INT64,
  motivo     STRING
);

-- ── raw: bonificacao_faltas ───────────────────────────────────────────────────
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

-- ── raw: vel_ref_abastecimento ────────────────────────────────────────────────
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

-- ── raw: erros_clientes_extra ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_erros_clientes_extra`
(
  cod_pedido        STRING,
  data_entrega      STRING,
  erro              STRING,
  considerar        STRING,
  grave             STRING,
  responsabilidade  STRING,
  link_drive        STRING,
  produto           STRING,
  tratativa         STRING,
  valor_solicitacao STRING
);

-- ── raw: foto_desconto ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_foto_desconto`
(
  store_code   STRING,
  year_ref     INT64,
  week_ref     INT64,
  pct_desconto FLOAT64
);

-- ── raw: detratoras_perdas ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_detratoras_perdas`
(
  Data                 DATE,
  Cracha               STRING,
  Operador             STRING,
  Lancamentos_Erroneos INT64,
  Total_Lancamentos    INT64
);

-- ── raw: organograma_darks_ext ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.organograma_darks_ext`
(
  cracha STRING,
  mat    STRING,
  nome   STRING
);

-- ── raw: pedidos_ifood_cache ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.pedidos_ifood_cache`
(
  cod_pedido  STRING,
  tipo        STRING,
  data        DATE,
  ingested_at TIMESTAMP
);

-- ── raw: pedidos_lojinhas (View_Pedidos_Lojinhas do intraday) ─────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.pedidos_lojinhas`
(
  order_date                 DATE,
  delivery_date              DATE,
  loja                       STRING,
  fulfillment_center_id      INT64,
  status_pedido              STRING,
  order_code                 STRING,
  kdabra_order_id            INT64,
  tipo_de_pedido             STRING,
  status_sla                 STRING,
  sla_seconds                INT64,
  cycle_duration_seconds     INT64,
  tempo_para_iniciar_seconds INT64,
  inicio_picking             TIMESTAMP,
  fim_packing                TIMESTAMP,
  pedido_criado_em           TIMESTAMP,
  delivery_time_frame_start  STRING,
  delivery_time_frame_end    STRING,
  foto_url                   STRING,
  ingested_at                TIMESTAMP
)
PARTITION BY delivery_date;

-- ── int: pedidos_sla ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.int_pedidos_sla`
(
  store_code       STRING,
  year_ref         INT64,
  week_ref         INT64,
  cod_pedido       STRING,
  nome             STRING,
  turno_bucket     STRING,
  categoria_pedido STRING,
  sla_segundos     INT64,
  is_sla_5m_scope  BOOL,
  is_sla_5m        BOOL,
  mat              STRING
)
PARTITION BY RANGE_BUCKET(year_ref, GENERATE_ARRAY(2024, 2030, 1));

-- ── int: store_metrics ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.int_store_metrics`
(
  store_code           STRING,
  year_ref             INT64,
  week_ref             INT64,
  pedidos_total        INT64,
  pedidos_sla_scope    INT64,
  pedidos_dentro_sla   INT64,
  taxa_separacao_loja  FLOAT64,
  pedidos_completos    INT64,
  taxa_completo_loja   FLOAT64,
  pedidos_com_ruptura  INT64,
  rupturas_itens       INT64
)
PARTITION BY RANGE_BUCKET(year_ref, GENERATE_ARRAY(2024, 2030, 1));

-- ── int: person_metrics ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.int_person_metrics`
(
  store_code                STRING,
  year_ref                  INT64,
  week_ref                  INT64,
  nome                      STRING,
  turno_bucket              STRING,
  funcao_bucket             STRING,
  mat                       STRING,
  taxa_separacao_person     FLOAT64,
  taxa_completo_person      FLOAT64,
  rupturas_person           INT64,
  taxa_separacao_turno      FLOAT64,
  taxa_completo_turno       FLOAT64,
  rupturas_turno            INT64,
  taxa_separacao_loja       FLOAT64,
  taxa_completo_loja        FLOAT64,
  rupturas_loja             INT64,
  taxa_separacao_individual FLOAT64,
  taxa_completo_individual  FLOAT64,
  rupturas_count            INT64,
  erros_normais             INT64,
  erros_graves              INT64
)
PARTITION BY RANGE_BUCKET(year_ref, GENERATE_ARRAY(2024, 2030, 1));

-- ── int: abastecimento_bonus ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.int_abastecimento_bonus`
(
  store_code                       STRING,
  year_ref                         INT64,
  week_ref                         INT64,
  nome                             STRING,
  mat                              STRING,
  turno_bucket                     STRING,
  dias_no_gate                     INT64,
  score_individual_semana          FLOAT64,
  score_coletivo_semana            FLOAT64,
  nota_abastecimento_final         FLOAT64,
  pct_pagamento_tier_abastecimento FLOAT64
)
PARTITION BY RANGE_BUCKET(year_ref, GENERATE_ARRAY(2024, 2030, 1));

-- ── int: foto_gate ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.int_foto_gate`
(
  store_code     STRING,
  year_ref       INT64,
  week_ref       INT64,
  taxa_foto_loja FLOAT64,
  gate_foto_flag BOOL
)
PARTITION BY RANGE_BUCKET(year_ref, GENERATE_ARRAY(2024, 2030, 1));

-- ── mart: bonificacao ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.mart_bonificacao`
(
  store_code                         STRING,
  year_ref                           INT64,
  week_ref                           INT64,
  nome                               STRING,
  turno_bucket                       STRING,
  funcao_bucket                      STRING,
  mat                                STRING,
  assiduidade_any_flag               BOOL,
  gate_loja_80_flag                  BOOL,
  gate_foto_flag                     BOOL,
  taxa_separacao_individual          FLOAT64,
  taxa_separacao_loja                FLOAT64,
  taxa_completo_loja                 FLOAT64,
  taxa_foto_loja                     FLOAT64,
  rupturas_count                     INT64,
  faixa_salario                      FLOAT64,
  multiplo_separacao                 FLOAT64,
  multiplo_completo                  FLOAT64,
  valor_obtido_base                  FLOAT64,
  valor_obtido                       FLOAT64,
  desconto_ruptura                   FLOAT64,
  valor_final_pre_gate               FLOAT64,
  nota_abastecimento_final           FLOAT64,
  pct_pagamento_tier_abastecimento   FLOAT64,
  bolso_pedidos                      FLOAT64,
  bolso_abastecimento                FLOAT64,
  valor_bonus_pedidos_pre_gate       FLOAT64,
  valor_bonus_abastecimento_pre_gate FLOAT64,
  valor_final_bonus                  FLOAT64,
  erros_normais                      INT64,
  erros_graves                       INT64,
  desconto_erros                     FLOAT64,
  pct_desconto_foto                  FLOAT64,
  erros_perdas                       INT64,
  total_perdas                       INT64,
  taxa_perdas                        FLOAT64,
  desconto_perdas                    FLOAT64
)
PARTITION BY RANGE_BUCKET(year_ref, GENERATE_ARRAY(2024, 2030, 1));


-- ════════════════════════════════════════════════════════════
-- PARTE 2 — BACKFILL: copia dados históricos do QA
-- (rodar após criar as tabelas acima)
-- ════════════════════════════════════════════════════════════

-- ── 1–8. raw tables — CTAS espelha schema exato do QA (evita erro de colunas) ─
-- Se a tabela já existir com schema errado, o DROP garante recriação correta.

DROP TABLE IF EXISTS `shopper-performance-prod.darkstore.raw_sku_classificacao`;
CREATE TABLE `shopper-performance-prod.darkstore.raw_sku_classificacao` AS
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_sku_classificacao`;

DROP TABLE IF EXISTS `shopper-performance-prod.darkstore.raw_pedidos_desconsiderar`;
CREATE TABLE `shopper-performance-prod.darkstore.raw_pedidos_desconsiderar` AS
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_pedidos_desconsiderar`;

DROP TABLE IF EXISTS `shopper-performance-prod.darkstore.raw_bonificacao_faltas`;
CREATE TABLE `shopper-performance-prod.darkstore.raw_bonificacao_faltas` AS
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_bonificacao_faltas`;

DROP TABLE IF EXISTS `shopper-performance-prod.darkstore.raw_vel_ref_abastecimento`;
CREATE TABLE `shopper-performance-prod.darkstore.raw_vel_ref_abastecimento` AS
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_vel_ref_abastecimento`;

DROP TABLE IF EXISTS `shopper-performance-prod.darkstore.raw_erros_clientes_extra`;
CREATE TABLE `shopper-performance-prod.darkstore.raw_erros_clientes_extra` AS
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_erros_clientes_extra`;

DROP TABLE IF EXISTS `shopper-performance-prod.darkstore.raw_foto_desconto`;
CREATE TABLE `shopper-performance-prod.darkstore.raw_foto_desconto` AS
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_foto_desconto`;

DROP TABLE IF EXISTS `shopper-performance-prod.darkstore.raw_detratoras_perdas`;
CREATE TABLE `shopper-performance-prod.darkstore.raw_detratoras_perdas` AS
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_detratoras_perdas`;

DROP TABLE IF EXISTS `shopper-performance-prod.darkstore.organograma_darks_ext`;
CREATE TABLE `shopper-performance-prod.darkstore.organograma_darks_ext` AS
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.organograma_darks_ext`;

-- ── 9. int_pedidos_sla ────────────────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.int_pedidos_sla`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.int_pedidos_sla`;

-- ── 10. int_store_metrics ─────────────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.int_store_metrics`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.int_store_metrics`;

-- ── 11. int_person_metrics ────────────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.int_person_metrics`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.int_person_metrics`;

-- ── 12. int_abastecimento_bonus ───────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.int_abastecimento_bonus`
SELECT
  store_code, year_ref, week_ref, nome, mat, turno_bucket,
  COALESCE(dias_gate, 0)                          AS dias_no_gate,
  COALESCE(score_ind, 0.0)                        AS score_individual_semana,
  COALESCE(score_col, 0.0)                        AS score_coletivo_semana,
  COALESCE(nota_abastecimento_final, 0.0)         AS nota_abastecimento_final,
  COALESCE(pct_pagamento_tier_abastecimento, 0.0) AS pct_pagamento_tier_abastecimento
FROM `shopper-datalakehouse-qa.performance_darkstore.int_abastecimento_bonus`;

-- ── 13. int_foto_gate ─────────────────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.int_foto_gate`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.int_foto_gate`;

-- ── 14. mart_bonificacao ──────────────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.mart_bonificacao`
SELECT
  store_code, year_ref, week_ref, nome, turno_bucket, funcao_bucket, mat,
  assiduidade_any_flag, gate_loja_80_flag, gate_foto_flag,
  taxa_separacao_individual, taxa_separacao_loja, taxa_completo_loja,
  COALESCE(taxa_foto_loja, 1.0)                    AS taxa_foto_loja,
  rupturas_count,
  faixa_salario, multiplo_separacao, multiplo_completo, valor_obtido_base, valor_obtido,
  desconto_ruptura, valor_final_pre_gate, nota_abastecimento_final,
  pct_pagamento_tier_abastecimento,
  bolso_pedidos, bolso_abastecimento,
  valor_bonus_pedidos_pre_gate, valor_bonus_abastecimento_pre_gate,
  valor_final_bonus,
  COALESCE(erros_normais, 0)                       AS erros_normais,
  COALESCE(erros_graves, 0)                        AS erros_graves,
  COALESCE(desconto_erros, 0.0)                    AS desconto_erros,
  COALESCE(pct_desconto_foto, 0.0)                 AS pct_desconto_foto,
  COALESCE(erros_perdas, 0)                        AS erros_perdas,
  COALESCE(total_perdas, 0)                        AS total_perdas,
  COALESCE(taxa_perdas, 0.0)                       AS taxa_perdas,
  COALESCE(desconto_perdas, 0.0)                   AS desconto_perdas
FROM `shopper-datalakehouse-qa.performance_darkstore.mart_bonificacao`;

-- ── 15. pedidos_ifood_cache (intraday) ────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.pedidos_ifood_cache`
SELECT
  cod_pedido,
  tipo,
  data,
  CURRENT_TIMESTAMP() AS ingested_at
FROM `shopper-datalakehouse-qa.Ranking_Performance.pedidos_ifood_cache`;

-- ── 16. pedidos_lojinhas (View_Pedidos_Lojinhas) ─────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.pedidos_lojinhas`
SELECT
  order_date,
  delivery_date,
  loja,
  fulfillment_center_id,
  status_pedido,
  order_code,
  kdabra_order_id,
  tipo_de_pedido,
  status_sla,
  sla_seconds,
  cycle_duration_seconds,
  tempo_para_iniciar_seconds,
  inicio_picking,
  fim_packing,
  pedido_criado_em,
  delivery_time_frame_start,
  delivery_time_frame_end,
  foto_url,
  CURRENT_TIMESTAMP() AS ingested_at
FROM `shopper-datalakehouse-qa.Ranking_Performance.View_Pedidos_Lojinhas`;
