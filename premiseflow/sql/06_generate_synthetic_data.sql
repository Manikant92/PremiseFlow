-- PremiseFlow :: 06_generate_synthetic_data.sql
-- Fully synthetic banking dataset containing a deliberately HIDDEN structural
-- break: incumbent salary-account retention collapses while promotional inflows
-- keep total deposits flat-to-growing.
--
-- The balance path is closed-form (piecewise-constant multiplicative drift) so
-- the dataset is fast to build and exactly reproducible. Pseudo-randomness uses
-- HASH() rather than RANDOM() for determinism.
-- NO REAL PII. Every identifier is generated.

USE DATABASE PREMISEFLOW;
USE SCHEMA RAW;

-- ---------------------------------------------------------------------------
-- 1. Timeline configuration
-- ---------------------------------------------------------------------------
DELETE FROM RAW.RAW_GEN_CONFIG;
INSERT INTO RAW.RAW_GEN_CONFIG (CONFIG_KEY, CONFIG_VALUE, DESCRIPTION)
SELECT * FROM VALUES
  ('DEMO_END_DATE',   TO_VARCHAR(CURRENT_DATE,'YYYY-MM-DD'), 'Last date of simulated history'),
  ('SPINE_DAYS',      '240',   'Days of daily balance history'),
  ('BREAK_OFFSET_DAYS','90',   'Structural break starts DEMO_END - this many days'),
  ('PRE_DAILY_FACTOR','0.99908','Incumbent payroll daily balance factor pre-break (~92% / 90d)'),
  ('POST_DAILY_FACTOR','0.99690','Incumbent payroll daily balance factor post-break (~78% smoothed / 90d)'),
  ('N_INCUMBENT_CUSTOMERS','8000','Incumbent customer count'),
  ('N_PROMO_CUSTOMERS','1600','Promotional in-flow customer count'),
  ('NONGOVERNED_DAILY_FACTOR','1.00026','Daily growth of deposits outside the governed pool'),
  ('ATTRITION_NORMALISER','1.1040','Rescales the heterogeneous attrition multipliers so the balance-weighted pool still lands on the target retention'),
  ('METRIC_WINDOW_DAYS','90','Rolling retention horizon for A-DEP-001');

CREATE OR REPLACE VIEW RAW.V_GEN_CONFIG AS
SELECT
  TO_DATE(MAX(CASE WHEN CONFIG_KEY='DEMO_END_DATE' THEN CONFIG_VALUE END))        AS DEMO_END_DATE,
  MAX(CASE WHEN CONFIG_KEY='SPINE_DAYS' THEN CONFIG_VALUE END)::INT               AS SPINE_DAYS,
  MAX(CASE WHEN CONFIG_KEY='BREAK_OFFSET_DAYS' THEN CONFIG_VALUE END)::INT        AS BREAK_OFFSET_DAYS,
  MAX(CASE WHEN CONFIG_KEY='PRE_DAILY_FACTOR' THEN CONFIG_VALUE END)::FLOAT       AS PRE_DAILY_FACTOR,
  MAX(CASE WHEN CONFIG_KEY='POST_DAILY_FACTOR' THEN CONFIG_VALUE END)::FLOAT      AS POST_DAILY_FACTOR,
  MAX(CASE WHEN CONFIG_KEY='N_INCUMBENT_CUSTOMERS' THEN CONFIG_VALUE END)::INT    AS N_INCUMBENT,
  MAX(CASE WHEN CONFIG_KEY='N_PROMO_CUSTOMERS' THEN CONFIG_VALUE END)::INT        AS N_PROMO,
  MAX(CASE WHEN CONFIG_KEY='NONGOVERNED_DAILY_FACTOR' THEN CONFIG_VALUE END)::FLOAT AS NONGOVERNED_DAILY_FACTOR,
  MAX(CASE WHEN CONFIG_KEY='ATTRITION_NORMALISER' THEN CONFIG_VALUE END)::FLOAT    AS ATTRITION_NORMALISER,
  MAX(CASE WHEN CONFIG_KEY='METRIC_WINDOW_DAYS' THEN CONFIG_VALUE END)::INT       AS METRIC_WINDOW_DAYS,
  DATEADD(day, -(MAX(CASE WHEN CONFIG_KEY='SPINE_DAYS' THEN CONFIG_VALUE END)::INT - 1),
          TO_DATE(MAX(CASE WHEN CONFIG_KEY='DEMO_END_DATE' THEN CONFIG_VALUE END))) AS SPINE_START_DATE,
  DATEADD(day, -MAX(CASE WHEN CONFIG_KEY='BREAK_OFFSET_DAYS' THEN CONFIG_VALUE END)::INT,
          TO_DATE(MAX(CASE WHEN CONFIG_KEY='DEMO_END_DATE' THEN CONFIG_VALUE END)))  AS BREAK_DATE
