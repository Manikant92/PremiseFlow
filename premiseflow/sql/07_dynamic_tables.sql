-- PremiseFlow :: 07_dynamic_tables.sql
-- Observation / reality layer. Derived state refreshes from the synthetic
-- source data so the platform keeps re-testing assumptions against reality.
--
-- Design note: the governed pool (incumbent payroll retail salary + linked
-- savings) is pre-aggregated first, then the rolling 90-day retention ratio is
-- computed as a self-join on that small aggregate. The account population is
-- constant across the window (all incumbent accounts open before the spine
-- start), so aggregate-then-ratio is exact and far cheaper than an
-- account-level self-join over 3M rows.
-- Dynamic tables avoid CURRENT_DATE/RANDOM; the timeline comes from
-- RAW.V_GEN_CONFIG and pseudo-randomness from HASH(), both deterministic.

USE DATABASE PREMISEFLOW;
USE SCHEMA CORE;

-- ---------------------------------------------------------------------------
-- Static observation series for the assumptions that are not wired to the
-- synthetic banking data. Keeps the registry alive without faking the primary
-- scenario. Seeded as a table (not a view) so dynamic tables stay deterministic.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.STATIC_OBSERVATIONS (
  ASSUMPTION_ID    STRING,
  METRIC_CODE      STRING,
  OBSERVATION_DATE DATE,
  OBSERVED_VALUE   FLOAT,
  SAMPLE_SIZE      NUMBER(12,0)
);

DELETE FROM CORE.STATIC_OBSERVATIONS;
INSERT INTO CORE.STATIC_OBSERVATIONS (ASSUMPTION_ID, METRIC_CODE, OBSERVATION_DATE, OBSERVED_VALUE, SAMPLE_SIZE)
WITH cfg AS (SELECT * FROM RAW.V_GEN_CONFIG),
spine AS (
  SELECT DATEADD(day, SEQ4(), cfg.SPINE_START_DATE) AS D, cfg.SPINE_START_DATE, cfg.DEMO_END_DATE, cfg.BREAK_DATE
  FROM TABLE(GENERATOR(ROWCOUNT=>400)) JOIN cfg ON TRUE
  WHERE DATEADD(day, SEQ4(), cfg.SPINE_START_DATE) <= cfg.DEMO_END_DATE
),
spec AS (
  SELECT * FROM VALUES
    ('A-DEP-003','TERM_ROLLOVER_RATE',         0.790, 0.030, 0.0,    4200),
    -- A-DEP-004 drifts upward after the break: digital/aggregator cohorts stop
    -- behaving like branch cohorts. Designed to land in WATCH, not BREACH.
    ('A-DEP-004','DIGITAL_COHORT_DIVERGENCE',  0.036, 0.008, 0.055,  6200),
    ('A-LIQ-001','LEVEL1_HQLA_SHARE',          0.762, 0.022, 0.0,     null),
    ('A-CRD-001','REVOLVER_UTILISATION_STRESS',0.428, 0.014, 0.0,     890),
    ('A-CRD-002','MORTGAGE_CPR',               0.091, 0.009, 0.0,    15400),
    ('A-IRR-001','NMD_REPRICING_LAG_MONTHS',   3.55,  0.220, 0.0,     null),
    ('A-MKT-001','COLLATERAL_LIQUIDATION_DAYS',3.40,  0.450, 0.0,     null),
    ('A-CAP-001','OPRISK_LOSS_FREQUENCY',      11.80, 1.100, 0.0,     null)
  AS t(ASSUMPTION_ID, METRIC_CODE, CENTRE, NOISE, POST_BREAK_DRIFT, SAMPLE_SIZE)
)
SELECT
  spec.ASSUMPTION_ID, spec.METRIC_CODE, spine.D,
  ROUND(
    spec.CENTRE
    + ((ABS(HASH(spec.ASSUMPTION_ID, spine.D))%2001)-1000)/1000.0 * spec.NOISE
    + CASE WHEN spine.D >= spine.BREAK_DATE
           THEN spec.POST_BREAK_DRIFT * LEAST(1.0, DATEDIFF(day, spine.BREAK_DATE, spine.D)/70.0)
           ELSE 0 END
  , 5),
  spec.SAMPLE_SIZE
