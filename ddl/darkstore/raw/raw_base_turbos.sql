-- ============================================================
-- PASSO 1: Criar tabela (rode uma vez)
-- ============================================================
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.raw_base_turbos`
(
  order_code    STRING,
  modo_entrega  STRING,
  created_at    DATE,
  store_code    STRING
)
PARTITION BY created_at
OPTIONS (
  description = 'Pedidos iFood com modo de entrega e loja. Histórico incremental — atualizar com os últimos 7 dias.'
);

-- ============================================================
-- PASSO 2: Remover os últimos 7 dias (evita duplicatas)
-- ============================================================
DELETE FROM `shopper-performance-prod.darkstore.raw_base_turbos`
WHERE created_at >= DATE_SUB(CURRENT_DATE('America/Sao_Paulo'), INTERVAL 7 DAY);

-- ============================================================
-- PASSO 3: Inserir os últimos 7 dias
-- ============================================================
INSERT INTO `shopper-performance-prod.darkstore.raw_base_turbos`
SELECT
  i.cod_pedido AS order_code,
  CASE
    WHEN UPPER(i.tipo) IN ('TURBO', 'EXPRESS')                       THEN 'EXPRESS'
    WHEN UPPER(i.tipo) IN ('FAST_DELIVERY', 'FAST_DELIVERY_OVERLAP') THEN 'FAST_DELIVERY'
    ELSE 'DEFAULT'
  END AS modo_entrega,
  SAFE_CAST(i.data AS DATE) AS created_at,
  CASE p.fulfillment_center_id
    WHEN 6  THEN 'pamplona'         WHEN 8  THEN 'moema'
    WHEN 9  THEN 'pinheiros'        WHEN 10 THEN 'higienopolis'
    WHEN 11 THEN 'vila olimpia'     WHEN 12 THEN 'alto de pinheiros'
    WHEN 13 THEN 'barra funda'      WHEN 14 THEN 'morumbi'
    WHEN 15 THEN 'vila mariana'     WHEN 16 THEN 'brooklin'
    WHEN 17 THEN 'são caetano'      WHEN 18 THEN 'campinas'
    WHEN 19 THEN 'tatuapé'
    ELSE LOWER(TRIM(p.fulfillment_center))
  END AS store_code
FROM `shopper-performance-prod.darkstore.raw_pedidos_ifood` AS i
LEFT JOIN `shopper-datalakehouse-prod.operations.picking_and_packing_pedidos_n2` AS p
  ON i.cod_pedido = p.order_code
WHERE SAFE_CAST(i.data AS DATE) >= DATE_SUB(CURRENT_DATE('America/Sao_Paulo'), INTERVAL 7 DAY)
  AND (p.fulfillment_center_id NOT IN (1, 2, 3, 7) OR p.fulfillment_center_id IS NULL);