FROM RAW.RAW_GEN_CONFIG;

-- ---------------------------------------------------------------------------
-- 2. Ground truth (what the challenger is supposed to find)
-- ---------------------------------------------------------------------------
DELETE FROM RAW.RAW_GROUND_TRUTH;
INSERT INTO RAW.RAW_GROUND_TRUTH
 (GROUND_TRUTH_ID, ASSUMPTION_ID, PHENOMENON, BREAK_START_DATE, DESCRIPTION,
  EXPECTED_PRE_VALUE, EXPECTED_POST_VALUE, MASKING_MECHANISM)
SELECT
  'GT-001', 'A-DEP-001', 'INCUMBENT_RETAIL_SALARY_RETENTION_COLLAPSE',
  c.BREAK_DATE,
  'Incumbent payroll customers begin materially drawing down salary-current and linked savings balances. '||
  'The 90-day rolling balance-retention ratio decays from ~92% to ~78% over the 90 days following the break date.',
  0.920, 0.780,
  'Simultaneous acquisition of promotional savings customers (cohort PROMOTIONAL_NEW) whose inflows exceed '||
  'incumbent outflows, so TOTAL deposits stay flat-to-growing and aggregate monitoring sees no problem.'
FROM RAW.V_GEN_CONFIG c;

-- ---------------------------------------------------------------------------
-- 3. Customers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE T_CUST AS
WITH n AS (
  SELECT SEQ4()+1 AS i FROM TABLE(GENERATOR(ROWCOUNT=>20000))
), cfg AS (SELECT * FROM RAW.V_GEN_CONFIG),
sel AS (
  SELECT n.i, cfg.*,
         CASE WHEN n.i <= cfg.N_INCUMBENT THEN 'INCUMBENT' ELSE 'PROMOTIONAL_NEW' END AS COHORT,
         (ABS(HASH(n.i, 'seg'))  % 10000)/10000.0 AS u_seg,
         (ABS(HASH(n.i, 'pay'))  % 10000)/10000.0 AS u_pay,
         (ABS(HASH(n.i, 'chan')) % 10000)/10000.0 AS u_chan,
         (ABS(HASH(n.i, 'risk')) % 10000)/10000.0 AS u_risk,
         (ABS(HASH(n.i, 'join')) % 10000)/10000.0 AS u_join,
         (ABS(HASH(n.i, 'reg'))  % 10000)/10000.0 AS u_reg
  FROM n JOIN cfg ON TRUE
  WHERE n.i <= cfg.N_INCUMBENT + cfg.N_PROMO
)
SELECT
  'C'||LPAD(i,6,'0') AS CUSTOMER_ID,
  COHORT,
  CASE
    WHEN COHORT='PROMOTIONAL_NEW' THEN CASE WHEN u_seg < 0.74 THEN 'RETAIL_MASS' ELSE 'RETAIL_AFFLUENT' END
    WHEN u_seg < 0.62 THEN 'RETAIL_MASS'
    WHEN u_seg < 0.84 THEN 'RETAIL_AFFLUENT'
    WHEN u_seg < 0.96 THEN 'SME'
    ELSE 'CORPORATE'
  END AS CUSTOMER_SEGMENT,
  u_pay, u_chan, u_risk, u_join, u_reg,
  DEMO_END_DATE, BREAK_DATE
FROM sel;

DELETE FROM RAW.RAW_CUSTOMERS;
INSERT INTO RAW.RAW_CUSTOMERS
 (CUSTOMER_ID, CUSTOMER_SEGMENT, TENURE_MONTHS, PAYROLL_CUSTOMER_FLAG,
  ACQUISITION_CHANNEL, JOIN_DATE, RISK_SEGMENT, COHORT, HOME_REGION_CODE)
