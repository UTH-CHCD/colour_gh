-- ============================================================
-- Newborn Claims: Year, Pers ID, Insurance, DOB linkage
-- Matches ICD-10-CM dx codes (research_di.med_dx) and CPT
-- procedure codes (research_di.medical_adj) against the
-- "newborn" tab of colour.ref_orr2024_codelists. Insurance is
-- assigned from enrollment (research_di.agg_yr_plan.prim_med_plan),
-- same as create_delivery_records.sql.
--
-- NEW: colour.dob is LEFT JOINed onto the claim-level staging
-- table so every matched claim carries the infant's derived DOB.
-- Nothing is dropped by that join - instead each claim gets
-- boolean flags (has_dob, has_mult_dob, in_dob_window) and the
-- downstream summary table applies them as a cumulative filter
-- waterfall, so the effect of each exclusion is measurable
-- rather than baked in.
--
-- DOB criterion for infants: claim DOS within +/- 7 days of
-- dob_derv. See DOB_WINDOW_DAYS note below to change it (or to
-- make it one-sided).
--
-- ASSUMPTION: `dos` is the date-of-service column on
-- research_di.med_dx, but research_di.medical_adj uses
-- `dos_from` instead (confirmed against create_delivery_records.sql).
-- Adjust below if either table names these differently.
--
-- colour.dob semantics (confirmed): one row per pers_id.
-- `mult_dob` is a NULL/1 flag - 1 means the person has more than
-- one DOB on file, NULL means a single DOB. It is NOT a count, so
-- the test is mult_dob = 1 (not mult_dob > 1, which would never
-- fire). NULLs are COALESCEd to 0 rather than 1 for the same
-- reason. `dobs` is the array of DOBs and is carried through as
-- n_dobs for QC only - it does not drive the flag. Cross-check
-- that the two agree with:
--   SELECT COALESCE(mult_dob, 0) AS mult_dob,
--          COALESCE(array_length(dobs, 1), 1) AS n_dobs, count(*)
--     FROM colour.dob GROUP BY 1, 2 ORDER BY 1, 2;
-- (expect n_dobs = 1 exactly where mult_dob is NULL).
-- The dob_1 CTE also collapses to one row per pers_id defensively
-- so the LEFT JOIN cannot fan out claim rows even if colour.dob
-- turns out to have duplicates.
-- ============================================================

-- ============================================================
-- Staging table: claim-level detail, one row per matched code
-- (pers_id, year, dos, clm_id, code, code_type, payor_code)
-- plus the DOB columns and flags.
-- payor_code is kept here for QC (which payors are showing up
-- on matched claims) but is no longer what drives the "ins"
-- bucket downstream - that now comes from the enrollment table,
-- same as create_delivery_records.sql. Not collapsed yet - this
-- is the table to build later, more complicated logic on top of
-- (e.g. excluding specific codes/claims) before anything gets
-- grouped.
-- ============================================================

DROP TABLE IF EXISTS colour.newborn_claims_stg;

CREATE TABLE colour.newborn_claims_stg AS
WITH newborn_dx AS (
    SELECT code
    FROM colour.ref_orr2024_codelists
    WHERE tab = 'newborn'
      AND code_type = 'ICD-10-CM'
),
newborn_cpt AS (
    SELECT code
    FROM colour.ref_orr2024_codelists
    WHERE tab = 'newborn'
      AND code_type = 'CPT'
),
dx_hits AS (
    SELECT
        pers_id,
        yr::integer   AS year,
        dos,
        clm_id,
        dx            AS code,
        'ICD-10-CM'   AS code_type,
        payor_code
    FROM research_di.med_dx
    WHERE dx IN (SELECT code FROM newborn_dx)
),
cpt_hits AS (
    SELECT
        pers_id,
        yr::integer   AS year,
        dos_from      AS dos,
        clm_id,
        proc_cd       AS code,
        'CPT'         AS code_type,
        payor_code
    FROM research_di.medical_adj
    WHERE proc_cd IN (SELECT code FROM newborn_cpt)
),
all_hits AS (
    SELECT * FROM dx_hits
    UNION ALL
    SELECT * FROM cpt_hits
),
-- Guarantees one row per pers_id so the LEFT JOIN below cannot
-- multiply claim rows. If colour.dob really is unique on pers_id
-- (expected), these aggregates are no-ops.
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
    (d.dob_derv IS NOT NULL)                                        AS has_dob,
    (COALESCE(d.mult_dob, 0) = 1)                                   AS has_mult_dob,
    (h.dos - d.dob_derv)                                            AS days_from_dob,
    -- DOB_WINDOW_DAYS = 7, applied symmetrically (claims up to a
    -- week either side of DOB). For a one-sided window - i.e. DOB
    -- through DOB+7 only, no pre-birth claims - swap the abs()
    -- test for: h.dos BETWEEN d.dob_derv AND d.dob_derv + 7
    (d.dob_derv IS NOT NULL AND abs(h.dos - d.dob_derv) <= 7)       AS in_dob_window
