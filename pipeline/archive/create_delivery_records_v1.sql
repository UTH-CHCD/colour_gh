-- ============================================================
-- Delivery Claims: Year, Pers ID, Baby Count, Insurance
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
-- ============================================================

-- ============================================================
-- Staging table: claim-level detail, one row per matched
-- code (pers_id, year, dos, clm_id, code, code_type, and the
-- code's baby_count if it's a dx code with one). Not collapsed
-- yet - this is the table to build later, more complicated
-- logic on top of (e.g. excluding specific codes/claims, QC on
-- which codes are driving counts) before anything gets grouped.
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
)
SELECT * FROM dx_hits
UNION ALL
SELECT * FROM proc_hits;

-- ============================================================
-- Collapse the claim-level staging table to one row per
-- pers_id/year, taking the MAX baby_count seen for that
-- person-year (defaulting to 1 for rows without a baby_count -
-- procedure-code hits, and any dx code not in the BabyCounts
-- lookup).
-- ============================================================

DROP TABLE IF EXISTS colour.delivery_records;

CREATE TABLE colour.delivery_records AS
SELECT
    year,
    pers_id,
    MAX(COALESCE(baby_count, 1)) AS baby_count
FROM colour.delivery_claims_stg
GROUP BY year, pers_id;

-- Sanity checks
-- SELECT count(*) FROM colour.delivery_records;
-- SELECT year, count(*) AS n_deliveries, sum(baby_count) AS n_babies
--   FROM colour.delivery_records GROUP BY year ORDER BY year;
-- SELECT baby_count, count(*) FROM colour.delivery_records
--   GROUP BY baby_count ORDER BY baby_count;

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
  AND b.age > 12;

-- ============================================================
-- Distinct-group summary query (preliminary counts, not
-- materialized - re-run ad hoc against the staging table above).
-- COUNT(DISTINCT pers_id) is used explicitly rather than
-- COUNT(*) for n_deliveries so this stays correct even once the
-- staging table's grain changes (e.g. if later logic joins in
-- something that fans out rows per pers_id/year).
-- ============================================================

SELECT year, ins,
       count(DISTINCT pers_id) AS n_deliveries,
       sum(baby_count)         AS n_babies
FROM colour.delivery_records_insurance_stg
GROUP BY 1, 2
ORDER BY 1, 2;
