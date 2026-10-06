-- PremiseFlow :: 10b_governance_procedures.sql
-- Human-in-the-loop governance, decision reassessment, AI narration,
-- external-system outbox, scheduled monitoring cycle and demo controls.
--
-- Governance invariants enforced here:
--   * AI/agents can propose, investigate, summarise, recommend and simulate.
--   * AI/agents can NEVER confirm a breach, approve a version, or publish a
--     new current version. Those procedures reject non-human actors outright.
--   * Approved versions are never overwritten. Superseding sets VALID_TO and
--     IS_CURRENT only; APPROVAL_STATUS / APPROVED_BY / APPROVED_AT / STATEMENT
--     of the historical row remain exactly as approved.

USE DATABASE PREMISEFLOW;
USE SCHEMA APP;

-- ===========================================================================
-- Actor guard
-- ===========================================================================
-- APP.IS_HUMAN_ACTOR is defined in 10d_governance_actors.sql and NOT here.
--
-- It was originally defined in this file as a denylist of suspicious identifiers.
-- That control was wrong (test F4 caught 'claude-sonnet-4-5' being accepted as a
-- human) and was replaced by an allowlist over CORE.GOVERNANCE_ACTORS. Keeping a
-- second CREATE OR REPLACE here made the effective definition depend on script
-- execution order: re-running this file silently reinstated the weaker guard and
-- regressed tests F4 and F4b. There is now exactly one definition, in 10d.

