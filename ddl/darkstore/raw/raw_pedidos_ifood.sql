CREATE OR REPLACE EXTERNAL TABLE `shopper-performance-prod.darkstore.raw_pedidos_ifood`
(
  data       STRING,
  tipo       STRING,
  cod_pedido STRING,
  id_cluster STRING,
  id_ifood   STRING
)
OPTIONS (
  description = 'Pedidos iFood. External table do Google Sheets — espelho da tabela de QA.',
  format      = 'GOOGLE_SHEETS',
  uris        = ['https://docs.google.com/spreadsheets/d/1UX7DEA2mnE20fRC_qhNmhpi7loaT2YanQTUOUIaonTc/edit?gid=0#gid=0'],
  sheet_range = 'Base!A02:E',
  skip_leading_rows = 0
);
