-- PASSO 6 — int_abastecimento_bonus (Metodologia v0.3 — binário por dia)
-- Substitua [YEAR_REF], [WEEK_REF], [DATE_INI] e [DATE_FIM] antes de rodar
-- ⚠️ Só executar se raw_abastecimento tiver dados para a semana

DELETE FROM `shopper-performance-prod.darkstore.int_abastecimento_bonus`
WHERE year_ref = [YEAR_REF] AND week_ref = [WEEK_REF];

INSERT INTO `shopper-performance-prod.darkstore.int_abastecimento_bonus`
WITH
vel AS (SELECT 284.0 AS cong, 162.0 AS flv, 402.0 AS merc),

roster AS (
  SELECT
    REGEXP_REPLACE(LOWER(TRIM(NORMALIZE_AND_CASEFOLD(setor, NFKD))), r'\pM', '') AS store_code,
    UPPER(TRIM(nome)) AS nome,
    mat,
    CASE UPPER(TRIM(turno)) WHEN 'MANHÃ' THEN 'MANHA' ELSE UPPER(TRIM(turno)) END AS turno_bucket,
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

store_map AS (
  SELECT
    market_store_name,
    CASE partner_name
      WHEN 'PR - STRESSER'  THEN 'juveve curitiba'
      WHEN 'PR - REPUBLICA' THEN 'agua verde curitiba'
      WHEN 'PR - RODOVIA'   THEN 'mossungue curitiba'
      WHEN 'DF - SIA NORTE'      THEN 'brasilia sia norte'
      WHEN 'DF - AGUAS CLARAS'   THEN 'brasilia aguas claras'
      WHEN 'GO - ALTO DA GLORIA' THEN 'goiania alto da gloria'
      WHEN 'GO - SETOR BUENO'    THEN 'goiania setor bueno'
      WHEN 'DF - ASA SUL'        THEN 'brasilia asa sul'
      WHEN 'DF - ASA NORTE'      THEN 'brasilia asa norte'
      ELSE REGEXP_REPLACE(LOWER(TRIM(NORMALIZE_AND_CASEFOLD(
        CASE LOWER(TRIM(REGEXP_REPLACE(partner_name, r'(?i)^LJ\s+', '')))
          WHEN 'tatupe' THEN 'tatuape'
          ELSE LOWER(TRIM(REGEXP_REPLACE(partner_name, r'(?i)^LJ\s+', '')))
        END
      , NFKD))), r'\pM', '')
    END AS store_code
  FROM `shopper-datalakehouse-prod.darkstores.market_integration_stores_n3`
  WHERE partner_name LIKE 'LJ %'
    OR partner_name IN ('PR - STRESSER', 'PR - REPUBLICA', 'PR - RODOVIA',
                        'DF - SIA NORTE', 'DF - AGUAS CLARAS', 'GO - ALTO DA GLORIA',
                        'GO - SETOR BUENO', 'DF - ASA SUL', 'DF - ASA NORTE')
),

real_hrs_pessoa AS (
  SELECT
    sm.store_code,
    UPPER(TRIM(u.user_name))                        AS nome,
    CAST(u.registration_number AS STRING)           AS mat,
    DATE(v.started_at)                              AS data_ref,
    SUM(DATETIME_DIFF(v.finished_at, v.started_at, SECOND)) / 3600.0 AS real_hrs
  FROM `shopper-datalakehouse-prod.darkstores.wss_market_store_visit_list_n2` v
  INNER JOIN store_map sm ON v.market_store_name = sm.market_store_name
  INNER JOIN `shopper-datalakehouse-prod.darkstores.wss_market_store_visit_list_operator_n2` op
    ON v.visit_id = op.visit_list_id
  INNER JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` u
    ON op.operator_id = u.user_id
  WHERE v.visit_type_name        = 'RESTOCK'
    AND v.visit_list_status_name = 'FINALIZADO'
    AND TRIM(COALESCE(v.order_code, '')) != ''
    AND (TIME(v.started_at) >= TIME '22:00:00' OR TIME(v.started_at) < TIME '06:00:00')
    AND DATE(v.started_at) BETWEEN '[DATE_INI]' AND '[DATE_FIM]'
    AND v.finished_at > v.started_at
    AND DATETIME_DIFF(v.finished_at, v.started_at, SECOND) > 60
  GROUP BY 1, 2, 3, 4
),

itens_pessoa_dia AS (
  SELECT
    sm.store_code,
    UPPER(TRIM(u.user_name))                                AS nome,
    CAST(u.registration_number AS STRING)                   AS mat,
    DATE(v.started_at)                                      AS data_ref,
    SUM(CASE WHEN COALESCE(c.tipo_sku,'mercearia')='congelado_refrigerado'
             THEN CAST(i.input_qty AS INT64) ELSE 0 END)   AS itens_cong,
    SUM(CASE WHEN COALESCE(c.tipo_sku,'mercearia')='flv'
             THEN CAST(i.input_qty AS INT64) ELSE 0 END)   AS itens_flv,
    SUM(CASE WHEN COALESCE(c.tipo_sku,'mercearia')='mercearia'
             THEN CAST(i.input_qty AS INT64) ELSE 0 END)   AS itens_merc,
    SUM(CAST(i.input_qty AS INT64))                        AS itens_pessoa
  FROM `shopper-datalakehouse-prod.darkstores.wss_market_store_visit_list_n2` v
  INNER JOIN store_map sm ON v.market_store_name = sm.market_store_name
  INNER JOIN `shopper-datalakehouse-prod.darkstores.wss_market_store_visit_list_operator_n2` op
    ON v.visit_id = op.visit_list_id
  INNER JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` u
    ON op.operator_id = u.user_id
  INNER JOIN `shopper-datalakehouse-prod.darkstores.wss_market_store_visit_list_items_n2` i
    ON v.visit_id = i.market_store_visit_list_id
  LEFT JOIN `shopper-performance-prod.darkstore.raw_sku_classificacao` c
    ON SAFE_CAST(i.sku_id AS INT64) = c.id_modelo
  WHERE v.visit_type_name        = 'RESTOCK'
    AND v.visit_list_status_name = 'FINALIZADO'
    AND TRIM(COALESCE(v.order_code, '')) != ''
    AND (TIME(v.started_at) >= TIME '22:00:00' OR TIME(v.started_at) < TIME '06:00:00')
    AND DATE(v.started_at) BETWEEN '[DATE_INI]' AND '[DATE_FIM]'
    AND v.finished_at > v.started_at
    AND DATETIME_DIFF(v.finished_at, v.started_at, SECOND) > 60
  GROUP BY 1, 2, 3, 4
),

person_day AS (
  SELECT
    ipd.store_code, ipd.nome, ipd.mat, ipd.data_ref,
    ipd.itens_cong, ipd.itens_flv, ipd.itens_merc, ipd.itens_pessoa,
    COALESCE(rh.real_hrs, 0.0) AS real_hrs
  FROM itens_pessoa_dia ipd
  LEFT JOIN real_hrs_pessoa rh
    ON ipd.store_code = rh.store_code AND ipd.data_ref = rh.data_ref
    AND (
      CASE WHEN TRIM(COALESCE(ipd.mat,'')) != '' AND TRIM(COALESCE(rh.mat,'')) != ''
           THEN TRIM(ipd.mat) = TRIM(rh.mat)
           ELSE ipd.nome = rh.nome
      END
    )
),

itens_turno AS (
  SELECT store_code, data_ref, SUM(itens_pessoa) AS total_itens_turno
  FROM person_day GROUP BY 1, 2
),

person_day_esp AS (
  SELECT pd.*, it.total_itens_turno,
    (pd.itens_cong / v.cong + pd.itens_flv / v.flv + pd.itens_merc / v.merc) AS esp_hrs_pessoa
  FROM person_day pd
  INNER JOIN itens_turno it ON pd.store_code = it.store_code AND pd.data_ref = it.data_ref
  CROSS JOIN vel v
  WHERE it.total_itens_turno > 0
),

day_gate AS (
  SELECT
    pde.store_code, pde.nome, pde.mat, pde.data_ref,
    pde.itens_pessoa, pde.real_hrs, pde.esp_hrs_pessoa, pde.total_itens_turno,
    SAFE_DIVIDE(pde.itens_pessoa, pde.total_itens_turno) >= 0.10 AS passou_gate
  FROM person_day_esp pde
),

esp_turno_gate AS (
  SELECT store_code, data_ref,
    COUNT(*) AS n_pessoas_gate, MAX(esp_hrs_pessoa) AS esp_hrs_turno_gate
  FROM day_gate WHERE passou_gate GROUP BY 1, 2
),

span_turno AS (
  SELECT sm.store_code, DATE(v.started_at) AS data_ref,
    DATETIME_DIFF(MAX(v.finished_at), MIN(v.started_at), SECOND) / 3600.0 AS span_hrs_turno
  FROM `shopper-datalakehouse-prod.darkstores.wss_market_store_visit_list_n2` v
  INNER JOIN store_map sm ON v.market_store_name = sm.market_store_name
  WHERE v.visit_type_name='RESTOCK' AND v.visit_list_status_name='FINALIZADO'
    AND TRIM(COALESCE(v.order_code,''))!=''
    AND (TIME(v.started_at) >= TIME '22:00:00' OR TIME(v.started_at) < TIME '06:00:00')
    AND DATE(v.started_at) BETWEEN '[DATE_INI]' AND '[DATE_FIM]'
    AND v.finished_at > v.started_at
  GROUP BY 1, 2
),

day_final AS (
  SELECT dg.store_code, dg.nome, dg.mat, dg.data_ref,
    dg.real_hrs, dg.esp_hrs_pessoa,
    eg.n_pessoas_gate, eg.esp_hrs_turno_gate,
    (dg.real_hrs        <= dg.esp_hrs_pessoa)     AS score_ind_dia,
    (st.span_hrs_turno  <= eg.esp_hrs_turno_gate) AS score_col_dia
  FROM day_gate dg
  INNER JOIN esp_turno_gate eg ON dg.store_code=eg.store_code AND dg.data_ref=eg.data_ref
  INNER JOIN span_turno     st ON dg.store_code=st.store_code AND dg.data_ref=st.data_ref
  WHERE dg.passou_gate
),

person_week AS (
  SELECT store_code, nome, ANY_VALUE(mat) AS mat,
    COUNT(*) AS dias_gate,
    ROUND(AVG(IF(score_ind_dia,1.0,0.0)),4) AS score_ind,
    ROUND(AVG(IF(score_col_dia,1.0,0.0)),4) AS score_col,
    ROUND(0.6*AVG(IF(score_ind_dia,1.0,0.0))+0.4*AVG(IF(score_col_dia,1.0,0.0)),4) AS score_semana
  FROM day_final GROUP BY 1, 2
),

store_week AS (
  SELECT store_code,
    COUNT(DISTINCT data_ref) AS dias_gate_loja,
    ROUND(AVG(IF(score_ind_dia,1.0,0.0)),4) AS score_ind_loja,
    ROUND(AVG(IF(score_col_dia,1.0,0.0)),4) AS score_col_loja,
    ROUND(0.6*AVG(IF(score_ind_dia,1.0,0.0))+0.4*AVG(IF(score_col_dia,1.0,0.0)),4) AS score_semana_loja
  FROM day_final GROUP BY 1
)

SELECT
  r.store_code,
  [YEAR_REF]   AS year_ref,
  [WEEK_REF]   AS week_ref,
  r.nome,
  r.mat,
  r.turno_bucket,
  COALESCE(pw.dias_gate,   IF(r.funcao_bucket='SUPERVISOR', sw.dias_gate_loja,   NULL), 0) AS dias_no_gate,
  COALESCE(pw.score_ind,   IF(r.funcao_bucket='SUPERVISOR', sw.score_ind_loja,   NULL), 0.0) AS score_individual_semana,
  COALESCE(pw.score_col,   IF(r.funcao_bucket='SUPERVISOR', sw.score_col_loja,   NULL), 0.0) AS score_coletivo_semana,
  COALESCE(pw.score_semana,IF(r.funcao_bucket='SUPERVISOR', sw.score_semana_loja,NULL), 0.0) AS nota_abastecimento_final,
  CASE
    WHEN COALESCE(pw.score_semana,IF(r.funcao_bucket='SUPERVISOR',sw.score_semana_loja,NULL),0.0)*100 < 70 THEN 0.00
    WHEN COALESCE(pw.score_semana,IF(r.funcao_bucket='SUPERVISOR',sw.score_semana_loja,NULL),0.0)*100 < 80 THEN 0.60
    WHEN COALESCE(pw.score_semana,IF(r.funcao_bucket='SUPERVISOR',sw.score_semana_loja,NULL),0.0)*100 < 90 THEN 0.80
    WHEN COALESCE(pw.score_semana,IF(r.funcao_bucket='SUPERVISOR',sw.score_semana_loja,NULL),0.0)*100 < 97 THEN 0.95
    ELSE 1.00
  END AS pct_pagamento_tier_abastecimento
FROM roster_dedup r
LEFT JOIN person_week pw
  ON r.store_code=pw.store_code
  AND (
    CASE WHEN TRIM(COALESCE(r.mat,''))!='' AND TRIM(COALESCE(pw.mat,''))!=''
         THEN TRIM(r.mat)=TRIM(pw.mat)
         ELSE r.nome=pw.nome END
  )
LEFT JOIN store_week sw ON r.store_code=sw.store_code
WHERE pw.store_code IS NOT NULL
   OR (r.funcao_bucket='SUPERVISOR' AND sw.store_code IS NOT NULL)
