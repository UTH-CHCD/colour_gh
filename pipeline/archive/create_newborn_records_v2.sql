-- ============================================================
-- INFANTS v3 - DOB-first (population) design
-- ============================================================
-- The denominator is every person with a single DOB on/after 2019-01-01.
-- Newborn codes are no longer what defines an infant - they are an
-- attribute measured against the DOB spine.
--
--   1. colour.infant_spine            - single-DOB persons, DOB >= 2019-01-01
--   2. colour.infant_enroll_segments  - continuous coverage segments per plan
--   3. colour.infant_enroll_stg       - spine x segments, distance from DOB
--   4. colour.infant_enroll_pick      - one segment per infant (closest to
--                                       DOB; ties -> Commercial)
--   5. colour.newborn_claims_stg      - newborn-code hits w/ days_from_dob
--   6. colour.newborn_claim_timing    - first newborn-code claim per infant
--   7. colour.infant_records          - one row per infant, everything joined
--
-- Windows are not baked into separate tables. Both sensitivity dimensions
-- are stored as continuous day counts on colour.infant_records:
--     days_to_enroll           -> enrollment window (1-12 months)
--     days_to_first_nb_claim   -> newborn-code window (7/30/60/90 days)
-- so every window is a WHERE clause. Summary queries at the bottom sweep both.
--
-- ------------------------------------------------------------
-- NOTES / THINGS TO VERIFY
-- ------------------------------------------------------------
-- A. colour.dob is one row per pers_id with dob_derv (date) and mult_dob
--    (1 = more than one DOB on file, NULL = single). Collapsed defensively
--    below anyway. agg_yrmon_plan carries `age`, not DOB, so colour.dob
--    stays the DOB source.
-- B. Enrollment months come from agg_yrmon_plan.yrmon (YYYYMM as bigint).
--    A month counts as enrolled when prim_med_plan is populated; if
--    med_ind is the better test, swap it in at enr_src.
-- C. Spec said DOB > 2019-01-01. Written as >= so 2019-01-01 births are
--    kept; change the operator in section 1 for strict >.
-- D. Newborn dx hits use med_dx.dos directly rather than joining back to
--    medical_adj for the claim span, since only a single date relative to
--    DOB is needed here. The delivery pipeline does join back, because
--    episode building needs real intervals.
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
  AND dob >= DATE '2019-01-01';   -- >>> EDIT <<< spec said "> 2019-01-01"

-- QC: what the single-DOB rule costs
SELECT COUNT(*) AS n_dob_persons,
        SUM(CASE WHEN COALESCE(mult_dob,0) = 1 THEN 1 ELSE 0 END) AS n_multi_dob
   FROM colour.dob WHERE dob_derv >= DATE '2019-01-01';

 SELECT birth_year, COUNT(*) FROM colour.infant_spine GROUP BY 1 ORDER BY 1;


-- ============================================================
-- 2. ENROLLMENT SEGMENTS
--    agg_yrmon_plan is month grain, so contiguous months are collapsed
--    into segments. A segment breaks on a month gap OR a plan change -
--    plan-specific segments are what makes "closest to birthday, ties ->
--    Commercial" well defined.
--    Restricted to spine members, so this table is infants only.
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
    WHERE e.prim_med_plan IS NOT NULL    -- >>> EDIT <<< or med_ind, see note B
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

-- QC: the segment nearest the DOB should almost always show age 0
SELECT min_age_in_seg, COUNT(*) FROM colour.infant_enroll_segments
 GROUP BY 1 ORDER BY 1 LIMIT 20;


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
--    Closest to the birthday; ties broken toward Commercial; remaining
--    ties broken deterministically so re-runs are stable.
--    Note that a birth-month segment covers the DOB and therefore scores
--    0, so most infants will tie at 0 whenever two plans overlap that
--    month - which is exactly the case the Commercial rule is for.
--    n_tied_at_min sizes how often it fires.
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