WITH j AS (
  SELECT t.*,
    CASE WHEN COHORT='INCUMBENT'
         THEN DATEADD(day, -(300 + FLOOR(u_join*2100)::INT), DEMO_END_DATE)
         ELSE DATEADD(day, FLOOR(u_join*85)::INT, BREAK_DATE)   -- promotional cohort arrives AFTER the break
    END AS JOIN_DATE,
    CASE WHEN COHORT='PROMOTIONAL_NEW' THEN (u_pay < 0.12)
         WHEN CUSTOMER_SEGMENT IN ('RETAIL_MASS','RETAIL_AFFLUENT') THEN (u_pay < 0.72)
         ELSE FALSE END AS PAYROLL_CUSTOMER_FLAG
  FROM T_CUST t
)
SELECT
  CUSTOMER_ID, CUSTOMER_SEGMENT,
  GREATEST(1, DATEDIFF(month, JOIN_DATE, DEMO_END_DATE)) AS TENURE_MONTHS,
  PAYROLL_CUSTOMER_FLAG,
  CASE
    WHEN COHORT='PROMOTIONAL_NEW' THEN CASE WHEN u_chan < 0.58 THEN 'AGGREGATOR'
                                            WHEN u_chan < 0.92 THEN 'DIGITAL' ELSE 'PARTNER' END
    WHEN u_chan < 0.46 THEN 'BRANCH'
    WHEN u_chan < 0.78 THEN 'DIGITAL'
    WHEN u_chan < 0.92 THEN 'PARTNER'
    ELSE 'AGGREGATOR'
  END AS ACQUISITION_CHANNEL,
  JOIN_DATE,
  CASE WHEN u_risk < 0.63 THEN 'LOW' WHEN u_risk < 0.91 THEN 'MEDIUM' ELSE 'HIGH' END AS RISK_SEGMENT,
  COHORT,
  'RG-'||LPAD(1 + FLOOR(u_reg*8)::INT, 2, '0') AS HOME_REGION_CODE
FROM j;

-- ---------------------------------------------------------------------------
-- 4. Accounts
-- ---------------------------------------------------------------------------
DELETE FROM RAW.RAW_ACCOUNTS;
INSERT INTO RAW.RAW_ACCOUNTS
 (ACCOUNT_ID, CUSTOMER_ID, PRODUCT_TYPE, OPEN_DATE, CURRENT_BALANCE, OPENING_BALANCE,
  INTEREST_RATE, PROMOTIONAL_FLAG, CURRENCY_CODE, STATUS)
WITH cfg AS (SELECT * FROM RAW.V_GEN_CONFIG),
cust AS (SELECT c.*, cfg.SPINE_START_DATE, cfg.BREAK_DATE, cfg.DEMO_END_DATE
         FROM RAW.RAW_CUSTOMERS c JOIN cfg ON TRUE),
