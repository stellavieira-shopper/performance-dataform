-- PASSO 4 — int_store_metrics
-- Substitua [YEAR_REF] e [WEEK_REF] antes de rodar

DELETE FROM `shopper-performance-prod.darkstore.int_store_metrics`
WHERE year_ref = [YEAR_REF] AND week_ref = [WEEK_REF];

INSERT INTO `shopper-performance-prod.darkstore.int_store_metrics`
WITH rupturas_pedidos AS (
  SELECT DISTINCT cod_pedido
  FROM `shopper-performance-prod.darkstore.raw_rupturas`
  WHERE issue_type = '2' AND resolved_at IS NOT NULL
),
rupturas_itens_raw AS (
  SELECT DISTINCT cod_pedido, TRIM(COALESCE(cod_produto, '')) AS cod_produto
  FROM `shopper-performance-prod.darkstore.raw_rupturas`
  WHERE issue_type = '2' AND resolved_at IS NOT NULL
    AND TRIM(COALESCE(cod_produto, '')) <> ''
),
pedidos AS (
  SELECT p.store_code, p.year_ref, p.week_ref, p.cod_pedido,
    p.is_sla_5m_scope, p.is_sla_5m,
    (rp.cod_pedido IS NOT NULL) AS has_ruptura
  FROM `shopper-performance-prod.darkstore.int_pedidos_sla` p
  LEFT JOIN rupturas_pedidos rp ON p.cod_pedido = rp.cod_pedido
  WHERE p.year_ref = [YEAR_REF] AND p.week_ref = [WEEK_REF]
),
rupturas_itens_loja AS (
  SELECT p.store_code,
    COUNT(DISTINCT CONCAT(ri.cod_pedido, '|', ri.cod_produto)) AS rupturas_itens
  FROM `shopper-performance-prod.darkstore.int_pedidos_sla` p
  INNER JOIN rupturas_itens_raw ri ON p.cod_pedido = ri.cod_pedido
  WHERE p.year_ref = [YEAR_REF] AND p.week_ref = [WEEK_REF]
  GROUP BY p.store_code
),
base AS (
  SELECT store_code, year_ref, week_ref,
    COUNT(*)                                              AS pedidos_total,
    COUNTIF(is_sla_5m_scope)                             AS pedidos_sla_scope,
    COUNTIF(is_sla_5m)                                   AS pedidos_dentro_sla,
    SAFE_DIVIDE(COUNTIF(is_sla_5m), NULLIF(COUNTIF(is_sla_5m_scope),0)) AS taxa_separacao_loja,
    COUNTIF(NOT has_ruptura)                             AS pedidos_completos,
    SAFE_DIVIDE(COUNTIF(NOT has_ruptura), COUNT(*))      AS taxa_completo_loja,
    COUNTIF(has_ruptura)                                 AS pedidos_com_ruptura
  FROM pedidos GROUP BY 1,2,3
)
SELECT
  b.store_code, b.year_ref, b.week_ref,
  b.pedidos_total, b.pedidos_sla_scope, b.pedidos_dentro_sla,
  b.taxa_separacao_loja, b.pedidos_completos, b.taxa_completo_loja,
  b.pedidos_com_ruptura,
  COALESCE(ril.rupturas_itens, 0) AS rupturas_itens
FROM base b
LEFT JOIN rupturas_itens_loja ril ON b.store_code = ril.store_code
