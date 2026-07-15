-- Depende de: curated_caixaria, curated_movement_media
CREATE OR REPLACE VIEW `shopper-performance-prod.operacao.curated_reposicao_fora_processo`
OPTIONS (description = 'Reposições fora do processo (detratora).')
AS
WITH BaseCalculo AS (
  SELECT
    m.movement_id, m.location_id, m.sku_id, m.item_qty AS qty,
    CAST(m.movement_at AS STRING)             AS end_timestamp,
    SAFE_CAST(u.registration_number AS INT64) AS cod_matricula,
    u.user_name, SAFE_CAST(REGEXP_REPLACE(TRIM(cx.caixaria), r'[^0-9.]', '') AS FLOAT64) AS caixaria, med.media_sem_outliers,
    'MOVEMENT_RESTOCK_INVALID'   AS metric_code,
    'REPOSIÇÃO FORA DO PROCESSO' AS descricao_atividade,
    'DETRATORA'                  AS metric_type
  FROM `shopper-datalakehouse-prod.inventory.wss_movimentacoes_n2` AS m
  LEFT JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` AS u ON u.user_id=SAFE_CAST(m.created_by AS INT64)
  LEFT JOIN `shopper-performance-prod.operacao.curated_caixaria` AS cx ON SAFE_CAST(REGEXP_REPLACE(TRIM(cx.id_modelo), r'[^0-9]', '') AS INT64)=m.sku_id
  LEFT JOIN (
    SELECT sku_id, AVG(media_sem_outliers) AS media_sem_outliers
    FROM `shopper-performance-prod.operacao.curated_movement_media`
    WHERE movement_group='REPOSICAO' GROUP BY sku_id
  ) AS med ON med.sku_id=m.sku_id
  WHERE m.justification='Entrada para abastecimento (reposição)' AND m.movement_type='E' AND m.item_qty>0
),
ComFatorCaixaria AS (
  SELECT *,
    CASE WHEN caixaria IS NULL THEN 1.0 WHEN qty=caixaria THEN 1.5
      ELSE GREATEST(1.0, 1.5-(0.5*SAFE_DIVIDE(ABS(qty-caixaria),caixaria))) END AS fator_caixaria
  FROM BaseCalculo
)
SELECT * EXCEPT (caixaria, fator_caixaria), caixaria,
  COALESCE(media_sem_outliers,1.0) AS media_para_calculo, fator_caixaria,
  CASE WHEN qty=0 THEN 0.0
    ELSE LEAST(2.0, SAFE_DIVIDE(qty, COALESCE(media_sem_outliers,1.0)) * fator_caixaria)
  END AS score_movimentacao
FROM ComFatorCaixaria;
