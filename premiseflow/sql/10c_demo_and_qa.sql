-- PremiseFlow :: 10c_demo_and_qa.sql
-- Grounded question answering (server-side, testable) + reproducible demo controls.
--
-- Note on the two Q&A paths, deliberately kept separate:
--   * AI.PREMISEFLOW_AGENT is the real Cortex Agent. It is invoked over REST from
--     the Streamlit app and is what a user talks to in the demo.
--   * APP.ASK_PREMISEFLOW is a server-side grounded Q&A procedure over the same
--     two evidence sources. It exists because agents are REST-only and therefore
--     cannot be asserted on from a SQL test harness. It is what the automated
--     agent test group exercises, and it is the app's fallback path.
-- Both are read-only and neither can approve anything.

USE DATABASE PREMISEFLOW;
USE SCHEMA APP;

CREATE OR REPLACE PROCEDURE APP.ASK_PREMISEFLOW(P_QUESTION STRING, P_ACTOR STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json, uuid

MODEL = 'claude-sonnet-4-5'
PROMPT_VERSION = 'grounded-qa-v1.2'

def lit(v):
    if v is None: return 'NULL'
    if isinstance(v, bool): return 'TRUE' if v else 'FALSE'
    if isinstance(v, (int, float)): return repr(v)
    # Escape backslashes BEFORE quotes: Snowflake processes backslash escapes inside
    # single-quoted literals, so LLM-generated text containing a backslash would
    # otherwise corrupt the statement.
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"

def rows(session, sql):
    try:
        return [r.as_dict() for r in session.sql(sql).collect()]
    except Exception as e:
        return [{'error': str(e)[:200]}]

def _as_text(raw):
    """AI_COMPLETE returns its text JSON-encoded; unwrap the quoted string so the
    stored answer is plain readable text rather than an escaped JSON literal."""
    if raw is None:
        return None
    s = str(raw)
    t = s.strip()
    if len(t) > 1 and t[0] == '"' and t[-1] == '"':
        try:
            v = json.loads(t)
            if isinstance(v, str):
                return v
        except Exception:
            pass
    return s


def run(session, question, actor):
    run_id = 'RUN-' + uuid.uuid4().hex[:16]

    # ---- unstructured evidence -------------------------------------------
    doc_hits, citations = [], []
    try:
        payload = json.dumps({'query': question,
                              'columns': ['CHUNK_TEXT','DOC_TITLE','DOC_REFERENCE','SECTION','RELATIVE_PATH','CHUNK_ID'],
                              'limit': 6})
        res = session.sql(f"""SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                'PREMISEFLOW.AI.PREMISEFLOW_DOC_SEARCH', {lit(payload)}) AS R""").collect()[0]['R']
        for h in json.loads(res).get('results', []):
            doc_hits.append(h)
            citations.append({'type': 'DOCUMENT', 'title': h.get('DOC_TITLE'),
                              'reference': h.get('DOC_REFERENCE'), 'section': h.get('SECTION'),
                              'path': h.get('RELATIVE_PATH'), 'chunk_id': h.get('CHUNK_ID')})
    except Exception as e:
        doc_hits = [{'error': str(e)[:200]}]

    # ---- structured evidence ---------------------------------------------
    ctx = {
      'assumption_registry': rows(session, """
          SELECT ASSUMPTION_ID, NAME, DOMAIN, MATERIALITY, STATUS, OWNER_ROLE,
                 VERSION_ID, VERSION_NUMBER, EXPECTED_VALUE, CHALLENGE_THRESHOLD, BREACH_THRESHOLD,
                 PERSISTENCE_DAYS, ROUND(LATEST_OBSERVED_VALUE,4) AS LATEST_OBSERVED_VALUE,
                 LATEST_OBSERVATION_DATE, ROUND(DEVIATION_PCT,4) AS DEVIATION_PCT,
                 OBSERVED_PERSISTENCE_DAYS, ROUND(LATEST_CONFIDENCE,3) AS CONFIDENCE,
                 CHANGE_POINT_DATE, APPROVED_BY, EVIDENCE_SUMMARY,
                 DIRECT_DEPENDENCY_COUNT, DEPENDENT_DECISION_COUNT
          FROM CORE.V_ASSUMPTION_CURRENT ORDER BY ASSUMPTION_ID"""),
      'retention_by_cohort_latest': rows(session, """
          SELECT GRAIN, DIM_VALUE, ROUND(RETENTION_RATE,4) AS RETENTION_RATE,
                 ROUND(BALANCE_CHANGE/1e6,2) AS BALANCE_CHANGE_USD_M, ACCOUNTS
          FROM CORE.DT_RETENTION_DAILY
          WHERE OBSERVATION_DATE=(SELECT MAX(OBSERVATION_DATE) FROM CORE.DT_RETENTION_DAILY)
          ORDER BY RETENTION_RATE"""),
      'deposit_aggregate_vs_cohort': rows(session, """
          SELECT BALANCE_DATE, ROUND(TOTAL_DEPOSITS/1e6,1) AS TOTAL_USD_M,
                 ROUND(GOVERNED_STABLE_DEPOSITS/1e6,1) AS GOVERNED_STABLE_USD_M,
                 ROUND(PROMOTIONAL_DEPOSITS/1e6,1) AS PROMOTIONAL_USD_M,
                 ROUND(TOTAL_DEPOSIT_GROWTH*100,2) AS TOTAL_GROWTH_PCT,
                 ROUND(GOVERNED_DEPOSIT_GROWTH*100,2) AS GOVERNED_GROWTH_PCT,
                 ROUND(PROMOTIONAL_FUNDING_SHARE*100,2) AS PROMO_FUNDING_SHARE_PCT
          FROM CORE.V_DEPOSIT_MASKING
          WHERE BALANCE_DATE IN (SELECT BREAK_DATE FROM RAW.V_GEN_CONFIG
                                 UNION SELECT DEMO_END_DATE FROM RAW.V_GEN_CONFIG
                                 UNION SELECT SPINE_START_DATE FROM RAW.V_GEN_CONFIG)
          ORDER BY BALANCE_DATE"""),
      'dependencies': rows(session, """
          SELECT ROOT_OBJECT, TARGET_OBJECT, TARGET_TYPE, RELATIONSHIP_TYPE, MATERIALITY, DEPTH
          FROM CORE.V_BLAST_RADIUS ORDER BY ROOT_OBJECT, DEPTH, TARGET_OBJECT"""),
      'decisions': rows(session, """
          SELECT DECISION_REF, TITLE, COMMITTEE, DECISION_DATE, GOVERNANCE_STATUS, MATERIALITY,
                 ASSUMPTION_ID, RELIED_ON_VERSION_ID, RELIANCE_STRENGTH, RATIONALE
          FROM CORE.V_AFFECTED_DECISIONS ORDER BY DECISION_REF"""),
      'open_reassessments': rows(session, """
          SELECT REASSESSMENT_ID, DECISION_ID, ASSUMPTION_ID, STATUS,
                 ROUND(OBSERVED_VALUE,4) AS OBSERVED_VALUE, APPROVED_VALUE,
                 IMPACT_SUMMARY, AI_RECOMMENDATION
          FROM CORE.REASSESSMENTS WHERE STATUS IN ('OPEN','IN_REVIEW')"""),
      'scenario_results': rows(session, """
          SELECT SCENARIO_TYPE, SCENARIO_NAME, ROUND(RETENTION_INPUT,4) AS RETENTION_INPUT,
                 METRIC_ID, METRIC_NAME, ROUND(METRIC_VALUE,3) AS METRIC_VALUE, UNIT,
                 INTERNAL_LIMIT, REGULATORY_MIN, BREACHES_LIMIT, FORMULA
          FROM CORE.V_SCENARIO_COMPARISON
          QUALIFY ROW_NUMBER() OVER (PARTITION BY SCENARIO_TYPE, METRIC_ID ORDER BY CREATED_AT DESC)=1
          ORDER BY METRIC_ID, SCENARIO_TYPE"""),
      'validity_envelope_now': rows(session, """
          SELECT OBSERVATION_DATE, ROUND(POLICY_RATE_PCT,3) AS POLICY_RATE_PCT,
                 ROUND(DEPOSIT_BETA,3) AS DEPOSIT_BETA,
                 ROUND(PROMOTIONAL_FUNDING_SHARE,4) AS PROMOTIONAL_FUNDING_SHARE,
                 ROUND(DEPOSIT_CONCENTRATION,4) AS DEPOSIT_CONCENTRATION
          FROM CORE.DT_ASSUMPTION_CONTEXT ORDER BY OBSERVATION_DATE DESC LIMIT 1"""),
      'ground_truth_note': 'Fully synthetic dataset. Risk figures are illustrative simplified POC calculations.',
    }

    docs_txt = '\n\n'.join(
        f"[DOC {i+1}] {h.get('DOC_TITLE')} ({h.get('DOC_REFERENCE')}) - section: {h.get('SECTION')}\n{h.get('CHUNK_TEXT','')[:1600]}"
        for i, h in enumerate(doc_hits) if 'CHUNK_TEXT' in h)

    prompt = f"""You are the PremiseFlow Assumption Analyst for a bank treasury risk function.

Answer the user's question using ONLY the evidence below. Rules:
- Always separate the APPROVED premise (from the assumption contract) from the OBSERVED value (measured from data). Never conflate them.
- Cite evidence inline: name the document and section for qualitative claims, or the structured object for numbers.
- Whenever you quote LCR, funding gap or net interest income, state that it is an illustrative simplified proof-of-concept calculation over fully synthetic data.
- You may explain, quantify, compare and recommend. You may NOT approve, confirm or publish anything. If asked to, refuse and say those actions are reserved to an accountable human governance owner via the Decision Reassessment page.
- If the evidence does not support an answer, say so plainly.
- Be specific and under 300 words.

=== STRUCTURED EVIDENCE (governed semantic layer) ===
{json.dumps(ctx, default=str)[:24000]}

=== DOCUMENT EVIDENCE (synthetic governance corpus) ===
{docs_txt[:12000]}

=== QUESTION ===
{question}
"""

    session.sql(f"""INSERT INTO AUDIT.AGENT_RUNS
        (RUN_ID, RUN_TYPE, STARTED_AT, STATUS, TRIGGERED_BY, MODEL_NAME, WORKFLOW_VERSION,
         PROMPT_REF, INPUT_SUMMARY, EVIDENCE_REFS)
        SELECT {lit(run_id)},'AGENT_QA',CURRENT_TIMESTAMP(),'RUNNING',{lit(actor or 'SYSTEM')},
               {lit(MODEL)},{lit(PROMPT_VERSION)},{lit(PROMPT_VERSION)},{lit(question[:2000])},
               TRY_PARSE_JSON({lit(json.dumps(citations))})""").collect()
    try:
        answer = _as_text(session.sql(f"SELECT AI_COMPLETE({lit(MODEL)}, {lit(prompt)})::STRING AS A").collect()[0]['A'])
        status = 'SUCCESS'
        err = None
    except Exception as e:
        answer, status, err = None, 'FAILED', str(e)[:1000]

    session.sql(f"""UPDATE AUDIT.AGENT_RUNS
        SET FINISHED_AT=CURRENT_TIMESTAMP(), STATUS={lit(status)},
            OUTPUT_SUMMARY={lit((answer or '')[:8000])}, ERROR_MESSAGE={lit(err)}
        WHERE RUN_ID={lit(run_id)}""").collect()

    return {'run_id': run_id, 'question': question, 'answer': answer, 'status': status,
            'error': err, 'model': MODEL, 'prompt_version': PROMPT_VERSION,
            'citations': citations,
            'disclaimer': 'Synthetic data / illustrative risk calculations for hackathon demonstration.'}
$$;

-- ===========================================================================
-- Demo controls
-- ===========================================================================
CREATE OR REPLACE PROCEDURE APP.RESET_DEMO()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json

def run(session):
    steps = []
    def ex(label, sql):
        session.sql(sql).collect()
        steps.append(label)

    # Governed state back to the approved baseline. Audit history is preserved
    # by design: only TEST-schema data and demo working state are cleared.
    ex('drop post-v1 assumption versions',
       "DELETE FROM CORE.ASSUMPTION_VERSIONS WHERE VERSION_NUMBER > 1")
    ex('restore v1 as current and approved',
       """UPDATE CORE.ASSUMPTION_VERSIONS
          SET IS_CURRENT=TRUE, VALID_TO=NULL, APPROVAL_STATUS='APPROVED'
          WHERE VERSION_NUMBER = 1""")
    # Correlated subqueries are not permitted in UPDATE ... SET, so the
    # statement text is restored from the v1 row via MERGE.
    ex('restore assumption statuses and v1 statement text',
       """MERGE INTO CORE.ASSUMPTIONS a
          USING (SELECT ASSUMPTION_ID, STATEMENT FROM CORE.ASSUMPTION_VERSIONS
                 WHERE VERSION_NUMBER = 1) v
          ON a.ASSUMPTION_ID = v.ASSUMPTION_ID
          WHEN MATCHED THEN UPDATE SET
            a.STATUS = 'VALID', a.CURRENT_VERSION = 1,
            a.STATEMENT = v.STATEMENT, a.UPDATED_AT = CURRENT_TIMESTAMP()""")
    ex('clear challenges',    "DELETE FROM CORE.ASSUMPTION_CHALLENGES")
    ex('clear breaches',      "DELETE FROM CORE.ASSUMPTION_BREACHES")
    ex('clear observations',  "DELETE FROM CORE.ASSUMPTION_OBSERVATIONS")
    ex('clear reassessments', "DELETE FROM CORE.REASSESSMENTS")
    ex('clear scenario results', "DELETE FROM CORE.SCENARIO_RESULTS")
    ex('clear scenarios',     "DELETE FROM CORE.SCENARIOS")
    ex('restore decision governance status',
       "UPDATE CORE.DECISIONS SET GOVERNANCE_STATUS='APPROVED', STATUS_CHANGED_AT=CURRENT_TIMESTAMP()")
    ex('clear demo outbox',   "DELETE FROM CORE.ACTION_OUTBOX WHERE STATUS='PENDING'")
    ex('log reset',
       """CALL AUDIT.LOG_EVENT('DEMO_RESET','SYSTEM','PREMISEFLOW','HUMAN',CURRENT_USER(),
          NULL,'BASELINE',NULL,NULL,
          'Demo reset to approved baseline. Audit history intentionally preserved.',NULL)""")

    state = session.sql("""SELECT COUNT(*) AS N, COUNT_IF(STATUS='VALID') AS V
                           FROM CORE.ASSUMPTIONS""").collect()[0]
    return {'status': 'RESET_COMPLETE', 'steps': steps,
            'assumptions': int(state['N']), 'valid': int(state['V']),
            'note': 'AUDIT.AUDIT_EVENTS, AGENT_RUNS, HUMAN_ACTIONS and INTEGRATION_ACTIONS are NOT cleared.'}
$$;

-- Advances the scenario from approved-and-quiet to breached-and-reassessed,
-- replaying the timeline so the progression is literal rather than asserted.
CREATE OR REPLACE PROCEDURE APP.RUN_DEMO(P_CONFIRM_ACTOR STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json

def j(v):
    return json.loads(v) if isinstance(v, str) else v

def run(session, confirm_actor):
    actor = confirm_actor or 'manikant.kella'
    cfg = session.sql("SELECT BREAK_DATE, DEMO_END_DATE FROM RAW.V_GEN_CONFIG").collect()[0]
    stages = []

    # 1. Assumption was valid before reality moved.
    r = j(session.call('APP.RUN_CHALLENGER', 'A-DEP-001', 'demo', 
                       session.sql("SELECT DATEADD(day,-10,BREAK_DATE) D FROM RAW.V_GEN_CONFIG").collect()[0]['D']))
    stages.append({'stage': '1. ASSUMPTION VALID',
                   'as_of': str(session.sql("SELECT DATEADD(day,-10,BREAK_DATE) D FROM RAW.V_GEN_CONFIG").collect()[0]['D']),
                   'status': r['results'][0]['status'],
                   'observed': r['results'][0]['observed_value'],
                   'narrative': 'Approved premise of 90% retention is supported by observation.'})

    # 2. Reality drifts; the challenge threshold is crossed persistently.
    d40 = session.sql("SELECT DATEADD(day,40,BREAK_DATE) D FROM RAW.V_GEN_CONFIG").collect()[0]['D']
    r = j(session.call('APP.RUN_CHALLENGER', 'A-DEP-001', 'demo', d40))
    stages.append({'stage': '2. ASSUMPTION CHALLENGED', 'as_of': str(d40),
                   'status': r['results'][0]['status'],
                   'observed': r['results'][0]['observed_value'],
                   'change_point': r['results'][0]['change_point_date'],
                   'narrative': 'Retention has fallen through the challenge threshold and stayed there.'})

    # 3. Breach detected at the current date, awaiting human confirmation.
    r = j(session.call('APP.RUN_CHALLENGER', 'A-DEP-001', 'demo', None))
    res = r['results'][0]
    breach_id = res.get('breach_id')
    stages.append({'stage': '3. BREACH DETECTED', 'as_of': str(cfg['DEMO_END_DATE']),
                   'status': res['status'], 'observed': res['observed_value'],
                   'persistence_days': res['persistence_days'],
                   'breach_id': breach_id,
                   'weakest_segments': res.get('affected_segments'),
                   'narrative': 'Deterministic breach. Awaiting human confirmation - the platform will not self-confirm.'})

    # 4. AI narrates why (it does not decide).
    ex = j(session.call('APP.EXPLAIN_CHALLENGE', 'A-DEP-001', 'demo'))
    stages.append({'stage': '4. AI INVESTIGATION', 'model': ex.get('model'),
                   'explanation': (ex.get('explanation') or '')[:1200],
                   'narrative': 'Narrative only. Status was already decided by deterministic rules.'})

    # 5-7. Human confirms -> impact simulated -> decisions reopened.
    cb = j(session.call('APP.CONFIRM_BREACH', breach_id, 'HUMAN', actor,
                        'Head of Treasury Risk',
                        'Confirmed during demo: sustained cohort-driven breach, not seasonal noise.'))
    ra = cb.get('reassessment', {})
    stages.append({'stage': '5. HUMAN CONFIRMS BREACH', 'actor': actor,
                   'narrative': 'Governed human action. AI actors are rejected by APP.IS_HUMAN_ACTOR.'})
    stages.append({'stage': '6. DOWNSTREAM IMPACT SIMULATED',
                   'lcr_approved_premise_pct': ra.get('lcr_baseline_pct'),
                   'lcr_reality_adjusted_pct': ra.get('lcr_observed_pct'),
                   'narrative': 'Illustrative simplified POC liquidity calculation.'})
    stages.append({'stage': '7. DECISIONS REASSESSMENT REQUIRED',
                   'decisions_reopened': ra.get('decisions_reopened'),
                   'reassessments': ra.get('reassessments'),
                   'narrative': 'Prior committee decisions are preserved unchanged; only governance status moves.'})

    unaffected = [r['DECISION_REF'] for r in session.sql("""
        SELECT DECISION_REF FROM CORE.DECISIONS
        WHERE GOVERNANCE_STATUS='APPROVED' ORDER BY DECISION_REF""").collect()]

    # Bring the rest of the registry up to date so the radar reflects reality for
    # every assumption, not just the one the demo walked through. A-DEP-001 is
    # re-evaluated too and stays BREACHED.
    full = j(session.call('APP.RUN_CHALLENGER', None, 'demo', None))
    stages.append({'stage': '8. MONITORING CONTINUES',
                   'evaluated': full.get('evaluated'),
                   'breached': full.get('breached'),
                   'challenged': full.get('challenged'),
                   'watch': full.get('watch'),
                   'narrative': 'Every active assumption is re-tested against current reality.'})

    return {'status': 'DEMO_ADVANCED', 'stages': stages,
            'decisions_still_approved': unaffected,
            'next_human_step': 'Propose a revised assumption version on the Decision Reassessment page, then approve it.',
            'disclaimer': 'Synthetic data / illustrative risk calculations for hackathon demonstration.'}
$$;

SELECT 'grounded QA + demo controls ready' AS STATUS;
