-- ============================================================
-- Delivery Claims: Year, Pers ID, Baby Count, Insurance, DOB linkage
-- Matches ICD-10-CM dx codes (research_di.med_dx) and CPT /
-- ICD-10-PCS procedure codes (research_di.medical_adj) against
-- the "Delivery" tab of colour.ref_orr2024_codelists (the
-- "Delivery Twin Excl." tab is NOT included here - deliveries
-- are identified from the main Delivery tab only).
--
-- Collapses to one row per pers_id/year and takes the MAX
-- baby_count seen for that person-year, defaulting to 1 for
-- codes without a baby_count (CPT/ICD-10-PCS procedure codes,
-- and any ICD-10-CM dx code not in the BabyCounts lookup).
--
-- NEW: colour.dob is LEFT JOINed onto the claim-level staging
-- table so every matched claim carries the mother's derived DOB
-- and her exact age at DOS. Nothing is dropped by that join -
-- each claim gets boolean flags (has_dob, has_mult_dob, age_ok)
-- and the downstream summary table applies them as a cumulative
-- filter waterfall, so the effect of each exclusion is
-- measurable rather than baked in.
--
-- DOB criterion for mothers: age at DOS between 12 and 50
-- inclusive (i.e. on/after the 12th birthday and before the 51st).
-- Baby counts are carried both as-is and restricted to age-eligible
-- claims, so births can be reported either way.
--
-- ASSUMPTION: tab = 'delivery' matches how the sheet's Tab
-- column landed in colour.ref_orr2024_codelists (mirrors
-- tab = 'newborn' in create_newborn_records.sql). Verify with:
--   SELECT DISTINCT tab FROM colour.ref_orr2024_codelists;
-- and adjust the literal below if it differs (e.g. 'Delivery').
--
-- ASSUMPTION: `dos` and `clm_id` are the date-of-service and
-- claim-id columns on research_di.med_dx / research_di.medical_adj
-- (mirrors the pattern used in jw_newborn_all_hits). Adjust the
-- column list below if either table names these differently.
--
-- colour.dob semantics (confirmed): one row per pers_id, and
-- `mult_dob` is a NULL/1 flag - 1 means more than one DOB on
-- file, NULL means a single DOB. So the test is mult_dob = 1, not
-- mult_dob > 1. `dobs` is carried through as n_dobs for QC only.
-- See the fuller note in create_newborn_records.sql.
-- ============================================================

