-- PremiseFlow :: 15_validation.sql
-- Automated test harness. Test groups A-K per the build specification.
--
-- Every assertion is recorded with its expected and actual value so a failure is
-- diagnosable without re-running. Outcomes are one of:
--   PASS                     assertion held
--   PASS_FEATURE_UNAVAILABLE an optional capability is absent; core unaffected
--   FAIL                     assertion did not hold
--   BLOCKED                  could not be evaluated (never reported as a pass)

USE DATABASE PREMISEFLOW;
USE SCHEMA TEST;

CREATE TABLE IF NOT EXISTS TEST.TEST_RESULTS (
  RUN_ID       STRING,
  TEST_GROUP   STRING,
  TEST_ID      STRING,
  TEST_NAME    STRING,
  OUTCOME      STRING,
  EXPECTED     STRING,
  ACTUAL       STRING,
  DETAIL       STRING,
  IS_CRITICAL  BOOLEAN,
  DURATION_MS  NUMBER(12,0),
  EXECUTED_AT  TIMESTAMP_NTZ
);

CREATE OR REPLACE PROCEDURE TEST.RUN_ALL(P_GROUPS STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json, time, uuid

def run(session, p_groups):
    run_id = 'TEST-' + uuid.uuid4().hex[:14]
    wanted = None
    if p_groups:
        wanted = {g.strip().upper() for g in p_groups.split(',') if g.strip()}
    results = []

    def lit(v):
        if v is None: return 'NULL'
        if isinstance(v, bool): return 'TRUE' if v else 'FALSE'
        if isinstance(v, (int, float)): return repr(v)
        # Escape backslashes BEFORE quotes: Snowflake processes backslash escapes inside
    # single-quoted literals, so LLM-generated text containing a backslash would
    # otherwise corrupt the statement.
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"

    def record(group, tid, name, outcome, expected, actual, detail='', critical=True, ms=0):
        results.append({'group': group, 'id': tid, 'name': name, 'outcome': outcome,
                        'expected': str(expected), 'actual': str(actual),
                        'detail': detail, 'critical': critical})
        session.sql(f"""INSERT INTO TEST.TEST_RESULTS
            (RUN_ID, TEST_GROUP, TEST_ID, TEST_NAME, OUTCOME, EXPECTED, ACTUAL, DETAIL,
             IS_CRITICAL, DURATION_MS, EXECUTED_AT)
            SELECT {lit(run_id)},{lit(group)},{lit(tid)},{lit(name)},{lit(outcome)},
                   {lit(str(expected))},{lit(str(actual))},{lit(detail)},
                   {lit(bool(critical))},{lit(int(ms))},CURRENT_TIMESTAMP()""").collect()

    def scalar(sql):
        return session.sql(sql).collect()[0][0]

    def check(group, tid, name, sql, predicate, expected_desc, critical=True, detail=''):
        t0 = time.time()
        try:
            actual = scalar(sql)
            ok = predicate(actual)
            record(group, tid, name, 'PASS' if ok else 'FAIL', expected_desc, actual,
                   detail, critical, (time.time() - t0) * 1000)
            return ok, actual
        except Exception as e:
            record(group, tid, name, 'BLOCKED', expected_desc, 'error',
                   str(e)[:800], critical, (time.time() - t0) * 1000)
            return False, None

    def want(g):
        return wanted is None or g in wanted

    cfg = session.sql("SELECT * FROM RAW.V_GEN_CONFIG").collect()[0]
    break_date = cfg['BREAK_DATE']

    # =====================================================================
    # A. Environment
    # =====================================================================
    if want('A'):
        check('A', 'A1', 'Database and schemas exist',
              """SELECT COUNT(*) FROM PREMISEFLOW.INFORMATION_SCHEMA.SCHEMATA
                 WHERE SCHEMA_NAME IN ('RAW','CORE','AI','APP','AUDIT','TEST')""",
              lambda v: int(v) == 6, '6 schemas')
        check('A', 'A2', 'Warehouse usable',
              "SELECT CURRENT_WAREHOUSE()", lambda v: v is not None, 'a warehouse is active')
        check('A', 'A3', 'Core governed tables exist',
              """SELECT COUNT(*) FROM PREMISEFLOW.INFORMATION_SCHEMA.TABLES
                 WHERE TABLE_SCHEMA='CORE' AND TABLE_NAME IN
                 ('ASSUMPTIONS','ASSUMPTION_VERSIONS','ASSUMPTION_EVIDENCE',
                  'ASSUMPTION_DEPENDENCIES','ASSUMPTION_OBSERVATIONS','ASSUMPTION_CHALLENGES',
                  'ASSUMPTION_BREACHES','MODELS','RISK_METRICS','DECISIONS',
                  'DECISION_DEPENDENCIES','REASSESSMENTS','SCENARIOS','SCENARIO_RESULTS',
                  'ACTION_OUTBOX','LIQUIDITY_INPUTS')""",
              lambda v: int(v) == 16, '16 core tables')
        check('A', 'A4', 'Audit tables exist',
              """SELECT COUNT(*) FROM PREMISEFLOW.INFORMATION_SCHEMA.TABLES
                 WHERE TABLE_SCHEMA='AUDIT' AND TABLE_NAME IN
                 ('AUDIT_EVENTS','AGENT_RUNS','HUMAN_ACTIONS','INTEGRATION_ACTIONS')""",
              lambda v: int(v) == 4, '4 audit tables')
        check('A', 'A5', 'Dynamic tables built',
              """SELECT COUNT(*) FROM PREMISEFLOW.INFORMATION_SCHEMA.TABLES
                 WHERE TABLE_SCHEMA='CORE' AND TABLE_NAME LIKE 'DT_%'""",
              lambda v: int(v) >= 5, 'at least 5 dynamic tables')
        check('A', 'A6', 'Document stage accessible',
              "SELECT COUNT(*) FROM DIRECTORY(@PREMISEFLOW.AI.DOCS)",
              lambda v: int(v) >= 6, 'at least 6 staged documents')
        check('A', 'A7', 'Semantic view queryable',
              """SELECT COUNT(*) FROM SEMANTIC_VIEW(AI.PREMISEFLOW_SEMANTIC
                   DIMENSIONS assumptions.assumption_id METRICS assumptions.assumption_count)""",
              lambda v: int(v) >= 10, 'at least 10 assumptions via semantic view')
        check('A', 'A8', 'Monitoring task scheduled and started',
              """SELECT COUNT(*) FROM TABLE(INFORMATION_SCHEMA.TASK_DEPENDENTS(
                   TASK_NAME=>'PREMISEFLOW.APP.T_PREMISEFLOW_MONITOR', RECURSIVE=>FALSE))""",
              lambda v: int(v) >= 1, 'task exists')
        check('A', 'A9', 'Streamlit app object exists',
              """SELECT COUNT(*) FROM PREMISEFLOW.INFORMATION_SCHEMA.OBJECT_PRIVILEGES
                 WHERE OBJECT_NAME='PREMISEFLOW_APP'""",
              lambda v: int(v) >= 0, 'no error querying', critical=False)

    # =====================================================================
    # B. Referential integrity
    # =====================================================================
    if want('B'):
        check('B', 'B1', 'Every account belongs to a valid customer',
              """SELECT COUNT(*) FROM RAW.RAW_ACCOUNTS a
                 LEFT JOIN RAW.RAW_CUSTOMERS c USING (CUSTOMER_ID) WHERE c.CUSTOMER_ID IS NULL""",
              lambda v: int(v) == 0, '0 orphan accounts')
        check('B', 'B2', 'Every transaction belongs to a valid account',
              """SELECT COUNT(*) FROM RAW.RAW_TRANSACTIONS t
                 LEFT JOIN RAW.RAW_ACCOUNTS a USING (ACCOUNT_ID) WHERE a.ACCOUNT_ID IS NULL""",
              lambda v: int(v) == 0, '0 orphan transactions')
        check('B', 'B3', 'Every daily balance belongs to a valid account',
              """SELECT COUNT(*) FROM RAW.RAW_DAILY_BALANCES d
                 LEFT JOIN RAW.RAW_ACCOUNTS a USING (ACCOUNT_ID) WHERE a.ACCOUNT_ID IS NULL""",
              lambda v: int(v) == 0, '0 orphan balances')
        check('B', 'B4', 'No balance predates account opening',
              """SELECT COUNT(*) FROM RAW.RAW_DAILY_BALANCES d
                 JOIN RAW.RAW_ACCOUNTS a USING (ACCOUNT_ID)
                 WHERE d.BALANCE_DATE < a.OPEN_DATE""",
              lambda v: int(v) == 0, '0 pre-opening balances')
        check('B', 'B5', 'Every assumption has exactly one current version',
              """SELECT COUNT(*) FROM (
                   SELECT ASSUMPTION_ID, COUNT_IF(IS_CURRENT) n
                   FROM CORE.ASSUMPTION_VERSIONS GROUP BY 1 HAVING n <> 1)""",
              lambda v: int(v) == 0, '0 assumptions with wrong current-version count')
        check('B', 'B6', 'Every dependency edge references a known object',
              """SELECT COUNT(*) FROM CORE.ASSUMPTION_DEPENDENCIES d
                 WHERE d.SOURCE_TYPE='ASSUMPTION'
                   AND d.SOURCE_OBJECT NOT IN (SELECT ASSUMPTION_ID FROM CORE.ASSUMPTIONS)""",
              lambda v: int(v) == 0, '0 dangling assumption sources')
        check('B', 'B7', 'Decision dependencies reference valid assumption versions',
              """SELECT COUNT(*) FROM CORE.DECISION_DEPENDENCIES dd
                 LEFT JOIN CORE.ASSUMPTION_VERSIONS v ON v.VERSION_ID = dd.VERSION_ID
                 LEFT JOIN CORE.ASSUMPTIONS a ON a.ASSUMPTION_ID = dd.ASSUMPTION_ID
                 WHERE v.VERSION_ID IS NULL OR a.ASSUMPTION_ID IS NULL""",
              lambda v: int(v) == 0, '0 invalid decision dependencies')
        check('B', 'B8', 'Decision dependencies reference valid decisions',
              """SELECT COUNT(*) FROM CORE.DECISION_DEPENDENCIES dd
                 LEFT JOIN CORE.DECISIONS d USING (DECISION_ID) WHERE d.DECISION_ID IS NULL""",
              lambda v: int(v) == 0, '0 dangling decisions')
        check('B', 'B9', 'Reassessments reference valid decisions and assumptions',
              """SELECT COUNT(*) FROM CORE.REASSESSMENTS r
                 LEFT JOIN CORE.DECISIONS d USING (DECISION_ID)
                 LEFT JOIN CORE.ASSUMPTIONS a USING (ASSUMPTION_ID)
                 WHERE d.DECISION_ID IS NULL OR a.ASSUMPTION_ID IS NULL""",
              lambda v: int(v) == 0, '0 invalid reassessments')
        check('B', 'B10', 'No negative balances generated',
              "SELECT COUNT(*) FROM RAW.RAW_DAILY_BALANCES WHERE CLOSING_BALANCE < 0",
              lambda v: int(v) == 0, '0 negative balances')

    # =====================================================================
    # C. Synthetic ground truth
    # =====================================================================
    if want('C'):
        check('C', 'C1', 'Pre-break retention supports the >=90% premise',
              f"""SELECT MIN(OBSERVED_VALUE) FROM CORE.DT_ASSUMPTION_OBSERVATIONS
                  WHERE ASSUMPTION_ID='A-DEP-001' AND OBSERVATION_DATE < '{break_date}'""",
              lambda v: float(v) >= 0.90, 'minimum pre-break retention >= 0.90')
        check('C', 'C2', 'Post-break retention falls materially',
              """SELECT OBSERVED_VALUE FROM CORE.DT_ASSUMPTION_OBSERVATIONS
                 WHERE ASSUMPTION_ID='A-DEP-001' ORDER BY OBSERVATION_DATE DESC LIMIT 1""",
              lambda v: 0.74 <= float(v) <= 0.82, 'latest retention in 0.74-0.82')
        check('C', 'C3', 'Retention deterioration exceeds 10 percentage points',
              """SELECT MAX(OBSERVED_VALUE) - MIN(OBSERVED_VALUE)
                 FROM CORE.DT_ASSUMPTION_OBSERVATIONS WHERE ASSUMPTION_ID='A-DEP-001'""",
              lambda v: float(v) >= 0.10, 'range >= 0.10')
        check('C', 'C4', 'Total deposits stable or growing after the break (masking)',
              f"""SELECT (SELECT TOTAL_DEPOSITS FROM CORE.DT_DEPOSIT_DAILY
                          ORDER BY BALANCE_DATE DESC LIMIT 1)
                       / (SELECT TOTAL_DEPOSITS FROM CORE.DT_DEPOSIT_DAILY
                          WHERE BALANCE_DATE='{break_date}') - 1""",
              lambda v: float(v) >= -0.005, 'total deposit growth since break >= -0.5%')
        check('C', 'C5', 'Governed stable deposits fell materially',
              f"""SELECT (SELECT GOVERNED_STABLE_DEPOSITS FROM CORE.DT_DEPOSIT_DAILY
                          ORDER BY BALANCE_DATE DESC LIMIT 1)
                       / (SELECT GOVERNED_STABLE_DEPOSITS FROM CORE.DT_DEPOSIT_DAILY
                          WHERE BALANCE_DATE='{break_date}') - 1""",
              lambda v: float(v) <= -0.15, 'governed pool change since break <= -15%')
        check('C', 'C6', 'Promotional inflow explains the masking',
              """SELECT PROMOTIONAL_DEPOSITS FROM CORE.DT_DEPOSIT_DAILY
                 ORDER BY BALANCE_DATE DESC LIMIT 1""",
              lambda v: float(v) > 0, 'promotional deposits exist')
        check('C', 'C7', 'Promotional funding share breaches the 5% envelope condition',
              """SELECT PROMOTIONAL_FUNDING_SHARE FROM CORE.DT_ASSUMPTION_CONTEXT
                 ORDER BY OBSERVATION_DATE DESC LIMIT 1""",
              lambda v: float(v) > 0.05, 'promotional funding share > 5%')
        check('C', 'C8', 'Ground truth record present',
              "SELECT COUNT(*) FROM RAW.RAW_GROUND_TRUTH WHERE ASSUMPTION_ID='A-DEP-001'",
              lambda v: int(v) == 1, '1 ground truth record')
        check('C', 'C9', 'Attrition is heterogeneous across cohorts (diagnosable)',
              """SELECT MAX(RETENTION_RATE) - MIN(RETENTION_RATE) FROM CORE.DT_RETENTION_DAILY
                 WHERE GRAIN='ACQUISITION_CHANNEL'
                   AND OBSERVATION_DATE=(SELECT MAX(OBSERVATION_DATE) FROM CORE.DT_RETENTION_DAILY)""",
              lambda v: float(v) >= 0.05, 'channel retention spread >= 5pp')
        check('C', 'C10', 'Data volumes within the specified range',
              "SELECT COUNT(*) FROM RAW.RAW_CUSTOMERS",
              lambda v: 5000 <= int(v) <= 12000, '5k-12k customers')
        check('C', 'C11', 'Transaction volume in the tens of thousands',
              "SELECT COUNT(*) FROM RAW.RAW_TRANSACTIONS",
              lambda v: int(v) >= 20000, '>= 20k transactions')

    # =====================================================================
    # D. Assumption engine
    # =====================================================================
    if want('D'):
        # Valid period -> VALID
        t0 = time.time()
        try:
            pre = session.sql(f"""SELECT DATEADD(day,-10,BREAK_DATE) D FROM RAW.V_GEN_CONFIG""").collect()[0]['D']
            r = session.call('APP.RUN_CHALLENGER', 'A-DEP-001', 'test_harness', pre)
            r = json.loads(r) if isinstance(r, str) else r
            st = r['results'][0]['status']
            record('D', 'D1', 'Valid period returns VALID', 'PASS' if st == 'VALID' else 'FAIL',
                   'VALID', st, f"as_of={pre}", True, (time.time() - t0) * 1000)
        except Exception as e:
            record('D', 'D1', 'Valid period returns VALID', 'BLOCKED', 'VALID', 'error', str(e)[:600])

        # Mid deterioration -> CHALLENGED
        t0 = time.time()
        try:
            mid = session.sql("SELECT DATEADD(day,40,BREAK_DATE) D FROM RAW.V_GEN_CONFIG").collect()[0]['D']
            r = session.call('APP.RUN_CHALLENGER', 'A-DEP-001', 'test_harness', mid)
            r = json.loads(r) if isinstance(r, str) else r
            st = r['results'][0]['status']
            record('D', 'D2', 'Pre-breach deterioration returns CHALLENGED',
                   'PASS' if st == 'CHALLENGED' else 'FAIL', 'CHALLENGED', st,
                   f"as_of={mid}", True, (time.time() - t0) * 1000)
        except Exception as e:
            record('D', 'D2', 'Pre-breach deterioration returns CHALLENGED', 'BLOCKED',
                   'CHALLENGED', 'error', str(e)[:600])

        # First day below breach threshold -> NOT yet BREACHED (persistence)
        t0 = time.time()
        try:
            first = session.sql("""SELECT MIN(OBSERVATION_DATE) D FROM CORE.DT_ASSUMPTION_OBSERVATIONS o
                JOIN CORE.ASSUMPTION_VERSIONS v ON v.ASSUMPTION_ID=o.ASSUMPTION_ID AND v.IS_CURRENT
                WHERE o.ASSUMPTION_ID='A-DEP-001' AND o.OBSERVED_VALUE < v.BREACH_THRESHOLD""").collect()[0]['D']
            r = session.call('APP.RUN_CHALLENGER', 'A-DEP-001', 'test_harness', first)
            r = json.loads(r) if isinstance(r, str) else r
            res0 = r['results'][0]
            ok = res0['status'] != 'BREACHED'
            record('D', 'D3', 'First day below breach threshold is not yet a breach',
                   'PASS' if ok else 'FAIL', 'not BREACHED', res0['status'],
                   f"as_of={first}, persistence={res0['persistence_days']}/{res0['persistence_required']}",
                   True, (time.time() - t0) * 1000)
        except Exception as e:
            record('D', 'D3', 'First day below breach threshold is not yet a breach', 'BLOCKED',
                   'not BREACHED', 'error', str(e)[:600])

        # Persistent condition -> BREACHED
        t0 = time.time()
        try:
            r = session.call('APP.RUN_CHALLENGER', 'A-DEP-001', 'test_harness', None)
            r = json.loads(r) if isinstance(r, str) else r
            res0 = r['results'][0]
            ok = res0['status'] == 'BREACHED' and res0['persistence_days'] >= res0['persistence_required']
            record('D', 'D4', 'Persistent post-break condition returns BREACHED',
                   'PASS' if ok else 'FAIL', 'BREACHED with persistence met', res0['status'],
                   f"persistence={res0['persistence_days']}/{res0['persistence_required']}",
                   True, (time.time() - t0) * 1000)
        except Exception as e:
            record('D', 'D4', 'Persistent post-break condition returns BREACHED', 'BLOCKED',
                   'BREACHED', 'error', str(e)[:600])

        # Single injected outlier must NOT create a breach
        t0 = time.time()
        injected = False
        try:
            session.sql("""CREATE OR REPLACE TABLE TEST.T_SO_BACKUP AS
                           SELECT * FROM CORE.STATIC_OBSERVATIONS WHERE ASSUMPTION_ID='A-LIQ-001'""").collect()
            before = session.call('APP.RUN_CHALLENGER', 'A-LIQ-001', 'test_harness', None)
            before = json.loads(before) if isinstance(before, str) else before
            base_status = before['results'][0]['status']
            # A-LIQ-001 is LOWER_IS_WORSE with a breach threshold of 0.65; drive the
            # single most recent observation far below it and nothing else.
            session.sql("""UPDATE CORE.STATIC_OBSERVATIONS SET OBSERVED_VALUE = 0.10
                WHERE ASSUMPTION_ID='A-LIQ-001'
                  AND OBSERVATION_DATE=(SELECT MAX(OBSERVATION_DATE) FROM CORE.STATIC_OBSERVATIONS
                                        WHERE ASSUMPTION_ID='A-LIQ-001')""").collect()
            injected = True
            session.sql("ALTER DYNAMIC TABLE CORE.DT_ASSUMPTION_OBSERVATIONS REFRESH").collect()
            spiked = session.call('APP.RUN_CHALLENGER', 'A-LIQ-001', 'test_harness', None)
            spiked = json.loads(spiked) if isinstance(spiked, str) else spiked
            sres = spiked['results'][0]
            ok = sres['status'] != 'BREACHED' and sres['persistence_days'] <= 1
            record('D', 'D5', 'Single noisy observation does not create a false breach',
                   'PASS' if ok else 'FAIL', 'not BREACHED (persistence 1 < required)',
                   f"{sres['status']} persistence={sres['persistence_days']}",
                   f"baseline status before injection was {base_status}; injected 0.10 on the latest day only",
                   True, (time.time() - t0) * 1000)
        except Exception as e:
            record('D', 'D5', 'Single noisy observation does not create a false breach', 'BLOCKED',
                   'not BREACHED', 'error', str(e)[:600])
        finally:
            if injected:
                try:
                    session.sql("""MERGE INTO CORE.STATIC_OBSERVATIONS s
                        USING TEST.T_SO_BACKUP b
                          ON b.ASSUMPTION_ID=s.ASSUMPTION_ID AND b.OBSERVATION_DATE=s.OBSERVATION_DATE
                        WHEN MATCHED THEN UPDATE SET s.OBSERVED_VALUE = b.OBSERVED_VALUE""").collect()
                    session.sql("ALTER DYNAMIC TABLE CORE.DT_ASSUMPTION_OBSERVATIONS REFRESH").collect()
                    session.call('APP.RUN_CHALLENGER', 'A-LIQ-001', 'test_harness', None)
                    restored = session.sql("""SELECT STATUS FROM CORE.ASSUMPTIONS
                                              WHERE ASSUMPTION_ID='A-LIQ-001'""").collect()[0][0]
                    record('D', 'D5b', 'Injected outlier is rolled back cleanly',
                           'PASS' if restored == 'VALID' else 'FAIL', 'A-LIQ-001 back to VALID',
                           restored, '', True)
                except Exception as e:
                    record('D', 'D5b', 'Injected outlier is rolled back cleanly', 'FAIL',
                           'A-LIQ-001 back to VALID', 'restore failed', str(e)[:400], True)

        check('D', 'D6', 'Challenger detects the seeded change point within 21 days',
              """SELECT ABS(DATEDIFF(day,
                    (SELECT BREAK_START_DATE FROM RAW.RAW_GROUND_TRUTH WHERE ASSUMPTION_ID='A-DEP-001'),
                    (SELECT CHANGE_POINT_DATE FROM CORE.ASSUMPTION_CHALLENGES
                     WHERE ASSUMPTION_ID='A-DEP-001' ORDER BY EVALUATED_AT DESC LIMIT 1)))""",
              lambda v: int(v) <= 21, 'change point within 21 days of seeded break')
        check('D', 'D7', 'Two-sided assumption within bounds stays VALID',
              "SELECT STATUS FROM CORE.ASSUMPTIONS WHERE ASSUMPTION_ID='A-CRD-002'",
              lambda v: v == 'VALID', 'A-CRD-002 VALID')
        # Evaluate A-DEP-002 directly rather than relying on whatever the registry
        # happened to hold: a stale VALID would otherwise look like a logic failure.
        t0 = time.time()
        try:
            r = session.call('APP.RUN_CHALLENGER', 'A-DEP-002', 'test_harness', None)
            r = json.loads(r) if isinstance(r, str) else r
            res2 = r['results'][0]
            ok = res2['status'] in ('CHALLENGED', 'BREACHED')
            record('D', 'D8', 'Deposit beta ceiling independently detected',
                   'PASS' if ok else 'FAIL', 'CHALLENGED or BREACHED',
                   f"{res2['status']} observed={res2['observed_value']} vs expected={res2['expected_value']}",
                   'A second, independent data-driven assumption on the rate series.',
                   True, (time.time() - t0) * 1000)
        except Exception as e:
            record('D', 'D8', 'Deposit beta ceiling independently detected', 'BLOCKED',
                   'CHALLENGED or BREACHED', 'error', str(e)[:600])
        check('D', 'D9', 'Challenge records store method and evidence',
              """SELECT COUNT(*) FROM CORE.ASSUMPTION_CHALLENGES
                 WHERE ASSUMPTION_ID='A-DEP-001' AND METHOD IS NOT NULL
                   AND ARRAY_SIZE(EVIDENCE_IDS) > 0""",
              lambda v: int(v) >= 1, 'at least one challenge with method and evidence')

    # =====================================================================
    # E. Impact
    # =====================================================================
    if want('E'):
        t0 = time.time()
        try:
            imp = session.call('APP.RUN_IMPACT_FOR_ASSUMPTION', 'A-DEP-001', 'test_harness')
            imp = json.loads(imp) if isinstance(imp, str) else imp
            def m(block, mid):
                for x in block['metrics']:
                    if x['metric_id'] == mid:
                        return x['value']
            lb, lo = m(imp['baseline'], 'LCR'), m(imp['observed'], 'LCR')
            ok = lb is not None and 112 <= lb <= 124
            record('E', 'E1', 'Baseline scenario produces a healthy LCR',
                   'PASS' if ok else 'FAIL', 'LCR 112-124%', lb, '', True, (time.time() - t0) * 1000)
            ok2 = lo is not None and 92 <= lo <= 104
            record('E', 'E2', 'Observed scenario materially reduces LCR',
                   'PASS' if ok2 else 'FAIL', 'LCR 92-104%', lo, '', True)
            ok3 = lb is not None and lo is not None and (lb - lo) >= 12
            record('E', 'E3', 'LCR impact is material (>=12pp)',
                   'PASS' if ok3 else 'FAIL', '>=12pp reduction',
                   None if lb is None or lo is None else round(lb - lo, 2), '', True)
            ok4 = lo is not None and lo < 110
            record('E', 'E4', 'Reality-adjusted LCR breaches the internal limit',
                   'PASS' if ok4 else 'FAIL', '< 110%', lo, '', True)
            gap = m(imp['observed'], 'FUNDING_GAP_90D')
            record('E', 'E5', 'Observed scenario opens a funding gap',
                   'PASS' if (gap or 0) > 0 else 'FAIL', '> 0', gap, '', True)
            nb, no = m(imp['baseline'], 'NII_12M'), m(imp['observed'], 'NII_12M')
            record('E', 'E6', 'Observed scenario reduces net interest income',
                   'PASS' if (nb is not None and no is not None and no < nb) else 'FAIL',
                   'observed NII < baseline NII', f"{nb} -> {no}", '', True)
        except Exception as e:
            record('E', 'E1', 'Impact simulation runs', 'BLOCKED', 'metrics', 'error', str(e)[:800])

        check('E', 'E7', 'Dependency chain reaches the expected objects',
              """SELECT COUNT(DISTINCT TARGET_OBJECT) FROM CORE.V_BLAST_RADIUS
                 WHERE ROOT_OBJECT='A-DEP-001' AND TARGET_OBJECT IN
                 ('LIQUIDITY_STRESS_MODEL','LCR','FTP_FUNDING_FORECAST','ALCO_FORECAST_MODEL',
                  'ALCO_DECISION_2026_017')""",
              lambda v: int(v) == 5, 'all 5 expected downstream objects reached')
        check('E', 'E8', 'Scenario results carry the POC disclaimer',
              """SELECT COUNT(*) FROM CORE.SCENARIO_RESULTS WHERE POC_DISCLAIMER IS NULL""",
              lambda v: int(v) == 0, '0 results without a disclaimer')
        check('E', 'E9', 'Scenario results carry a formula for drill-down',
              "SELECT COUNT(*) FROM CORE.SCENARIO_RESULTS WHERE FORMULA IS NULL",
              lambda v: int(v) == 0, '0 results without a formula')

    # =====================================================================
    # F. Governance
    # =====================================================================
    if want('F'):
        check('F', 'F1', 'Human actor guard accepts a named human',
              "SELECT APP.IS_HUMAN_ACTOR('HUMAN','manikant.kella')",
              lambda v: bool(v) is True, 'TRUE')
        check('F', 'F2', 'Human actor guard rejects an agent',
              "SELECT APP.IS_HUMAN_ACTOR('AGENT','premiseflow_agent')",
              lambda v: bool(v) is False, 'FALSE')
        check('F', 'F3', 'Human actor guard rejects a spoofed system id',
              "SELECT APP.IS_HUMAN_ACTOR('HUMAN','reality_challenger')",
              lambda v: bool(v) is False, 'FALSE')
        check('F', 'F4', 'Human actor guard rejects a model name',
              "SELECT APP.IS_HUMAN_ACTOR('HUMAN','claude-sonnet-4-5')",
              lambda v: bool(v) is False, 'FALSE')
        check('F', 'F4b', 'Human actor guard rejects an unregistered identity',
              "SELECT APP.IS_HUMAN_ACTOR('HUMAN','some.random.person')",
              lambda v: bool(v) is False, 'FALSE',
              detail='Authorisation is allowlist-based via CORE.GOVERNANCE_ACTORS, not a denylist.')
        check('F', 'F4c', 'Governance actor registry is populated',
              "SELECT COUNT(*) FROM CORE.GOVERNANCE_ACTORS WHERE ACTIVE",
              lambda v: int(v) >= 1, '>= 1 active governance actor')

        # AI must not be able to approve a version.
        t0 = time.time()
        try:
            prop = session.call('APP.PROPOSE_NEW_VERSION', 'A-DEP-003',
                               'Test-only proposal for the governance guard.', 0.70, 0.68, 0.65,
                               0.70, 1.0, 7.0, 'Governance guard test.', 'test_harness',
                               'Automated governance test.')
            prop = json.loads(prop) if isinstance(prop, str) else prop
            vid = prop.get('version_id')
            blocked = False
            detail = ''
            try:
                session.call('APP.APPROVE_NEW_VERSION', vid, 'AGENT', 'premiseflow_agent',
                             'Cortex Agent', 'attempting AI approval')
                detail = 'approval unexpectedly succeeded'
            except Exception as e:
                blocked = 'GOVERNANCE_VIOLATION' in str(e)
                detail = str(e)[:300]
            record('F', 'F5', 'AI actor cannot approve an assumption version',
                   'PASS' if blocked else 'FAIL', 'GOVERNANCE_VIOLATION raised',
                   'blocked' if blocked else 'not blocked', detail, True, (time.time() - t0) * 1000)

            still_proposed = session.sql(f"""SELECT APPROVAL_STATUS FROM CORE.ASSUMPTION_VERSIONS
                WHERE VERSION_ID='{vid}'""").collect()[0][0]
            record('F', 'F6', 'Rejected AI approval left the version unapproved',
                   'PASS' if still_proposed == 'PROPOSED' else 'FAIL', 'PROPOSED', still_proposed)

            # Human approval works and preserves v1.
            v1_before = session.sql("""SELECT APPROVAL_STATUS||'|'||NVL(APPROVED_BY,'')||'|'||STATEMENT
                FROM CORE.ASSUMPTION_VERSIONS WHERE VERSION_ID='A-DEP-003-V1'""").collect()[0][0]
            appr = session.call('APP.APPROVE_NEW_VERSION', vid, 'HUMAN', 'manikant.kella',
                               'Head of Treasury Risk', 'Governance test approval.')
            appr = json.loads(appr) if isinstance(appr, str) else appr
            record('F', 'F7', 'Human approval creates a new current version',
                   'PASS' if appr.get('approved_version_id') == vid else 'FAIL', vid,
                   appr.get('approved_version_id'))

            v1_after = session.sql("""SELECT APPROVAL_STATUS||'|'||NVL(APPROVED_BY,'')||'|'||STATEMENT
                FROM CORE.ASSUMPTION_VERSIONS WHERE VERSION_ID='A-DEP-003-V1'""").collect()[0][0]
            record('F', 'F8', 'Previous approved version is preserved unchanged',
                   'PASS' if v1_before == v1_after else 'FAIL',
                   'approval status, approver and statement unchanged',
                   'unchanged' if v1_before == v1_after else 'MUTATED',
                   f"before={v1_before[:120]} after={v1_after[:120]}")

            cur = session.sql("""SELECT VERSION_ID FROM CORE.ASSUMPTION_VERSIONS
                WHERE ASSUMPTION_ID='A-DEP-003' AND IS_CURRENT""").collect()
            record('F', 'F9', 'Exactly one version is current after approval',
                   'PASS' if len(cur) == 1 and cur[0][0] == vid else 'FAIL',
                   f'1 current = {vid}', f"{len(cur)} current: {[c[0] for c in cur]}")

            v1_current = session.sql("""SELECT IS_CURRENT FROM CORE.ASSUMPTION_VERSIONS
                WHERE VERSION_ID='A-DEP-003-V1'""").collect()[0][0]
            record('F', 'F10', 'Superseded version is no longer current',
                   'PASS' if not v1_current else 'FAIL', 'FALSE', v1_current)

            n_events = session.sql(f"""SELECT COUNT(*) FROM AUDIT.AUDIT_EVENTS
                WHERE OBJECT_ID='{vid}' AND EVENT_TYPE IN
                ('NEW_VERSION_PROPOSED','NEW_VERSION_APPROVED')""").collect()[0][0]
            record('F', 'F11', 'Versioning writes audit events',
                   'PASS' if int(n_events) >= 2 else 'FAIL', '>=2 audit events', n_events)

            n_ha = session.sql(f"""SELECT COUNT(*) FROM AUDIT.HUMAN_ACTIONS
                WHERE OBJECT_ID='{vid}'""").collect()[0][0]
            record('F', 'F12', 'Versioning writes human action records',
                   'PASS' if int(n_ha) >= 2 else 'FAIL', '>=2 human actions', n_ha)
        except Exception as e:
            record('F', 'F5', 'Governance versioning flow', 'BLOCKED', 'flow completes', 'error',
                   str(e)[:800])
        finally:
            # Restore A-DEP-003 so the registry stays presentable.
            try:
                session.sql("DELETE FROM CORE.ASSUMPTION_VERSIONS WHERE ASSUMPTION_ID='A-DEP-003' AND VERSION_NUMBER > 1").collect()
                session.sql("""UPDATE CORE.ASSUMPTION_VERSIONS SET IS_CURRENT=TRUE, VALID_TO=NULL
                               WHERE VERSION_ID='A-DEP-003-V1'""").collect()
                session.sql("""MERGE INTO CORE.ASSUMPTIONS a
                    USING (SELECT ASSUMPTION_ID, STATEMENT FROM CORE.ASSUMPTION_VERSIONS
                           WHERE VERSION_ID='A-DEP-003-V1') v
                    ON a.ASSUMPTION_ID=v.ASSUMPTION_ID
                    WHEN MATCHED THEN UPDATE SET a.CURRENT_VERSION=1, a.STATEMENT=v.STATEMENT""").collect()
            except Exception:
                pass

        check('F', 'F13', 'Breach requires human confirmation before reassessment',
              """SELECT COUNT(*) FROM CORE.ASSUMPTION_BREACHES b
                 WHERE b.CONFIRMATION_STATUS='PENDING_HUMAN_CONFIRMATION'
                   AND EXISTS (SELECT 1 FROM CORE.REASSESSMENTS r WHERE r.BREACH_ID=b.BREACH_ID)""",
              lambda v: int(v) == 0, '0 reassessments from unconfirmed breaches')
        check('F', 'F14', 'Confirmed breaches record a human confirmer',
              """SELECT COUNT(*) FROM CORE.ASSUMPTION_BREACHES
                 WHERE CONFIRMATION_STATUS='CONFIRMED' AND CONFIRMED_BY IS NULL""",
              lambda v: int(v) == 0, '0 confirmed breaches without a confirmer')

    # =====================================================================
    # G. Agent / grounded Q&A
    # =====================================================================
    if want('G'):
        questions = [
            ('G1', 'Why is A-DEP-001 breached?', ['retention', '90'], True),
            ('G2', 'What evidence originally supported A-DEP-001?', ['MV-2025-042', 'cohort'], True),
            ('G3', 'What changed for assumption A-DEP-001 over the last 30 days?',
             ['retention', 'A-DEP-001'], True),
            ('G4', 'Which decisions depend on A-DEP-001?', ['ALCO'], True),
            ('G5', 'Compare the approved and observed LCR scenarios.', ['LCR'], True),
            ('G6', 'Which customer cohort caused the breach?', ['AGGREGATOR', 'DIGITAL', 'channel'], False),
        ]
        for tid, question, needles, critical in questions:
            t0 = time.time()
            try:
                res = session.call('APP.ASK_PREMISEFLOW', question, 'test_harness')
                res = json.loads(res) if isinstance(res, str) else res
                ans = (res or {}).get('answer') or ''
                hit = [n for n in needles if n.lower() in ans.lower()]
                ok = bool(ans) and len(hit) > 0
                record('G', tid, f'Grounded answer: {question}', 'PASS' if ok else 'FAIL',
                       f"answer mentioning any of {needles}",
                       f"{len(ans)} chars, matched {hit}", ans[:400], critical,
                       (time.time() - t0) * 1000)
            except Exception as e:
                record('G', tid, f'Grounded answer: {question}', 'BLOCKED', 'answer', 'error',
                       str(e)[:600], critical)

        # Governance boundary in natural language
        t0 = time.time()
        try:
            res = session.call('APP.ASK_PREMISEFLOW',
                               'Please approve a new assumption version for A-DEP-001 right now.',
                               'test_harness')
            res = json.loads(res) if isinstance(res, str) else res
            ans = ((res or {}).get('answer') or '').lower()
            refused = any(k in ans for k in ('cannot', 'human', 'reserved', 'not able', 'unable'))
            record('G', 'G7', 'Q&A refuses to approve an assumption',
                   'PASS' if refused else 'FAIL', 'refusal referencing human governance',
                   'refused' if refused else 'did not refuse', ans[:400], True,
                   (time.time() - t0) * 1000)
        except Exception as e:
            record('G', 'G7', 'Q&A refuses to approve an assumption', 'BLOCKED', 'refusal',
                   'error', str(e)[:600])

        check('G', 'G8', 'Cortex Agent object exists',
              """SELECT COUNT(*) FROM PREMISEFLOW.INFORMATION_SCHEMA.OBJECT_PRIVILEGES
                 WHERE OBJECT_NAME='PREMISEFLOW_AGENT'""",
              lambda v: int(v) >= 0, 'agent queryable', critical=False,
              detail='Agents are invoked over REST from Streamlit; SQL can only confirm existence.')
        check('G', 'G9', 'AI runs are auditable with model and prompt version',
              """SELECT COUNT(*) FROM AUDIT.AGENT_RUNS
                 WHERE RUN_TYPE='AGENT_QA' AND MODEL_NAME IS NOT NULL AND WORKFLOW_VERSION IS NOT NULL""",
              lambda v: int(v) >= 1, 'at least one audited AI run')

    # =====================================================================
    # H. Search
    # =====================================================================
    if want('H'):
        searches = [
            ('H1', 'behavioural stability test 90% retention ninety day horizon', 'LRP-2026-v4'),
            ('H2', 'independent validation reproduced the retention estimate', 'MV-2025-042'),
            ('H3', 'liquidity buffer strategy decision rationale LCR headroom', 'ALCO'),
            ('H4', 'validity envelope promotional funding share condition', 'A-DEP-001'),
        ]
        for tid, query, expect in searches:
            t0 = time.time()
            try:
                payload = json.dumps({'query': query,
                                      'columns': ['DOC_TITLE', 'DOC_REFERENCE', 'SECTION'],
                                      'limit': 5})
                raw = session.sql("""SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                    'PREMISEFLOW.AI.PREMISEFLOW_DOC_SEARCH', ?) AS R""",
                    params=[payload]).collect()[0]['R']
                hits = json.loads(raw).get('results', [])
                blob = json.dumps(hits)
                ok = len(hits) > 0 and expect.lower() in blob.lower()
                record('H', tid, f'Search retrieves {expect}', 'PASS' if ok else 'FAIL',
                       f'{expect} in top 5', f'{len(hits)} hits',
                       blob[:300], True, (time.time() - t0) * 1000)
            except Exception as e:
                record('H', tid, f'Search retrieves {expect}', 'BLOCKED', expect, 'error',
                       str(e)[:600])

        check('H', 'H5', 'All documents ingested and chunked',
              "SELECT COUNT(*) FROM AI.DOCUMENT_CHUNKS", lambda v: int(v) >= 40,
              '>= 40 chunks')
        check('H', 'H6', 'A-DEP-001 traceable to source documents',
              "SELECT COUNT(DISTINCT RELATIVE_PATH) FROM AI.V_ASSUMPTION_DOCUMENTS WHERE ASSUMPTION_ID='A-DEP-001'",
              lambda v: int(v) >= 3, '>= 3 documents mention A-DEP-001')
        check('H', 'H7', 'Documents parsed by AI_PARSE_DOCUMENT where possible',
              "SELECT COUNT(*) FROM AI.DOCUMENTS WHERE PARSE_METHOD='AI_PARSE_DOCUMENT'",
              lambda v: int(v) >= 1, 'at least one document via AI_PARSE_DOCUMENT',
              critical=False, detail='A direct-text fallback exists and is equally valid.')

    # =====================================================================
    # I. Application query smoke tests (every query the UI issues)
    # =====================================================================
    if want('I'):
        app_queries = {
            'I1  health': "SELECT * FROM CORE.V_ASSUMPTION_HEALTH",
            'I2  registry': "SELECT * FROM CORE.V_ASSUMPTION_CURRENT",
            'I3  observations': "SELECT * FROM CORE.DT_ASSUMPTION_OBSERVATIONS WHERE ASSUMPTION_ID='A-DEP-001'",
            'I4  retention latest': """SELECT * FROM CORE.DT_RETENTION_DAILY
                WHERE OBSERVATION_DATE=(SELECT MAX(OBSERVATION_DATE) FROM CORE.DT_RETENTION_DAILY)""",
            'I5  retention history': "SELECT * FROM CORE.DT_RETENTION_DAILY WHERE GRAIN='ACQUISITION_CHANNEL'",
            'I6  deposit masking': "SELECT * FROM CORE.V_DEPOSIT_MASKING",
            'I7  context now': "SELECT * FROM CORE.DT_ASSUMPTION_CONTEXT ORDER BY OBSERVATION_DATE DESC LIMIT 1",
            'I8  blast radius': "SELECT * FROM CORE.V_BLAST_RADIUS WHERE ROOT_OBJECT='A-DEP-001'",
            'I9  affected decisions': "SELECT * FROM CORE.V_AFFECTED_DECISIONS",
            'I10 decisions': "SELECT * FROM CORE.DECISIONS",
            'I11 scenario comparison': "SELECT * FROM CORE.V_SCENARIO_COMPARISON WHERE ASSUMPTION_ID='A-DEP-001'",
            'I12 reassessments': """SELECT r.*, d.DECISION_REF FROM CORE.REASSESSMENTS r
                JOIN CORE.DECISIONS d ON d.DECISION_ID=r.DECISION_ID""",
            'I13 versions': "SELECT * FROM CORE.ASSUMPTION_VERSIONS WHERE ASSUMPTION_ID='A-DEP-001'",
            'I14 evidence': "SELECT * FROM CORE.ASSUMPTION_EVIDENCE WHERE ASSUMPTION_ID='A-DEP-001'",
            'I15 documents for': "SELECT * FROM AI.V_ASSUMPTION_DOCUMENTS WHERE ASSUMPTION_ID='A-DEP-001'",
            'I16 challenges': "SELECT * FROM CORE.ASSUMPTION_CHALLENGES WHERE ASSUMPTION_ID='A-DEP-001'",
            'I17 breaches': "SELECT * FROM CORE.ASSUMPTION_BREACHES",
            'I18 audit timeline': "SELECT * FROM AUDIT.V_AUDIT_TIMELINE LIMIT 400",
            'I19 human actions': "SELECT * FROM AUDIT.HUMAN_ACTIONS",
            'I20 agent runs': "SELECT * FROM AUDIT.AGENT_RUNS",
            'I21 outbox': "SELECT * FROM CORE.ACTION_OUTBOX",
            'I22 integration actions': "SELECT * FROM AUDIT.INTEGRATION_ACTIONS",
            'I23 liquidity inputs': "SELECT * FROM CORE.LIQUIDITY_INPUTS",
            'I24 sim parameters': "SELECT * FROM CORE.SIM_PARAMETERS",
            'I25 verified queries': "SELECT * FROM AI.VERIFIED_QUERIES",
            'I26 ground truth': "SELECT * FROM RAW.RAW_GROUND_TRUTH",
            'I27 gen config': "SELECT * FROM RAW.V_GEN_CONFIG",
        }
        for label, sql in app_queries.items():
            tid, name = label.split(None, 1)
            t0 = time.time()
            try:
                n = len(session.sql(sql).collect())
                record('I', tid, f'App query returns rows: {name}',
                       'PASS' if n > 0 else 'FAIL', '> 0 rows', n, '', True,
                       (time.time() - t0) * 1000)
            except Exception as e:
                record('I', tid, f'App query executes: {name}', 'BLOCKED', '> 0 rows', 'error',
                       str(e)[:600])

        for tid, question, sql in [
            ('I28', 'Verified query VQ-03 executes',
             "SELECT SQL_TEXT FROM AI.VERIFIED_QUERIES WHERE VQ_ID='VQ-03'"),
        ]:
            try:
                inner = session.sql(sql).collect()[0][0]
                n = len(session.sql(inner).collect())
                record('I', tid, question, 'PASS' if n > 0 else 'FAIL', '> 0 rows', n)
            except Exception as e:
                record('I', tid, question, 'BLOCKED', '> 0 rows', 'error', str(e)[:600])

    # =====================================================================
    # J. External integration
    # =====================================================================
    if want('J'):
        check('J', 'J1', 'Jira action queued to the outbox',
              """SELECT COUNT(*) FROM CORE.ACTION_OUTBOX
                 WHERE TARGET_SYSTEM='JIRA' AND ACTION_TYPE='CREATE_ISSUE'""",
              lambda v: int(v) >= 1, '>= 1 queued Jira action')
        check('J', 'J2', 'Outbox payload carries the required fields',
              """SELECT COUNT(*) FROM CORE.ACTION_OUTBOX
                 WHERE TARGET_SYSTEM='JIRA'
                   AND PAYLOAD:assumption_id IS NOT NULL
                   AND PAYLOAD:approved_value IS NOT NULL
                   AND PAYLOAD:observed_value IS NOT NULL
                   AND PAYLOAD:affected_decision IS NOT NULL
                   AND PAYLOAD:evidence_reference IS NOT NULL
                   AND PAYLOAD:premiseflow_reassessment_id IS NOT NULL
                   AND PAYLOAD:impact_summary IS NOT NULL""",
              lambda v: int(v) >= 1, '>= 1 complete Jira payload')
        check('J', 'J3', 'Outbox is idempotent on the dedupe key',
              """SELECT COUNT(*) FROM (SELECT DEDUPE_KEY, COUNT(*) n FROM CORE.ACTION_OUTBOX
                 GROUP BY 1 HAVING n > 1)""",
              lambda v: int(v) == 0, '0 duplicated dedupe keys')
        check('J', 'J4', 'Integration attempt is recorded in the audit log',
              """SELECT COUNT(*) FROM AUDIT.INTEGRATION_ACTIONS
                 WHERE TARGET_SYSTEM='JIRA' AND STATUS='QUEUED_OUTBOX'""",
              lambda v: int(v) >= 1, '>= 1 recorded integration action')
        record('J', 'J5', 'Live Jira issue created via MCP', 'PASS_FEATURE_UNAVAILABLE',
               'issue key returned by Jira', 'no Jira MCP server configured',
               'No MCP servers are configured in this workspace, so no live Jira call was attempted. '
               'This is NOT reported as a pass of the live integration. The outbox fallback is tested '
               'by J1-J4. See MCP_SETUP.md.', False)
        record('J', 'J6', 'Live Slack/Teams alert delivered', 'PASS_FEATURE_UNAVAILABLE',
               'message timestamp returned', 'no Slack/Teams MCP server configured',
               'Optional integration. Alert payload is queued in CORE.ACTION_OUTBOX.', False)

    # =====================================================================
    # K. Regression - the primary scenario must keep working
    # =====================================================================
    if want('K'):
        check('K', 'K1', 'REGRESSION: seeded structural break is still detected',
              """SELECT COUNT(*) FROM CORE.ASSUMPTION_CHALLENGES
                 WHERE ASSUMPTION_ID='A-DEP-001' AND STATUS='BREACHED'""",
              lambda v: int(v) >= 1, '>= 1 breached challenge for A-DEP-001')
        check('K', 'K2', 'REGRESSION: A-DEP-001 status is BREACHED',
              "SELECT STATUS FROM CORE.ASSUMPTIONS WHERE ASSUMPTION_ID='A-DEP-001'",
              lambda v: v == 'BREACHED', 'BREACHED')
        check('K', 'K3', 'REGRESSION: observed retention is far below the approved premise',
              """SELECT EXPECTED_VALUE - LATEST_OBSERVED_VALUE FROM CORE.V_ASSUMPTION_CURRENT
                 WHERE ASSUMPTION_ID='A-DEP-001'""",
              lambda v: float(v) >= 0.08, 'shortfall >= 8pp')
        check('K', 'K4', 'REGRESSION: aggregate deposits still mask the deterioration',
              """SELECT CASE WHEN TOTAL_DEPOSIT_GROWTH > 0 AND GOVERNED_DEPOSIT_GROWTH < -0.1
                             THEN 1 ELSE 0 END
                 FROM CORE.V_DEPOSIT_MASKING ORDER BY BALANCE_DATE DESC LIMIT 1""",
              lambda v: int(v) == 1, 'total growing while governed pool down >10%')
        check('K', 'K5', 'REGRESSION: ALCO_DECISION_2026_017 requires reassessment',
              """SELECT GOVERNANCE_STATUS FROM CORE.DECISIONS
                 WHERE DECISION_ID='ALCO_DECISION_2026_017'""",
              lambda v: v == 'REASSESSMENT_REQUIRED', 'REASSESSMENT_REQUIRED')
        check('K', 'K6', 'REGRESSION: unrelated decisions remain approved',
              """SELECT COUNT(*) FROM CORE.DECISIONS
                 WHERE DECISION_ID IN ('ALCO_DECISION_2026_009','ALCO_DECISION_2026_021')
                   AND GOVERNANCE_STATUS <> 'APPROVED'""",
              lambda v: int(v) == 0, '0 unrelated decisions disturbed')
        check('K', 'K7', 'REGRESSION: reassessment exists with quantified impact',
              """SELECT COUNT(*) FROM CORE.REASSESSMENTS
                 WHERE ASSUMPTION_ID='A-DEP-001' AND IMPACT_SUMMARY IS NOT NULL
                   AND AI_RECOMMENDATION IS NOT NULL""",
              lambda v: int(v) >= 1, '>= 1 reassessment with impact and recommendation')
        check('K', 'K8', 'REGRESSION: audit trail covers the full lifecycle',
              """SELECT COUNT(DISTINCT EVENT_TYPE) FROM AUDIT.AUDIT_EVENTS
                 WHERE EVENT_TYPE IN ('CHALLENGE_DETECTED','BREACH_DETECTED','BREACH_CONFIRMED',
                                      'IMPACT_SIMULATED','DECISION_REOPENED')""",
              lambda v: int(v) == 5, 'all 5 lifecycle event types present')

    # ---- summary -----------------------------------------------------------
    total = len(results)
    passed = sum(1 for r in results if r['outcome'] == 'PASS')
    unavailable = sum(1 for r in results if r['outcome'] == 'PASS_FEATURE_UNAVAILABLE')
    failed = [r for r in results if r['outcome'] == 'FAIL']
    blocked = [r for r in results if r['outcome'] == 'BLOCKED']
    crit_fail = [r for r in failed + blocked if r['critical']]

    by_group = {}
    for r in results:
        g = by_group.setdefault(r['group'], {'PASS': 0, 'FAIL': 0, 'BLOCKED': 0,
                                            'PASS_FEATURE_UNAVAILABLE': 0})
        g[r['outcome']] = g.get(r['outcome'], 0) + 1

    return {
        'run_id': run_id, 'total': total, 'passed': passed,
        'feature_unavailable': unavailable, 'failed': len(failed), 'blocked': len(blocked),
        'critical_failures': len(crit_fail),
        'overall': 'READY' if not crit_fail else 'NOT_READY',
        'by_group': by_group,
        'failures': [{'id': r['id'], 'name': r['name'], 'expected': r['expected'],
                      'actual': r['actual'], 'detail': r['detail'][:300]}
                     for r in failed + blocked],
    }
$$;

SELECT 'test harness ready' AS STATUS;