prod AS (
  SELECT CUSTOMER_ID, 'SALARY_CURRENT' AS PRODUCT_TYPE, 1 AS SLOT FROM cust
    WHERE PAYROLL_CUSTOMER_FLAG
  UNION ALL
  SELECT CUSTOMER_ID, 'SAVINGS_RETAIL', 2 FROM cust
    WHERE CUSTOMER_SEGMENT IN ('RETAIL_MASS','RETAIL_AFFLUENT')
      AND COHORT='INCUMBENT'
      AND ( NOT PAYROLL_CUSTOMER_FLAG OR (ABS(HASH(CUSTOMER_ID,'sav'))%10000)/10000.0 < 0.55 )
  UNION ALL
  SELECT CUSTOMER_ID, 'TERM_DEPOSIT', 3 FROM cust
    WHERE COHORT='INCUMBENT'
      AND CUSTOMER_SEGMENT IN ('RETAIL_MASS','RETAIL_AFFLUENT')
      AND (ABS(HASH(CUSTOMER_ID,'td'))%10000)/10000.0 < 0.26
  UNION ALL
  SELECT CUSTOMER_ID, 'SME_CURRENT', 4 FROM cust WHERE CUSTOMER_SEGMENT IN ('SME','CORPORATE')
  UNION ALL
  SELECT CUSTOMER_ID, 'SAVINGS_RETAIL', 5 FROM cust
    WHERE CUSTOMER_SEGMENT='SME' AND (ABS(HASH(CUSTOMER_ID,'smesav'))%10000)/10000.0 < 0.4
  UNION ALL
  SELECT CUSTOMER_ID, 'PROMO_SAVINGS', 6 FROM cust WHERE COHORT='PROMOTIONAL_NEW'
),
base AS (
  SELECT p.CUSTOMER_ID, p.PRODUCT_TYPE, p.SLOT, c.CUSTOMER_SEGMENT, c.COHORT,
         c.JOIN_DATE, c.SPINE_START_DATE, c.BREAK_DATE, c.DEMO_END_DATE,
         (ABS(HASH(p.CUSTOMER_ID, p.SLOT, 'bal'))%10000)/10000.0 AS u_bal,
         (ABS(HASH(p.CUSTOMER_ID, p.SLOT, 'open'))%10000)/10000.0 AS u_open,
         (ABS(HASH(p.CUSTOMER_ID, p.SLOT, 'rate'))%10000)/10000.0 AS u_rate
  FROM prod p JOIN cust c USING (CUSTOMER_ID)
)
SELECT
  'A'||LPAD(ROW_NUMBER() OVER (ORDER BY CUSTOMER_ID, SLOT), 7, '0') AS ACCOUNT_ID,
  CUSTOMER_ID,
  PRODUCT_TYPE,
  OPEN_DATE,
  ROUND(OPENING_BALANCE, 2) AS CURRENT_BALANCE,   -- refreshed from daily balances below
  ROUND(OPENING_BALANCE, 2) AS OPENING_BALANCE,
  ROUND(RATE, 4) AS INTEREST_RATE,
  (PRODUCT_TYPE='PROMO_SAVINGS') AS PROMOTIONAL_FLAG,
  'USD' AS CURRENCY_CODE,
  'ACTIVE' AS STATUS
FROM (
  SELECT b.*,
    CASE WHEN PRODUCT_TYPE='PROMO_SAVINGS'
         THEN JOIN_DATE
         ELSE LEAST(DATEADD(day, 20, JOIN_DATE), DATEADD(day,-5,SPINE_START_DATE))
    END AS OPEN_DATE,
    ( CASE PRODUCT_TYPE
        WHEN 'SALARY_CURRENT' THEN 38000
        WHEN 'SAVINGS_RETAIL' THEN 65000
        WHEN 'TERM_DEPOSIT'   THEN 150000
        WHEN 'SME_CURRENT'    THEN 95000
        WHEN 'PROMO_SAVINGS'  THEN 60000
      END
      * CASE CUSTOMER_SEGMENT WHEN 'RETAIL_AFFLUENT' THEN 2.6 WHEN 'CORPORATE' THEN 4.0 ELSE 1.0 END
      * EXP((u_bal - 0.5) * 1.8)
    ) AS OPENING_BALANCE,
    CASE PRODUCT_TYPE
      WHEN 'SALARY_CURRENT' THEN 0.0025 + u_rate*0.0015
      WHEN 'SAVINGS_RETAIL' THEN 0.0180 + u_rate*0.0060
      WHEN 'TERM_DEPOSIT'   THEN 0.0390 + u_rate*0.0070
      WHEN 'SME_CURRENT'    THEN 0.0120 + u_rate*0.0060
      WHEN 'PROMO_SAVINGS'  THEN 0.0455 + u_rate*0.0060
    END AS RATE
  FROM base b
);

-- ---------------------------------------------------------------------------
-- 5. Daily balances (closed-form drift + deterministic noise)
-- ---------------------------------------------------------------------------
DELETE FROM RAW.RAW_DAILY_BALANCES;
INSERT INTO RAW.RAW_DAILY_BALANCES
 (ACCOUNT_ID, CUSTOMER_ID, BALANCE_DATE, CLOSING_BALANCE, PRODUCT_TYPE, COHORT,
  PROMOTIONAL_FLAG, PAYROLL_CUSTOMER_FLAG)
