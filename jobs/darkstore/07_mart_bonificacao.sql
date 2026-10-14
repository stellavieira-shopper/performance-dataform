-- PASSO 7 — mart_bonificacao (cálculo final)
-- Substitua [YEAR_REF] e [WEEK_REF] antes de rodar
-- ⚠️ raw_erros_clientes é Drive-linked: rodar via run_darkstore_week.py

DELETE FROM `shopper-performance-prod.darkstore.mart_bonificacao`
WHERE year_ref = [YEAR_REF] AND week_ref = [WEEK_REF];

INSERT INTO `shopper-performance-prod.darkstore.mart_bonificacao`
WITH
pedidos_person AS (
  SELECT store_code, year_ref, week_ref, nome, mat, COUNT(*) AS total_pedidos
  FROM `shopper-performance-prod.darkstore.int_pedidos_sla`
  WHERE year_ref=[YEAR_REF] AND week_ref=[WEEK_REF] GROUP BY 1,2,3,4,5
),
pedidos_turno AS (
  SELECT store_code, year_ref, week_ref, turno_bucket, COUNT(*) AS total_pedidos
  FROM `shopper-performance-prod.darkstore.int_pedidos_sla`
  WHERE year_ref=[YEAR_REF] AND week_ref=[WEEK_REF] GROUP BY 1,2,3,4
),
pedidos_loja AS (
  SELECT store_code, year_ref, week_ref, COUNT(*) AS total_pedidos
  FROM `shopper-performance-prod.darkstore.int_pedidos_sla`
  WHERE year_ref=[YEAR_REF] AND week_ref=[WEEK_REF] GROUP BY 1,2,3
),
erros_raw AS (
  SELECT DISTINCT cod_pedido, 'normal' AS tipo_erro
  FROM `shopper-performance-prod.darkstore.raw_erros_clientes`
  WHERE TRIM(COALESCE(cod_pedido,''))!=''
    AND UPPER(TRIM(COALESCE(considerar,''))) = 'CONSIDERAR'
  UNION DISTINCT
  SELECT DISTINCT cod_pedido, 'normal' AS tipo_erro
  FROM `shopper-performance-prod.darkstore.raw_erros_clientes_extra`
  WHERE TRIM(COALESCE(cod_pedido,''))!=''
    AND UPPER(TRIM(COALESCE(considerar,''))) = 'CONSIDERAR'
),
erros_turno AS (
  SELECT p.store_code, p.year_ref, p.week_ref, p.turno_bucket,
    COUNTIF(e.tipo_erro='normal') AS erros_normais_turno,
    COUNTIF(e.tipo_erro='grave')  AS erros_graves_turno
  FROM `shopper-performance-prod.darkstore.int_pedidos_sla` p
  INNER JOIN erros_raw e ON p.cod_pedido=e.cod_pedido
  WHERE p.year_ref=[YEAR_REF] AND p.week_ref=[WEEK_REF] GROUP BY 1,2,3,4
),
erros_loja AS (
  SELECT p.store_code, p.year_ref, p.week_ref,
    COUNTIF(e.tipo_erro='normal') AS erros_normais_loja,
    COUNTIF(e.tipo_erro='grave')  AS erros_graves_loja
  FROM `shopper-performance-prod.darkstore.int_pedidos_sla` p
  INNER JOIN erros_raw e ON p.cod_pedido=e.cod_pedido
  WHERE p.year_ref=[YEAR_REF] AND p.week_ref=[WEEK_REF] GROUP BY 1,2,3
),
loja_metricas AS (
  SELECT store_code, year_ref, week_ref,
    ANY_VALUE(taxa_separacao_loja) AS taxa_separacao_loja,
    ANY_VALUE(taxa_completo_loja)  AS taxa_completo_loja,
    MAX(rupturas_count)            AS rupturas_count
  FROM `shopper-performance-prod.darkstore.int_person_metrics`
  WHERE year_ref=[YEAR_REF] AND week_ref=[WEEK_REF] GROUP BY 1,2,3
),
turno_metricas AS (
  SELECT store_code, year_ref, week_ref, turno_bucket,
    ANY_VALUE(taxa_separacao_turno) AS taxa_separacao_turno
  FROM `shopper-performance-prod.darkstore.int_person_metrics`
  WHERE year_ref=[YEAR_REF] AND week_ref=[WEEK_REF] GROUP BY 1,2,3,4
),
org_cracha AS (
  SELECT TRIM(cracha) AS cracha, TRIM(mat) AS mat
  FROM `shopper-performance-prod.darkstore.organograma_darks_ext`
  WHERE TRIM(COALESCE(cracha,''))!='' AND TRIM(COALESCE(mat,''))!=''
),
perdas_raw AS (
  SELECT
    COALESCE(org.mat, UPPER(TRIM(p.Operador))) AS chave_pessoa,
    CASE WHEN org.mat IS NOT NULL THEN 'mat' ELSE 'nome' END AS tipo_chave,
    SUM(COALESCE(p.Lancamentos_Erroneos,0)) AS erros_perdas,
    SUM(COALESCE(p.Total_Lancamentos,0))    AS total_perdas
  FROM `shopper-performance-prod.darkstore.raw_detratoras_perdas` p
  LEFT JOIN org_cracha org ON TRIM(p.Cracha)=org.cracha
  WHERE p.Data BETWEEN
    DATE_ADD(DATE_TRUNC(DATE([YEAR_REF], 1, 4), ISOWEEK), INTERVAL ([WEEK_REF]-2)*7 + 4 DAY)
    AND
    DATE_ADD(DATE_TRUNC(DATE([YEAR_REF], 1, 4), ISOWEEK), INTERVAL ([WEEK_REF]-1)*7 + 3 DAY)
  GROUP BY 1, 2
),
base AS (
  SELECT
    r.store_code, [YEAR_REF] AS year_ref, [WEEK_REF] AS week_ref,
    r.nome, r.turno_bucket, r.funcao_bucket, r.mat,
    r.taxa_separacao_individual, r.taxa_separacao_loja, r.taxa_completo_loja, r.rupturas_count,
    COALESCE(f.assiduidade_any_flag, FALSE) AS assiduidade_any_flag,
    (r.taxa_separacao_loja < (CASE r.store_code WHEN 'pamplona' THEN 0.80 ELSE 0.85 END)
     OR r.taxa_completo_loja < (CASE r.store_code WHEN 'pamplona' THEN 0.80 ELSE 0.85 END)) AS gate_loja_80_flag,
    COALESCE(fg.gate_foto_flag, FALSE) AS gate_foto_flag,
    COALESCE(fg.taxa_foto_loja, 1.0)  AS taxa_foto_loja,
    CASE r.funcao_bucket
      WHEN 'OPERADOR' THEN
        CASE WHEN r.taxa_separacao_individual<(CASE r.store_code WHEN 'pamplona' THEN 0.80 ELSE 0.85 END) THEN 0
             WHEN r.taxa_separacao_individual<0.90 THEN 50 WHEN r.taxa_separacao_individual<0.95 THEN 100 ELSE 150 END
      WHEN 'TEAM_LIDER' THEN
        CASE WHEN r.taxa_separacao_individual<(CASE r.store_code WHEN 'pamplona' THEN 0.80 ELSE 0.85 END) THEN 0
             WHEN r.taxa_separacao_individual<0.90 THEN 100 WHEN r.taxa_separacao_individual<0.95 THEN 150 ELSE 200 END
      WHEN 'SUPERVISOR' THEN
        CASE WHEN r.taxa_separacao_individual<(CASE r.store_code WHEN 'pamplona' THEN 0.80 ELSE 0.85 END) THEN 0
             WHEN r.taxa_separacao_individual<0.90 THEN 150 WHEN r.taxa_separacao_individual<0.95 THEN 200 ELSE 250 END
      ELSE 0 END AS faixa_salario,
    CASE WHEN r.taxa_separacao_loja<(CASE r.store_code WHEN 'pamplona' THEN 0.80 ELSE 0.85 END) THEN 0.0
         WHEN r.taxa_separacao_loja<0.95 THEN 0.8 WHEN r.taxa_separacao_loja<0.98 THEN 1.5 ELSE 2.0 END AS multiplo_separacao,
    CASE WHEN r.taxa_completo_loja<0.95 THEN 0.0 WHEN r.taxa_completo_loja<0.98 THEN 0.8
         WHEN r.taxa_completo_loja<0.99 THEN 1.5 ELSE 2.0 END AS multiplo_completo,
    CASE WHEN r.taxa_completo_loja<0.95 THEN 0
         WHEN r.taxa_completo_loja<0.96 THEN CASE r.funcao_bucket WHEN 'SUPERVISOR' THEN 100 WHEN 'TEAM_LIDER' THEN 75 ELSE 50 END
         WHEN r.taxa_completo_loja<0.97 THEN CASE r.funcao_bucket WHEN 'SUPERVISOR' THEN 80  WHEN 'TEAM_LIDER' THEN 60 ELSE 40 END
         WHEN r.taxa_completo_loja<0.98 THEN CASE r.funcao_bucket WHEN 'SUPERVISOR' THEN 60  WHEN 'TEAM_LIDER' THEN 45 ELSE 30 END
         WHEN r.taxa_completo_loja<0.99 THEN CASE r.funcao_bucket WHEN 'SUPERVISOR' THEN 40  WHEN 'TEAM_LIDER' THEN 30 ELSE 20 END
         ELSE 0 END AS desconto_ruptura,
    CASE r.funcao_bucket
      WHEN 'OPERADOR' THEN SAFE_DIVIDE(COALESCE(r.erros_normais,0)+COALESCE(r.erros_graves,0),NULLIF(COALESCE(pp.total_pedidos,0),0))
      WHEN 'TEAM_LIDER' THEN SAFE_DIVIDE(COALESCE(et.erros_normais_turno,0)+COALESCE(et.erros_graves_turno,0),NULLIF(COALESCE(pt.total_pedidos,0),0))
      ELSE SAFE_DIVIDE(COALESCE(el.erros_normais_loja,0)+COALESCE(el.erros_graves_loja,0),NULLIF(COALESCE(pl.total_pedidos,0),0))
    END AS taxa_erros_individual,
    r.erros_normais, r.erros_graves,
    CASE r.funcao_bucket WHEN 'SUPERVISOR' THEN 440 WHEN 'TEAM_LIDER' THEN 330 ELSE 220 END AS teto_novo,
    CASE WHEN r.funcao_bucket='SUPERVISOR' THEN 0.5 WHEN r.turno_bucket='NOITE' THEN 0.4 ELSE 1.0 END AS pct_bolso_pedidos,
    CASE WHEN r.funcao_bucket='SUPERVISOR' THEN 0.5 WHEN r.turno_bucket='NOITE' THEN 0.6 ELSE 0.0 END AS pct_bolso_abastecimento,
    COALESCE(ab.nota_abastecimento_final, 0) AS nota_abastecimento_final,
    COALESCE(ab.pct_pagamento_tier_abastecimento, 0) AS pct_pagamento_tier_abastecimento,
    COALESCE(fd.pct_desconto, 0.0) AS pct_desconto_foto,
    COALESCE(pd.erros_perdas, 0)  AS erros_perdas,
    COALESCE(pd.total_perdas, 0)  AS total_perdas
  FROM (
    SELECT
      REGEXP_REPLACE(LOWER(TRIM(NORMALIZE_AND_CASEFOLD(c.setor,NFKD))),r'\pM','') AS store_code,
      UPPER(TRIM(c.nome)) AS nome, c.mat,
      COALESCE(pm.turno_bucket, c.turno) AS turno_bucket,
      COALESCE(pm.funcao_bucket,
        CASE WHEN REGEXP_CONTAINS(UPPER(NORMALIZE_AND_CASEFOLD(COALESCE(c.atribui_o,c.fun_o,''),NFKD)),r'SUPERVISOR') THEN 'SUPERVISOR'
             WHEN REGEXP_CONTAINS(UPPER(NORMALIZE_AND_CASEFOLD(COALESCE(c.atribui_o,c.fun_o,''),NFKD)),r'TEAM\s*L')   THEN 'TEAM_LIDER'
             WHEN REGEXP_CONTAINS(UPPER(NORMALIZE_AND_CASEFOLD(COALESCE(c.atribui_o,c.fun_o,''),NFKD)),r'SEPAR|OPERADOR') THEN 'OPERADOR'
             ELSE NULL END) AS funcao_bucket,
      CASE COALESCE(pm.funcao_bucket,
             CASE WHEN REGEXP_CONTAINS(UPPER(NORMALIZE_AND_CASEFOLD(COALESCE(c.atribui_o,c.fun_o,''),NFKD)),r'SUPERVISOR') THEN 'SUPERVISOR'
                  WHEN REGEXP_CONTAINS(UPPER(NORMALIZE_AND_CASEFOLD(COALESCE(c.atribui_o,c.fun_o,''),NFKD)),r'TEAM\s*L')   THEN 'TEAM_LIDER'
                  ELSE 'OPERADOR' END)
        WHEN 'SUPERVISOR' THEN COALESCE(pm.taxa_separacao_individual, lm.taxa_separacao_loja, 0)
        WHEN 'TEAM_LIDER' THEN COALESCE(pm.taxa_separacao_individual, tm.taxa_separacao_turno, lm.taxa_separacao_loja, 0)
        ELSE COALESCE(pm.taxa_separacao_individual, 0)
      END AS taxa_separacao_individual,
      COALESCE(pm.taxa_separacao_loja, lm.taxa_separacao_loja, 0) AS taxa_separacao_loja,
      COALESCE(pm.taxa_completo_loja,  lm.taxa_completo_loja,  0) AS taxa_completo_loja,
      COALESCE(pm.rupturas_count, lm.rupturas_count, 0) AS rupturas_count,
      COALESCE(pm.erros_normais, 0) AS erros_normais,
      COALESCE(pm.erros_graves,  0) AS erros_graves
    FROM `shopper-performance-prod.darkstore.raw_bonificacao_cargos` c
    LEFT JOIN `shopper-performance-prod.darkstore.int_person_metrics` pm
      ON REGEXP_REPLACE(LOWER(TRIM(NORMALIZE_AND_CASEFOLD(c.setor,NFKD))),r'\pM','')=pm.store_code
      AND (CASE WHEN TRIM(COALESCE(c.mat,''))!='' AND TRIM(COALESCE(pm.mat,''))!=''
                THEN TRIM(c.mat)=TRIM(pm.mat) ELSE UPPER(TRIM(c.nome))=pm.nome END)
      AND pm.year_ref=[YEAR_REF] AND pm.week_ref=[WEEK_REF]
    LEFT JOIN loja_metricas lm ON REGEXP_REPLACE(LOWER(TRIM(NORMALIZE_AND_CASEFOLD(c.setor,NFKD))),r'\pM','')=lm.store_code
    LEFT JOIN turno_metricas tm
      ON REGEXP_REPLACE(LOWER(TRIM(NORMALIZE_AND_CASEFOLD(c.setor,NFKD))),r'\pM','')=tm.store_code
      AND COALESCE(pm.turno_bucket,c.turno)=tm.turno_bucket
    WHERE TRIM(COALESCE(c.nome,''))!='' AND TRIM(COALESCE(c.fun_o,''))!=''
      AND UPPER(TRIM(COALESCE(c.fun_o,''))) NOT IN ('APRENDIZ','')
  ) r
  LEFT JOIN `shopper-performance-prod.darkstore.raw_bonificacao_faltas` f
    ON (CASE WHEN TRIM(COALESCE(r.mat,''))!='' AND TRIM(COALESCE(f.mat,''))!=''
             THEN TRIM(r.mat)=TRIM(f.mat)
             ELSE REGEXP_REPLACE(LOWER(TRIM(NORMALIZE_AND_CASEFOLD(f.store_code,NFKD))),r'\pM','')=r.store_code
                  AND UPPER(TRIM(f.nome))=r.nome END)
    AND f.year_ref=[YEAR_REF] AND f.week_ref=[WEEK_REF]
  LEFT JOIN `shopper-performance-prod.darkstore.int_abastecimento_bonus` ab
    ON r.store_code=ab.store_code
    AND (CASE WHEN TRIM(COALESCE(r.mat,''))!='' AND TRIM(COALESCE(ab.mat,''))!=''
              THEN TRIM(r.mat)=TRIM(ab.mat) ELSE r.nome=ab.nome END)
    AND ab.year_ref=[YEAR_REF] AND ab.week_ref=[WEEK_REF]
  LEFT JOIN `shopper-performance-prod.darkstore.int_foto_gate` fg
    ON r.store_code=fg.store_code AND fg.year_ref=[YEAR_REF] AND fg.week_ref=[WEEK_REF]
  LEFT JOIN `shopper-performance-prod.darkstore.raw_foto_desconto` fd
    ON r.store_code=fd.store_code AND fd.year_ref=[YEAR_REF] AND fd.week_ref=[WEEK_REF]
  LEFT JOIN perdas_raw pd ON (
    CASE WHEN TRIM(COALESCE(r.mat,''))!=''
         THEN pd.chave_pessoa=TRIM(r.mat) AND pd.tipo_chave='mat'
         ELSE pd.chave_pessoa=UPPER(TRIM(r.nome)) AND pd.tipo_chave='nome' END
  )
  LEFT JOIN pedidos_person pp ON r.store_code=pp.store_code
    AND (CASE WHEN TRIM(COALESCE(r.mat,''))!='' AND TRIM(COALESCE(pp.mat,''))!=''
              THEN TRIM(r.mat)=TRIM(pp.mat) ELSE UPPER(TRIM(r.nome))=UPPER(TRIM(pp.nome)) END)
    AND pp.year_ref=[YEAR_REF] AND pp.week_ref=[WEEK_REF]
  LEFT JOIN pedidos_turno  pt ON r.store_code=pt.store_code AND r.turno_bucket=pt.turno_bucket AND pt.year_ref=[YEAR_REF] AND pt.week_ref=[WEEK_REF]
  LEFT JOIN pedidos_loja   pl ON r.store_code=pl.store_code AND pl.year_ref=[YEAR_REF] AND pl.week_ref=[WEEK_REF]
  LEFT JOIN erros_turno    et ON r.store_code=et.store_code AND r.turno_bucket=et.turno_bucket AND et.year_ref=[YEAR_REF] AND et.week_ref=[WEEK_REF]
  LEFT JOIN erros_loja     el ON r.store_code=el.store_code AND el.year_ref=[YEAR_REF] AND el.week_ref=[WEEK_REF]
),
calc AS (
  SELECT *,
    faixa_salario*(0.7*multiplo_separacao+0.3*multiplo_completo) AS valor_obtido_base,
    CASE WHEN assiduidade_any_flag THEN 0
         ELSE faixa_salario*(0.7*multiplo_separacao+0.3*multiplo_completo) END AS valor_obtido,
    teto_novo*pct_bolso_pedidos AS bolso_pedidos,
    teto_novo*pct_bolso_abastecimento AS bolso_abastecimento
  FROM base
),
pre_gate AS (
  SELECT *,
    valor_obtido * CASE
      WHEN funcao_bucket='OPERADOR' THEN CASE
        WHEN COALESCE(taxa_erros_individual,0)>=0.04 THEN 1.00
        WHEN COALESCE(taxa_erros_individual,0)>=0.03 THEN 0.75
        WHEN COALESCE(taxa_erros_individual,0)>=0.02 THEN 0.50
        WHEN COALESCE(taxa_erros_individual,0)>=0.01 THEN 0.25
        WHEN COALESCE(taxa_erros_individual,0)>0     THEN 0.15
        ELSE 0 END
      ELSE CASE
        WHEN COALESCE(taxa_erros_individual,0)>=0.03  THEN 1.00
        WHEN COALESCE(taxa_erros_individual,0)>=0.02  THEN 0.75
        WHEN COALESCE(taxa_erros_individual,0)>=0.01  THEN 0.50
        WHEN COALESCE(taxa_erros_individual,0)>=0.005 THEN 0.25
        WHEN COALESCE(taxa_erros_individual,0)>0      THEN 0.15
        ELSE 0 END
    END AS desconto_erros,
    SAFE_DIVIDE(erros_perdas, NULLIF(total_perdas,0)) AS taxa_perdas,
    valor_obtido * CASE
      WHEN total_perdas=0 THEN 0
      ELSE CASE
        WHEN total_perdas<=10  THEN CASE WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.03 THEN 0.00 WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.10 THEN IF(erros_perdas>=10,0.10,0.00) WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.30 THEN 0.10 WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.50 THEN 0.20 ELSE 0.30 END
        WHEN total_perdas<=30  THEN CASE WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.03 THEN 0.00 WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.10 THEN 0.10 WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.30 THEN 0.20 WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.50 THEN 0.35 ELSE 0.55 END
        WHEN total_perdas<=100 THEN CASE WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.03 THEN 0.00 WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.10 THEN 0.20 WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.30 THEN 0.35 WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.50 THEN 0.55 ELSE 0.75 END
        ELSE CASE WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.03 THEN 0.00 WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.10 THEN 0.35 WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.30 THEN 0.55 WHEN SAFE_DIVIDE(erros_perdas,total_perdas)<0.50 THEN 0.75 ELSE 0.75 END
      END
    END AS desconto_perdas,
    GREATEST(valor_obtido - valor_obtido * CASE
      WHEN funcao_bucket='OPERADOR' THEN CASE
        WHEN COALESCE(taxa_erros_individual,0)>=0.04 THEN 1.00 WHEN COALESCE(taxa_erros_individual,0)>=0.03 THEN 0.75
        WHEN COALESCE(taxa_erros_individual,0)>=0.02 THEN 0.50 WHEN COALESCE(taxa_erros_individual,0)>=0.01 THEN 0.25
        WHEN COALESCE(taxa_erros_individual,0)>0 THEN 0.15 ELSE 0 END
      ELSE CASE
        WHEN COALESCE(taxa_erros_individual,0)>=0.03  THEN 1.00 WHEN COALESCE(taxa_erros_individual,0)>=0.02  THEN 0.75
        WHEN COALESCE(taxa_erros_individual,0)>=0.01  THEN 0.50 WHEN COALESCE(taxa_erros_individual,0)>=0.005 THEN 0.25
        WHEN COALESCE(taxa_erros_individual,0)>0      THEN 0.15 ELSE 0 END
    END, 0) AS valor_final_pre_gate
  FROM calc
),
final AS (
  SELECT *,
    GREATEST(LEAST(valor_obtido, bolso_pedidos) - desconto_ruptura, 0) AS valor_bonus_pedidos_pre_gate,
    bolso_abastecimento*pct_pagamento_tier_abastecimento AS valor_bonus_abastecimento_pre_gate
  FROM pre_gate
),
exclusoes_manuais AS (
  SELECT CAST(NULL AS STRING) AS nome, 'agua verde curitiba' AS store_code, 2026 AS year_ref, 38 AS week_ref, 'MANHA' AS turno_bucket, CAST(NULL AS STRING) AS funcao_bucket
  UNION ALL
  SELECT 'JACKSON DE OLIVEIRA VICENTE', 'agua verde curitiba', 2026, 38, CAST(NULL AS STRING), 'SUPERVISOR'
),
gate_final AS (
  SELECT f.*, (ex.store_code IS NOT NULL) AS exclusao_manual_flag
  FROM final f
  LEFT JOIN exclusoes_manuais ex
    ON ex.store_code=f.store_code AND ex.year_ref=f.year_ref AND ex.week_ref=f.week_ref
    AND (ex.turno_bucket IS NULL OR ex.turno_bucket=f.turno_bucket)
    AND (ex.funcao_bucket IS NULL OR ex.funcao_bucket=f.funcao_bucket)
    AND (ex.nome IS NULL OR ex.nome=f.nome)
)
SELECT
  store_code, year_ref, week_ref, nome, turno_bucket, funcao_bucket, mat,
  assiduidade_any_flag, gate_loja_80_flag, gate_foto_flag,
  taxa_separacao_individual, taxa_separacao_loja, taxa_completo_loja, taxa_foto_loja, rupturas_count,
  faixa_salario, multiplo_separacao, multiplo_completo, valor_obtido_base, valor_obtido,
  desconto_ruptura, valor_final_pre_gate, nota_abastecimento_final, pct_pagamento_tier_abastecimento,
  bolso_pedidos, bolso_abastecimento, valor_bonus_pedidos_pre_gate, valor_bonus_abastecimento_pre_gate,
  CASE
    WHEN exclusao_manual_flag THEN 0.0
    WHEN gate_loja_80_flag OR assiduidade_any_flag THEN 0.0
    WHEN funcao_bucket='OPERADOR' AND COALESCE(taxa_erros_individual,0)>=0.04 THEN 0.0
    WHEN funcao_bucket!='OPERADOR' AND COALESCE(taxa_erros_individual,0)>=0.03 THEN 0.0
    ELSE ROUND(
      GREATEST(
        GREATEST(valor_bonus_pedidos_pre_gate+valor_bonus_abastecimento_pre_gate-desconto_erros,0)
        *(1.0-GREATEST(IF(gate_foto_flag,0.40,0.0),pct_desconto_foto))
        -desconto_perdas,
      0), 2)
  END AS valor_final_bonus,
  erros_normais, erros_graves, desconto_erros,
  pct_desconto_foto,
  erros_perdas, total_perdas, taxa_perdas, desconto_perdas
FROM gate_final
