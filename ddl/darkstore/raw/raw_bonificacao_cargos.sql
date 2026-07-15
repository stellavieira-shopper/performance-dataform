-- Depende de: organograma_bonificacao
-- Recriar sempre que o organograma for atualizado
CREATE OR REPLACE TABLE `shopper-performance-prod.darkstore.raw_bonificacao_cargos` AS
SELECT
  UPPER(TRIM(org.nome))                                                              AS nome,
  REGEXP_REPLACE(NORMALIZE(LOWER(TRIM(org.dark)), NFD), r'\p{M}', '')              AS setor,
  CAST(org.mat AS STRING)                                                            AS mat,
  org.cargo                                                                          AS fun_o,
  CAST(NULL AS STRING)                                                               AS atribui_o,
  UPPER(TRIM(org.turno))                                                             AS turno,
  NULL                                                                               AS data_admissao,
  NULL                                                                               AS horario_exato,
  LOWER(TRIM(u.user_email))                                                          AS email
FROM `shopper-performance-prod.darkstore.organograma_bonificacao` org
LEFT JOIN `shopper-datalakehouse-prod.shared.picking_and_packing_usuarios_n2` u
  ON TRIM(CAST(org.mat AS STRING)) = CAST(u.registration_number AS STRING)
WHERE TRIM(COALESCE(org.nome, '')) <> ''
  AND TRIM(COALESCE(org.cargo, '')) <> ''
  AND UPPER(TRIM(COALESCE(org.cargo, ''))) NOT IN ('APRENDIZ', 'APRENDIZ OPERACIONAL', 'CARGO');