-- QC
SELECT n_tied_at_min, COUNT(*) FROM colour.infant_enroll_pick GROUP BY 1 ORDER BY 1;
SELECT ins, COUNT(*) FROM colour.infant_enroll_pick GROUP BY 1;


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

-- QC: codes that never hit, and claims dated before the DOB
SELECT code_type, COUNT(*) AS n_rows, COUNT(DISTINCT pers_id) AS n_persons
   FROM colour.newborn_claims_stg GROUP BY 1;

SELECT SUM(CASE WHEN days_from_dob < 0 THEN 1 ELSE 0 END) AS n_pre_dob,
        COUNT(*) AS n_rows FROM colour.newborn_claims_stg;


-- ============================================================
-- 6. FIRST NEWBORN-CODE CLAIM PER INFANT
--    Claims dated before the DOB are excluded from the "first claim"
--    calculation but remain in the staging table above.
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
-- 7. FINAL INFANT TABLE - one row per infant
--    LEFT JOINs throughout: an infant with no enrollment segment and an
--    infant with no newborn-code claim both stay on the spine with NULLs,
--    so every filter below is additive and sizeable.
-- ============================================================

DROP TABLE IF EXISTS colour.infant_records;

CREATE TABLE colour.infant_records AS
SELECT
    s.pers_id,
    s.dob,
    s.birth_year,
    -- enrollment
    p.plan,
    COALESCE(p.ins, 'Not Enrolled') AS ins,
    p.seg_start,
    p.seg_end,
    p.days_to_enroll,
    p.n_segments,
    p.n_tied_at_min,
    -- newborn-code claims
    t.first_nb_claim_dt,
    t.days_to_first_nb_claim,
    t.days_to_first_nb_cpt,
    t.n_nb_claims,
    CASE WHEN t.days_to_first_nb_claim <=  7 THEN 1 ELSE 0 END AS nb_claim_7d,
    CASE WHEN t.days_to_first_nb_claim <= 30 THEN 1 ELSE 0 END AS nb_claim_30d,
    CASE WHEN t.days_to_first_nb_claim <= 60 THEN 1 ELSE 0 END AS nb_claim_60d,
    CASE WHEN t.days_to_first_nb_claim <= 90 THEN 1 ELSE 0 END AS nb_claim_90d
FROM colour.infant_spine s
LEFT JOIN colour.infant_enroll_pick   p ON p.pers_id = s.pers_id
LEFT JOIN colour.newborn_claim_timing t ON t.pers_id = s.pers_id;


-- ============================================================
-- SUMMARY A - enrollment window sensitivity (1-12 months)
-- "Month" = 30 days so this stays an integer comparison on
-- days_to_enroll. Cumulative: month 12 includes everyone in month 1.
-- ============================================================

SELECT
    m.months,
    r.birth_year,
    SUM(CASE WHEN r.days_to_enroll <= m.months * 30 THEN 1 ELSE 0 END) AS n_enrolled,
    COUNT(*) AS n_spine,
    ROUND(100.0 * SUM(CASE WHEN r.days_to_enroll <= m.months * 30 THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*), 0), 1) AS pct_enrolled
FROM colour.infant_records r
CROSS JOIN generate_series(1, 12) AS m(months)
GROUP BY 1, 2
ORDER BY 1, 2;


-- ============================================================
-- SUMMARY B - newborn-code claim windows within the 12-month
-- enrollment population, by year and insurance.
-- ============================================================

SELECT
    birth_year,
    ins,
    COUNT(*) AS n_infants,
    SUM(nb_claim_7d)  AS n_nb_7d,
    SUM(nb_claim_30d) AS n_nb_30d,
    SUM(nb_claim_60d) AS n_nb_60d,
    SUM(nb_claim_90d) AS n_nb_90d
FROM colour.infant_records
WHERE days_to_enroll <= 365
GROUP BY 1, 2
ORDER BY 1, 2;