WITH cfg AS (SELECT * FROM RAW.V_GEN_CONFIG),
spine AS (
  SELECT DATEADD(day, SEQ4(), cfg.SPINE_START_DATE) AS BALANCE_DATE
  FROM TABLE(GENERATOR(ROWCOUNT=>400)) g JOIN cfg ON TRUE
  WHERE DATEADD(day, SEQ4(), cfg.SPINE_START_DATE) <= cfg.DEMO_END_DATE
),
acct AS (
  SELECT a.ACCOUNT_ID, a.CUSTOMER_ID, a.PRODUCT_TYPE, a.OPEN_DATE, a.OPENING_BALANCE,
         a.PROMOTIONAL_FLAG, c.COHORT, c.PAYROLL_CUSTOMER_FLAG,
         GREATEST(a.OPEN_DATE, cfg.SPINE_START_DATE) AS REF_DATE,
         -- Behavioural deposits governed by assumption A-DEP-001
         (c.COHORT='INCUMBENT' AND c.PAYROLL_CUSTOMER_FLAG
          AND a.PRODUCT_TYPE IN ('SALARY_CURRENT','SAVINGS_RETAIL')) AS IS_GOVERNED,
         -- Attrition is NOT uniform. Rate-aware, digitally-acquired and shorter-tenure
         -- customers leave fastest; branch-acquired long-tenure customers are stickiest.
         -- This is what makes segment decomposition diagnostically useful.
         ( CASE c.ACQUISITION_CHANNEL
             WHEN 'BRANCH' THEN 0.62 WHEN 'PARTNER' THEN 0.95
             WHEN 'DIGITAL' THEN 1.35 WHEN 'AGGREGATOR' THEN 1.60 ELSE 1.0 END
         * CASE WHEN c.TENURE_MONTHS < 24 THEN 1.30
                WHEN c.TENURE_MONTHS < 60 THEN 1.05 ELSE 0.88 END
         * CASE c.CUSTOMER_SEGMENT WHEN 'RETAIL_AFFLUENT' THEN 1.20 ELSE 0.95 END
         / cfg.ATTRITION_NORMALISER )                    AS POST_INTENSITY_MULT,
         cfg.BREAK_DATE, cfg.PRE_DAILY_FACTOR, cfg.POST_DAILY_FACTOR, cfg.NONGOVERNED_DAILY_FACTOR
  FROM RAW.RAW_ACCOUNTS a
  JOIN RAW.RAW_CUSTOMERS c USING (CUSTOMER_ID)
  JOIN cfg ON TRUE
),
joined AS (
  SELECT
    a.ACCOUNT_ID, a.CUSTOMER_ID, a.PRODUCT_TYPE, a.COHORT,
    a.PROMOTIONAL_FLAG, a.PAYROLL_CUSTOMER_FLAG, a.OPENING_BALANCE,
    s.BALANCE_DATE,
    CASE
      WHEN a.IS_GOVERNED THEN
        POWER(a.PRE_DAILY_FACTOR,
              GREATEST(0, DATEDIFF(day, a.REF_DATE, LEAST(s.BALANCE_DATE, a.BREAK_DATE))))
        * POWER(a.POST_DAILY_FACTOR,
              GREATEST(0, DATEDIFF(day, GREATEST(a.REF_DATE, a.BREAK_DATE), s.BALANCE_DATE))
              * a.POST_INTENSITY_MULT)
      WHEN a.PRODUCT_TYPE='PROMO_SAVINGS' THEN
        LEAST(1.0, (DATEDIFF(day, a.OPEN_DATE, s.BALANCE_DATE)+1)/14.0)
        * (1 + 0.0016 * DATEDIFF(day, a.OPEN_DATE, s.BALANCE_DATE))
      ELSE POWER(a.NONGOVERNED_DAILY_FACTOR, DATEDIFF(day, a.REF_DATE, s.BALANCE_DATE))
    END AS DRIFT,
    1 + ((ABS(HASH(a.ACCOUNT_ID, s.BALANCE_DATE))%2001)-1000)/1000.0 * 0.012 AS IDIO,
    1 + ((ABS(HASH(s.BALANCE_DATE,'mkt'))%2001)-1000)/1000.0 * 0.0035        AS MKT,
    CASE WHEN a.PRODUCT_TYPE='SALARY_CURRENT' AND DAY(s.BALANCE_DATE) <= 5
         THEN 1.022 ELSE 1.0 END                                            AS SEASON
  FROM acct a
  JOIN spine s ON s.BALANCE_DATE >= a.OPEN_DATE
)
SELECT
  ACCOUNT_ID, CUSTOMER_ID, BALANCE_DATE,
  ROUND(GREATEST(0, OPENING_BALANCE * DRIFT * IDIO * MKT * SEASON), 2) AS CLOSING_BALANCE,
  PRODUCT_TYPE, COHORT, PROMOTIONAL_FLAG, PAYROLL_CUSTOMER_FLAG