FROM spec JOIN spine ON TRUE;

-- ---------------------------------------------------------------------------
-- 1. Governed pool, pre-aggregated by decomposition dimensions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE CORE.DT_GOVERNED_DAILY
  TARGET_LAG='60 minutes' WAREHOUSE=PREMISEFLOW_WH REFRESH_MODE=AUTO
  COMMENT='Daily balance of the deposit pool governed by A-DEP-001, by segment/channel/tenure band.'
AS
SELECT
  db.BALANCE_DATE,
  c.CUSTOMER_SEGMENT,
  c.ACQUISITION_CHANNEL,
  CASE WHEN c.TENURE_MONTHS < 24 THEN '0-2y'
       WHEN c.TENURE_MONTHS < 60 THEN '2-5y'
       ELSE '5y+' END               AS TENURE_BAND,
  c.RISK_SEGMENT,
  db.PRODUCT_TYPE,
  SUM(db.CLOSING_BALANCE)           AS BALANCE,
  COUNT(DISTINCT db.ACCOUNT_ID)     AS ACCOUNTS
FROM RAW.RAW_DAILY_BALANCES db
JOIN RAW.RAW_CUSTOMERS c ON c.CUSTOMER_ID = db.CUSTOMER_ID
JOIN RAW.RAW_ACCOUNTS  a ON a.ACCOUNT_ID  = db.ACCOUNT_ID
JOIN RAW.V_GEN_CONFIG cfg ON TRUE
WHERE db.COHORT = 'INCUMBENT'
  AND db.PAYROLL_CUSTOMER_FLAG
  AND db.PRODUCT_TYPE IN ('SALARY_CURRENT','SAVINGS_RETAIL')
  AND a.OPEN_DATE < cfg.SPINE_START_DATE     -- constant population across the window
GROUP BY 1,2,3,4,5,6;

-- ---------------------------------------------------------------------------
-- 2. Rolling 90-day retention, overall and decomposed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE CORE.DT_RETENTION_DAILY
  TARGET_LAG='60 minutes' WAREHOUSE=PREMISEFLOW_WH REFRESH_MODE=AUTO
  COMMENT='Rolling 90-day incumbent balance retention for A-DEP-001, overall (GRAIN=OVERALL) and by dimension.'
