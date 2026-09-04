-- ============================================================
-- Texas Births by Source of Payment for Delivery, 2018-2024
-- Source: CDC WONDER, Natality 2016-2024 (expanded)
-- Note: 2018 "Other"/"Unknown or Not Stated" values appear to
-- reflect a different NCHS bucketing than 2019-2024; treat 2018
-- with caution in time-series analysis.
-- ============================================================


DROP TABLE IF EXISTS colour.ref_vital_stats_tx;

CREATE TABLE colour.ref_vital_stats_tx (
    year                    INTEGER NOT NULL,
    medicaid                INTEGER,
    private_insurance       INTEGER,
    self_pay                INTEGER,
    other                   INTEGER,
    unknown_or_not_stated   INTEGER,
    total                   INTEGER,
    CONSTRAINT pk_ref_vital_stats_tx PRIMARY KEY (year)
);


INSERT INTO colour.ref_vital_stats_tx
    (year, medicaid, private_insurance, self_pay, other, unknown_or_not_stated, total)
VALUES
    (2018, 176219, 151966, 28703, 20694, 1042, 378624),
    (2019, 187054, 154726, 26369,  2261, 7189, 377599),
    (2020, 183057, 152975, 23058,  1758, 7342, 368190),
    (2021, 180705, 159756, 23763,  1863, 7507, 373594),
    (2022, 188585, 165149, 25835,  2194, 7978, 389741),
    (2023, 185348, 166903, 25583,  2292, 7819, 387945),
    (2024, 175110, 177154, 27908,  2096, 8560, 390828);