FROM joined;

-- Refresh point-in-time account balances from the generated path
MERGE INTO RAW.RAW_ACCOUNTS a
USING (
  SELECT db.ACCOUNT_ID, db.CLOSING_BALANCE
  FROM RAW.RAW_DAILY_BALANCES db
  JOIN RAW.V_GEN_CONFIG cfg ON db.BALANCE_DATE = cfg.DEMO_END_DATE
) b
ON a.ACCOUNT_ID = b.ACCOUNT_ID
WHEN MATCHED THEN UPDATE SET a.CURRENT_BALANCE = b.CLOSING_BALANCE;

-- ---------------------------------------------------------------------------
-- 6. Transactions
-- ---------------------------------------------------------------------------
DELETE FROM RAW.RAW_TRANSACTIONS;
INSERT INTO RAW.RAW_TRANSACTIONS
 (TRANSACTION_ID, ACCOUNT_ID, CUSTOMER_ID, TXN_DATE, TXN_TYPE, AMOUNT, DIRECTION,
  COUNTERPARTY_TYPE, CHANNEL)
WITH cfg AS (SELECT * FROM RAW.V_GEN_CONFIG),
slots AS (SELECT SEQ4()+1 AS k FROM TABLE(GENERATOR(ROWCOUNT=>8))),
a AS (
  SELECT ac.ACCOUNT_ID, ac.CUSTOMER_ID, ac.PRODUCT_TYPE, ac.OPEN_DATE, ac.OPENING_BALANCE,
         c.COHORT, c.PAYROLL_CUSTOMER_FLAG, cfg.DEMO_END_DATE, cfg.SPINE_START_DATE, cfg.BREAK_DATE
  FROM RAW.RAW_ACCOUNTS ac JOIN RAW.RAW_CUSTOMERS c USING (CUSTOMER_ID) JOIN cfg ON TRUE
),
x AS (
  SELECT a.*, s.k,
    (ABS(HASH(a.ACCOUNT_ID, s.k, 'd'))%10000)/10000.0 AS u_d,
    (ABS(HASH(a.ACCOUNT_ID, s.k, 't'))%10000)/10000.0 AS u_t,
    (ABS(HASH(a.ACCOUNT_ID, s.k, 'a'))%10000)/10000.0 AS u_a,
    (ABS(HASH(a.ACCOUNT_ID, s.k, 'c'))%10000)/10000.0 AS u_c
  FROM a JOIN slots s ON TRUE
),
y AS (
  SELECT x.*,
    GREATEST(OPEN_DATE, DATEADD(day, FLOOR(u_d * DATEDIFF(day, GREATEST(OPEN_DATE, SPINE_START_DATE), DEMO_END_DATE))::INT,
             GREATEST(OPEN_DATE, SPINE_START_DATE))) AS TXN_DATE
  FROM x
)
SELECT
  'T'||LPAD(ROW_NUMBER() OVER (ORDER BY ACCOUNT_ID, k), 9, '0') AS TRANSACTION_ID,
  ACCOUNT_ID, CUSTOMER_ID, TXN_DATE, TXN_TYPE,
  ROUND(AMOUNT,2) AS AMOUNT, DIRECTION,
  CASE WHEN TXN_TYPE='salary_credit' THEN 'EMPLOYER'
       WHEN TXN_TYPE='promotional_deposit' THEN 'EXTERNAL_BANK'
       WHEN TXN_TYPE='transfer' THEN 'EXTERNAL_BANK'
       ELSE 'RETAIL' END AS COUNTERPARTY_TYPE,
  CASE WHEN u_c < 0.55 THEN 'MOBILE' WHEN u_c < 0.8 THEN 'ONLINE'
       WHEN u_c < 0.93 THEN 'BRANCH' ELSE 'ATM' END AS CHANNEL
