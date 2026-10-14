-- PASSO 5 — int_person_metrics
-- Substitua [YEAR_REF] e [WEEK_REF] antes de rodar
-- ⚠️ raw_erros_clientes é Drive-linked: rodar via run_darkstore_week.py (credencial Drive)

DELETE FROM `shopper-performance-prod.darkstore.int_person_metrics`
WHERE year_ref = [YEAR_REF] AND week_ref = [WEEK_REF];

INSERT INTO `shopper-performance-prod.darkstore.int_person_metrics`
WITH rupturas AS (
  SELECT DISTINCT cod_pedido
  FROM `shopper-performance-prod.darkstore.raw_rupturas`
  WHERE issue_type='2' AND resolved_at IS NOT NULL
),
erros AS (
  SELECT DISTINCT cod_pedido, 'normal' AS tipo_erro
  FROM `shopper-performance-prod.darkstore.raw_erros_clientes`
  WHERE TRIM(COALESCE(cod_pedido,'')) != ''
    AND UPPER(TRIM(COALESCE(considerar,''))) = 'CONSIDERAR'
  UNION DISTINCT
  SELECT DISTINCT cod_pedido, 'normal' AS tipo_erro
  FROM `shopper-performance-prod.darkstore.raw_erros_clientes_extra`
  WHERE TRIM(COALESCE(cod_pedido,'')) != ''
    AND UPPER(TRIM(COALESCE(considerar,''))) = 'CONSIDERAR'
),
pedidos AS (
  SELECT p.store_code, p.year_ref, p.week_ref, p.nome, p.mat, p.turno_bucket, p.cod_pedido,
    p.is_sla_5m_scope, p.is_sla_5m,
    (r.cod_pedido IS NOT NULL) AS has_ruptura
  FROM `shopper-performance-prod.darkstore.int_pedidos_sla` p
  LEFT JOIN rupturas r ON p.cod_pedido = r.cod_pedido
  WHERE p.year_ref = [YEAR_REF] AND p.week_ref = [WEEK_REF]
),
person_m AS (
  SELECT store_code, year_ref, week_ref, nome, mat,
    COUNTIF(is_sla_5m_scope) AS sla_scope_person,
    COUNTIF(is_sla_5m) AS sla_ok_person,
    SAFE_DIVIDE(COUNTIF(is_sla_5m), NULLIF(COUNTIF(is_sla_5m_scope),0)) AS taxa_separacao_person,
    COUNTIF(NOT has_ruptura) AS completos_person,
    SAFE_DIVIDE(COUNTIF(NOT has_ruptura), COUNT(*)) AS taxa_completo_person,
    COUNTIF(has_ruptura) AS rupturas_person
  FROM pedidos GROUP BY 1,2,3,4,5
),
turno_m AS (
  SELECT store_code, year_ref, week_ref, turno_bucket,
    COUNTIF(is_sla_5m_scope) AS sla_scope_turno,
    COUNTIF(is_sla_5m) AS sla_ok_turno,
    SAFE_DIVIDE(COUNTIF(is_sla_5m), NULLIF(COUNTIF(is_sla_5m_scope),0)) AS taxa_separacao_turno,
    COUNTIF(NOT has_ruptura) AS completos_turno,
    SAFE_DIVIDE(COUNTIF(NOT has_ruptura), COUNT(*)) AS taxa_completo_turno,
    COUNTIF(has_ruptura) AS rupturas_turno
  FROM pedidos GROUP BY 1,2,3,4
),
roster AS (
  SELECT REGEXP_REPLACE(LOWER(TRIM(NORMALIZE_AND_CASEFOLD(setor, NFKD))), r'\pM', '') AS store_code,
    UPPER(TRIM(nome)) AS nome,
    CASE UPPER(TRIM(turno)) WHEN 'MANHÃ' THEN 'MANHA' ELSE UPPER(TRIM(turno)) END AS turno_bucket,
    mat,
    CASE
      WHEN REGEXP_CONTAINS(UPPER(NORMALIZE_AND_CASEFOLD(COALESCE(atribui_o,fun_o,''),NFKD)),r'SUPERVISOR') THEN 'SUPERVISOR'
      WHEN REGEXP_CONTAINS(UPPER(NORMALIZE_AND_CASEFOLD(COALESCE(atribui_o,fun_o,''),NFKD)),r'TEAM\s*L')  THEN 'TEAM_LIDER'
      WHEN REGEXP_CONTAINS(UPPER(NORMALIZE_AND_CASEFOLD(COALESCE(atribui_o,fun_o,''),NFKD)),r'SEPAR|OPERADOR') THEN 'OPERADOR'
      ELSE NULL
    END AS funcao_bucket,
    ROW_NUMBER() OVER (
      PARTITION BY LOWER(TRIM(setor)), UPPER(TRIM(nome))
      ORDER BY SAFE_CAST(mat AS INT64) DESC NULLS LAST
    ) AS rn
  FROM `shopper-performance-prod.darkstore.raw_bonificacao_cargos`
  WHERE TRIM(COALESCE(nome,''))!='' AND UPPER(TRIM(fun_o)) NOT IN ('APRENDIZ','')
),
roster_dedup AS (SELECT * FROM roster WHERE rn=1 AND funcao_bucket IS NOT NULL),
erros_person AS (
  SELECT
    p.store_code, p.year_ref, p.week_ref, p.mat,
    COUNTIF(e.tipo_erro = 'normal') AS erros_normais,
    COUNTIF(e.tipo_erro = 'grave')  AS erros_graves
  FROM `shopper-performance-prod.darkstore.int_pedidos_sla` p
  INNER JOIN erros e ON p.cod_pedido = e.cod_pedido
  WHERE p.year_ref = [YEAR_REF] AND p.week_ref = [WEEK_REF]
  GROUP BY 1, 2, 3, 4
)
SELECT
  pm.store_code, pm.year_ref, pm.week_ref,
  pm.nome, r.turno_bucket, r.funcao_bucket, r.mat,
  pm.taxa_separacao_person, pm.taxa_completo_person, pm.rupturas_person,
  tm.taxa_separacao_turno, tm.taxa_completo_turno, tm.rupturas_turno,
  sm.taxa_separacao_loja, sm.taxa_completo_loja,
  COALESCE(sm.rupturas_itens, 0) AS rupturas_loja,
  CASE r.funcao_bucket
    WHEN 'SUPERVISOR' THEN sm.taxa_separacao_loja
    WHEN 'TEAM_LIDER' THEN tm.taxa_separacao_turno
    ELSE pm.taxa_separacao_person
  END AS taxa_separacao_individual,
  CASE r.funcao_bucket
    WHEN 'SUPERVISOR' THEN sm.taxa_completo_loja
    WHEN 'TEAM_LIDER' THEN tm.taxa_completo_turno
    ELSE pm.taxa_completo_person
  END AS taxa_completo_individual,
  COALESCE(sm.rupturas_itens, 0) AS rupturas_count,
  COALESCE(ep.erros_normais, 0) AS erros_normais,
  COALESCE(ep.erros_graves,  0) AS erros_graves
FROM person_m pm
INNER JOIN roster_dedup r ON pm.store_code=r.store_code AND pm.mat=r.mat
LEFT JOIN turno_m tm
  ON pm.store_code=tm.store_code AND pm.year_ref=tm.year_ref
 AND pm.week_ref=tm.week_ref AND r.turno_bucket=tm.turno_bucket
LEFT JOIN `shopper-performance-prod.darkstore.int_store_metrics` sm
  ON pm.store_code=sm.store_code AND pm.year_ref=sm.year_ref AND pm.week_ref=sm.week_ref
LEFT JOIN erros_person ep
  ON pm.store_code=ep.store_code AND pm.year_ref=ep.year_ref AND pm.week_ref=ep.week_ref AND pm.mat=ep.mat
WHERE r.funcao_bucket IS NOT NULL
