-- PremiseFlow :: tests/regression/primary_scenario.sql
-- PERMANENT REGRESSION GUARD for the primary demo scenario.
--
-- This must fail if PremiseFlow ever stops detecting the structural break that
-- is deliberately seeded into the synthetic dataset. Run it after any change to
-- the generator, the observation layer, the challenger, the thresholds or the
-- reassessment engine.

USE WAREHOUSE PREMISEFLOW_WH;

CALL PREMISEFLOW.TEST.RUN_ALL('C,D,E,K');

WITH latest AS (
  SELECT RUN_ID FROM PREMISEFLOW.TEST.TEST_RESULTS
  WHERE TEST_GROUP <> 'L' ORDER BY EXECUTED_AT DESC LIMIT 1
), r AS (
  SELECT * FROM PREMISEFLOW.TEST.TEST_RESULTS WHERE RUN_ID = (SELECT RUN_ID FROM latest)
)
SELECT
  IFF(COUNT_IF(OUTCOME IN ('FAIL','BLOCKED') AND IS_CRITICAL) = 0,
      'REGRESSION PASS', 'REGRESSION FAIL')              AS VERDICT,
  COUNT(*)                                               AS ASSERTIONS,
  COUNT_IF(OUTCOME='PASS')                               AS PASSED,
  COUNT_IF(OUTCOME IN ('FAIL','BLOCKED'))                AS NOT_PASSED,
  LISTAGG(IFF(OUTCOME<>'PASS', TEST_ID||' '||TEST_NAME, NULL), ' | ') AS PROBLEMS
FROM r;

-- The seeded break versus what was detected. This is the assertion that matters:
-- the platform is not asserting a finding, it is rediscovering a known fact.
SELECT
  g.BREAK_START_DATE                                     AS SEEDED_BREAK_DATE,
  g.EXPECTED_PRE_VALUE                                   AS DESIGNED_PRE_RETENTION,
  g.EXPECTED_POST_VALUE                                  AS DESIGNED_POST_RETENTION,
  c.CHANGE_POINT_DATE                                    AS DETECTED_CHANGE_POINT,
  ABS(DATEDIFF(day, g.BREAK_START_DATE, c.CHANGE_POINT_DATE)) AS DETECTION_ERROR_DAYS,
  ROUND(c.OBSERVED_VALUE, 4)                             AS OBSERVED_RETENTION,
  c.EXPECTED_VALUE                                       AS APPROVED_PREMISE,
  c.PERSISTENCE_DAYS                                     AS CONSECUTIVE_BREACH_DAYS,
  c.STATUS,
  IFF(c.STATUS = 'BREACHED' AND ABS(DATEDIFF(day, g.BREAK_START_DATE, c.CHANGE_POINT_DATE)) <= 21,
      'GROUND TRUTH MATCHED', 'GROUND TRUTH MISSED')     AS VERDICT
FROM PREMISEFLOW.RAW.RAW_GROUND_TRUTH g
CROSS JOIN (
  SELECT CHANGE_POINT_DATE, OBSERVED_VALUE, EXPECTED_VALUE, PERSISTENCE_DAYS, STATUS
  FROM PREMISEFLOW.CORE.ASSUMPTION_CHALLENGES
  WHERE ASSUMPTION_ID = 'A-DEP-001' ORDER BY EVALUATED_AT DESC LIMIT 1
) c
WHERE g.ASSUMPTION_ID = 'A-DEP-001';

-- The masking effect must still be present, otherwise the demo has no point.
SELECT
  ROUND(TOTAL_DEPOSITS/1e6, 1)            AS TOTAL_USD_M,
  ROUND(TOTAL_DEPOSIT_GROWTH*100, 2)      AS TOTAL_GROWTH_PCT,
  ROUND(GOVERNED_STABLE_DEPOSITS/1e6, 1)  AS GOVERNED_STABLE_USD_M,
  ROUND(GOVERNED_DEPOSIT_GROWTH*100, 2)   AS GOVERNED_GROWTH_PCT,
  ROUND(PROMOTIONAL_FUNDING_SHARE*100, 2) AS PROMO_FUNDING_SHARE_PCT,
  IFF(TOTAL_DEPOSIT_GROWTH > 0 AND GOVERNED_DEPOSIT_GROWTH < -0.10,
      'MASKING PRESENT', 'MASKING ABSENT') AS VERDICT
FROM PREMISEFLOW.CORE.V_DEPOSIT_MASKING
ORDER BY BALANCE_DATE DESC LIMIT 1;

-- Consequence propagation must still reach the right decisions, and only those.
SELECT DECISION_REF, GOVERNANCE_STATUS,
       IFF(DECISION_ID IN ('ALCO_DECISION_2026_017','ALCO_DECISION_2026_011'),
           'SHOULD BE REASSESSMENT_REQUIRED', 'SHOULD REMAIN APPROVED') AS EXPECTATION
FROM PREMISEFLOW.CORE.DECISIONS
ORDER BY DECISION_REF;
