-- DDL: pedidos_lojinhas — equivalente à View_Pedidos_Lojinhas do intraday (snapshot semanal)
-- Projeto: shopper-performance-prod | Dataset: darkstore
CREATE TABLE IF NOT EXISTS `shopper-performance-prod.darkstore.pedidos_lojinhas`
(
  order_date                      DATE,
  delivery_date                   DATE,
  loja                            STRING,
  fulfillment_center_id           INT64,
  status_pedido                   STRING,
  order_code                      STRING,
  kdabra_order_id                 INT64,
  tipo_de_pedido                  STRING,
  status_sla                      STRING,
  sla_seconds                     INT64,
  cycle_duration_seconds          INT64,
  tempo_para_iniciar_seconds      INT64,
  inicio_picking                  TIMESTAMP,
  fim_packing                     TIMESTAMP,
  pedido_criado_em                TIMESTAMP,
  delivery_time_frame_start       STRING,
  delivery_time_frame_end         STRING,
  foto_url                        STRING,
  ingested_at                     TIMESTAMP
)
PARTITION BY delivery_date;
