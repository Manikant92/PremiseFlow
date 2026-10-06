-- PremiseFlow :: tests/sql/run_all.sql
-- Full automated suite, groups A-K, plus static application verification (L).
--
-- The harness itself lives in sql/15_validation.sql and sql/16_app_lint.sql; the
-- files in this directory are the entrypoints you actually run.

USE WAREHOUSE PREMISEFLOW_WH;

CALL PREMISEFLOW.TEST.RUN_ALL(NULL);
CALL PREMISEFLOW.TEST.LINT_APP();

-- Summary of the most recent A-K run
WITH latest AS (
  SELECT RUN_ID FROM PREMISEFLOW.TEST.TEST_RESULTS
  WHERE TEST_GROUP <> 'L' ORDER BY EXECUTED_AT DESC LIMIT 1
)
SELECT TEST_GROUP,
       COUNT(*)                                        AS TOTAL,
       COUNT_IF(OUTCOME='PASS')                        AS PASS,
       COUNT_IF(OUTCOME='PASS_FEATURE_UNAVAILABLE')    AS UNAVAILABLE,
       COUNT_IF(OUTCOME='FAIL')                        AS FAIL,
       COUNT_IF(OUTCOME='BLOCKED')                     AS BLOCKED,
       COUNT_IF(OUTCOME IN ('FAIL','BLOCKED') AND IS_CRITICAL) AS CRITICAL_FAILURES
FROM PREMISEFLOW.TEST.TEST_RESULTS
WHERE RUN_ID = (SELECT RUN_ID FROM latest)
GROUP BY TEST_GROUP
ORDER BY TEST_GROUP;

-- Anything that did not pass, with diagnostics
SELECT TEST_GROUP, TEST_ID, TEST_NAME, OUTCOME, EXPECTED, ACTUAL, LEFT(DETAIL, 500) AS DETAIL
FROM PREMISEFLOW.TEST.TEST_RESULTS
WHERE RUN_ID = (SELECT RUN_ID FROM PREMISEFLOW.TEST.TEST_RESULTS
                WHERE TEST_GROUP <> 'L' ORDER BY EXECUTED_AT DESC LIMIT 1)
  AND OUTCOME <> 'PASS'
ORDER BY TEST_GROUP, TEST_ID;