AS
WITH salary AS (   -- metric scope: retail salary accounts only
  SELECT BALANCE_DATE, CUSTOMER_SEGMENT, ACQUISITION_CHANNEL, TENURE_BAND, BALANCE, ACCOUNTS
  FROM CORE.DT_GOVERNED_DAILY
  WHERE PRODUCT_TYPE = 'SALARY_CURRENT'
),
overall AS (
  SELECT BALANCE_DATE, 'OVERALL' AS GRAIN, 'ALL' AS DIM_VALUE,
         SUM(BALANCE) AS BALANCE, SUM(ACCOUNTS) AS ACCOUNTS
  FROM salary GROUP BY 1
),
by_segment AS (
  SELECT BALANCE_DATE, 'CUSTOMER_SEGMENT', CUSTOMER_SEGMENT, SUM(BALANCE), SUM(ACCOUNTS)
  FROM salary GROUP BY 1,2,3
),
by_channel AS (
  SELECT BALANCE_DATE, 'ACQUISITION_CHANNEL', ACQUISITION_CHANNEL, SUM(BALANCE), SUM(ACCOUNTS)
  FROM salary GROUP BY 1,2,3
),
by_tenure AS (
  SELECT BALANCE_DATE, 'TENURE_BAND', TENURE_BAND, SUM(BALANCE), SUM(ACCOUNTS)
  FROM salary GROUP BY 1,2,3
),
stacked AS (
  SELECT * FROM overall UNION ALL SELECT * FROM by_segment
  UNION ALL SELECT * FROM by_channel UNION ALL SELECT * FROM by_tenure
),
-- Salary accounts receive a month-start credit bump, so a point-in-time ratio
-- 90 days apart picks up a day-of-month artifact. A 30-day trailing average
-- removes it; for exponential balance decay the ratio of two 30-day averages
-- 90 days apart equals the underlying point ratio exactly.
smoothed AS (
  SELECT
    BALANCE_DATE, GRAIN, DIM_VALUE, BALANCE, ACCOUNTS,
    AVG(BALANCE) OVER (PARTITION BY GRAIN, DIM_VALUE ORDER BY BALANCE_DATE
                       ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS BALANCE_30D_AVG,
    COUNT(*)    OVER (PARTITION BY GRAIN, DIM_VALUE ORDER BY BALANCE_DATE
                       ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS WINDOW_OBS
  FROM stacked
)
SELECT
  cur.BALANCE_DATE            AS OBSERVATION_DATE,
  cur.GRAIN,
  cur.DIM_VALUE,
  cfg.METRIC_WINDOW_DAYS      AS WINDOW_DAYS,
  cur.BALANCE_30D_AVG         AS CURRENT_BALANCE,
  pri.BALANCE_30D_AVG         AS WINDOW_START_BALANCE,
  cur.BALANCE_30D_AVG / NULLIF(pri.BALANCE_30D_AVG,0) AS RETENTION_RATE,
  cur.BALANCE_30D_AVG - pri.BALANCE_30D_AVG           AS BALANCE_CHANGE,
  cur.ACCOUNTS                AS ACCOUNTS
FROM smoothed cur
JOIN smoothed pri
  ON pri.GRAIN = cur.GRAIN AND pri.DIM_VALUE = cur.DIM_VALUE
JOIN RAW.V_GEN_CONFIG cfg ON TRUE
WHERE pri.BALANCE_DATE = DATEADD(day, -cfg.METRIC_WINDOW_DAYS, cur.BALANCE_DATE)
  AND cur.WINDOW_OBS = 30 AND pri.WINDOW_OBS = 30;   -- complete smoothing windows only

-- ---------------------------------------------------------------------------
-- 3. Aggregate deposit picture -- the view that makes the masking obvious
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE CORE.DT_DEPOSIT_DAILY
  TARGET_LAG='60 minutes' WAREHOUSE=PREMISEFLOW_WH REFRESH_MODE=AUTO
  COMMENT='Total vs incumbent vs promotional deposits per day. Shows aggregate health masking cohort deterioration.'
AS
SELECT
  db.BALANCE_DATE,
  SUM(db.CLOSING_BALANCE)                                                        AS TOTAL_DEPOSITS,
  SUM(IFF(db.COHORT='INCUMBENT', db.CLOSING_BALANCE, 0))                         AS INCUMBENT_DEPOSITS,
  SUM(IFF(db.COHORT='PROMOTIONAL_NEW', db.CLOSING_BALANCE, 0))                   AS NEW_CUSTOMER_DEPOSITS,
  SUM(IFF(db.PROMOTIONAL_FLAG, db.CLOSING_BALANCE, 0))                           AS PROMOTIONAL_DEPOSITS,
  SUM(IFF(db.COHORT='INCUMBENT' AND db.PAYROLL_CUSTOMER_FLAG
          AND db.PRODUCT_TYPE IN ('SALARY_CURRENT','SAVINGS_RETAIL'),
          db.CLOSING_BALANCE, 0))                                                AS GOVERNED_STABLE_DEPOSITS,
  SUM(IFF(db.PRODUCT_TYPE='TERM_DEPOSIT', db.CLOSING_BALANCE, 0))                AS TERM_DEPOSITS,
  SUM(IFF(db.PRODUCT_TYPE='SME_CURRENT', db.CLOSING_BALANCE, 0))                 AS WHOLESALE_LIKE_DEPOSITS,
  COUNT(DISTINCT db.CUSTOMER_ID)                                                 AS ACTIVE_CUSTOMERS
FROM RAW.RAW_DAILY_BALANCES db
GROUP BY 1;

-- ---------------------------------------------------------------------------
-- 4. Validity-envelope context (are the conditions under which the assumption
--    was validated still in force?)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE CORE.DT_ASSUMPTION_CONTEXT
  TARGET_LAG='60 minutes' WAREHOUSE=PREMISEFLOW_WH REFRESH_MODE=AUTO
  COMMENT='Daily conditions used to test each assumption validity envelope.'
AS
SELECT
  d.BALANCE_DATE                                             AS OBSERVATION_DATE,
  r.POLICY_RATE_PCT,
  r.DEPOSIT_BETA,
  r.PEER_DEPOSIT_RATE_PCT - r.OWN_DEPOSIT_RATE_PCT           AS PEER_RATE_GAP_PCT,
  d.PROMOTIONAL_DEPOSITS / NULLIF(d.TOTAL_DEPOSITS,0)        AS PROMOTIONAL_FUNDING_SHARE,
  d.NEW_CUSTOMER_DEPOSITS / NULLIF(d.TOTAL_DEPOSITS,0)       AS NEW_CUSTOMER_FUNDING_SHARE,
  d.WHOLESALE_LIKE_DEPOSITS / NULLIF(d.TOTAL_DEPOSITS,0)     AS DEPOSIT_CONCENTRATION,
  d.TOTAL_DEPOSITS,
  d.GOVERNED_STABLE_DEPOSITS
FROM CORE.DT_DEPOSIT_DAILY d
JOIN RAW.RAW_MARKET_RATES r ON r.RATE_DATE = d.BALANCE_DATE;

-- ---------------------------------------------------------------------------
-- 5. THE observation object: current observations for every active assumption
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE CORE.DT_ASSUMPTION_OBSERVATIONS
  TARGET_LAG='60 minutes' WAREHOUSE=PREMISEFLOW_WH REFRESH_MODE=AUTO
  COMMENT='One observed value per active assumption per day. Input to the Reality Challenger.'
AS
-- A-DEP-001: rolling 90-day incumbent retail salary retention (data-driven)
SELECT
  'A-DEP-001'                AS ASSUMPTION_ID,
  'INCUMBENT_SALARY_RETENTION_90D' AS METRIC_CODE,
  OBSERVATION_DATE,
  RETENTION_RATE             AS OBSERVED_VALUE,
  ACCOUNTS                   AS SAMPLE_SIZE,
  WINDOW_DAYS,
  'DT_RETENTION_DAILY'       AS SOURCE
FROM CORE.DT_RETENTION_DAILY
WHERE GRAIN='OVERALL'
UNION ALL
-- A-DEP-002: 30-day rolling blended deposit beta (data-driven)
SELECT
  'A-DEP-002', 'DEPOSIT_BETA_ROLLING', RATE_DATE,
  AVG(DEPOSIT_BETA) OVER (ORDER BY RATE_DATE ROWS BETWEEN 29 PRECEDING AND CURRENT ROW),
  NULL, 30, 'RAW_MARKET_RATES'
FROM RAW.RAW_MARKET_RATES
UNION ALL
-- Remaining registry assumptions
SELECT ASSUMPTION_ID, METRIC_CODE, OBSERVATION_DATE, OBSERVED_VALUE, SAMPLE_SIZE, 1, 'STATIC_OBSERVATIONS'
FROM CORE.STATIC_OBSERVATIONS;

SELECT 'observation layer ready' AS STATUS,
  (SELECT COUNT(*) FROM CORE.DT_RETENTION_DAILY)        AS RETENTION_ROWS,
  (SELECT COUNT(*) FROM CORE.DT_DEPOSIT_DAILY)          AS DEPOSIT_DAYS,
  (SELECT COUNT(*) FROM CORE.DT_ASSUMPTION_OBSERVATIONS) AS OBSERVATION_ROWS;
