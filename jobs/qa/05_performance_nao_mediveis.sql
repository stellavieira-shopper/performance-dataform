BEGIN

  DECLARE v_start_date DATE;
  DECLARE v_end_date DATE;

  SET (v_start_date, v_end_date) = (
    SELECT AS STRUCT
      CASE
        WHEN dow IN (4, 5) THEN anchor_friday
        ELSE DATE_SUB(anchor_friday, INTERVAL 7 DAY)
      END AS DS_START_DATE,
      CASE
        WHEN dow IN (4, 5) THEN DATE_ADD(anchor_friday, INTERVAL 6 DAY)
        ELSE DATE_SUB(anchor_friday, INTERVAL 1 DAY)
      END AS DS_END_DATE
    FROM (
      SELECT
        current_dt,
        EXTRACT(DAYOFWEEK FROM current_dt) AS dow,
        DATE_SUB(current_dt, INTERVAL MOD(EXTRACT(DAYOFWEEK FROM current_dt) - 6 + 7, 7) DAY) AS anchor_friday
      FROM (SELECT CURRENT_DATE('America/Sao_Paulo') AS current_dt)
    )
  );

  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Performance Colaboradores Nao Mediveis`
  WHERE data_inicio_periodo = v_start_date;

  CREATE OR REPLACE TEMP TABLE tmp_PessoasUnicas AS
  SELECT * EXCEPT(rn)
  FROM (
    SELECT
      SAFE_CAST(MATRICULA AS INT64) AS MATRICULA,
      UPPER(TRIM(NOME)) AS NOME,
      UPPER(TRIM(SETOR)) AS SETOR,
      UPPER(TRIM(ATRIBUICAO)) AS ATRIBUICAO,
      UPPER(TRIM(TURNO)) AS TURNO,
      UPPER(TRIM(FC)) AS FC,
      ROW_NUMBER() OVER(PARTITION BY MATRICULA ORDER BY DATA_ADM DESC) AS rn
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Organograma`
  )
  WHERE rn = 1
    AND MATRICULA IS NOT NULL;

  CREATE OR REPLACE TEMP TABLE tmp_AuxFaltantes AS
  SELECT DISTINCT
    SAFE_CAST(matricula AS INT64) AS MATRICULA
  FROM `shopper-datalakehouse-qa.Ranking_Performance.aux_faltantes`
  WHERE matricula IS NOT NULL;

  CREATE OR REPLACE TEMP TABLE tmp_DadosPonto AS
  SELECT
    SAFE_CAST(registration_number AS INT64) AS MATRICULA,
    COUNTIF(absence IS NOT NULL) AS FALTAS,
    COUNTIF(medical_certificate IS NOT NULL) AS ATESTADOS,
    COUNTIF(delay IS NOT NULL) AS qtd_delay,
    SUM(
      IF(
        delay IS NOT NULL,
        EXTRACT(HOUR FROM delay) * 3600
          + EXTRACT(MINUTE FROM delay) * 60
          + EXTRACT(SECOND FROM delay),
        0
      )
    ) AS total_segundos_delay,
    COUNTIF(hours_declaration IS NOT NULL) AS qtd_hours_declaration,
    SUM(
      IF(
        hours_declaration IS NOT NULL,
        EXTRACT(HOUR FROM hours_declaration) * 3600
          + EXTRACT(MINUTE FROM hours_declaration) * 60
          + EXTRACT(SECOND FROM hours_declaration),
        0
      )
    ) AS total_segundos_declaration
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Expected Points Tratada`
  WHERE reference_date BETWEEN v_start_date AND v_end_date
  GROUP BY 1;

  CREATE OR REPLACE TEMP TABLE tmp_DadosMedidas AS
  SELECT
    SAFE_CAST(MATRICULA AS INT64) AS MATRICULA,
    COUNT(*) AS ADVERTENCIAS
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Medidas Disciplinares `
  WHERE DATA_OCORRENCIA BETWEEN v_start_date AND v_end_date
    AND APLICADA IS TRUE
    AND INDEVIDA IS FALSE
  GROUP BY 1;

  CREATE OR REPLACE TEMP TABLE tmp_DadosAfastamentos AS
  SELECT
    SAFE_CAST(Matricula AS INT64) AS MATRICULA,
    STRING_AGG(DISTINCT Motivo, ', ') AS motivo_afastamento
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Afastamentos`
  WHERE Data_inicio <= v_end_date
    AND Data_final >= v_start_date
    AND UPPER(TRIM(Motivo)) IN (
      'AFASTAMENTO INSS',
      'AFASTAMENTO NÃO REMUNERADO',
      'LICENÇA MATERNIDADE',
      'FÉRIAS'
    )
  GROUP BY 1;

  CREATE OR REPLACE TEMP TABLE tmp_KPIs AS
  SELECT
    CAST(MATRICULA AS STRING) AS MATRICULA,
    (
      COALESCE(MULT_MATRICULA, 1.0)
      * COALESCE(MULT_TURNO, 1.0)
      * COALESCE(MULT_SETOR, 1.0)
      * COALESCE(MULT_ATRIBUICAO, 1.0)
      * COALESCE(MULT_FC, 1.0)
    ) AS mult_total
  FROM `shopper-datalakehouse-qa.Ranking_Performance.KPIs_OPERAÇÃO`
  WHERE data_inicio = v_start_date;

  CREATE OR REPLACE TEMP TABLE tmp_MetricasRanking AS
  SELECT
    r.FC,
    r.TURNO,
    AVG(r.pontuacao_final) AS media_turno,
    MAX(MAX(r.pontuacao_final)) OVER(PARTITION BY r.FC) AS max_fc_global
  FROM `shopper-datalakehouse-qa.Ranking_Performance.Ranking Semanal` r
  WHERE r.data_inicio_periodo = v_start_date
  GROUP BY 1, 2;

  CREATE OR REPLACE TEMP TABLE tmp_Carteira AS
  SELECT
    SAFE_CAST(matricula AS INT64) AS MATRICULA,
    CAST(saldo_pos_bonificacao AS STRING) AS SALDO
  FROM `shopper-datalakehouse-qa.Ranking_Performance.carteira_operação`
  WHERE data_inicio_ranking < v_start_date
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY SAFE_CAST(matricula AS INT64)
    ORDER BY data_inicio_ranking DESC, update_at DESC, report_at DESC
  ) = 1;

  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Performance Colaboradores Nao Mediveis` (
    data_inicio_periodo,
    data_fim_periodo,
    matricula,
    nome,
    setor,
    turno,
    fc,
    atribuicao,
    pontuacao_atribuida,
    valor_bonificacao,
    motivo_desqualificacao,
    qtd_faltas,
    qtd_atestados,
    qtd_advertencias,
    atrasos,
    declaracao_horas,
    VALOR_A_RECEBER_ANTES_DO_KPI,
    saldo_da_carteira
  )

  WITH ColaboradoresAlvo AS (
    SELECT
      pu.*,
      IF(aux.MATRICULA IS NOT NULL, TRUE, FALSE) AS flag_aux_faltantes
    FROM tmp_PessoasUnicas pu
    LEFT JOIN tmp_AuxFaltantes aux
      ON pu.MATRICULA = aux.MATRICULA
    WHERE
      (
        (
          (pu.SETOR = 'MANUTENÇÃO' AND pu.ATRIBUICAO = 'AUX. MANUTENÇÃO')
          OR (pu.SETOR = 'PRÉ OPERAÇÃO' AND pu.ATRIBUICAO IN ('AUXILIAR','IMPRESSÃO DE NOTA','INSUMOS'))
          OR (pu.SETOR = 'RECEBIMENTO' AND pu.ATRIBUICAO = 'AUXILIAR NF')
          OR (pu.SETOR IN ('PRÉ EXPEDIÇÃO', 'EXPEDIÇÃO') AND pu.ATRIBUICAO IN ('AUXILIAR NF','AUXILIAR NFE','IMPRESSÃO DE NOTA','IMPRESSÃO DE ROMANEIO','IMPRESSÃO DE NOTAS'))
          OR (pu.SETOR = 'BRINDE' AND pu.ATRIBUICAO IN ('BRINDE', 'BODAS'))
          OR (pu.SETOR = 'GESTÃO DE ESTOQUE' AND pu.ATRIBUICAO IN ('GESTÃO DE ESTOQUE','INSUMOS','FALTANTES'))
          OR (pu.SETOR = 'LOGISTICA' AND pu.ATRIBUICAO IN ('IMPRESSÃO DE ROMANEIO','AUX. ROMANEIO'))
          OR (pu.SETOR = 'OPERAÇÃO FRESH' AND pu.ATRIBUICAO IN ('INSUMOS'))
          OR (pu.SETOR = 'LIMPEZA' AND pu.ATRIBUICAO = 'LIMPEZA')
          OR (pu.SETOR = 'EXPEDIÇÃO CAMPINAS' AND pu.ATRIBUICAO IN ('AUX. EXPEDIÇÃO CAMPINAS','FISCAL - CAMPINAS'))
          OR pu.ATRIBUICAO IN ('RONDA/REPOSITOR FLV','PICADOS','RONDA - SEMANA')
          OR (pu.FC = 'FC2' AND pu.ATRIBUICAO = 'INVENTÁRIO')
        )
        OR (
          (pu.ATRIBUICAO LIKE '%FISCAL%' OR pu.ATRIBUICAO LIKE '%SUPERVISOR%')
          AND pu.SETOR IN ('MANUTENÇÃO','PRÉ OPERAÇÃO','BRINDE','GESTÃO DE ESTOQUE','LOGISTICA','LIMPEZA')
          AND pu.SETOR NOT IN ('PRÉ EXPEDIÇÃO','EXPEDIÇÃO','FRACIONAMENTO','REPOSIÇÃO','OPERAÇÃO FRESH','RECEBIMENTO')
        )
        OR aux.MATRICULA IS NOT NULL
      )
      AND pu.ATRIBUICAO NOT IN (
        'FISCAL - PERDAS MERCEARIA',
        'FISCAL - PERDAS/DESFAZER PEDIDOS FRESH',
        'FISCAL - PERDAS',
        'FISCAL - INVENTÁRIO',
        'FISCAL PERDAS MERCEARIA',
        'FISCAL PERDAS/DESFAZER PEDIDOS FRESH',
        'PERDAS FISCAL PERDAS',
        'FISCAL INVENTÁRIO'
      )
  ),

  ProcessamentoFinal AS (
    SELECT
      c.*,
      COALESCE(pt.FALTAS, 0) AS FALTAS,
      COALESCE(pt.ATESTADOS, 0) AS ATESTADOS,
      COALESCE(md.ADVERTENCIAS, 0) AS ADVERTENCIAS,
      af.motivo_afastamento,
      FORMAT(
        '%d (%02d:%02d:%02d)',
        COALESCE(pt.qtd_delay, 0),
        DIV(COALESCE(pt.total_segundos_delay, 0), 3600),
        DIV(MOD(COALESCE(pt.total_segundos_delay, 0), 3600), 60),
        MOD(COALESCE(pt.total_segundos_delay, 0), 60)
      ) AS atrasos_fmt,
      FORMAT(
        '%d (%02d:%02d:%02d)',
        COALESCE(pt.qtd_hours_declaration, 0),
        DIV(COALESCE(pt.total_segundos_declaration, 0), 3600),
        DIV(MOD(COALESCE(pt.total_segundos_declaration, 0), 3600), 60),
        MOD(COALESCE(pt.total_segundos_declaration, 0), 60)
      ) AS declaracao_fmt,
      COALESCE(k.mult_total, 1.0) AS mult_total,
      CASE
        WHEN c.flag_aux_faltantes IS TRUE THEN COALESCE(tr.media_turno, 0) * 2
        ELSE COALESCE(tr.media_turno, 0)
      END AS pts_referencia,
      COALESCE(tr.max_fc_global, 0) AS max_fc_ref,
      COALESCE(cfg.valor_minimo, 0) AS valor_minimo,
      COALESCE(cfg.valor_maximo, 0) AS valor_maximo,
      cart.SALDO AS saldo_da_carteira
    FROM ColaboradoresAlvo c
    LEFT JOIN tmp_DadosPonto pt ON c.MATRICULA = pt.MATRICULA
    LEFT JOIN tmp_DadosMedidas md ON c.MATRICULA = md.MATRICULA
    LEFT JOIN tmp_DadosAfastamentos af ON c.MATRICULA = af.MATRICULA
    LEFT JOIN tmp_KPIs k ON CAST(c.MATRICULA AS STRING) = k.MATRICULA
    LEFT JOIN tmp_MetricasRanking tr ON c.FC = tr.FC AND c.TURNO = tr.TURNO
    LEFT JOIN tmp_Carteira cart ON c.MATRICULA = cart.MATRICULA
    CROSS JOIN (
      SELECT valor_minimo, valor_maximo
      FROM `shopper-datalakehouse-qa.Ranking_Performance.Config_Bonificacao_Ranking`
      LIMIT 1
    ) cfg
  ),

  CalculoBonus AS (
    SELECT
      *,
      CASE
        WHEN motivo_afastamento IS NOT NULL THEN motivo_afastamento
        WHEN FALTAS > 0 THEN 'Falta'
        WHEN ADVERTENCIAS > 0 THEN 'Advertência'
        WHEN ATESTADOS > 0 THEN 'Atestado'
        WHEN pts_referencia = 0 THEN 'Sem Produção no Turno'
        ELSE NULL
      END AS motivo_desq_label,
      CASE
        WHEN (
          motivo_afastamento IS NOT NULL
          OR FALTAS > 0
          OR ADVERTENCIAS > 0
          OR ATESTADOS > 0
          OR pts_referencia = 0
        ) THEN 0
        ELSE
          IF(
            pts_referencia <= 1000000,
            (pts_referencia / 1000000) * valor_minimo,
            valor_minimo
              + ((pts_referencia - 1000000) / GREATEST(1, max_fc_ref - 1000000))
                * (valor_maximo - valor_minimo)
          )
      END AS valor_bruto
    FROM ProcessamentoFinal
  )

  SELECT
    v_start_date AS data_inicio_periodo,
    v_end_date AS data_fim_periodo,
    MATRICULA AS matricula,
    COALESCE(NOME, 'N/A') AS nome,
    COALESCE(SETOR, 'N/A') AS setor,
    COALESCE(TURNO, 'N/A') AS turno,
    COALESCE(FC, 'N/A') AS fc,
    COALESCE(ATRIBUICAO, 'N/A') AS atribuicao,
    COALESCE(ROUND(pts_referencia, 2), 0) AS pontuacao_atribuida,
    COALESCE(ROUND(valor_bruto * mult_total, 2), 0) AS valor_bonificacao,
    COALESCE(motivo_desq_label, '') AS motivo_desqualificacao,
    COALESCE(FALTAS, 0) AS qtd_faltas,
    COALESCE(ATESTADOS, 0) AS qtd_atestados,
    COALESCE(ADVERTENCIAS, 0) AS qtd_advertencias,
    COALESCE(atrasos_fmt, '0 (00:00:00)') AS atrasos,
    COALESCE(declaracao_fmt, '0 (00:00:00)') AS declaracao_horas,
    IF(
      COALESCE(ROUND(valor_bruto, 2), 0) <> COALESCE(ROUND(valor_bruto * mult_total, 2), 0)
      AND valor_bruto > 0,
      COALESCE(ROUND(valor_bruto, 2), 0),
      0
    ) AS VALOR_A_RECEBER_ANTES_DO_KPI,
    COALESCE(saldo_da_carteira, '0') AS saldo_da_carteira
  FROM CalculoBonus;

END;
