-- Depende de: curated_movement_media, curated_caixaria
CREATE OR REPLACE VIEW `shopper-performance-prod.operacao.curated_reposicao`
OPTIONS (description = 'Score de reposição por SKU/colaborador.')
AS
WITH Base AS (
  SELECT
    SAFE_CAST(JSON_VALUE(rm.details, '$.sku_id') AS INT64)               AS sku_id,
    SAFE_CAST(JSON_VALUE(rm.details, '$.restock_item_list_id') AS INT64) AS restock_item_list_id,
    JSON_VALUE(rm.details, '$.restock_list_level')                        AS restock_list_level,
    JSON_VALUE(rm.details, '$.restock_list_type')                         AS restock_list_type,
    JSON_VALUE(rm.details, '$.source_location')                           AS source_location,
    JSON_VALUE(rm.details, '$.destination_location')                      AS destination_location,
    SAFE_CAST(u.registration_number AS INT64)                             AS cod_matricula,
    u.user_name, rm.source_system, rm.start_timestamp, rm.end_timestamp, rm.metric_code,
    SAFE_CAST(rm.value AS FLOAT64) AS qty,
    CASE
      WHEN JSON_VALUE(rm.details, '$.restock_list_type') = 'Reposição - Mercearia'
        THEN CONCAT('REPOSIÇÃO MERCEARIA: ', UPPER(JSON_VALUE(rm.details, '$.restock_list_level')))
      WHEN JSON_VALUE(rm.details, '$.restock_list_type') IN ('Retorno Picking Secos','Picking Secos') THEN 'REPOSIÇÃO PICKING SECOS'
      WHEN JSON_VALUE(rm.details, '$.restock_list_type') IN ('Check-in - Mercearia','Check-in - Fresh') THEN 'REPOSIÇÃO CHECKIN'
      WHEN JSON_VALUE(rm.details, '$.restock_list_type') = 'Transferência' THEN 'REPOSIÇÃO TRANSFERÊNCIA'
      WHEN JSON_VALUE(rm.details, '$.restock_list_type') = 'Reposição - Fresh' THEN 'REPOSIÇÃO FRESH'
      ELSE 'REPOSIÇÃO'
    END AS descricao_atividade
  FROM `shopper-datalakehouse-prod.performance.raw_measures_n2` AS rm
  INNER JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` AS u ON u.uuid = rm.operator_uuid
  WHERE rm.metric_code IN ('MOVEMENT_PICKUP','MOVEMENT_RESTOCK') AND SAFE_CAST(rm.value AS FLOAT64) > 0
),
ComMediaECaixaria AS (
  SELECT b.*, med.media_sem_outliers, SAFE_CAST(REGEXP_REPLACE(TRIM(cx.caixaria), r'[^0-9.]', '') AS FLOAT64) AS caixaria
  FROM Base AS b
  LEFT JOIN `shopper-performance-prod.operacao.curated_movement_media` AS med
    ON med.sku_id=b.sku_id AND med.movement_group='REPOSICAO'
    AND med.restock_list_level=b.restock_list_level AND med.restock_list_type=b.restock_list_type
  LEFT JOIN `shopper-performance-prod.operacao.curated_caixaria` AS cx ON SAFE_CAST(REGEXP_REPLACE(TRIM(cx.id_modelo), r'[^0-9]', '') AS INT64)=b.sku_id
)
SELECT
  T.* EXCEPT (caixaria, fator_caixaria), T.caixaria,
  COALESCE(T.media_sem_outliers, 1) AS media_para_calculo, T.fator_caixaria,
  CASE WHEN T.qty=0 THEN 0.0
    ELSE LEAST(2.0, SAFE_DIVIDE(T.qty, COALESCE(T.media_sem_outliers,1.0)) * T.fator_caixaria)
  END AS score_movimentacao
FROM (
  SELECT *,
    CASE WHEN caixaria IS NULL THEN 1.0 WHEN qty=caixaria THEN 1.5
      ELSE GREATEST(1.0, 1.5-(0.5*SAFE_DIVIDE(ABS(qty-caixaria),caixaria))) END AS fator_caixaria
  FROM ComMediaECaixaria
) AS T;
