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
          'SUSPENSÃO',
          'SUSPENSAO',
          'FALTA - ADVERTÊNCIA',
          'FALTA - ADVERTENCIA'
        ) THEN 'FALTA_RH'
        WHEN UPPER(TRIM(Motivo)) IN (
          'ATESTADO',
          'ATESTADO (ADM)',
          'ATESTADO (OPERAÇÃO)',
          'ATESTADO (OPERACAO)'
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
          WHEN UPPER(TRIM(Motivo)) IN (
            'SUSPENSÃO',
            'SUSPENSAO',
            'FALTA - ADVERTÊNCIA',
            'FALTA - ADVERTENCIA'
          ) THEN 1
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

  -- 2.1 ASSIDUIDADE (EXTRAÇÃO DOS MOTIVOS PARA BUSCA DE DATAS)
  Assiduidade_Motivos AS (
    SELECT DISTINCT
      CAST(matricula AS NUMERIC) AS matricula_falta,
      LOWER(motivo) AS motivo_texto
    FROM `shopper-datalakehouse-qa.Ranking_Performance.assiduidade_resultados`
    WHERE periodo_inicio = v_inicio
      AND (
        LOWER(motivo) LIKE '%absence%'
        OR LOWER(motivo) LIKE '%falta%'
        OR LOWER(motivo) LIKE '%atestado%'
      )
  ),

  -- 2.2 ORGANOGRAMA (FOLGAS FIXAS)
  Organograma_Folgas AS (
    SELECT DISTINCT
      CAST(matricula AS NUMERIC) AS matricula_org,
      UPPER(TRIM(FOLGA_FIXA)) AS folga_fixa
    FROM `shopper-datalakehouse-qa.Ranking_Performance.Organograma`
    WHERE matricula IS NOT NULL
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

      CASE
        WHEN am.motivo_texto IS NOT NULL
             AND REGEXP_CONTAINS(am.motivo_texto, CONCAT(r'(absence|falta|atestado).*?', FORMAT_DATE('%d/%m', COALESCE(p.reference_date, rh.dia_referencia))))
        THEN TRUE
        ELSE FALSE
      END AS tem_falta_extraida,

      CASE
        WHEN EXTRACT(DAYOFWEEK FROM COALESCE(p.reference_date, rh.dia_referencia)) = 1 AND org.folga_fixa IN ('DOMINGO') THEN TRUE
        WHEN EXTRACT(DAYOFWEEK FROM COALESCE(p.reference_date, rh.dia_referencia)) = 2 AND org.folga_fixa IN ('SEGUNDA', 'SEGUNDA-FEIRA') THEN TRUE
        WHEN EXTRACT(DAYOFWEEK FROM COALESCE(p.reference_date, rh.dia_referencia)) = 3 AND org.folga_fixa IN ('TERÇA', 'TERÇA-FEIRA', 'TERCA', 'TERCA-FEIRA') THEN TRUE
        WHEN EXTRACT(DAYOFWEEK FROM COALESCE(p.reference_date, rh.dia_referencia)) = 4 AND org.folga_fixa IN ('QUARTA', 'QUARTA-FEIRA') THEN TRUE
        WHEN EXTRACT(DAYOFWEEK FROM COALESCE(p.reference_date, rh.dia_referencia)) = 5 AND org.folga_fixa IN ('QUINTA', 'QUINTA-FEIRA') THEN TRUE
        WHEN EXTRACT(DAYOFWEEK FROM COALESCE(p.reference_date, rh.dia_referencia)) = 6 AND org.folga_fixa IN ('SEXTA', 'SEXTA-FEIRA') THEN TRUE
        WHEN EXTRACT(DAYOFWEEK FROM COALESCE(p.reference_date, rh.dia_referencia)) = 7 AND org.folga_fixa IN ('SABADO', 'SÁBADO') THEN TRUE
        ELSE FALSE
      END AS eh_folga_fixa

    FROM Pontos_Origem p
    FULL OUTER JOIN Afastamentos_Expandidos rh
      ON p.matricula_ponto = rh.matricula_rh
      AND p.reference_date = rh.dia_referencia
    LEFT JOIN Assiduidade_Motivos am
      ON COALESCE(p.matricula_ponto, rh.matricula_rh) = am.matricula_falta
    LEFT JOIN Organograma_Folgas org
      ON COALESCE(p.matricula_ponto, rh.matricula_rh) = org.matricula_org
  ),

  -- 4. APLICAÇÃO DAS REGRAS
  Tratamento_Final AS (
    SELECT
      employee_uuid,
      registration_number,
      reference_date,

      worked_hours_original AS worked_hours,

      expected_hours,
      real_hours,

      CASE
        WHEN expected_hours IS NULL THEN NULL
        WHEN eh_folga_fixa THEN NULL
        WHEN absence_original IS NOT NULL THEN absence_original
        WHEN tem_falta_extraida THEN COALESCE(expected_hours, real_hours, TIME '00:00:00')
        ELSE NULL
      END AS absence,

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
        WHEN categoria_motivo = 'FALTA_RH' AND tem_falta_extraida THEN CONCAT('FALTA POR ', motivo_original_rh)
        WHEN tem_falta_extraida AND absence_original IS NULL THEN 'FALTA (API)'
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