FROM all_hits h
LEFT JOIN dob_1 d
    ON h.pers_id = d.pers_id
DISTRIBUTED BY (pers_id);

-- Sanity checks
-- SELECT count(*) FROM colour.newborn_claims_stg;
-- SELECT code_type, count(*) AS n_hits, count(DISTINCT pers_id) AS n_persons
--   FROM colour.newborn_claims_stg GROUP BY code_type;
-- SELECT has_dob, has_mult_dob, in_dob_window, count(*) AS n_hits,
--        count(DISTINCT pers_id) AS n_persons
--   FROM colour.newborn_claims_stg GROUP BY 1,2,3 ORDER BY 1,2,3;
-- Distribution of days_from_dob - use this to sanity-check the 7-day
-- window before committing to it:
-- SELECT days_from_dob, count(*) FROM colour.newborn_claims_stg
--   WHERE days_from_dob BETWEEN -30 AND 60
--   GROUP BY 1 ORDER BY 1;

-- ============================================================
-- Collapse the claim-level staging table to one row per
-- pers_id/year, carrying the DOB flags plus claim counts
-- (total and within-window). Claim counts are built in two
-- passes - claim level first, then person-year - so no query
-- needs more than one DISTINCT-qualified aggregate.
--
-- n_claims       = distinct clm_id for that person-year
-- n_code_hits    = matched code rows (a claim can hit several codes)
-- *_in_window    = same, restricted to claims within 7 days of DOB
-- ============================================================

DROP TABLE IF EXISTS colour.newborn_records;

CREATE TABLE colour.newborn_records AS
WITH clm AS (
    SELECT
        year,
        pers_id,
        clm_id,
        min(dos)               AS dos,
        max(dob_derv)          AS dob_derv,
        bool_or(has_dob)       AS has_dob,
        bool_or(has_mult_dob)  AS has_mult_dob,
        bool_or(in_dob_window) AS in_dob_window,
        min(days_from_dob)     AS days_from_dob,
        count(*)               AS n_code_hits
    FROM colour.newborn_claims_stg
    GROUP BY year, pers_id, clm_id
)
SELECT
    year,
    pers_id,
    max(dob_derv)          AS dob_derv,
    bool_or(has_dob)       AS has_dob,
    bool_or(has_mult_dob)  AS has_mult_dob,
    bool_or(in_dob_window) AS any_claim_in_window,
    min(days_from_dob)     AS min_days_from_dob,
    max(days_from_dob)     AS max_days_from_dob,
    count(*)                                               AS n_claims,
    sum(CASE WHEN in_dob_window THEN 1 ELSE 0 END)         AS n_claims_in_window,
    sum(n_code_hits)                                       AS n_code_hits,
    sum(CASE WHEN in_dob_window THEN n_code_hits ELSE 0 END) AS n_code_hits_in_window,
    min(dos)               AS first_dos,
    max(dos)               AS last_dos
FROM clm
GROUP BY year, pers_id
DISTRIBUTED BY (pers_id);

-- Sanity checks
-- SELECT count(*) FROM colour.newborn_records;
-- SELECT year, count(*) AS n FROM colour.newborn_records GROUP BY year ORDER BY year;
-- SELECT has_dob, has_mult_dob, any_claim_in_window, count(*)
--   FROM colour.newborn_records GROUP BY 1,2,3 ORDER BY 1,2,3;

-- ============================================================
-- Tie to enrollment: research_di.agg_yr_plan is already at the
-- pers_id/yr grain (one row per person per year, with their
-- primary med plan for that year), so this joins directly onto
-- newborn_records on (pers_id, year = yr) - same table and same
-- CASE WHEN logic as create_delivery_records.sql, plus the
-- age < 1 filter.
--
-- prim_med_plan observed values: Medicaid, Commercial, Com-Ers,
-- Com-ErsTrs, Com-Trs, Medicare Advantage, Medicare Advantage
-- Imputed, Medicare FFS, Medicare Imputed, Federal.
--
-- LEFT JOIN (not INNER) so newborns with no match in agg_yr_plan
-- show up as their own 'Not Enrolled' bucket instead of silently
-- disappearing - useful for QC. The age < 1 filter below is
-- NULL-unsafe, so unmatched rows get excluded from the final
-- staging table anyway (same pattern as the delivery pipeline's
-- age > 12 filter).
--
-- NOTE: the enrollment age < 1 filter is kept as-is so that
-- stage 0 of the waterfall below reproduces the previous
-- numbers exactly. The DOB window is a stricter, claim-level
-- version of the same idea; if the DOB linkage proves complete
-- enough you may want to drop the enrollment age filter and let
-- the DOB window carry it alone.
-- ============================================================

