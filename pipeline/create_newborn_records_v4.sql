-- ============================================================
-- INFANTS v3 - DOB-first (population) design
-- ============================================================
-- The denominator is every person with a single DOB on/after 2019-01-01.
-- Newborn codes are no longer what defines an infant - they are an
-- attribute measured against the DOB spine.
--
-- Windows are not baked into separate tables. All three sensitivity
-- dimensions are stored as continuous day counts on colour.infant_records:
--     days_to_enroll           -> enrollment window (1-12 months)
--     days_to_first_nb_claim   -> newborn-code window (7/30/60/90 days)
--     days_to_first_any_claim  -> any-claim window (30/60/90 days)
-- so every window is a WHERE clause. Summary queries at the bottom sweep them.

-- ============================================================


-- ============================================================
-- 1. INFANT SPINE
-- ============================================================

DROP TABLE IF EXISTS colour.infant_spine;

CREATE TABLE colour.infant_spine AS
WITH dob_collapsed AS (
    SELECT
        pers_id,
        MIN(dob_derv) AS dob,
        MAX(COALESCE(mult_dob, 0)) AS mult_dob
    FROM colour.dob
    WHERE dob_derv IS NOT NULL
    GROUP BY pers_id
)
SELECT
    pers_id,
    dob,
    EXTRACT(YEAR FROM dob)::integer AS birth_year
FROM dob_collapsed
WHERE mult_dob = 0
  AND dob >= DATE '2019-01-01';   

-- QC: what the single-DOB rule costs
/*SELECT COUNT(*) AS n_dob_persons,
        SUM(CASE WHEN COALESCE(mult_dob,0) = 1 THEN 1 ELSE 0 END) AS n_multi_dob
   FROM colour.dob WHERE dob_derv >= DATE '2019-01-01';*/

 SELECT birth_year, COUNT(*) FROM colour.infant_spine GROUP BY 1 ORDER BY 1;


-- ============================================================
-- 2. ENROLLMENT SEGMENTS
-- ============================================================

DROP TABLE IF EXISTS colour.infant_enroll_segments;

CREATE TABLE colour.infant_enroll_segments AS
WITH enr_src AS (
    SELECT
        e.pers_id,
        (e.yrmon / 100)::integer AS enr_yr,
        (e.yrmon % 100)::integer AS enr_mo,
        e.prim_med_plan AS plan,
        e.age
    FROM research_di.agg_yrmon_plan e
    JOIN colour.infant_spine s ON s.pers_id = e.pers_id
    WHERE e.prim_med_plan IS NOT NULL    
      AND e.yrmon >= 201801
),
enr AS (
    SELECT
        pers_id,
        plan,
        age,
        enr_yr * 12 + enr_mo AS mo_index,
        -- if make_date is unavailable:
        --   to_date(enr_yr::text || lpad(enr_mo::text, 2, '0'), 'YYYYMM')
        make_date(enr_yr, enr_mo, 1) AS mo_start
    FROM enr_src
),
flagged AS (
    SELECT
        f.*,
        CASE
            WHEN LAG(mo_index) OVER (PARTITION BY pers_id, plan ORDER BY mo_index) IS NULL THEN 1
            WHEN mo_index > LAG(mo_index) OVER (PARTITION BY pers_id, plan ORDER BY mo_index) + 1 THEN 1
            ELSE 0
        END AS new_seg_flag
    FROM enr f
),
grouped AS (
    SELECT
        g.*,
        SUM(new_seg_flag) OVER (PARTITION BY pers_id, plan ORDER BY mo_index
                                ROWS UNBOUNDED PRECEDING) AS seg_id
    FROM flagged g
)
SELECT
    pers_id,
    plan,
    seg_id,
    MIN(mo_start) AS seg_start,
    (MAX(mo_start) + INTERVAL '1 month' - INTERVAL '1 day')::date AS seg_end,
    COUNT(*) AS n_months,
    MIN(age) AS min_age_in_seg
FROM grouped
GROUP BY pers_id, plan, seg_id;



-- ============================================================
-- 3. SPINE x SEGMENTS, WITH DISTANCE FROM DOB
--    days_from_dob is 0 when the segment covers the DOB, otherwise the
--    gap in days to the nearer endpoint. Always >= 0, so it behaves the
--    same for coverage that starts before the DOB (which happens, since
--    segments start on the 1st of a month) and coverage that starts after.
-- ============================================================

DROP TABLE IF EXISTS colour.infant_enroll_stg;