-- ============================================================
-- Staging table: claim-level detail, one row per matched
-- code (pers_id, year, dos, clm_id, code, code_type, the code's
-- baby_count if it's a dx code with one) plus the DOB columns
-- and flags. Not collapsed yet - this is the table to build
-- later, more complicated logic on top of (e.g. excluding
-- specific codes/claims, QC on which codes are driving counts)
-- before anything gets grouped.
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_claims_stg;

CREATE TABLE colour.delivery_claims_stg AS
WITH delivery_dx AS (
    SELECT code, baby_count
    FROM colour.ref_orr2024_codelists
    WHERE tab = 'delivery'
      AND code_type = 'ICD-10-CM'
),
delivery_proc AS (
    SELECT code
    FROM colour.ref_orr2024_codelists
    WHERE tab = 'delivery'
      AND code_type IN ('CPT', 'ICD-10-PCS')
),
dx_hits AS (
    SELECT
        a.pers_id,
        a.yr::integer AS year,
        a.dos,
        a.clm_id,
        a.dx          AS code,
        'ICD-10-CM'   AS code_type,
        b.baby_count
    FROM research_di.med_dx a
    JOIN delivery_dx b ON a.dx = b.code
),
proc_hits AS (
    SELECT
        pers_id,
        yr::integer          AS year,
        dos_from as dos,
        clm_id,
        proc_cd               AS code,
        'CPT/ICD-10-PCS'      AS code_type,
        NULL::integer          AS baby_count
    FROM research_di.medical_adj
    WHERE proc_cd IN (SELECT code FROM delivery_proc)
),
all_hits AS (
    SELECT * FROM dx_hits
    UNION ALL
    SELECT * FROM proc_hits
),
dob_1 AS (
    SELECT
        pers_id,
        min(dob_derv)                             AS dob_derv,
        max(COALESCE(mult_dob, 0))                AS mult_dob,
        max(COALESCE(array_length(dobs, 1), 1))   AS n_dobs
    FROM colour.dob
    GROUP BY pers_id
)
SELECT
    h.*,
    d.dob_derv,
    d.mult_dob,
    d.n_dobs,
    (d.dob_derv IS NOT NULL)                                    AS has_dob,
    (COALESCE(d.mult_dob, 0) = 1)                               AS has_mult_dob,
    EXTRACT(YEAR FROM age(h.dos, d.dob_derv))::integer          AS age_at_dos,
    (d.dob_derv IS NOT NULL
     AND EXTRACT(YEAR FROM age(h.dos, d.dob_derv)) BETWEEN 12 AND 50) AS age_ok
FROM all_hits h
LEFT JOIN dob_1 d
    ON h.pers_id = d.pers_id
DISTRIBUTED BY (pers_id);

-- Sanity checks
-- SELECT has_dob, has_mult_dob, age_ok, count(*) AS n_hits,
--        count(DISTINCT pers_id) AS n_persons
--   FROM colour.delivery_claims_stg GROUP BY 1,2,3 ORDER BY 1,2,3;
-- Age distribution - use this to sanity-check the 12-50 bounds:
-- SELECT age_at_dos, count(*) FROM colour.delivery_claims_stg
--   GROUP BY 1 ORDER BY 1;

-- ============================================================
-- Collapse the claim-level staging table to one row per
-- pers_id/year, taking the MAX baby_count seen for that
-- person-year (defaulting to 1 for rows without a baby_count -
-- procedure-code hits, and any dx code not in the BabyCounts
-- lookup), and carrying the DOB flags plus claim counts.
-- Built in two passes - claim level first, then person-year -
-- so no query needs more than one DISTINCT-qualified aggregate.
--
-- baby_count         = MAX over all matched claims (unchanged)
-- baby_count_age_ok  = MAX over age-eligible claims only (NULL if none)
-- n_claims           = distinct clm_id for that person-year
-- n_code_hits        = matched code rows (a claim can hit several codes)
-- *_age_ok           = same, restricted to claims with age 12-50 at DOS
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_records;

CREATE TABLE colour.delivery_records AS
WITH clm AS (
    SELECT
        year,
        pers_id,
        clm_id,
        min(dos)                     AS dos,
        max(dob_derv)                AS dob_derv,
        bool_or(has_dob)             AS has_dob,
        bool_or(has_mult_dob)        AS has_mult_dob,
        bool_or(age_ok)              AS age_ok,
        max(age_at_dos)              AS age_at_dos,
        max(COALESCE(baby_count, 1)) AS baby_count,
        count(*)                     AS n_code_hits
    FROM colour.delivery_claims_stg
    GROUP BY year, pers_id, clm_id
)
SELECT
    year,
    pers_id,
    max(baby_count)                                  AS baby_count,
    max(CASE WHEN age_ok THEN baby_count END)        AS baby_count_age_ok,
    max(dob_derv)                                    AS dob_derv,
    bool_or(has_dob)                                 AS has_dob,
    bool_or(has_mult_dob)                            AS has_mult_dob,
    bool_or(age_ok)                                  AS any_claim_age_ok,
    min(age_at_dos)                                  AS min_age_at_dos,
    max(age_at_dos)                                  AS max_age_at_dos,
    count(*)                                         AS n_claims,
    sum(CASE WHEN age_ok THEN 1 ELSE 0 END)          AS n_claims_age_ok,
    sum(n_code_hits)                                 AS n_code_hits,
    sum(CASE WHEN age_ok THEN n_code_hits ELSE 0 END) AS n_code_hits_age_ok,
    min(dos)                                         AS first_dos,
    max(dos)                                         AS last_dos
FROM clm
GROUP BY year, pers_id
DISTRIBUTED BY (pers_id);

-- Sanity checks
-- SELECT count(*) FROM colour.delivery_records;
-- SELECT year, count(*) AS n_deliveries, sum(baby_count) AS n_babies
--   FROM colour.delivery_records GROUP BY year ORDER BY year;
-- SELECT baby_count, count(*) FROM colour.delivery_records
--   GROUP BY baby_count ORDER BY baby_count;
-- SELECT has_dob, has_mult_dob, any_claim_age_ok, count(*)
--   FROM colour.delivery_records GROUP BY 1,2,3 ORDER BY 1,2,3;

-- ============================================================
-- Tie to enrollment: research_di.agg_yr_plan is already at the
-- pers_id/yr grain (one row per person per year, with their
-- primary med plan for that year), so this joins directly onto
-- delivery_records on (pers_id, year = yr) - no month-level
-- matching needed.
--
-- prim_med_plan observed values: Medicaid, Commercial, Com-Ers,
-- Com-ErsTrs, Com-Trs, Medicare Advantage, Medicare Advantage
-- Imputed, Medicare FFS, Medicare Imputed, Federal.
--
-- LEFT JOIN (not INNER, unlike the newborn/payor_code join) so
-- deliveries with no match in agg_yr_plan show up as their own
-- 'Not Enrolled' bucket instead of silently disappearing - useful
-- for QC. Fold 'Not Enrolled' into 'Other' at analysis time if you
-- want it to line up cleanly with the 3-category vital stats split.
--
-- NOTE: the enrollment age > 12 filter is kept as-is so that
-- stage 0 of the waterfall below reproduces the previous numbers
-- exactly. The DOB-based age 12-50 test is the stricter,
-- claim-level version (it also caps the top end, which the
-- enrollment filter never did).
-- ============================================================

-- ============================================================
-- Staging table: row-level (one row per pers_id/year), carries
-- prim_med_plan and the derived "ins" bucket. This is the table
-- to build later, more complicated logic on top of (e.g. HTW
-- exclusions, risk groups) - kept at person-year grain on purpose
-- rather than pre-aggregated.
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_records_insurance_stg;

CREATE TABLE colour.delivery_records_insurance_stg AS
SELECT
    a.*,
    b.prim_med_plan,
    CASE
        WHEN b.prim_med_plan = 'Medicaid' THEN 'Medicaid'
        WHEN b.prim_med_plan IN ('Commercial', 'Com-Ers', 'Com-ErsTrs', 'Com-Trs') THEN 'Commercial'
        WHEN b.prim_med_plan IS NULL THEN 'Not Enrolled'
        ELSE 'Other'
    END AS ins
FROM colour.delivery_records a
LEFT JOIN research_di.agg_yr_plan b
    ON a.pers_id = b.pers_id
   AND a.year = b.yr
WHERE a.year BETWEEN 2019 AND 2024
DISTRIBUTED BY (pers_id);

-- ============================================================
-- Filter waterfall: cumulative stages, so each row shows what
-- is left after applying that exclusion and everything above it.
-- Stage 0 reproduces the pre-DOB pipeline exactly.
--
--   0. All matched claims (current pipeline)
--   1. + DOB present               <- excludes persons with no DOB
--   2. + claim with age 12-50 at DOS
--   3. + single DOB only           <- excludes persons with multiple DOBs
--
-- Claim counts and baby counts follow the same logic: stages 0-1
-- use all matched claims for the retained persons, stages 2-3 use
-- only the age-eligible claims, since from stage 2 on those are
-- the only claims that qualify.
--
-- n_babies_asis is the unrestricted MAX baby_count carried
-- through every stage, so births can be read "as is" for the
-- retained population alongside the age-restricted version.
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_counts_by_stage;

CREATE TABLE colour.delivery_counts_by_stage AS
WITH ppl AS (
    SELECT DISTINCT
        year, pers_id, ins,
        has_dob, has_mult_dob,
        baby_count, baby_count_age_ok,
        n_claims, n_claims_age_ok,
        n_code_hits, n_code_hits_age_ok
    FROM colour.delivery_records_insurance_stg
),
stages (stage_num, stage) AS (
    VALUES
        (0, '0. All matched claims'),
        (1, '1. + DOB present'),
        (2, '2. + claim with age 12-50 at DOS'),
        (3, '3. + single DOB only')
)
SELECT
    s.stage_num,
    s.stage,
    a.year,
    a.ins,
    count(DISTINCT a.pers_id) AS n_mothers,
    sum(CASE WHEN s.stage_num >= 2 THEN COALESCE(a.baby_count_age_ok, 0)
             ELSE a.baby_count END)                    AS n_babies,
    sum(a.baby_count)                                  AS n_babies_asis,
    sum(CASE WHEN s.stage_num >= 2 THEN a.n_claims_age_ok
             ELSE a.n_claims END)                      AS n_claims,
    sum(CASE WHEN s.stage_num >= 2 THEN a.n_code_hits_age_ok
             ELSE a.n_code_hits END)                   AS n_code_hits
FROM ppl a
CROSS JOIN stages s
WHERE s.stage_num = 0
   OR (s.stage_num = 1 AND a.has_dob)
   OR (s.stage_num = 2 AND a.has_dob AND a.n_claims_age_ok > 0)
   OR (s.stage_num = 3 AND a.has_dob AND a.n_claims_age_ok > 0 AND NOT a.has_mult_dob)
GROUP BY 1, 2, 3, 4
DISTRIBUTED RANDOMLY;

-- ============================================================
-- Non-cumulative DOB QC: splits the stage-0 population into
-- No DOB / Single DOB / Multiple DOB so each exclusion can be
-- sized independently of the order they're applied in.
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_dob_qc;

CREATE TABLE colour.delivery_dob_qc AS
WITH ppl AS (
    SELECT DISTINCT
        year, pers_id, ins,
        has_dob, has_mult_dob,
        baby_count, n_claims, n_claims_age_ok
    FROM colour.delivery_records_insurance_stg
)
SELECT
    year,
    ins,
    CASE
        WHEN NOT has_dob   THEN 'No DOB'
        WHEN has_mult_dob  THEN 'Multiple DOB'
        ELSE 'Single DOB'
    END AS dob_status,
    count(DISTINCT pers_id)                              AS n_mothers,
    sum(CASE WHEN n_claims_age_ok > 0 THEN 1 ELSE 0 END) AS n_mothers_age_ok,
    sum(baby_count)                                      AS n_babies,
    sum(n_claims)                                        AS n_claims,
    sum(n_claims_age_ok)                                 AS n_claims_age_ok
FROM ppl
GROUP BY 1, 2, 3
DISTRIBUTED RANDOMLY;

-- ============================================================
-- Distinct-group summary query (preliminary counts, not
-- materialized - re-run ad hoc against the staging table above).
-- COUNT(DISTINCT pers_id) is used explicitly rather than
-- COUNT(*) for n_deliveries so this stays correct even once the
-- staging table's grain changes (e.g. if later logic joins in
-- something that fans out rows per pers_id/year).
-- Unchanged from the pre-DOB version; equals stage 0 of the
-- waterfall.
-- ============================================================

SELECT year, ins,
       count(DISTINCT pers_id) AS n_deliveries,
       sum(baby_count)         AS n_babies
FROM colour.delivery_records_insurance_stg
GROUP BY 1, 2
ORDER BY 1, 2;
