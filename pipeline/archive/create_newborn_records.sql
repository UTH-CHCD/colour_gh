-- ============================================================
-- Newborn Claims: Year, Pers ID, Payor Code, Insurance
-- Matches ICD-10-CM dx codes (research_di.med_dx) and CPT
-- procedure codes (research_di.medical_adj) against the
-- "newborn" tab of colour.ref_orr2024_codelists.
--
-- ASSUMPTION: `dos` is the date-of-service column on
-- research_di.med_dx, but research_di.medical_adj uses
-- `dos_from` instead (confirmed against create_delivery_records.sql).
-- Adjust below if either table names these differently.
-- ============================================================

-- ============================================================
-- Staging table: claim-level detail, one row per matched code
-- (pers_id, year, dos, clm_id, code, code_type, payor_code).
-- Not collapsed yet - this is the table to build later, more
-- complicated logic on top of (e.g. excluding specific
-- codes/claims, QC on which codes are driving counts) before
-- anything gets grouped.
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
-- pers_id/year/payor_code (mirrors the original de-duplicated
-- shape - a person-year can have more than one distinct
-- payor_code if it shows up across different claims).
-- ============================================================

DROP TABLE IF EXISTS colour.newborn_records;

CREATE TABLE colour.newborn_records AS
SELECT DISTINCT year, pers_id, payor_code
FROM colour.newborn_claims_stg;

-- Sanity checks
-- SELECT count(*) FROM colour.newborn_records;
-- SELECT year, count(*) AS n FROM colour.newborn_records GROUP BY year ORDER BY year;

-- ============================================================
-- Tie to enrollment for the age filter: newborn identification
-- should be restricted to age < 1 at the enrollment-year grain,
-- via research_di.agg_yr_plan (pers_id/yr). Insurance category
-- itself still comes from the claim-level payor_code via
-- reference.submitter_info_oct24, same as before - only the age
-- filter is new here.
--
-- LEFT JOIN to agg_yr_plan (not INNER) so unmatched rows show up
-- for QC rather than silently disappearing, but the age < 1
-- filter in the WHERE clause below is NULL-unsafe, so unmatched
-- (NULL age) rows get excluded anyway - same pattern used in
-- create_delivery_records.sql's age > 12 filter.
-- ============================================================

-- ============================================================
-- Staging table: row-level (one row per pers_id/year/payor_code),
-- carries the derived "ins" bucket and the age < 1 filter. This
-- is the table to build later, more complicated logic on top of.
-- ============================================================

DROP TABLE IF EXISTS colour.newborn_records_insurance_stg;

CREATE TABLE colour.newborn_records_insurance_stg AS
SELECT
    a.*,
    CASE
        WHEN b.medicaid_plan   = 'MD' THEN 'Medicaid'
        WHEN b.commercial_plan = 'C'  THEN 'Commercial'
        ELSE 'Other'
    END AS ins
FROM colour.newborn_records a
JOIN reference.submitter_info_oct24 b
    ON a.payor_code::text = b.payor_code
LEFT JOIN research_di.agg_yr_plan c
    ON a.pers_id = c.pers_id
   AND a.year = c.yr
WHERE a.year BETWEEN 2019 AND 2024
  AND c.age < 1;

-- ============================================================
-- Distinct-group summary query (preliminary counts, not
-- materialized - re-run ad hoc against the staging table above).
-- ============================================================

SELECT year, ins,
       count(DISTINCT pers_id) AS n_newborns
FROM colour.newborn_records_insurance_stg
GROUP BY 1, 2
ORDER BY 1, 2;