CREATE TABLE colour.infant_enroll_stg AS
SELECT
    s.pers_id,
    s.dob,
    s.birth_year,
    e.plan,
    e.seg_id,
    e.seg_start,
    e.seg_end,
    e.n_months,
    e.min_age_in_seg,
    CASE
        WHEN s.dob BETWEEN e.seg_start AND e.seg_end THEN 0
        WHEN s.dob <  e.seg_start THEN (e.seg_start - s.dob)
        ELSE (s.dob - e.seg_end)
    END AS days_from_dob,
    CASE WHEN e.seg_start < s.dob THEN 1 ELSE 0 END AS starts_before_dob,
    CASE
        WHEN e.plan = 'Medicaid' THEN 'Medicaid'
        WHEN e.plan IN ('Commercial', 'Com-Ers', 'Com-ErsTrs', 'Com-Trs') THEN 'Commercial'
        ELSE 'Other'
    END AS ins
FROM colour.infant_spine s
JOIN colour.infant_enroll_segments e
  ON e.pers_id = s.pers_id;


-- ============================================================
-- 4. PICK ONE SEGMENT PER INFANT
-- ============================================================

DROP TABLE IF EXISTS colour.infant_enroll_pick;

CREATE TABLE colour.infant_enroll_pick AS
WITH dist AS (
    SELECT
        a.*,
        MIN(days_from_dob) OVER (PARTITION BY pers_id) AS min_dist,
        COUNT(*)           OVER (PARTITION BY pers_id) AS n_segments
    FROM colour.infant_enroll_stg a
),
ranked AS (
    SELECT
        d.*,
        SUM(CASE WHEN days_from_dob = min_dist THEN 1 ELSE 0 END)
            OVER (PARTITION BY pers_id) AS n_tied_at_min,
        ROW_NUMBER() OVER (
            PARTITION BY pers_id
            ORDER BY days_from_dob,
                     CASE WHEN ins = 'Commercial' THEN 0 ELSE 1 END,
                     seg_start,
                     n_months DESC,
                     plan
        ) AS rn
    FROM dist d
)
SELECT
    pers_id, dob, birth_year,
    plan, ins, seg_start, seg_end, n_months, min_age_in_seg,
    days_from_dob AS days_to_enroll,
    starts_before_dob,
    n_segments,
    n_tied_at_min
FROM ranked
WHERE rn = 1;



-- ============================================================
-- 5. NEWBORN-CODE CLAIMS (spine members only, nothing windowed)
--    Every matched code row is kept with its date and days_from_dob
--    (negative = dated before the DOB).
-- ============================================================

DROP TABLE IF EXISTS colour.newborn_claims_stg;

CREATE TABLE colour.newborn_claims_stg AS
WITH nb_dx AS (
    SELECT btrim(code) AS code FROM colour.ref_orr2024_codelists
    WHERE tab = 'newborn' AND code_type = 'ICD-10-CM'
),
nb_cpt AS (
    SELECT btrim(code) AS code FROM colour.ref_orr2024_codelists
    WHERE tab = 'newborn' AND code_type = 'CPT'
),
dx_hits AS (
    SELECT DISTINCT
        a.pers_id,
        a.clm_id,
        a.dos::date   AS dos,
        btrim(a.dx)   AS code,
        'ICD-10-CM'   AS code_type
    FROM research_di.med_dx a
    JOIN nb_dx b ON btrim(a.dx) = b.code
),
cpt_hits AS (
    SELECT
        a.pers_id,
        a.clm_id,
        a.dos_from       AS dos,
        btrim(a.proc_cd) AS code,
        'CPT'            AS code_type
    FROM research_di.medical_adj a
    JOIN nb_cpt b ON btrim(a.proc_cd) = b.code
),
all_hits AS (
    SELECT * FROM dx_hits
    UNION ALL
    SELECT * FROM cpt_hits
)
SELECT
    s.pers_id,
    s.dob,
    s.birth_year,
    h.clm_id,
    h.dos,
    h.code,
    h.code_type,
    (h.dos - s.dob) AS days_from_dob
FROM colour.infant_spine s
JOIN all_hits h ON h.pers_id = s.pers_id;




-- ============================================================
-- 6. FIRST NEWBORN-CODE CLAIM PER INFANT
-- ============================================================

DROP TABLE IF EXISTS colour.newborn_claim_timing;

CREATE TABLE colour.newborn_claim_timing AS
SELECT
    pers_id,
    MIN(dos) AS first_nb_claim_dt,
    MIN(days_from_dob) AS days_to_first_nb_claim,
    MIN(CASE WHEN code_type = 'CPT'       THEN days_from_dob END) AS days_to_first_nb_cpt,
    MIN(CASE WHEN code_type = 'ICD-10-CM' THEN days_from_dob END) AS days_to_first_nb_dx,
    COUNT(DISTINCT clm_id) AS n_nb_claims
