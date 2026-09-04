-- ============================================================
-- DELIVERIES v5 - episode-based, real claim date spans
-- ============================================================
-- ============================================================


-- ============================================================
-- 1. CODE HITS (claim level, one row per matched code)
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_code_hits;

CREATE TABLE colour.delivery_code_hits AS
WITH del_dx AS (
    SELECT btrim(code) AS code, baby_count
    FROM colour.ref_orr2024_codelists
    WHERE tab = 'delivery' AND code_type = 'ICD-10-CM'
),
del_cpt AS (
    SELECT btrim(code) AS code
    FROM colour.ref_orr2024_codelists
    WHERE tab = 'delivery' AND code_type = 'CPT'
),
dx_hits AS (
    SELECT DISTINCT
        a.pers_id,
        a.clm_id,
        btrim(a.dx)   AS code,
        'ICD-10-CM'   AS code_type,
        b.baby_count,
        NULL::date    AS line_dos_from,
        NULL::date    AS line_dos_thru
    FROM research_di.med_dx a
    JOIN del_dx b ON btrim(a.dx) = b.code
),
cpt_hits AS (
    SELECT
        a.pers_id,
        a.clm_id,
        btrim(a.proc_cd) AS code,
        'CPT'            AS code_type,
        NULL::integer    AS baby_count,
        a.dos_from       AS line_dos_from,
        a.dos_thru       AS line_dos_thru
    FROM research_di.medical_adj a
    JOIN del_cpt b ON btrim(a.proc_cd) = b.code
)
SELECT * FROM dx_hits
UNION ALL
SELECT * FROM cpt_hits;



-- ============================================================
-- 2. CLAIM-LEVEL DATE SPANS
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_claim_dates;

CREATE TABLE colour.delivery_claim_dates AS
SELECT
    a.pers_id,
    a.clm_id,
    MIN(a.dos_from)      AS dos_from,
    MAX(a.dos_thru)      AS dos_thru,
    MIN(a.admit_dt)      AS admit_dt,
    MAX(a.discharge_dt)  AS discharge_dt,
    MAX(btrim(a.claim_type)) AS claim_type,
    COUNT(*)             AS n_lines
FROM research_di.medical_adj a
JOIN (SELECT DISTINCT pers_id, clm_id FROM colour.delivery_code_hits) h
  ON h.pers_id = a.pers_id
 AND h.clm_id  = a.clm_id
GROUP BY a.pers_id, a.clm_id;

select * from colour.delivery_claim_dates order by 1,3;


-- ============================================================
-- 3. CLAIM-LEVEL STAGING + DOB / AGE
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_claims_stg;

CREATE TABLE colour.delivery_claims_stg AS
SELECT
    h.pers_id,
    h.clm_id,
    d.dos_from,
    d.dos_thru,
    h.line_dos_from,
    h.line_dos_thru,
    d.admit_dt,
    d.discharge_dt,
    d.claim_type,
    h.code,
    h.code_type,
    h.baby_count,
    b.dob,
    b.mult_dob,
    CASE WHEN b.dob IS NULL THEN NULL
         ELSE date_part('year', age(d.dos_from, b.dob))::integer
    END AS age_at_dos
FROM colour.delivery_code_hits h
JOIN colour.delivery_claim_dates d
  ON d.pers_id = h.pers_id AND d.clm_id = h.clm_id
LEFT JOIN (
    SELECT pers_id,
           MIN(dob_derv) AS dob,
           MAX(COALESCE(mult_dob, 0)) AS mult_dob
    FROM colour.dob
    WHERE dob_derv IS NOT NULL
    GROUP BY pers_id
) b ON b.pers_id = h.pers_id;


-- ============================================================
-- 4. AGE QUALIFICATION (person level)
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_claims_qual;

CREATE TABLE colour.delivery_claims_qual AS
WITH person_age AS (
    SELECT
        pers_id,
        MAX(CASE WHEN age_at_dos BETWEEN 12 AND 50 THEN 1 ELSE 0 END) AS any_in_range,
        MAX(CASE WHEN dob IS NOT NULL THEN 1 ELSE 0 END) AS has_dob
    FROM colour.delivery_claims_stg
    GROUP BY pers_id
),
qualified AS (
    SELECT pers_id,
           CASE WHEN has_dob = 0 THEN 'unknown' ELSE 'in range' END AS age_status
    FROM person_age
    WHERE any_in_range = 1
       OR has_dob = 0
)
SELECT a.*, q.age_status
FROM colour.delivery_claims_stg a
JOIN qualified q ON q.pers_id = a.pers_id;


-- ============================================================
-- 5. PSEUDO-EPISODES (claim level, nothing dropped)
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_claim_episodes;

