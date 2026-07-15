CREATE OR REPLACE VIEW `shopper-performance-prod.operacao.curated_lote_media`
OPTIONS (description = 'Média IQR de quantidade movimentada por SKU (entradas de abastecimento via movimentação).')
AS
WITH ValoresValidos AS (
  SELECT m.sku_id AS id_modelo, m.item_qty AS quantidade
  FROM `shopper-datalakehouse-prod.inventory.wss_movimentacoes_n2` AS m
  WHERE m.item_qty > 0
    AND m.justification LIKE '%Entrada para abastecimento (movimentação)%'
),
CalculoIQR AS (
  SELECT *,
    PERCENTILE_CONT(quantidade, 0.25) OVER () AS q1,
    PERCENTILE_CONT(quantidade, 0.75) OVER () AS q3
  FROM ValoresValidos
),
DadosSemOutliers AS (
  SELECT id_modelo, quantidade
  FROM CalculoIQR
  WHERE quantidade >= (q1 - 1.5*(q3-q1)) AND quantidade <= (q3 + 1.5*(q3-q1))
)
SELECT id_modelo, AVG(quantidade) AS media_movimentada_sem_outliers
FROM DadosSemOutliers
GROUP BY id_modelo;