FROM colour.newborn_claims_stg
WHERE days_from_dob >= 0
GROUP BY pers_id;


-- ============================================================
-- 6b. FIRST CLAIM OF ANY KIND PER INFANT
-- ============================================================

DROP TABLE IF EXISTS colour.infant_any_claim_timing;

CREATE TABLE colour.infant_any_claim_timing AS
WITH any_lines AS (
    SELECT
        s.pers_id,
        a.clm_id,
        a.dos_from::date           AS dos,
        (a.dos_from::date - s.dob) AS days_from_dob
    FROM colour.infant_spine s
    JOIN research_di.medical_adj a
      ON a.pers_id = s.pers_id
    WHERE a.dos_from IS NOT NULL
      AND a.dos_from::date >= s.dob
      AND a.dos_from::date <= s.dob + 400
),
any_claims AS (
    SELECT
        pers_id,
        clm_id,
        MIN(dos)           AS dos,
        MIN(days_from_dob) AS days_from_dob
    FROM any_lines
    GROUP BY pers_id, clm_id
)
SELECT
    pers_id,
    MIN(dos)           AS first_any_claim_dt,
    MIN(days_from_dob) AS days_to_first_any_claim,
    COUNT(*)           AS n_any_claims_400d,
    SUM(CASE WHEN days_from_dob <= 30 THEN 1 ELSE 0 END) AS n_any_claims_30d,
    SUM(CASE WHEN days_from_dob <= 60 THEN 1 ELSE 0 END) AS n_any_claims_60d,
    SUM(CASE WHEN days_from_dob <= 90 THEN 1 ELSE 0 END) AS n_any_claims_90d
FROM any_claims
GROUP BY pers_id;


-- ============================================================
-- 7. FINAL INFANT TABLE - one row per infant
-- ============================================================

DROP TABLE IF EXISTS colour.infant_records;

CREATE TABLE colour.infant_records AS
WITH run_out AS (
    SELECT DATE '2025-06-30' AS claims_thru -- can change this if needed
),
base AS (
SELECT
    s.pers_id,
    s.dob,
    s.birth_year,
    p.plan,
    COALESCE(p.ins, 'Not Enrolled') AS ins,
    p.seg_start,
    p.seg_end,
    p.days_to_enroll,
    p.n_segments,
    p.n_tied_at_min,
    t.first_nb_claim_dt,
    t.days_to_first_nb_claim,
    t.days_to_first_nb_cpt,
    t.n_nb_claims,
    CASE WHEN t.days_to_first_nb_claim <=  7 THEN 1 ELSE 0 END AS nb_claim_7d,
    CASE WHEN t.days_to_first_nb_claim <= 30 THEN 1 ELSE 0 END AS nb_claim_30d,
    CASE WHEN t.days_to_first_nb_claim <= 60 THEN 1 ELSE 0 END AS nb_claim_60d,
    CASE WHEN t.days_to_first_nb_claim <= 90 THEN 1 ELSE 0 END AS nb_claim_90d,
    a.first_any_claim_dt,
    a.days_to_first_any_claim,
    a.n_any_claims_400d,
    CASE WHEN a.days_to_first_any_claim <=  7 THEN 1 ELSE 0 END AS any_claim_7d,
    CASE WHEN a.days_to_first_any_claim <= 30 THEN 1 ELSE 0 END AS any_claim_30d,
    CASE WHEN a.days_to_first_any_claim <= 60 THEN 1 ELSE 0 END AS any_claim_60d,
    CASE WHEN a.days_to_first_any_claim <= 90 THEN 1 ELSE 0 END AS any_claim_90d,
    r.claims_thru,
    LEAST(400, (r.claims_thru - s.dob)) AS followup_days
FROM colour.infant_spine s
CROSS JOIN run_out r
LEFT JOIN colour.infant_enroll_pick     p ON p.pers_id = s.pers_id
LEFT JOIN colour.newborn_claim_timing   t ON t.pers_id = s.pers_id
LEFT JOIN colour.infant_any_claim_timing a ON a.pers_id = s.pers_id
)
SELECT
    b.*,
    CASE
        WHEN b.days_to_first_any_claim IS NOT NULL
         AND b.days_to_first_any_claim <= b.followup_days THEN 1
        ELSE 0
    END AS any_claim_event,
    CASE
        WHEN b.days_to_first_any_claim IS NOT NULL
         AND b.days_to_first_any_claim <= b.followup_days
        THEN b.days_to_first_any_claim
        ELSE b.followup_days
    END AS any_claim_time
FROM base b;




