-- PASSO 3 — int_pedidos_sla
-- Substitua [YEAR_REF], [WEEK_REF], [DATE_INI] e [DATE_FIM] antes de rodar

DELETE FROM `shopper-performance-prod.darkstore.int_pedidos_sla`
WHERE year_ref = [YEAR_REF] AND week_ref = [WEEK_REF];

INSERT INTO `shopper-performance-prod.darkstore.int_pedidos_sla`
WITH turbo AS (
  SELECT order_code AS cod_pedido,
    CASE WHEN UPPER(modo_entrega) IN ('EXPRESS','TURBO') THEN 'EXPRESS'
         WHEN UPPER(modo_entrega) = 'FAST_DELIVERY' THEN 'FAST_DELIVERY'
         ELSE 'DEFAULT' END AS categoria_pedido
  FROM `shopper-performance-prod.darkstore.raw_base_turbos`
  WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY order_code
    ORDER BY CASE WHEN UPPER(modo_entrega) IN ('EXPRESS','TURBO') THEN 0
                  WHEN UPPER(modo_entrega) = 'FAST_DELIVERY' THEN 1 ELSE 2 END
  ) = 1
),
shopper_native AS (
  SELECT
    cod_pedido,
    CASE
      WHEN delivery_time_frame_start IS NOT NULL
        AND delivery_time_frame_end IS NOT NULL
        AND TIME_DIFF(
              SAFE_CAST(delivery_time_frame_end   AS TIME),
              SAFE_CAST(delivery_time_frame_start AS TIME),
              MINUTE
            ) <= 30
      THEN 'TURBO_SHOPPER'
      ELSE 'SHOPPER_NOW'
    END AS categoria_pedido
  FROM `shopper-performance-prod.darkstore.raw_pedidos`
  WHERE ENDS_WITH(cod_pedido, 'N')
    AND cod_pedido NOT IN (
      SELECT cod_pedido
      FROM `shopper-datalakehouse-qa.Ranking_Performance.pedidos_ifood`
    )
)
SELECT
  CASE
    REGEXP_REPLACE(LOWER(TRIM(NORMALIZE_AND_CASEFOLD(REGEXP_REPLACE(LOWER(TRIM(p.store_code)), r'^lj\d+\s*-\s*', ''), NFKD))), r'\pM', '')
    WHEN 'tatupe'         THEN 'tatuape'
    WHEN 'pr - stresser'  THEN 'juveve curitiba'
    WHEN 'pr - republica' THEN 'agua verde curitiba'
    WHEN 'pr - rodovia'   THEN 'mossungue curitiba'
    ELSE REGEXP_REPLACE(LOWER(TRIM(NORMALIZE_AND_CASEFOLD(REGEXP_REPLACE(LOWER(TRIM(p.store_code)), r'^lj\d+\s*-\s*', ''), NFKD))), r'\pM', '')
  END AS store_code,
  [YEAR_REF] AS year_ref,
  [WEEK_REF] AS week_ref,
  p.cod_pedido,
  UPPER(TRIM(p.nome))                                             AS nome,
  p.schedule                                                      AS turno_bucket,
  COALESCE(t.categoria_pedido, sn.categoria_pedido, 'DEFAULT')   AS categoria_pedido,
  TIMESTAMP_DIFF(
    SAFE_CAST(p.fim_packing AS TIMESTAMP),
    SAFE_CAST(p.entrada_pedido_sistema AS TIMESTAMP), SECOND
  )                                                               AS sla_segundos,
  COALESCE(t.categoria_pedido, sn.categoria_pedido, 'DEFAULT')
    IN ('EXPRESS','FAST_DELIVERY','TURBO_SHOPPER')               AS is_sla_5m_scope,
  (
    COALESCE(t.categoria_pedido, sn.categoria_pedido, 'DEFAULT')
      IN ('EXPRESS','FAST_DELIVERY','TURBO_SHOPPER')
    AND TIMESTAMP_DIFF(
      SAFE_CAST(p.fim_packing AS TIMESTAMP),
      SAFE_CAST(p.entrada_pedido_sistema AS TIMESTAMP), SECOND
    ) <= 300
  )                                                               AS is_sla_5m,
  CAST(p.mat AS STRING) AS mat
FROM `shopper-performance-prod.darkstore.raw_pedidos` p
LEFT JOIN turbo t          ON p.cod_pedido = t.cod_pedido
LEFT JOIN shopper_native sn ON p.cod_pedido = sn.cod_pedido
LEFT JOIN `shopper-performance-prod.darkstore.raw_pedidos_desconsiderar` desc_
  ON desc_.order_code = p.cod_pedido
 AND desc_.year_ref = [YEAR_REF] AND desc_.week_ref = [WEEK_REF]
WHERE DATE(SAFE_CAST(p.entrada_pedido_sistema AS TIMESTAMP), 'America/Sao_Paulo') BETWEEN '[DATE_INI]' AND '[DATE_FIM]'
  AND TRIM(COALESCE(p.store_code,'')) != ''
  AND desc_.order_code IS NULL
  AND EXTRACT(HOUR FROM SAFE_CAST(p.entrada_pedido_sistema AS TIMESTAMP) AT TIME ZONE 'America/Sao_Paulo') != 23
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY p.store_code, p.cod_pedido
  ORDER BY SAFE_CAST(p.fim_packing AS TIMESTAMP) DESC NULLS LAST
) = 1