FROM (
  SELECT z.*,
    CASE WHEN z.TXN_TYPE IN ('deposit','interest_credit','salary_credit','promotional_deposit')
         THEN 'CREDIT' ELSE 'DEBIT' END AS DIRECTION
  FROM (
    SELECT y.*,
      CASE
        WHEN PRODUCT_TYPE='PROMO_SAVINGS' THEN 'promotional_deposit'
        WHEN PRODUCT_TYPE='SALARY_CURRENT' AND u_t < 0.34 THEN 'salary_credit'
        WHEN PRODUCT_TYPE IN ('SAVINGS_RETAIL','TERM_DEPOSIT') AND u_t < 0.16 THEN 'interest_credit'
        -- Post-break incumbent payroll customers skew heavily to outflows
        WHEN COHORT='INCUMBENT' AND PAYROLL_CUSTOMER_FLAG AND TXN_DATE >= BREAK_DATE AND u_t < 0.80
          THEN CASE WHEN u_a < 0.55 THEN 'transfer' ELSE 'withdrawal' END
        WHEN u_t < 0.58 THEN 'withdrawal'
        WHEN u_t < 0.80 THEN 'deposit'
        ELSE 'transfer'
      END AS TXN_TYPE,
      OPENING_BALANCE * (0.02 + u_a * 0.16) AS AMOUNT
    FROM y
  ) z
);

-- ---------------------------------------------------------------------------
-- 7. Market rates  (rising-rate environment, deposit beta drifts up post-break)
-- ---------------------------------------------------------------------------
DELETE FROM RAW.RAW_MARKET_RATES;
INSERT INTO RAW.RAW_MARKET_RATES
 (RATE_DATE, POLICY_RATE_PCT, INTERBANK_3M_PCT, PEER_DEPOSIT_RATE_PCT, OWN_DEPOSIT_RATE_PCT, DEPOSIT_BETA)
WITH cfg AS (SELECT * FROM RAW.V_GEN_CONFIG),
s AS (
  SELECT DATEADD(day, SEQ4(), cfg.SPINE_START_DATE) AS RATE_DATE, cfg.*
  FROM TABLE(GENERATOR(ROWCOUNT=>400)) JOIN cfg ON TRUE
  WHERE DATEADD(day, SEQ4(), cfg.SPINE_START_DATE) <= cfg.DEMO_END_DATE
)
SELECT RATE_DATE,
  ROUND(PR, 4), ROUND(PR + 0.18, 4),
  ROUND(PEER, 4), ROUND(OWN, 4),
  ROUND(LEAST(0.75, GREATEST(0.05, (OWN - 2.60) / NULLIF(PR - 2.60, 0))), 4) AS DEPOSIT_BETA
FROM (
  SELECT RATE_DATE, BREAK_DATE, SPINE_START_DATE,
    4.25 + 0.75 * LEAST(1.0, DATEDIFF(day, SPINE_START_DATE, RATE_DATE)/170.0) AS PR,
    3.55 + 0.95 * LEAST(1.0, DATEDIFF(day, SPINE_START_DATE, RATE_DATE)/150.0)
         + CASE WHEN RATE_DATE >= BREAK_DATE THEN 0.55 * LEAST(1.0, DATEDIFF(day, BREAK_DATE, RATE_DATE)/70.0) ELSE 0 END AS PEER,
    3.05 + 0.60 * LEAST(1.0, DATEDIFF(day, SPINE_START_DATE, RATE_DATE)/160.0)
         + CASE WHEN RATE_DATE >= BREAK_DATE THEN 0.42 * LEAST(1.0, DATEDIFF(day, BREAK_DATE, RATE_DATE)/80.0) ELSE 0 END AS OWN
  FROM s
);

SELECT 'synthetic data generated' AS STATUS,
       (SELECT COUNT(*) FROM RAW.RAW_CUSTOMERS)      AS CUSTOMERS,
       (SELECT COUNT(*) FROM RAW.RAW_ACCOUNTS)       AS ACCOUNTS,
       (SELECT COUNT(*) FROM RAW.RAW_DAILY_BALANCES) AS DAILY_BALANCES,
       (SELECT COUNT(*) FROM RAW.RAW_TRANSACTIONS)   AS TRANSACTIONS,
       (SELECT COUNT(*) FROM RAW.RAW_MARKET_RATES)   AS RATE_DAYS;
