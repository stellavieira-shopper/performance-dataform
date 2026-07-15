BEGIN

  -- Datas calculadas automaticamente (mesma lógica do Ranking: sexta a quinta)
  DECLARE v_inicio DATE;
  DECLARE v_fim    DATE;

  SET (v_inicio, v_fim) = (
    SELECT AS STRUCT
      CASE WHEN dow IN (4, 5) THEN anchor_friday ELSE DATE_SUB(anchor_friday, INTERVAL 7 DAY) END AS v_inicio,
      CASE WHEN dow IN (4, 5) THEN DATE_ADD(anchor_friday, INTERVAL 6 DAY) ELSE DATE_SUB(anchor_friday, INTERVAL 1 DAY) END AS v_fim
    FROM (
      SELECT current_dt, EXTRACT(DAYOFWEEK FROM current_dt) AS dow,
        DATE_SUB(current_dt, INTERVAL MOD(EXTRACT(DAYOFWEEK FROM current_dt) - 6 + 7, 7) DAY) AS anchor_friday
      FROM (SELECT CURRENT_DATE('America/Sao_Paulo') AS current_dt)
    )
  );

  -- 1. LIMPEZA PREVENTIVA
  DELETE FROM `shopper-datalakehouse-qa.Ranking_Performance.Expected Points Tratada`
  WHERE reference_date BETWEEN v_inicio AND v_fim;

  -- 2. INSERÇÃO DOS NOVOS DADOS
  INSERT INTO `shopper-datalakehouse-qa.Ranking_Performance.Expected Points Tratada` (
    employee_uuid,
    registration_number,
    reference_date,
    worked_hours,
    expected_hours,
    real_hours,
    absence,
    negative_hour_balance,
    positive_hour_balance,
    allowance,
    medical_certificate,
    reprimand_absence,
    hours_declaration,
    delay,
    extra_hour_100_percent,
    vacation,
    motivo_consolidado,
    expected_points
  )

  WITH
  -- 1. TRATAMENTO E DEDUPLICAÇÃO DE AFASTAMENTOS (RH)
  Afastamentos_Expandidos AS (
    SELECT
      CAST(Matricula AS NUMERIC) AS matricula_rh,
      Nome AS nome_rh,
      UPPER(TRIM(Motivo)) AS motivo_original_rh,

      CASE
        WHEN UPPER(TRIM(Motivo)) IN ('FÉRIAS', 'FERIAS') THEN 'FERIAS'
        WHEN UPPER(TRIM(Motivo)) IN (
          'SUSPENSÃO','SUSPENSAO','FALTA - ADVERTÊNCIA','FALTA - ADVERTENCIA'
        ) THEN 'FALTA_RH'
        WHEN UPPER(TRIM(Motivo)) IN (
          'ATESTADO','ATESTADO (ADM)','ATESTADO (OPERAÇÃO)','ATESTADO (OPERACAO)'
        ) THEN 'ATESTADO_RH'
        ELSE 'OUTROS'
      END AS categoria_motivo,

      dia_referencia
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Afastamentos`,
    UNNEST(GENERATE_DATE_ARRAY(Data_inicio, Data_final)) AS dia_referencia
    WHERE Data_inicio <= v_fim
      AND Data_final >= v_inicio
      AND dia_referencia BETWEEN v_inicio AND v_fim
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY CAST(Matricula AS NUMERIC), dia_referencia
      ORDER BY
        CASE
          WHEN UPPER(TRIM(Motivo)) IN ('SUSPENSÃO','SUSPENSAO','FALTA - ADVERTÊNCIA','FALTA - ADVERTENCIA') THEN 1
          WHEN UPPER(TRIM(Motivo)) IN ('FÉRIAS', 'FERIAS') THEN 2
          WHEN UPPER(TRIM(Motivo)) LIKE 'ATESTADO%' THEN 3
          ELSE 4
        END ASC,
        Data_inicio DESC
    ) = 1
  ),

  -- 2. TRATAMENTO E DEDUPLICAÇÃO DO PONTO (ORIGEM)
  Pontos_Origem AS (
    SELECT
      *,
      SAFE_CAST(registration_number AS NUMERIC) AS matricula_ponto
    FROM `shopper-datalakehouse-prod.performance.performance_expected_points_daily_n2`
    WHERE reference_date BETWEEN v_inicio AND v_fim
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY SAFE_CAST(registration_number AS NUMERIC), reference_date
      ORDER BY worked_hours DESC, expected_points DESC
    ) = 1
  ),

  -- 2.1 FALTAS
  Faltas_Assiduidade AS (
    SELECT DISTINCT
      p.matricula_ponto AS matricula_falta,
      TRUE AS possui_falta_registrada
    FROM Pontos_Origem p
    INNER JOIN `shopper-datalakehouse-qa.Ranking_Performance.assiduidade_resultados` a
      ON CAST(a.matricula AS NUMERIC) = p.matricula_ponto
     AND a.periodo_inicio = v_inicio
     AND a.tem_direito = 'Não'
    WHERE p.absence IS NOT NULL
       OR LOWER(a.motivo) LIKE '%absence%'
       OR LOWER(a.motivo) LIKE '%falta%'
  ),

  -- 3. UNIFICAÇÃO
  Base_Unificada AS (
    SELECT
      COALESCE(p.employee_uuid, CONCAT('rh_gen_', CAST(rh.matricula_rh AS STRING))) AS employee_uuid,
      COALESCE(p.matricula_ponto, rh.matricula_rh) AS registration_number,
      COALESCE(p.reference_date, rh.dia_referencia) AS reference_date,
      p.worked_hours AS worked_hours_original,
      p.expected_hours,
      p.real_hours,
      p.absence AS absence_original,
      p.negative_hour_balance,
      p.positive_hour_balance,
      p.allowance,
      p.medical_certificate AS medical_original,
      p.reprimand_absence,
      p.hours_declaration,
      p.delay,
      p.extra_hour_100_percent,
      p.vacation AS vacation_original,
      p.expected_points,
      rh.motivo_original_rh,
      rh.categoria_motivo,
      CASE WHEN p.matricula_ponto IS NOT NULL THEN TRUE ELSE FALSE END AS existe_no_ponto,
      CASE WHEN rh.matricula_rh IS NOT NULL THEN TRUE ELSE FALSE END AS existe_no_rh,
      COALESCE(fa.possui_falta_registrada, FALSE) AS tem_falta_assiduidade,
      CASE
        WHEN COALESCE(fa.possui_falta_registrada, FALSE) IS TRUE THEN TRUE
        WHEN p.absence IS NOT NULL THEN TRUE
        WHEN p.medical_certificate IS NOT NULL THEN TRUE
        WHEN p.vacation IS NOT NULL THEN TRUE
        WHEN p.reprimand_absence IS NOT NULL THEN TRUE
        WHEN rh.categoria_motivo IN ('FERIAS', 'ATESTADO_RH', 'FALTA_RH') THEN TRUE
        ELSE FALSE
      END AS possui_ocorrencia_bloqueante
    FROM Pontos_Origem p
    FULL OUTER JOIN Afastamentos_Expandidos rh
      ON p.matricula_ponto = rh.matricula_rh
     AND p.reference_date = rh.dia_referencia
    LEFT JOIN Faltas_Assiduidade fa
      ON COALESCE(p.matricula_ponto, rh.matricula_rh) = fa.matricula_falta
  ),

  -- 4. APLICAÇÃO DAS REGRAS
  Tratamento_Final AS (
    SELECT
      employee_uuid,
      registration_number,
      reference_date,
      CASE
        WHEN worked_hours_original IS NOT NULL THEN worked_hours_original
        WHEN worked_hours_original IS NULL AND real_hours IS NOT NULL AND possui_ocorrencia_bloqueante IS FALSE THEN real_hours
        ELSE worked_hours_original
      END AS worked_hours,
      expected_hours,
      real_hours,
      IF(tem_falta_assiduidade, COALESCE(absence_original, expected_hours, real_hours, TIME '00:00:00'), NULL) AS absence,
      negative_hour_balance,
      positive_hour_balance,
      allowance,
      CASE
        WHEN categoria_motivo = 'ATESTADO_RH' THEN COALESCE(medical_original, expected_hours, real_hours, TIME '00:00:00')
        ELSE medical_original
      END AS medical_certificate,
      reprimand_absence,
      hours_declaration,
      delay,
      extra_hour_100_percent,
      CASE
        WHEN categoria_motivo = 'FERIAS' THEN COALESCE(vacation_original, expected_hours, real_hours, TIME '00:00:00')
        ELSE NULL
      END AS vacation,
      CASE
        WHEN categoria_motivo = 'FERIAS' THEN 'FÉRIAS (RH)'
        WHEN categoria_motivo = 'ATESTADO_RH' THEN CONCAT('JUSTIFICATIVA: ', motivo_original_rh)
        WHEN medical_original IS NOT NULL THEN 'ATESTADO (PONTO)'
        WHEN categoria_motivo = 'FALTA_RH' AND tem_falta_assiduidade THEN CONCAT('FALTA POR ', motivo_original_rh)
        WHEN tem_falta_assiduidade AND absence_original IS NULL THEN 'FALTA (API)'
        WHEN worked_hours_original IS NULL AND real_hours IS NOT NULL AND possui_ocorrencia_bloqueante IS FALSE THEN 'WORKED HOURS PREENCHIDO COM REAL HOURS'
        ELSE NULL
      END AS motivo_consolidado,
      expected_points,
      existe_no_rh,
      existe_no_ponto,
      worked_hours_original,
      medical_original,
      absence_original
    FROM Base_Unificada
  )

  -- 5. SELEÇÃO FINAL
  SELECT
    employee_uuid,
    registration_number,
    reference_date,
    worked_hours,
    expected_hours,
    real_hours,
    absence,
    negative_hour_balance,
    positive_hour_balance,
    allowance,
    medical_certificate,
    reprimand_absence,
    hours_declaration,
    delay,
    extra_hour_100_percent,
    vacation,
    motivo_consolidado,
    expected_points
  FROM Tratamento_Final
  WHERE
    (
      existe_no_rh = TRUE
      OR
      (
        existe_no_rh = FALSE
        AND (
          worked_hours IS NOT NULL
          OR real_hours IS NOT NULL
          OR medical_original IS NOT NULL
          OR delay IS NOT NULL
          OR hours_declaration IS NOT NULL
          OR reprimand_absence IS NOT NULL
          OR allowance IS NOT NULL
          OR negative_hour_balance IS NOT NULL
          OR positive_hour_balance IS NOT NULL
          OR extra_hour_100_percent IS NOT NULL
          OR (absence_original IS NOT NULL)
          OR absence IS NOT NULL
        )
      )
    )
  ORDER BY registration_number, reference_date;

END;
