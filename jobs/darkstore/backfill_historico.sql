-- ============================================================
-- BACKFILL HISTÓRICO — darkstore QA → shopper-performance-prod
-- ============================================================
-- Copia todos os dados históricos do dataset de origem
-- (shopper-datalakehouse-qa.performance_darkstore) para o novo projeto.
--
-- Executar UMA VEZ, na ordem abaixo.
-- Usar: python scripts/run_bq_query.py jobs/darkstore/backfill_historico.sql
--       --project shopper-performance-prod
--
-- ⚠️  raw_erros_clientes e raw_bonificacao_cargos são Drive-linked:
--     não são copiadas aqui — recriar via ddl/darkstore/raw/setup_raw_new_project.sql
-- ============================================================


-- ── 1. raw_sku_classificacao ──────────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.raw_sku_classificacao`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_sku_classificacao`;


-- ── 2. raw_pedidos_desconsiderar ─────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.raw_pedidos_desconsiderar`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_pedidos_desconsiderar`;


-- ── 3. raw_bonificacao_faltas ─────────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.raw_bonificacao_faltas`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_bonificacao_faltas`;


-- ── 4. raw_vel_ref_abastecimento ──────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.raw_vel_ref_abastecimento`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_vel_ref_abastecimento`;


-- ── 5. raw_erros_clientes_extra ───────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.raw_erros_clientes_extra`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_erros_clientes_extra`;


-- ── 6. raw_foto_desconto ──────────────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.raw_foto_desconto`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_foto_desconto`;


-- ── 7. raw_detratoras_perdas ──────────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.raw_detratoras_perdas`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.raw_detratoras_perdas`;


-- ── 8. organograma_darks_ext ──────────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.organograma_darks_ext`
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
  -- colunas disponíveis no QA; preenche com 0 se ausentes
  COALESCE(dias_gate, 0)                        AS dias_no_gate,
  COALESCE(score_ind, 0.0)                      AS score_individual_semana,
  COALESCE(score_col, 0.0)                      AS score_coletivo_semana,
  COALESCE(nota_abastecimento_final, 0.0)       AS nota_abastecimento_final,
  COALESCE(pct_pagamento_tier_abastecimento, 0.0) AS pct_pagamento_tier_abastecimento
FROM `shopper-datalakehouse-qa.performance_darkstore.int_abastecimento_bonus`;


-- ── 13. int_foto_gate ─────────────────────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.int_foto_gate`
SELECT * FROM `shopper-datalakehouse-qa.performance_darkstore.int_foto_gate`;


-- ── 14. mart_bonificacao ──────────────────────────────────────────────────────
-- Nota: colunas pct_desconto_foto, erros_perdas, total_perdas, taxa_perdas,
-- desconto_perdas foram adicionadas depois — se ausentes no QA, usa 0/NULL.
INSERT INTO `shopper-performance-prod.darkstore.mart_bonificacao`
SELECT
  store_code, year_ref, week_ref, nome, turno_bucket, funcao_bucket, mat,
  assiduidade_any_flag, gate_loja_80_flag, gate_foto_flag,
  taxa_separacao_individual, taxa_separacao_loja, taxa_completo_loja,
  COALESCE(taxa_foto_loja, 1.0)              AS taxa_foto_loja,
  rupturas_count,
  faixa_salario, multiplo_separacao, multiplo_completo, valor_obtido_base, valor_obtido,
  desconto_ruptura, valor_final_pre_gate, nota_abastecimento_final,
  pct_pagamento_tier_abastecimento,
  bolso_pedidos, bolso_abastecimento,
  valor_bonus_pedidos_pre_gate, valor_bonus_abastecimento_pre_gate,
  valor_final_bonus,
  COALESCE(erros_normais, 0)                 AS erros_normais,
  COALESCE(erros_graves, 0)                  AS erros_graves,
  COALESCE(desconto_erros, 0.0)              AS desconto_erros,
  COALESCE(pct_desconto_foto, 0.0)           AS pct_desconto_foto,
  COALESCE(erros_perdas, 0)                  AS erros_perdas,
  COALESCE(total_perdas, 0)                  AS total_perdas,
  COALESCE(taxa_perdas, 0.0)                 AS taxa_perdas,
  COALESCE(desconto_perdas, 0.0)             AS desconto_perdas
FROM `shopper-datalakehouse-qa.performance_darkstore.mart_bonificacao`;


-- ── 15. pedidos_ifood_cache (intraday) ────────────────────────────────────────
INSERT INTO `shopper-performance-prod.darkstore.pedidos_ifood_cache`
SELECT
  cod_pedido,
  tipo,
  data,
  CURRENT_TIMESTAMP() AS ingested_at
FROM `shopper-datalakehouse-qa.Ranking_Performance.pedidos_ifood_cache`;


-- ── 16. pedidos_lojinhas (View_Pedidos_Lojinhas do intraday) ─────────────────
-- Snapshot histórico da view do intraday — apenas colunas disponíveis na view.
-- O campo ingested_at marca quando foi feita a cópia.
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