-- ===========================================================================
-- Outbox: used whenever an external system is not wired up (Jira/Slack/Teams)
-- ===========================================================================
CREATE OR REPLACE PROCEDURE APP.QUEUE_OUTBOX_ACTION(
  P_ACTION_TYPE STRING, P_TARGET_SYSTEM STRING, P_PAYLOAD STRING,
  P_DEDUPE_KEY STRING, P_OBJECT_TYPE STRING, P_OBJECT_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  AID STRING DEFAULT 'ACT-' || REPLACE(UUID_STRING(),'-','');
  EXISTING STRING;
  IAID STRING DEFAULT 'IA-' || REPLACE(UUID_STRING(),'-','');
BEGIN
  -- Idempotent on DEDUPE_KEY so repeated testing never spams the target system.
  SELECT ACTION_ID INTO :EXISTING FROM CORE.ACTION_OUTBOX
   WHERE DEDUPE_KEY = :P_DEDUPE_KEY LIMIT 1;
  IF (:EXISTING IS NOT NULL) THEN
    RETURN :EXISTING;
  END IF;

  INSERT INTO CORE.ACTION_OUTBOX (ACTION_ID, ACTION_TYPE, TARGET_SYSTEM, PAYLOAD, STATUS, DEDUPE_KEY)
  SELECT :AID, :P_ACTION_TYPE, :P_TARGET_SYSTEM, TRY_PARSE_JSON(:P_PAYLOAD), 'PENDING', :P_DEDUPE_KEY;

  INSERT INTO AUDIT.INTEGRATION_ACTIONS
    (INTEGRATION_ACTION_ID, TARGET_SYSTEM, ACTION_TYPE, OBJECT_TYPE, OBJECT_ID,
     STATUS, REQUEST_PAYLOAD, NOTE)
  SELECT :IAID, :P_TARGET_SYSTEM, :P_ACTION_TYPE, :P_OBJECT_TYPE, :P_OBJECT_ID,
         'QUEUED_OUTBOX', TRY_PARSE_JSON(:P_PAYLOAD),
         'No MCP connector configured for this target system. Action queued in CORE.ACTION_OUTBOX. See MCP_SETUP.md.';
  RETURN :AID;
END;
$$;

-- Records the result of an external delivery (used by an MCP-backed skill).
CREATE OR REPLACE PROCEDURE APP.MARK_OUTBOX_SENT(P_ACTION_ID STRING, P_EXTERNAL_ID STRING, P_EXTERNAL_URL STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  UPDATE CORE.ACTION_OUTBOX
     SET STATUS='SENT', PROCESSED_AT=CURRENT_TIMESTAMP(), EXTERNAL_ID=:P_EXTERNAL_ID
   WHERE ACTION_ID=:P_ACTION_ID;
  UPDATE AUDIT.INTEGRATION_ACTIONS
     SET STATUS='SENT', EXTERNAL_ID=:P_EXTERNAL_ID, EXTERNAL_URL=:P_EXTERNAL_URL,
         NOTE='Delivered to external system.'
   WHERE OBJECT_ID = (SELECT DEDUPE_KEY FROM CORE.ACTION_OUTBOX WHERE ACTION_ID=:P_ACTION_ID)
      OR INTEGRATION_ACTION_ID = :P_ACTION_ID;
  RETURN 'marked sent: ' || :P_EXTERNAL_ID;
END;
$$;

-- ===========================================================================
-- AI narration. Explains an outcome that deterministic code already decided.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE APP.EXPLAIN_CHALLENGE(P_ASSUMPTION_ID STRING, P_ACTOR STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json, uuid

MODEL = 'claude-sonnet-4-5'
PROMPT_VERSION = 'explain-challenge-v1.1'

def lit(v):
    if v is None: return 'NULL'
    if isinstance(v, (int, float)) and not isinstance(v, bool): return repr(v)
    # Escape backslashes BEFORE quotes: Snowflake processes backslash escapes inside
    # single-quoted literals, so LLM-generated text containing a backslash would
    # otherwise corrupt the statement.
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"

def _as_text(raw):
    """AI_COMPLETE returns its text JSON-encoded, so the value arrives wrapped in
    double quotes with escaped newlines. Unwrap it before storing, otherwise the
    UI renders a leading quote and literal \\n sequences."""
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


def run(session, p_assumption_id, p_actor):
    run_id = 'RUN-' + uuid.uuid4().hex[:16]
    ch = session.sql(f"""
        SELECT c.*, a.NAME, a.STATEMENT, a.DOMAIN, a.MATERIALITY
        FROM CORE.ASSUMPTION_CHALLENGES c JOIN CORE.ASSUMPTIONS a USING (ASSUMPTION_ID)
        WHERE c.ASSUMPTION_ID = {lit(p_assumption_id)}
        ORDER BY c.EVALUATED_AT DESC LIMIT 1""").collect()
    if not ch:
        return {'error': 'no challenge recorded for ' + str(p_assumption_id)}
    c = ch[0]

    mask = session.sql("""
        SELECT ROUND(TOTAL_DEPOSIT_GROWTH*100,2) TG, ROUND(GOVERNED_DEPOSIT_GROWTH*100,2) GG,
               ROUND(PROMOTIONAL_FUNDING_SHARE*100,2) PS, ROUND(TOTAL_DEPOSITS/1e6,1) TD,
               ROUND(GOVERNED_STABLE_DEPOSITS/1e6,1) GD, ROUND(PROMOTIONAL_DEPOSITS/1e6,1) PD
        FROM CORE.V_DEPOSIT_MASKING ORDER BY BALANCE_DATE DESC LIMIT 1""").collect()
    m = mask[0] if mask else None

    segs = json.loads(c['AFFECTED_SEGMENTS']) if c['AFFECTED_SEGMENTS'] else []
    seg_txt = '; '.join(f"{s['grain']}={s['value']} retention {s['retention']:.1%}" for s in segs[:6]) or 'not decomposable'

    facts = f"""
Assumption: {c['ASSUMPTION_ID']} - {c['NAME']}
Statement: {c['STATEMENT']}
Domain: {c['DOMAIN']}; Materiality: {c['MATERIALITY']}
Deterministic status decided by the platform: {c['STATUS']}
Approved expected value: {c['EXPECTED_VALUE']}
Observed value on {c['OBSERVATION_DATE']}: {c['OBSERVED_VALUE']}
Deviation: {c['DEVIATION']} ({c['DEVIATION_PCT']})
Consecutive days beyond threshold: {c['PERSISTENCE_DAYS']}
Robust z-score vs validated regime: {c['ROBUST_Z']}
Detected change point: {c['CHANGE_POINT_DATE']}
Weakest segments: {seg_txt}
Aggregate context: total deposits {m['TD'] if m else 'n/a'}m ({m['TG'] if m else 'n/a'}% vs period start);
governed stable deposits {m['GD'] if m else 'n/a'}m ({m['GG'] if m else 'n/a'}% vs period start);
promotional deposits {m['PD'] if m else 'n/a'}m = {m['PS'] if m else 'n/a'}% of funding.
"""
    prompt = (
        "You are a bank treasury-risk analyst writing an assumption challenge note. "
        "Using ONLY the facts provided, explain in 4-6 sentences: what changed, which cohort drove it, "
        "why aggregate deposit monitoring would have missed it, and what it means for reliance on this assumption. "
        "Do not invent numbers. Do not recommend approving or rejecting anything. "
        "State plainly that the status was determined by deterministic threshold and persistence rules.\n\n"
        "FACTS:\n" + facts)

    session.sql(f"""INSERT INTO AUDIT.AGENT_RUNS
        (RUN_ID, RUN_TYPE, STARTED_AT, STATUS, TRIGGERED_BY, MODEL_NAME, WORKFLOW_VERSION,
         PROMPT_REF, INPUT_SUMMARY, EVIDENCE_REFS)
        SELECT {lit(run_id)},'AGENT_QA',CURRENT_TIMESTAMP(),'RUNNING',{lit(p_actor or 'SYSTEM')},
               {lit(MODEL)},{lit(PROMPT_VERSION)},{lit(PROMPT_VERSION)},
               {lit('explain ' + str(p_assumption_id) + ' challenge ' + str(c['CHALLENGE_ID']))},
               TRY_PARSE_JSON({lit(json.dumps([c['CHALLENGE_ID']]))})""").collect()
    try:
        txt = _as_text(session.sql(f"SELECT AI_COMPLETE({lit(MODEL)}, {lit(prompt)})::STRING AS T").collect()[0]['T'])
    except Exception as e:
        txt = ('AI narration unavailable (' + str(e)[:200] + '). Deterministic finding stands: '
               f"observed {c['OBSERVED_VALUE']} vs approved {c['EXPECTED_VALUE']} for "
               f"{c['PERSISTENCE_DAYS']} consecutive days; status {c['STATUS']}.")
        session.sql(f"""UPDATE AUDIT.AGENT_RUNS SET STATUS='FAILED',
            ERROR_MESSAGE={lit(str(e)[:1000])}, FINISHED_AT=CURRENT_TIMESTAMP()
            WHERE RUN_ID={lit(run_id)}""").collect()

    session.sql(f"""UPDATE CORE.ASSUMPTION_CHALLENGES SET EXPLANATION={lit(txt)}
        WHERE CHALLENGE_ID={lit(c['CHALLENGE_ID'])}""").collect()
    session.sql(f"""UPDATE CORE.ASSUMPTION_BREACHES SET ROOT_CAUSE_SUMMARY={lit(txt)}
        WHERE ASSUMPTION_ID={lit(p_assumption_id)} AND CONFIRMATION_STATUS<>'DISMISSED'
          AND ROOT_CAUSE_SUMMARY IS NULL""").collect()
    session.sql(f"""UPDATE AUDIT.AGENT_RUNS SET FINISHED_AT=CURRENT_TIMESTAMP(),
        STATUS=IFF(STATUS='FAILED','FAILED','SUCCESS'), OUTPUT_SUMMARY={lit(txt[:4000])}
        WHERE RUN_ID={lit(run_id)}""").collect()
    session.sql(f"""CALL AUDIT.LOG_EVENT('AI_EXPLANATION_GENERATED','CHALLENGE',{lit(c['CHALLENGE_ID'])},
        'AGENT',{lit(MODEL)},NULL,NULL,{lit(c['CHALLENGE_ID'])},{lit(run_id)},
        {lit('Narrative explanation only; status was decided deterministically.')},NULL)""").collect()
    return {'run_id': run_id, 'assumption_id': p_assumption_id,
            'challenge_id': c['CHALLENGE_ID'], 'status': c['STATUS'],
            'model': MODEL, 'prompt_version': PROMPT_VERSION, 'explanation': txt}
$$;

-- ===========================================================================
-- Decision reassessment engine
-- ===========================================================================
CREATE OR REPLACE PROCEDURE APP.TRIGGER_REASSESSMENTS(
  P_ASSUMPTION_ID STRING, P_BREACH_ID STRING, P_RUN_ID STRING, P_ACTOR STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json, uuid

def lit(v):
    if v is None: return 'NULL'
    if isinstance(v, bool): return 'TRUE' if v else 'FALSE'
    if isinstance(v, (int, float)): return repr(v)
    # Escape backslashes BEFORE quotes: Snowflake processes backslash escapes inside
    # single-quoted literals, so LLM-generated text containing a backslash would
    # otherwise corrupt the statement.
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"

def run(session, p_assumption_id, p_breach_id, p_run_id, p_actor):
    run_id = p_run_id or ('RUN-' + uuid.uuid4().hex[:16])
    cur = session.sql(f"""SELECT * FROM CORE.V_ASSUMPTION_CURRENT
                          WHERE ASSUMPTION_ID={lit(p_assumption_id)}""").collect()
    if not cur:
        return {'error': 'unknown assumption'}
    a = cur[0]
    approved = float(a['EXPECTED_VALUE'])
    observed = float(a['LATEST_OBSERVED_VALUE'])

    imp = session.call('APP.RUN_IMPACT_FOR_ASSUMPTION', p_assumption_id, p_actor or 'impact_engine')
    imp = json.loads(imp) if isinstance(imp, str) else imp

    def metric(block, mid):
        for m in block['metrics']:
            if m['metric_id'] == mid:
                return m['value']
        return None

    lcr_base = metric(imp['baseline'], 'LCR')
    lcr_obs  = metric(imp['observed'], 'LCR')
    gap_obs  = metric(imp['observed'], 'FUNDING_GAP_90D')
    nii_base = metric(imp['baseline'], 'NII_12M')
    nii_obs  = metric(imp['observed'], 'NII_12M')

    impact_summary = (
        f"Reality-adjusted retention of {observed:.2%} versus the approved premise of {approved:.2%} moves the "
        f"illustrative LCR from {lcr_base:.1f}% to {lcr_obs:.1f}% (internal limit 110%, regulatory minimum 100%), "
        f"opens a {gap_obs:.1f}m stable-funding gap and reduces twelve-month NII from {nii_base:.1f}m to {nii_obs:.1f}m. "
        "Hackathon POC - illustrative simplified risk calculation.")

    # Which prior decisions are exposed? MATERIAL reliance always; SUPPORTING
    # reliance only when the assumption itself is CRITICAL.
    deps = session.sql(f"""
        SELECT dd.DECISION_ID, dd.VERSION_ID, dd.RELIANCE_STRENGTH, dd.RELIANCE_NOTE,
               d.DECISION_REF, d.TITLE, d.GOVERNANCE_STATUS, d.MATERIALITY
        FROM CORE.DECISION_DEPENDENCIES dd
        JOIN CORE.DECISIONS d ON d.DECISION_ID = dd.DECISION_ID
        WHERE dd.ASSUMPTION_ID = {lit(p_assumption_id)}
          AND ( dd.RELIANCE_STRENGTH = 'MATERIAL'
             OR (dd.RELIANCE_STRENGTH = 'SUPPORTING' AND {lit(a['MATERIALITY'])} = 'CRITICAL') )""").collect()

    created = []
    for d in deps:
        existing = session.sql(f"""SELECT REASSESSMENT_ID FROM CORE.REASSESSMENTS
            WHERE DECISION_ID={lit(d['DECISION_ID'])} AND ASSUMPTION_ID={lit(p_assumption_id)}
              AND STATUS IN ('OPEN','IN_REVIEW')""").collect()
        if existing:
            created.append({'decision_id': d['DECISION_ID'],
                            'reassessment_id': existing[0]['REASSESSMENT_ID'], 'action': 'ALREADY_OPEN'})
            continue

        rid = 'RA-' + uuid.uuid4().hex[:16]
        recommendation = (
            f"Recommend the committee re-run the liquidity buffer decision using an evidence-based retention premise. "
            f"The observed {observed:.2%} retention is sustained, not transient. Options to consider: "
            f"(1) revise A-DEP-001 to a lower governed threshold and re-derive the buffer; "
            f"(2) retain the 90% premise but restrict it to a narrower, still-compliant cohort; "
            f"(3) hold the premise and pre-fund term wholesale capacity to restore LCR headroom. "
            f"This is a recommendation only - PremiseFlow cannot approve a revised assumption or a revised decision.")

        session.sql(f"""INSERT INTO CORE.REASSESSMENTS
            (REASSESSMENT_ID, DECISION_ID, ASSUMPTION_ID, BREACH_ID, TRIGGERED_AT, TRIGGER_REASON,
             ORIGINAL_VERSION_ID, OBSERVED_VALUE, APPROVED_VALUE, IMPACT_SUMMARY, MATERIALITY,
             AI_RECOMMENDATION, STATUS)
            SELECT {lit(rid)},{lit(d['DECISION_ID'])},{lit(p_assumption_id)},{lit(p_breach_id)},
                   CURRENT_TIMESTAMP(),
                   {lit('Confirmed breach of ' + str(p_assumption_id) + ' (' + str(d['RELIANCE_STRENGTH']) + ' reliance): ' + str(d['RELIANCE_NOTE']))},
                   {lit(d['VERSION_ID'])},{lit(observed)},{lit(approved)},
                   {lit(impact_summary)},{lit(a['MATERIALITY'])},{lit(recommendation)},'OPEN'""").collect()

        prior = d['GOVERNANCE_STATUS']
        session.sql(f"""UPDATE CORE.DECISIONS
            SET GOVERNANCE_STATUS='REASSESSMENT_REQUIRED', STATUS_CHANGED_AT=CURRENT_TIMESTAMP()
            WHERE DECISION_ID={lit(d['DECISION_ID'])}""").collect()
        session.sql(f"""CALL AUDIT.LOG_EVENT('DECISION_REOPENED','DECISION',{lit(d['DECISION_ID'])},
            'SYSTEM',{lit(p_actor or 'reassessment_engine')},{lit(prior)},'REASSESSMENT_REQUIRED',
            {lit(p_breach_id)},{lit(run_id)},{lit(impact_summary[:3000])},NULL)""").collect()

        payload = {
            'summary': f"[PremiseFlow] Critical assumption {p_assumption_id} requires reassessment",
            'assumption_id': p_assumption_id,
            'assumption_name': a['NAME'],
            'approved_value': approved,
            'observed_value': round(observed, 4),
            'approved_version_id': d['VERSION_ID'],
            'affected_decision': d['DECISION_REF'],
            'affected_decision_title': d['TITLE'],
            'lcr_approved_premise_pct': lcr_base,
            'lcr_reality_adjusted_pct': lcr_obs,
            'funding_gap_usd_m': gap_obs,
            'impact_summary': impact_summary,
            'evidence_reference': p_breach_id,
            'premiseflow_reassessment_id': rid,
            'issue_type': 'Task', 'priority': 'Highest',
            'labels': ['premiseflow', 'assumption-breach', 'liquidity'],
            'note': 'Synthetic data / illustrative risk calculations for hackathon demonstration.',
        }
        session.call('APP.QUEUE_OUTBOX_ACTION', 'CREATE_ISSUE', 'JIRA',
                     json.dumps(payload), 'jira:' + rid, 'REASSESSMENT', rid)
        session.call('APP.QUEUE_OUTBOX_ACTION', 'POST_ALERT', 'SLACK',
                     json.dumps({'channel': '#treasury-risk-alerts',
                                 'text': f"*{p_assumption_id} BREACHED* - {d['DECISION_REF']} moved to "
                                         f"REASSESSMENT_REQUIRED. Illustrative LCR {lcr_base:.1f}% -> {lcr_obs:.1f}%.",
                                 'reassessment_id': rid}),
                     'slack:' + rid, 'REASSESSMENT', rid)

        created.append({'decision_id': d['DECISION_ID'], 'decision_ref': d['DECISION_REF'],
                        'reliance': d['RELIANCE_STRENGTH'], 'reassessment_id': rid,
                        'action': 'REASSESSMENT_REQUIRED'})

    return {'run_id': run_id, 'assumption_id': p_assumption_id,
            'impact_summary': impact_summary,
            'lcr_baseline_pct': lcr_base, 'lcr_observed_pct': lcr_obs,
            'reassessments': created,
            'decisions_reopened': [c['decision_id'] for c in created if c['action'] == 'REASSESSMENT_REQUIRED']}
$$;

-- ===========================================================================
-- Human actions
-- ===========================================================================
CREATE OR REPLACE PROCEDURE APP.CONFIRM_BREACH(
  P_BREACH_ID STRING, P_ACTOR_TYPE STRING, P_ACTOR_ID STRING, P_ACTOR_ROLE STRING, P_NOTE STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json, uuid

def lit(v):
    if v is None: return 'NULL'
    if isinstance(v, bool): return 'TRUE' if v else 'FALSE'
    if isinstance(v, (int, float)): return repr(v)
    # Escape backslashes BEFORE quotes: Snowflake processes backslash escapes inside
    # single-quoted literals, so LLM-generated text containing a backslash would
    # otherwise corrupt the statement.
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"

def run(session, p_breach_id, p_actor_type, p_actor_id, p_actor_role, p_note):
    ok = session.sql(f"SELECT APP.IS_HUMAN_ACTOR({lit(p_actor_type)},{lit(p_actor_id)}) AS OK").collect()[0]['OK']
    if not ok:
        raise Exception('GOVERNANCE_VIOLATION: confirming a breach requires a human actor. '
                        f'Rejected actor_type={p_actor_type}, actor_id={p_actor_id}. '
                        'PremiseFlow does not permit AI or system actors to confirm breaches.')

    b = session.sql(f"""SELECT * FROM CORE.ASSUMPTION_BREACHES WHERE BREACH_ID={lit(p_breach_id)}""").collect()
    if not b:
        return {'error': 'unknown breach ' + str(p_breach_id)}
    b = b[0]
    if b['CONFIRMATION_STATUS'] == 'CONFIRMED':
        return {'breach_id': p_breach_id, 'status': 'ALREADY_CONFIRMED'}

    run_id = 'RUN-' + uuid.uuid4().hex[:16]
    aid = b['ASSUMPTION_ID']
    session.sql(f"""UPDATE CORE.ASSUMPTION_BREACHES
        SET CONFIRMATION_STATUS='CONFIRMED', CONFIRMED_BY={lit(p_actor_id)}, CONFIRMED_AT=CURRENT_TIMESTAMP()
        WHERE BREACH_ID={lit(p_breach_id)}""").collect()
    act_id = 'HA-' + uuid.uuid4().hex[:16]
    session.sql(f"""INSERT INTO AUDIT.HUMAN_ACTIONS
        (ACTION_ID, ACTION_TYPE, OBJECT_TYPE, OBJECT_ID, ACTOR_ID, ACTOR_ROLE, DECISION, NOTE)
        SELECT {lit(act_id)},'CONFIRM_BREACH','BREACH',{lit(p_breach_id)},{lit(p_actor_id)},
               {lit(p_actor_role)},'CONFIRMED',{lit(p_note)}""").collect()
    session.sql(f"""CALL AUDIT.LOG_EVENT('BREACH_CONFIRMED','BREACH',{lit(p_breach_id)},
        'HUMAN',{lit(p_actor_id)},'PENDING_HUMAN_CONFIRMATION','CONFIRMED',
        {lit(b['CHALLENGE_ID'])},{lit(run_id)},{lit(p_note or 'Breach confirmed by governance owner.')},NULL)""").collect()

    ra = session.call('APP.TRIGGER_REASSESSMENTS', aid, p_breach_id, run_id, p_actor_id)
    ra = json.loads(ra) if isinstance(ra, str) else ra
    return {'breach_id': p_breach_id, 'assumption_id': aid, 'status': 'CONFIRMED',
            'confirmed_by': p_actor_id, 'run_id': run_id, 'reassessment': ra}
$$;

CREATE OR REPLACE PROCEDURE APP.DISMISS_CHALLENGE(
  P_ASSUMPTION_ID STRING, P_ACTOR_TYPE STRING, P_ACTOR_ID STRING, P_ACTOR_ROLE STRING, P_NOTE STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  PRIOR STRING;
BEGIN
  IF (NOT APP.IS_HUMAN_ACTOR(:P_ACTOR_TYPE, :P_ACTOR_ID)) THEN
    RETURN 'GOVERNANCE_VIOLATION: dismissing a challenge requires a human actor.';
  END IF;
  SELECT STATUS INTO :PRIOR FROM CORE.ASSUMPTIONS WHERE ASSUMPTION_ID = :P_ASSUMPTION_ID;
  UPDATE CORE.ASSUMPTION_BREACHES
     SET CONFIRMATION_STATUS='DISMISSED', CONFIRMED_BY=:P_ACTOR_ID, CONFIRMED_AT=CURRENT_TIMESTAMP()
   WHERE ASSUMPTION_ID=:P_ASSUMPTION_ID AND CONFIRMATION_STATUS='PENDING_HUMAN_CONFIRMATION';
  UPDATE CORE.ASSUMPTIONS SET STATUS='VALID', UPDATED_AT=CURRENT_TIMESTAMP(),
         LAST_VALIDATED_AT=CURRENT_TIMESTAMP()
   WHERE ASSUMPTION_ID=:P_ASSUMPTION_ID;
  INSERT INTO AUDIT.HUMAN_ACTIONS (ACTION_ID, ACTION_TYPE, OBJECT_TYPE, OBJECT_ID, ACTOR_ID, ACTOR_ROLE, DECISION, NOTE)
  SELECT 'HA-'||REPLACE(UUID_STRING(),'-',''),'DISMISS_CHALLENGE','ASSUMPTION',:P_ASSUMPTION_ID,
         :P_ACTOR_ID,:P_ACTOR_ROLE,'DISMISSED',:P_NOTE;
  CALL AUDIT.LOG_EVENT('CHALLENGE_DISMISSED','ASSUMPTION',:P_ASSUMPTION_ID,'HUMAN',:P_ACTOR_ID,
       :PRIOR,'VALID',NULL,NULL,:P_NOTE,NULL);
  RETURN 'challenge dismissed for ' || :P_ASSUMPTION_ID;
END;
$$;

CREATE OR REPLACE PROCEDURE APP.REQUEST_MORE_EVIDENCE(
  P_ASSUMPTION_ID STRING, P_ACTOR_TYPE STRING, P_ACTOR_ID STRING, P_ACTOR_ROLE STRING, P_NOTE STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  PRIOR STRING;
BEGIN
  IF (NOT APP.IS_HUMAN_ACTOR(:P_ACTOR_TYPE, :P_ACTOR_ID)) THEN
    RETURN 'GOVERNANCE_VIOLATION: requesting evidence requires a human actor.';
  END IF;
  SELECT STATUS INTO :PRIOR FROM CORE.ASSUMPTIONS WHERE ASSUMPTION_ID = :P_ASSUMPTION_ID;
  UPDATE CORE.ASSUMPTIONS SET STATUS='UNDER_REVIEW', UPDATED_AT=CURRENT_TIMESTAMP()
   WHERE ASSUMPTION_ID=:P_ASSUMPTION_ID;
  INSERT INTO AUDIT.HUMAN_ACTIONS (ACTION_ID, ACTION_TYPE, OBJECT_TYPE, OBJECT_ID, ACTOR_ID, ACTOR_ROLE, DECISION, NOTE)
  SELECT 'HA-'||REPLACE(UUID_STRING(),'-',''),'REQUEST_MORE_EVIDENCE','ASSUMPTION',:P_ASSUMPTION_ID,
         :P_ACTOR_ID,:P_ACTOR_ROLE,'MORE_EVIDENCE_REQUESTED',:P_NOTE;
  CALL AUDIT.LOG_EVENT('MORE_EVIDENCE_REQUESTED','ASSUMPTION',:P_ASSUMPTION_ID,'HUMAN',:P_ACTOR_ID,
       :PRIOR,'UNDER_REVIEW',NULL,NULL,:P_NOTE,NULL);
  RETURN 'assumption moved to UNDER_REVIEW: ' || :P_ASSUMPTION_ID;
END;
$$;

-- ===========================================================================
-- Versioning. Proposing is open to AI; approving is human-only.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE APP.PROPOSE_NEW_VERSION(
  P_ASSUMPTION_ID STRING, P_STATEMENT STRING, P_EXPECTED FLOAT,
  P_CHALLENGE FLOAT, P_BREACH FLOAT, P_LOWER FLOAT, P_UPPER FLOAT,
  P_PERSISTENCE FLOAT, P_EVIDENCE_SUMMARY STRING, P_ACTOR_ID STRING, P_RATIONALE STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json

def lit(v):
    if v is None: return 'NULL'
    if isinstance(v, bool): return 'TRUE' if v else 'FALSE'
    if isinstance(v, (int, float)): return repr(v)
    # Escape backslashes BEFORE quotes: Snowflake processes backslash escapes inside
    # single-quoted literals, so LLM-generated text containing a backslash would
    # otherwise corrupt the statement.
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"

def run(session, aid, statement, expected, challenge, breach, lower, upper,
        persistence, evidence_summary, actor_id, rationale):
    cur = session.sql(f"""SELECT * FROM CORE.ASSUMPTION_VERSIONS
        WHERE ASSUMPTION_ID={lit(aid)} AND IS_CURRENT""").collect()
    if not cur:
        return {'error': 'no current version for ' + str(aid)}
    cur = cur[0]
    nxt = session.sql(f"""SELECT COALESCE(MAX(VERSION_NUMBER),0)+1 AS N
        FROM CORE.ASSUMPTION_VERSIONS WHERE ASSUMPTION_ID={lit(aid)}""").collect()[0]['N']
    vid = f"{aid}-V{int(nxt)}"

    # Inherit the envelope, then record that the promotional-funding condition
    # under which v1 was validated no longer holds.
    ctx = session.sql("""SELECT ROUND(PROMOTIONAL_FUNDING_SHARE,4) PS, ROUND(POLICY_RATE_PCT,4) PR,
                                ROUND(DEPOSIT_CONCENTRATION,4) DC
                         FROM CORE.DT_ASSUMPTION_CONTEXT ORDER BY OBSERVATION_DATE DESC LIMIT 1""").collect()
    env = json.loads(cur['VALIDITY_ENVELOPE']) if cur['VALIDITY_ENVELOPE'] else {}
    if ctx:
        env['observed_at_proposal'] = {'promotional_funding_share': float(ctx[0]['PS']),
                                       'policy_rate_pct': float(ctx[0]['PR']),
                                       'deposit_concentration': float(ctx[0]['DC'])}
        env['promotional_funding_share_max'] = round(float(ctx[0]['PS']) + 0.02, 4)

    session.sql(f"""INSERT INTO CORE.ASSUMPTION_VERSIONS
        (VERSION_ID, ASSUMPTION_ID, VERSION_NUMBER, STATEMENT, EXPECTED_VALUE, LOWER_BOUND, UPPER_BOUND,
         CHALLENGE_THRESHOLD, BREACH_THRESHOLD, PERSISTENCE_DAYS, DIRECTION, VALID_FROM, VALID_TO,
         VALIDITY_ENVELOPE, EVIDENCE_SUMMARY, APPROVAL_STATUS, PROPOSED_BY, PROPOSED_AT,
         SUPERSEDES_VERSION_ID, IS_CURRENT)
        SELECT {lit(vid)},{lit(aid)},{lit(int(nxt))},{lit(statement)},{lit(expected)},
               {lit(lower)},{lit(upper)},{lit(challenge)},{lit(breach)},{lit(int(persistence))},
               {lit(cur['DIRECTION'])},NULL,NULL,
               TRY_PARSE_JSON({lit(json.dumps(env))}),{lit(evidence_summary)},
               'PROPOSED',{lit(actor_id)},CURRENT_TIMESTAMP(),{lit(cur['VERSION_ID'])},FALSE""").collect()
    session.sql(f"""CALL AUDIT.LOG_EVENT('NEW_VERSION_PROPOSED','ASSUMPTION_VERSION',{lit(vid)},
        'HUMAN',{lit(actor_id)},{lit(cur['VERSION_ID'])},{lit(vid)},NULL,NULL,
        {lit(rationale or 'Revised assumption proposed following confirmed breach.')},NULL)""").collect()
    session.sql(f"""INSERT INTO AUDIT.HUMAN_ACTIONS
        (ACTION_ID, ACTION_TYPE, OBJECT_TYPE, OBJECT_ID, ACTOR_ID, DECISION, NOTE)
        SELECT 'HA-'||REPLACE(UUID_STRING(),'-',''),'PROPOSE_NEW_ASSUMPTION','ASSUMPTION_VERSION',
               {lit(vid)},{lit(actor_id)},'PROPOSED',{lit(rationale)}""").collect()
    return {'assumption_id': aid, 'version_id': vid, 'version_number': int(nxt),
            'approval_status': 'PROPOSED', 'is_current': False,
            'supersedes': cur['VERSION_ID'],
            'note': 'Proposed only. A human governance owner must approve before this becomes current.'}
$$;

CREATE OR REPLACE PROCEDURE APP.APPROVE_NEW_VERSION(
  P_VERSION_ID STRING, P_ACTOR_TYPE STRING, P_ACTOR_ID STRING, P_ACTOR_ROLE STRING, P_NOTE STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
def lit(v):
    if v is None: return 'NULL'
    if isinstance(v, bool): return 'TRUE' if v else 'FALSE'
    if isinstance(v, (int, float)): return repr(v)
    # Escape backslashes BEFORE quotes: Snowflake processes backslash escapes inside
    # single-quoted literals, so LLM-generated text containing a backslash would
    # otherwise corrupt the statement.
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"

def run(session, vid, actor_type, actor_id, actor_role, note):
    ok = session.sql(f"SELECT APP.IS_HUMAN_ACTOR({lit(actor_type)},{lit(actor_id)}) AS OK").collect()[0]['OK']
    if not ok:
        raise Exception('GOVERNANCE_VIOLATION: approving an assumption version requires a human actor. '
                        f'Rejected actor_type={actor_type}, actor_id={actor_id}. '
                        'PremiseFlow does not permit AI or system actors to approve or publish versions.')

    v = session.sql(f"SELECT * FROM CORE.ASSUMPTION_VERSIONS WHERE VERSION_ID={lit(vid)}").collect()
    if not v:
        return {'error': 'unknown version ' + str(vid)}
    v = v[0]
    if v['APPROVAL_STATUS'] != 'PROPOSED':
        return {'error': f"version {vid} is {v['APPROVAL_STATUS']}, only PROPOSED versions can be approved"}
    aid = v['ASSUMPTION_ID']
    prior = session.sql(f"""SELECT VERSION_ID, VERSION_NUMBER FROM CORE.ASSUMPTION_VERSIONS
        WHERE ASSUMPTION_ID={lit(aid)} AND IS_CURRENT""").collect()
    prior_vid = prior[0]['VERSION_ID'] if prior else None

    # Supersede the previous version WITHOUT touching its approval facts or text.
    if prior_vid:
        session.sql(f"""UPDATE CORE.ASSUMPTION_VERSIONS
            SET IS_CURRENT=FALSE, VALID_TO=CURRENT_TIMESTAMP()
            WHERE VERSION_ID={lit(prior_vid)}""").collect()

    session.sql(f"""UPDATE CORE.ASSUMPTION_VERSIONS
        SET APPROVAL_STATUS='APPROVED', APPROVED_BY={lit(actor_id)}, APPROVED_AT=CURRENT_TIMESTAMP(),
            VALID_FROM=CURRENT_TIMESTAMP(), IS_CURRENT=TRUE
        WHERE VERSION_ID={lit(vid)}""").collect()
    session.sql(f"""UPDATE CORE.ASSUMPTIONS
        SET CURRENT_VERSION={lit(int(v['VERSION_NUMBER']))}, STATUS='VALID',
            STATEMENT={lit(v['STATEMENT'])},
            LAST_VALIDATED_AT=CURRENT_TIMESTAMP(), UPDATED_AT=CURRENT_TIMESTAMP()
        WHERE ASSUMPTION_ID={lit(aid)}""").collect()

    # Monitoring resumes against the NEW version.
    session.sql(f"""UPDATE CORE.ASSUMPTION_BREACHES
        SET CONFIRMATION_STATUS='CONFIRMED'
        WHERE ASSUMPTION_ID={lit(aid)} AND CONFIRMATION_STATUS='PENDING_HUMAN_CONFIRMATION'""").collect()

    session.sql(f"""INSERT INTO AUDIT.HUMAN_ACTIONS
        (ACTION_ID, ACTION_TYPE, OBJECT_TYPE, OBJECT_ID, ACTOR_ID, ACTOR_ROLE, DECISION, NOTE)
        SELECT 'HA-'||REPLACE(UUID_STRING(),'-',''),'APPROVE_NEW_VERSION','ASSUMPTION_VERSION',
               {lit(vid)},{lit(actor_id)},{lit(actor_role)},'APPROVED',{lit(note)}""").collect()
    session.sql(f"""CALL AUDIT.LOG_EVENT('NEW_VERSION_APPROVED','ASSUMPTION_VERSION',{lit(vid)},
        'HUMAN',{lit(actor_id)},{lit(prior_vid)},{lit(vid)},NULL,NULL,
        {lit(note or 'Revised assumption version approved; previous version preserved and superseded.')},NULL)""").collect()

    res = session.call('APP.RUN_CHALLENGER', aid, 'post_approval_monitor', None)
    return {'assumption_id': aid, 'approved_version_id': vid,
            'version_number': int(v['VERSION_NUMBER']),
            'superseded_version_id': prior_vid,
            'approved_by': actor_id,
            'monitoring_restarted': True,
            'post_approval_challenge': res}
$$;

CREATE OR REPLACE PROCEDURE APP.REJECT_NEW_VERSION(
  P_VERSION_ID STRING, P_ACTOR_TYPE STRING, P_ACTOR_ID STRING, P_ACTOR_ROLE STRING, P_NOTE STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  IF (NOT APP.IS_HUMAN_ACTOR(:P_ACTOR_TYPE, :P_ACTOR_ID)) THEN
    RETURN 'GOVERNANCE_VIOLATION: rejecting an assumption version requires a human actor.';
  END IF;
  UPDATE CORE.ASSUMPTION_VERSIONS
     SET APPROVAL_STATUS='REJECTED', IS_CURRENT=FALSE
   WHERE VERSION_ID=:P_VERSION_ID AND APPROVAL_STATUS='PROPOSED';
  INSERT INTO AUDIT.HUMAN_ACTIONS (ACTION_ID, ACTION_TYPE, OBJECT_TYPE, OBJECT_ID, ACTOR_ID, ACTOR_ROLE, DECISION, NOTE)
  SELECT 'HA-'||REPLACE(UUID_STRING(),'-',''),'REJECT_NEW_VERSION','ASSUMPTION_VERSION',
         :P_VERSION_ID,:P_ACTOR_ID,:P_ACTOR_ROLE,'REJECTED',:P_NOTE;
  CALL AUDIT.LOG_EVENT('NEW_VERSION_REJECTED','ASSUMPTION_VERSION',:P_VERSION_ID,'HUMAN',:P_ACTOR_ID,
       'PROPOSED','REJECTED',NULL,NULL,:P_NOTE,NULL);
  RETURN 'version rejected: ' || :P_VERSION_ID;
END;
$$;

-- Resolve a reassessment (human closes the loop on the decision).
CREATE OR REPLACE PROCEDURE APP.RESOLVE_REASSESSMENT(
  P_REASSESSMENT_ID STRING, P_RESOLUTION STRING, P_ACTOR_TYPE STRING,
  P_ACTOR_ID STRING, P_ACTOR_ROLE STRING, P_NOTE STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  DID STRING;
BEGIN
  IF (NOT APP.IS_HUMAN_ACTOR(:P_ACTOR_TYPE, :P_ACTOR_ID)) THEN
    RETURN 'GOVERNANCE_VIOLATION: resolving a reassessment requires a human actor.';
  END IF;
  SELECT DECISION_ID INTO :DID FROM CORE.REASSESSMENTS WHERE REASSESSMENT_ID=:P_REASSESSMENT_ID;
  UPDATE CORE.REASSESSMENTS
     SET STATUS='RESOLVED', RESOLVED_BY=:P_ACTOR_ID, RESOLVED_AT=CURRENT_TIMESTAMP(),
         RESOLUTION_NOTE=:P_NOTE
   WHERE REASSESSMENT_ID=:P_REASSESSMENT_ID;
  UPDATE CORE.DECISIONS
     SET GOVERNANCE_STATUS=:P_RESOLUTION, STATUS_CHANGED_AT=CURRENT_TIMESTAMP()
   WHERE DECISION_ID=:DID;
  INSERT INTO AUDIT.HUMAN_ACTIONS (ACTION_ID, ACTION_TYPE, OBJECT_TYPE, OBJECT_ID, ACTOR_ID, ACTOR_ROLE, DECISION, NOTE)
  SELECT 'HA-'||REPLACE(UUID_STRING(),'-',''),'RESOLVE_REASSESSMENT','REASSESSMENT',
         :P_REASSESSMENT_ID,:P_ACTOR_ID,:P_ACTOR_ROLE,:P_RESOLUTION,:P_NOTE;
  CALL AUDIT.LOG_EVENT('REASSESSMENT_RESOLVED','DECISION',:DID,'HUMAN',:P_ACTOR_ID,
       'REASSESSMENT_REQUIRED',:P_RESOLUTION,:P_REASSESSMENT_ID,NULL,:P_NOTE,NULL);
  RETURN 'reassessment resolved: ' || :P_REASSESSMENT_ID;
END;
$$;

-- ===========================================================================
-- Scheduled monitoring cycle (the body of the Snowflake task)
-- ===========================================================================
CREATE OR REPLACE PROCEDURE APP.MONITORING_CYCLE()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json, uuid

def run(session):
    run_id = 'RUN-' + uuid.uuid4().hex[:16]
    steps = []
    for dt in ('DT_GOVERNED_DAILY','DT_RETENTION_DAILY','DT_DEPOSIT_DAILY',
               'DT_ASSUMPTION_CONTEXT','DT_ASSUMPTION_OBSERVATIONS'):
        try:
            session.sql(f'ALTER DYNAMIC TABLE CORE.{dt} REFRESH').collect()
            steps.append({'step': 'refresh ' + dt, 'status': 'OK'})
        except Exception as e:
            steps.append({'step': 'refresh ' + dt, 'status': 'SKIPPED', 'detail': str(e)[:200]})

    ch = session.call('APP.RUN_CHALLENGER', None, 'monitoring_task', None)
    ch = json.loads(ch) if isinstance(ch, str) else ch
    steps.append({'step': 'challenger', 'status': 'OK',
                  'breached': ch.get('breached'), 'challenged': ch.get('challenged')})

    # Narrate newly breached critical assumptions, and pre-compute impact so the
    # reviewer opens the app to a ready-made pack. Reassessment still waits for
    # a human to confirm the breach.
    for aid in ch.get('breached', []):
        mat = session.sql(f"SELECT MATERIALITY FROM CORE.ASSUMPTIONS WHERE ASSUMPTION_ID='{aid}'").collect()
        try:
            session.call('APP.EXPLAIN_CHALLENGE', aid, 'monitoring_task')
            steps.append({'step': 'explain ' + aid, 'status': 'OK'})
        except Exception as e:
            steps.append({'step': 'explain ' + aid, 'status': 'FAILED', 'detail': str(e)[:200]})
        if mat and mat[0]['MATERIALITY'] == 'CRITICAL':
            try:
                session.call('APP.RUN_IMPACT_FOR_ASSUMPTION', aid, 'monitoring_task')
                steps.append({'step': 'impact ' + aid, 'status': 'OK'})
            except Exception as e:
                steps.append({'step': 'impact ' + aid, 'status': 'FAILED', 'detail': str(e)[:200]})

    pending = [r['BREACH_ID'] for r in session.sql("""
        SELECT BREACH_ID FROM CORE.ASSUMPTION_BREACHES
        WHERE CONFIRMATION_STATUS='PENDING_HUMAN_CONFIRMATION'""").collect()]
    summary = {'run_id': run_id, 'steps': steps,
               'breached': ch.get('breached'), 'challenged': ch.get('challenged'),
               'watch': ch.get('watch'),
               'breaches_awaiting_human_confirmation': pending}
    session.sql(f"""INSERT INTO AUDIT.AGENT_RUNS
        (RUN_ID, RUN_TYPE, STARTED_AT, FINISHED_AT, STATUS, TRIGGERED_BY, WORKFLOW_VERSION, OUTPUT_SUMMARY)
        SELECT '{run_id}','CHALLENGER',CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP(),'SUCCESS',
               'monitoring_task','monitoring-cycle-v1.1',
               '{json.dumps(summary).replace(chr(39), chr(39)+chr(39))[:8000]}'""").collect()
    return summary
$$;

SELECT 'governance + reassessment + monitoring procedures ready' AS STATUS;
