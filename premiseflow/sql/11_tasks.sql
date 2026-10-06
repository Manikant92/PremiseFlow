-- PremiseFlow :: 11_tasks.sql
-- Snowflake-native recurring monitoring. This is the production scheduler for
-- the product: it refreshes observations, re-tests every active assumption,
-- records challenges, identifies deterministic breaches, narrates them and
-- pre-computes impact for critical breaches.
--
-- It deliberately STOPS SHORT of creating reassessments. Reassessment follows
-- human confirmation of the breach (APP.CONFIRM_BREACH), so the task can never
-- reopen a committee decision on its own.

USE DATABASE PREMISEFLOW;
USE SCHEMA APP;

CREATE OR REPLACE TASK APP.T_PREMISEFLOW_MONITOR
  WAREHOUSE = PREMISEFLOW_WH
  SCHEDULE = 'USING CRON 0 6 * * * UTC'   -- daily 06:00 UTC
  SUSPEND_TASK_AFTER_NUM_FAILURES = 5
  COMMENT = 'PremiseFlow continuous assumption monitoring cycle.'
AS
  CALL APP.MONITORING_CYCLE();

-- A frequent variant is provided (suspended) purely so the recurring behaviour
-- can be demonstrated inside a short presentation window.
CREATE OR REPLACE TASK APP.T_PREMISEFLOW_MONITOR_DEMO
  WAREHOUSE = PREMISEFLOW_WH
  SCHEDULE = '10 MINUTE'
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
  COMMENT = 'Demo-cadence monitoring cycle. Keep SUSPENDED outside a demo.'
AS
  CALL APP.MONITORING_CYCLE();

ALTER TASK APP.T_PREMISEFLOW_MONITOR RESUME;
ALTER TASK APP.T_PREMISEFLOW_MONITOR_DEMO SUSPEND;

-- Operations:
--   ALTER TASK PREMISEFLOW.APP.T_PREMISEFLOW_MONITOR SUSPEND;
--   ALTER TASK PREMISEFLOW.APP.T_PREMISEFLOW_MONITOR RESUME;
--   EXECUTE TASK PREMISEFLOW.APP.T_PREMISEFLOW_MONITOR;   -- run once, now
--   SELECT NAME, STATE, SCHEDULED_TIME, STATE, ERROR_MESSAGE
--     FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME=>'T_PREMISEFLOW_MONITOR'))
--    ORDER BY SCHEDULED_TIME DESC;

SHOW TASKS LIKE 'T_PREMISEFLOW%' IN SCHEMA PREMISEFLOW.APP;