CREATE TABLE colour.delivery_claim_episodes AS
WITH cfg AS (
    SELECT 1::integer AS gap_days           -- >>> EDIT <<< see note above
),
ordered AS (
    SELECT
        a.*,
        c.gap_days,
        ROW_NUMBER() OVER (PARTITION BY a.pers_id
                           ORDER BY a.dos_from, a.dos_thru, a.clm_id, a.code) AS rn
    FROM colour.delivery_claims_qual a
    CROSS JOIN cfg c
),
running AS (
    SELECT
        o.*,
        MAX(dos_thru) OVER (PARTITION BY pers_id ORDER BY rn
                            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
            AS max_end_before
    FROM ordered o
),
flagged AS (
    SELECT
        r.*,
        CASE
            WHEN max_end_before IS NULL THEN 1                 -- first row for this person
            WHEN dos_from > max_end_before + gap_days THEN 1   -- gap wider than tolerance
            ELSE 0                                             -- overlaps / abuts
        END AS new_episode_flag
    FROM running r
)
SELECT
    pers_id, clm_id, dos_from, dos_thru, line_dos_from, line_dos_thru,
    admit_dt, discharge_dt, claim_type,
    code, code_type, baby_count,
    dob, mult_dob, age_at_dos, age_status,
    SUM(new_episode_flag) OVER (PARTITION BY pers_id ORDER BY rn
                                ROWS UNBOUNDED PRECEDING) AS episode_id
FROM flagged;


-- ============================================================
-- 6. EPISODE SUMMARY
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_episodes;

CREATE TABLE colour.delivery_episodes AS
SELECT
    pers_id,
    episode_id,
    -- full-span bounds (drove the collapse)
    MIN(dos_from) AS episode_start,
    MAX(dos_thru) AS episode_end,
    (MAX(dos_thru) - MIN(dos_from)) AS episode_len_days,
    MIN(admit_dt)     AS admit_dt,
    MAX(discharge_dt) AS discharge_dt,
    -- CPT-only bounds (procedure dates)
    MIN(CASE WHEN code_type = 'CPT' THEN line_dos_from END) AS cpt_dos_min,
    MAX(CASE WHEN code_type = 'CPT' THEN line_dos_thru END) AS cpt_dos_max,
    MIN(CASE WHEN code_type = 'ICD-10-CM' THEN dos_from END) AS dx_dos_min,
    COALESCE(MIN(CASE WHEN code_type = 'CPT' THEN line_dos_from END),
             MIN(dos_from)) AS delivery_dt,
    CASE WHEN MIN(CASE WHEN code_type = 'CPT' THEN line_dos_from END) IS NOT NULL
         THEN 'cpt' ELSE 'diagnosis' END AS delivery_dt_src,
    MAX(COALESCE(baby_count, 1)) AS baby_count,
    MAX(baby_count)              AS baby_count_coded,  -- NULL if no dx code carried one
    COUNT(*)                                                 AS n_code_rows,
    COUNT(DISTINCT clm_id)                                   AS n_claims,
    SUM(CASE WHEN code_type = 'CPT' THEN 1 ELSE 0 END)       AS n_cpt_rows,
    SUM(CASE WHEN code_type = 'ICD-10-CM' THEN 1 ELSE 0 END) AS n_dx_rows,
    MAX(dob)        AS dob,
    MAX(mult_dob)   AS mult_dob,
    MAX(age_status) AS age_status,
    MIN(age_at_dos) AS age_at_delivery
FROM colour.delivery_claim_episodes
GROUP BY pers_id, episode_id;



-- ============================================================
-- 7. INSURANCE (episode grain)
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_episodes_insurance_stg;

CREATE TABLE colour.delivery_episodes_insurance_stg AS
WITH ep AS (
    SELECT
        e.*,
        EXTRACT(YEAR FROM e.delivery_dt)::integer AS delivery_year
    FROM colour.delivery_episodes e
)
SELECT
    a.*,
    b.prim_med_plan,
    CASE
        WHEN b.prim_med_plan = 'Medicaid' THEN 'Medicaid'
        WHEN b.prim_med_plan IN ('Commercial', 'Com-Ers', 'Com-ErsTrs', 'Com-Trs') THEN 'Commercial'
        WHEN b.prim_med_plan IS NULL THEN 'Not Enrolled'
        ELSE 'Other'
    END AS ins
FROM ep a
LEFT JOIN research_di.agg_yr_plan b
    ON a.pers_id = b.pers_id
   AND a.delivery_year = b.yr
WHERE a.delivery_year BETWEEN 2019 AND 2025;


-- ============================================================
-- ============================================================

WITH person_year AS (
    SELECT
        pers_id,
        delivery_year,
        MAX(ins)         AS ins,          -- one plan per person-year anyway
        MAX(baby_count)  AS baby_count,
        COUNT(*)         AS n_episodes
    FROM colour.delivery_episodes_insurance_stg
    GROUP BY pers_id, delivery_year
)
SELECT
    delivery_year AS year,
    ins,
    COUNT(*)         AS n_mothers,
    SUM(baby_count)  AS n_babies,
    SUM(n_episodes)  AS n_episodes
FROM person_year
GROUP BY 1, 2
ORDER BY 1, 2;
