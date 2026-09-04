-- ============================================================
-- Newborn Claims: Year, Pers ID, Insurance
-- Matches ICD-10-CM dx codes (research_di.med_dx) and CPT
-- procedure codes (research_di.medical_adj) against the
-- "newborn" tab of colour.ref_orr2024_codelists. Insurance is
-- assigned from enrollment (research_di.agg_yr_plan.prim_med_plan),
-- same as create_delivery_records.sql.
--
-- ASSUMPTION: `dos` is the date-of-service column on
-- research_di.med_dx, but research_di.medical_adj uses
-- `dos_from` instead (confirmed against create_delivery_records.sql).
-- Adjust below if either table names these differently.
-- ============================================================

-- ============================================================
-- Staging table: claim-level detail, one row per matched code
-- (pers_id, year, dos, clm_id, code, code_type, payor_code).
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
)
SELECT * FROM dx_hits
UNION ALL
SELECT * FROM cpt_hits;

-- Sanity checks
-- SELECT count(*) FROM colour.newborn_claims_stg;
-- SELECT code_type, count(*) AS n_hits, count(DISTINCT pers_id) AS n_persons
--   FROM colour.newborn_claims_stg GROUP BY code_type;
-- SELECT code, count(*) FROM colour.newborn_claims_stg
--   GROUP BY code ORDER BY count(*) DESC;

-- ============================================================
-- Collapse the claim-level staging table to one row per
-- pers_id/year (mirrors create_delivery_records.sql - insurance
-- is now assigned from the enrollment table below rather than
-- claim-level payor_code, so payor_code isn't needed past this
-- point).
-- ============================================================

DROP TABLE IF EXISTS colour.newborn_records;

CREATE TABLE colour.newborn_records AS
SELECT DISTINCT year, pers_id
FROM colour.newborn_claims_stg;

-- Sanity checks
-- SELECT count(*) FROM colour.newborn_records;
-- SELECT year, count(*) AS n FROM colour.newborn_records GROUP BY year ORDER BY year;

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
-- ============================================================

-- ============================================================
-- Staging table: row-level (one row per pers_id/year), carries
-- prim_med_plan and the derived "ins" bucket. This is the table
-- to build later, more complicated logic on top of.
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
  AND b.age < 1;

-- ============================================================
-- Distinct-group summary query (preliminary counts, not
-- materialized - re-run ad hoc against the staging table above).
-- ============================================================

SELECT year, ins,
       count(DISTINCT pers_id) AS n_newborns
FROM colour.newborn_records_insurance_stg
GROUP BY 1, 2
ORDER BY 1, 2;