-- ============================================================
-- Staging table: row-level (one row per pers_id/year), carries
-- prim_med_plan and the derived "ins" bucket, plus everything
-- from newborn_records. This is the table to build later, more
-- complicated logic on top of.
-- ============================================================

DROP TABLE IF EXISTS colour.newborn_records_insurance_stg;

CREATE TABLE colour.newborn_records_insurance_stg AS
SELECT
    a.*,
    b.prim_med_plan,
    CASE
        WHEN b.prim_med_plan = 'Medicaid' THEN 'Medicaid'
        WHEN b.prim_med_plan IN ('Commercial', 'Com-Ers', 'Com-ErsTrs', 'Com-Trs') THEN 'Commercial'
        WHEN b.prim_med_plan IS NULL THEN 'Not Enrolled'
        ELSE 'Other'
    END AS ins
FROM colour.newborn_records a
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
--   1. + DOB present            <- excludes persons with no DOB
--   2. + claim within 7 days of DOB
--   3. + single DOB only        <- excludes persons with multiple DOBs
--
-- Claim counts follow the same logic: stages 0-1 count all
-- matched claims for the retained persons, stages 2-3 count only
-- the within-window claims, since from stage 2 on those are the
-- only claims that qualify.
--
-- The DISTINCT in the `ppl` CTE is defensive: if agg_yr_plan ever
-- has >1 row per pers_id/yr, the person-year rows would fan out
-- and the claim-count SUMs would double count. count(DISTINCT
-- pers_id) is used for the person count for the same reason.
-- ============================================================

DROP TABLE IF EXISTS colour.newborn_counts_by_stage;

CREATE TABLE colour.newborn_counts_by_stage AS
WITH ppl AS (
    SELECT DISTINCT
        year, pers_id, ins,
        has_dob, has_mult_dob,
        n_claims, n_claims_in_window,
        n_code_hits, n_code_hits_in_window
    FROM colour.newborn_records_insurance_stg
),
stages (stage_num, stage) AS (
    VALUES
        (0, '0. All matched claims'),
        (1, '1. + DOB present'),
        (2, '2. + claim within 7 days of DOB'),
        (3, '3. + single DOB only')
)
SELECT
    s.stage_num,
    s.stage,
    a.year,
    a.ins,
    count(DISTINCT a.pers_id) AS n_newborns,
    sum(CASE WHEN s.stage_num >= 2 THEN a.n_claims_in_window
             ELSE a.n_claims END)                     AS n_claims,
    sum(CASE WHEN s.stage_num >= 2 THEN a.n_code_hits_in_window
             ELSE a.n_code_hits END)                  AS n_code_hits
FROM ppl a
CROSS JOIN stages s
WHERE s.stage_num = 0
   OR (s.stage_num = 1 AND a.has_dob)
   OR (s.stage_num = 2 AND a.has_dob AND a.n_claims_in_window > 0)
   OR (s.stage_num = 3 AND a.has_dob AND a.n_claims_in_window > 0 AND NOT a.has_mult_dob)
GROUP BY 1, 2, 3, 4
DISTRIBUTED RANDOMLY;

-- ============================================================
-- Non-cumulative DOB QC: splits the stage-0 population into
-- No DOB / Single DOB / Multiple DOB so each exclusion can be
-- sized independently of the order they're applied in.
-- ============================================================

DROP TABLE IF EXISTS colour.newborn_dob_qc;

CREATE TABLE colour.newborn_dob_qc AS
WITH ppl AS (
    SELECT DISTINCT
        year, pers_id, ins,
        has_dob, has_mult_dob,
        n_claims, n_claims_in_window
    FROM colour.newborn_records_insurance_stg
)
SELECT
    year,
    ins,
    CASE
        WHEN NOT has_dob   THEN 'No DOB'
        WHEN has_mult_dob  THEN 'Multiple DOB'
        ELSE 'Single DOB'
    END AS dob_status,
    count(DISTINCT pers_id)                                  AS n_newborns,
    sum(CASE WHEN n_claims_in_window > 0 THEN 1 ELSE 0 END)  AS n_newborns_in_window,
    sum(n_claims)                                            AS n_claims,
    sum(n_claims_in_window)                                  AS n_claims_in_window
FROM ppl
GROUP BY 1, 2, 3
DISTRIBUTED RANDOMLY;

-- ============================================================
-- Distinct-group summary query (preliminary counts, not
-- materialized - re-run ad hoc against the staging table above).
-- Unchanged from the pre-DOB version; equals stage 0 of the
-- waterfall.
-- ============================================================

SELECT year, ins,
       count(DISTINCT pers_id) AS n_newborns
FROM colour.newborn_records_insurance_stg
GROUP BY 1, 2
ORDER BY 1, 2;
