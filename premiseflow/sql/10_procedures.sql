-- PremiseFlow :: 10_procedures.sql
-- Reality Challenger + Impact Simulation Engine.
--
-- Division of labour, deliberately:
--   * Numeric threshold outcomes are decided by DETERMINISTIC code only.
--   * The LLM is used strictly to narrate/explain an outcome that has already
--     been decided, and its output is stored as EXPLANATION, never as STATUS.
--
-- Hackathon POC - illustrative simplified risk calculations.

USE DATABASE PREMISEFLOW;
USE SCHEMA APP;

-- ===========================================================================
-- RUN_CHALLENGER : continuously attempt to falsify active assumptions
-- ===========================================================================
CREATE OR REPLACE PROCEDURE APP.RUN_CHALLENGER(P_ASSUMPTION_ID STRING, P_ACTOR STRING, P_AS_OF DATE)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json, uuid, statistics
from datetime import datetime

WORKFLOW_VERSION = 'challenger-v1.3'

def q(session, sql, params=None):
    return session.sql(sql, params=params or []).collect()

def lit(v):
    if v is None:
        return 'NULL'
    if isinstance(v, bool):
        return 'TRUE' if v else 'FALSE'
    if isinstance(v, (int, float)):
        return repr(v)
    # Escape backslashes BEFORE quotes: Snowflake processes backslash escapes inside
    # single-quoted literals, so LLM-generated text containing a backslash would
    # otherwise corrupt the statement.
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"

def breach_side(direction, value, expected, threshold):
    """Is `value` on the wrong side of `threshold`? Deterministic, no LLM."""
    if direction == 'LOWER_IS_WORSE':
        return value < threshold
    if direction == 'UPPER_IS_WORSE':
        return value > threshold
    # TWO_SIDED: thresholds are expressed as distance-from-expected magnitudes
    return abs(value - expected) > abs(threshold - expected)

def beyond_bounds(direction, value, expected, lower, upper):
    """Has the observation left the envelope the version was approved within?
    Uses the approved bounds rather than the point estimate, so a TWO_SIDED
    assumption is not flagged merely for being non-identical to expected."""
    if direction == 'LOWER_IS_WORSE':
        return value < (lower if lower is not None else expected)
    if direction == 'UPPER_IS_WORSE':
        return value > (upper if upper is not None else expected)
    lo = lower if lower is not None else expected
    hi = upper if upper is not None else expected
    return value < lo or value > hi

def consecutive_run(series, predicate):
    """Length of the unbroken run of `predicate` ending at the last observation.
    This is what stops a single noisy point from being called a breach."""
    n = 0
    for _, v in reversed(series):
        if predicate(v):
            n += 1
        else:
            break
    return n

def robust_z(baseline_vals, value):
    """Median/MAD deviation against the regime in which the version was validated.
    The scale is floored at 0.5% of the median: these series can be extremely
    smooth, and an unfloored MAD yields meaningless four-figure z-scores.
    The result is clamped for presentational sanity."""
    if len(baseline_vals) < 8:
        return None
    med = statistics.median(baseline_vals)
    mad = statistics.median([abs(x - med) for x in baseline_vals])
    scale = max(mad * 1.4826, abs(med) * 0.005,
                (statistics.pstdev(baseline_vals) or 0.0), 1e-9)
    return max(-50.0, min(50.0, (value - med) / scale))

def driver_series(session, assumption_id, as_of=None):
    """Underlying behavioural driver, where one exists.

    A rolling-retention ratio is a lagging transform of the balance path, so a
    change point found on the ratio lands well after behaviour actually shifted.
    For A-DEP-001 the detector therefore runs on the daily log-return of the
    governed deposit pool, whose mean shifts on the day behaviour changes."""
    if assumption_id != 'A-DEP-001':
        return None, None
    cutoff = '' if not as_of else f" WHERE BALANCE_DATE <= TO_DATE('{as_of}')"
    rows = session.sql(f"""
        WITH daily AS (
          SELECT BALANCE_DATE, SUM(BALANCE) AS BAL
          FROM CORE.DT_GOVERNED_DAILY{cutoff} GROUP BY 1
        ), sm AS (
          SELECT BALANCE_DATE,
                 AVG(BAL) OVER (ORDER BY BALANCE_DATE ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS BAL7,
                 COUNT(*) OVER (ORDER BY BALANCE_DATE ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS N
          FROM daily
        )
        SELECT BALANCE_DATE,
               LN(BAL7 / NULLIF(LAG(BAL7) OVER (ORDER BY BALANCE_DATE),0)) AS LOG_RETURN
        FROM sm WHERE N = 7
        QUALIFY LOG_RETURN IS NOT NULL
        ORDER BY BALANCE_DATE""").collect()
    if not rows:
        return None, None
    return ([(r['BALANCE_DATE'], float(r['LOG_RETURN'])) for r in rows],
            'daily log-return of the governed deposit pool (7-day smoothed)')

def change_point(series, min_side=10):
    """Maximum mean-shift split point. Explainable and cheap: pick the date that
    maximises |mean(after) - mean(before)|."""
    n = len(series)
    if n < 2 * min_side + 1:
        return None, 0.0
    vals = [v for _, v in series]
    total = sum(vals)
    best_d, best_gap, running = None, 0.0, 0.0
    for i in range(n):
        running += vals[i]
        left_n = i + 1
        right_n = n - left_n
        if left_n < min_side or right_n < min_side:
            continue
        gap = abs((total - running) / right_n - running / left_n)
        if gap > best_gap:
            best_gap, best_d = gap, series[i][0]
    return best_d, best_gap

def run(session, p_assumption_id, p_actor, p_as_of):
    run_id = 'RUN-' + uuid.uuid4().hex[:16]
    actor = p_actor or 'SYSTEM'
    # An explicit as-of date lets the platform be replayed at any point in the
    # timeline, which is how the VALID -> CHALLENGED -> BREACHED progression is
    # demonstrated and regression-tested against the seeded break.
    as_of_clause = '' if not p_as_of else f" AND OBSERVATION_DATE <= TO_DATE('{p_as_of}')"
    q(session, f"""INSERT INTO AUDIT.AGENT_RUNS
        (RUN_ID, RUN_TYPE, STARTED_AT, STATUS, TRIGGERED_BY, WORKFLOW_VERSION, INPUT_SUMMARY)
        SELECT {lit(run_id)},'CHALLENGER',CURRENT_TIMESTAMP(),'RUNNING',{lit(actor)},
               {lit(WORKFLOW_VERSION)},{lit('assumption=' + (p_assumption_id or 'ALL') + '; as_of=' + str(p_as_of or 'LATEST'))}""")

    where = "" if not p_assumption_id else f" AND a.ASSUMPTION_ID = {lit(p_assumption_id)}"
    contracts = q(session, f"""
        SELECT a.ASSUMPTION_ID, a.NAME, a.STATUS, a.MATERIALITY, a.METRIC_CODE,
               v.VERSION_ID, v.EXPECTED_VALUE, v.CHALLENGE_THRESHOLD, v.BREACH_THRESHOLD,
               v.PERSISTENCE_DAYS, v.DIRECTION, v.LOWER_BOUND, v.UPPER_BOUND
        FROM CORE.ASSUMPTIONS a
        JOIN CORE.ASSUMPTION_VERSIONS v
          ON v.ASSUMPTION_ID = a.ASSUMPTION_ID AND v.IS_CURRENT
         AND v.APPROVAL_STATUS = 'APPROVED'
        WHERE a.STATUS <> 'RETIRED'{where}
        ORDER BY a.ASSUMPTION_ID""")

    results = []
    try:
        for c in contracts:
            aid = c['ASSUMPTION_ID']
            obs = q(session, f"""
                SELECT OBSERVATION_DATE, OBSERVED_VALUE, SAMPLE_SIZE, WINDOW_DAYS, SOURCE
                FROM CORE.DT_ASSUMPTION_OBSERVATIONS
                WHERE ASSUMPTION_ID = {lit(aid)} AND OBSERVED_VALUE IS NOT NULL{as_of_clause}
                ORDER BY OBSERVATION_DATE""")
            if not obs:
                results.append({'assumption_id': aid, 'status': 'NO_OBSERVATIONS'})
                continue

            series = [(r['OBSERVATION_DATE'], float(r['OBSERVED_VALUE'])) for r in obs]
            latest_date, latest_val = series[-1]
            sample_size = obs[-1]['SAMPLE_SIZE']
            window_days = obs[-1]['WINDOW_DAYS']
            source = obs[-1]['SOURCE']

            expected = float(c['EXPECTED_VALUE'])
            ch_thr   = float(c['CHALLENGE_THRESHOLD'])
            br_thr   = float(c['BREACH_THRESHOLD'])
            need     = int(c['PERSISTENCE_DAYS'])
            direction = c['DIRECTION']

            is_breach_now    = breach_side(direction, latest_val, expected, br_thr)
            is_challenge_now = breach_side(direction, latest_val, expected, ch_thr)
            lower = float(c['LOWER_BOUND']) if c['LOWER_BOUND'] is not None else None
            upper = float(c['UPPER_BOUND']) if c['UPPER_BOUND'] is not None else None
            is_outside_envelope = beyond_bounds(direction, latest_val, expected, lower, upper)

            breach_run    = consecutive_run(series, lambda v: breach_side(direction, v, expected, br_thr))
            challenge_run = consecutive_run(series, lambda v: breach_side(direction, v, expected, ch_thr))

            # ---- deterministic status decision -------------------------------
            if is_breach_now and breach_run >= need:
                status = 'BREACHED'
            elif is_challenge_now and challenge_run >= need:
                status = 'CHALLENGED'
            elif is_challenge_now or is_breach_now:
                status = 'WATCH'      # threshold touched but not yet persistent
            elif is_outside_envelope:
                status = 'WATCH'
            else:
                status = 'VALID'

            baseline = [v for _, v in series[:40]]
            z = robust_z(baseline, latest_val)
            drv, drv_label = driver_series(session, aid, p_as_of)
            if drv:
                cp_date, cp_gap = change_point(drv)
                cp_basis = drv_label
            else:
                cp_date, cp_gap = change_point(series)
                cp_basis = 'observation series'

            persistence = breach_run if is_breach_now else challenge_run
            confidence = min(0.99,
                             0.50
                             + 0.25 * min(1.0, persistence / max(need, 1))
                             + 0.25 * min(1.0, abs(z or 0.0) / 6.0)) if status != 'VALID' else 0.0

            deviation = latest_val - expected
            deviation_pct = deviation / abs(expected) if expected else None

            # ---- segment decomposition (A-DEP-001 only has dimensional data) --
            segments = []
            seg_rows = q(session, f"""
                SELECT GRAIN, DIM_VALUE, RETENTION_RATE, BALANCE_CHANGE, ACCOUNTS
                FROM CORE.DT_RETENTION_DAILY
                WHERE OBSERVATION_DATE = TO_DATE({lit(str(latest_date))})
                  AND GRAIN <> 'OVERALL' AND {lit(aid)} = 'A-DEP-001'
                ORDER BY RETENTION_RATE ASC LIMIT 12""")
            for s in seg_rows:
                segments.append({'grain': s['GRAIN'], 'value': s['DIM_VALUE'],
                                 'retention': round(float(s['RETENTION_RATE']), 4),
                                 'balance_change': float(s['BALANCE_CHANGE']),
                                 'accounts': int(s['ACCOUNTS'] or 0)})

            evidence_ids = [r['EVIDENCE_ID'] for r in q(session,
                f"SELECT EVIDENCE_ID FROM CORE.ASSUMPTION_EVIDENCE WHERE ASSUMPTION_ID={lit(aid)}")]

            # ---- persist the observation the challenger actually acted on -----
            obs_id = 'OBS-' + uuid.uuid4().hex[:16]
            q(session, f"""INSERT INTO CORE.ASSUMPTION_OBSERVATIONS
                (OBSERVATION_ID, ASSUMPTION_ID, VERSION_ID, OBSERVATION_DATE, METRIC_CODE,
                 OBSERVED_VALUE, SAMPLE_SIZE, WINDOW_DAYS, CONTEXT, SOURCE)
                SELECT {lit(obs_id)},{lit(aid)},{lit(c['VERSION_ID'])},
                       TO_DATE({lit(str(latest_date))}),{lit(c['METRIC_CODE'])},
                       {lit(latest_val)},{lit(int(sample_size) if sample_size else None)},
                       {lit(int(window_days) if window_days else None)},
                       TRY_PARSE_JSON({lit(json.dumps({'run_id': run_id, 'series_length': len(series)}))}),
                       {lit(source)}""")

            chal_id = 'CHL-' + uuid.uuid4().hex[:16]
            q(session, f"""INSERT INTO CORE.ASSUMPTION_CHALLENGES
                (CHALLENGE_ID, RUN_ID, ASSUMPTION_ID, VERSION_ID, EVALUATED_AT, OBSERVATION_DATE,
                 OBSERVED_VALUE, EXPECTED_VALUE, DEVIATION, DEVIATION_PCT, PERSISTENCE_DAYS,
                 CONFIDENCE, ROBUST_Z, CHANGE_POINT_DATE, AFFECTED_SEGMENTS, EVIDENCE_IDS,
                 STATUS, METHOD, EXPLANATION)
                SELECT {lit(chal_id)},{lit(run_id)},{lit(aid)},{lit(c['VERSION_ID'])},
                       CURRENT_TIMESTAMP(),TO_DATE({lit(str(latest_date))}),
                       {lit(latest_val)},{lit(expected)},{lit(deviation)},{lit(deviation_pct)},
                       {lit(persistence)},{lit(confidence)},{lit(z)},
                       {('TO_DATE(' + lit(str(cp_date)) + ')') if cp_date else 'NULL'},
                       TRY_PARSE_JSON({lit(json.dumps(segments))}),
                       TRY_PARSE_JSON({lit(json.dumps(evidence_ids))}),
                       {lit(status)},
                       {lit('deterministic thresholds + persistence run + median/MAD robust z + max-mean-shift change point on ' + cp_basis)},
                       NULL""")

            prior_status = c['STATUS']
            if prior_status != status:
                q(session, f"""UPDATE CORE.ASSUMPTIONS
                    SET STATUS={lit(status)}, UPDATED_AT=CURRENT_TIMESTAMP(),
                        LAST_VALIDATED_AT=CASE WHEN {lit(status)}='VALID'
                                               THEN CURRENT_TIMESTAMP() ELSE LAST_VALIDATED_AT END
                    WHERE ASSUMPTION_ID={lit(aid)}""")
                ev_type = {'BREACHED': 'BREACH_DETECTED', 'CHALLENGED': 'CHALLENGE_DETECTED'}.get(status, 'STATUS_CHANGED')
                q(session, f"""CALL AUDIT.LOG_EVENT({lit(ev_type)},'ASSUMPTION',{lit(aid)},
                    'SYSTEM',{lit('reality_challenger')},{lit(prior_status)},{lit(status)},
                    {lit(chal_id)},{lit(run_id)},
                    {lit(f'Observed {latest_val:.4f} vs approved {expected:.4f}; persistence {persistence}/{need} days.')},
                    NULL)""")
            else:
                q(session, f"""CALL AUDIT.LOG_EVENT('OBSERVATION_GENERATED','ASSUMPTION',{lit(aid)},
                    'SYSTEM',{lit('reality_challenger')},{lit(prior_status)},{lit(status)},
                    {lit(chal_id)},{lit(run_id)},{lit(f'Re-tested; still {status}.')},NULL)""")

            # ---- breach record awaiting HUMAN confirmation --------------------
            breach_id = None
            if status == 'BREACHED':
                existing = q(session, f"""SELECT BREACH_ID FROM CORE.ASSUMPTION_BREACHES
                    WHERE ASSUMPTION_ID={lit(aid)} AND VERSION_ID={lit(c['VERSION_ID'])}
                      AND CONFIRMATION_STATUS <> 'DISMISSED'""")
                if existing:
                    breach_id = existing[0]['BREACH_ID']
                else:
                    breach_id = 'BRC-' + uuid.uuid4().hex[:16]
                    first_breach = None
                    for d, v in series:
                        if breach_side(direction, v, expected, br_thr):
                            first_breach = d
                            break
                    sev = 'CRITICAL' if c['MATERIALITY'] == 'CRITICAL' else 'HIGH'
                    q(session, f"""INSERT INTO CORE.ASSUMPTION_BREACHES
                        (BREACH_ID, ASSUMPTION_ID, VERSION_ID, CHALLENGE_ID, DETECTED_AT,
                         FIRST_BREACH_DATE, OBSERVED_VALUE, EXPECTED_VALUE, PERSISTENCE_DAYS,
                         SEVERITY, CONFIRMATION_STATUS, ROOT_CAUSE_SUMMARY)
                        SELECT {lit(breach_id)},{lit(aid)},{lit(c['VERSION_ID'])},{lit(chal_id)},
                               CURRENT_TIMESTAMP(),
                               {('TO_DATE(' + lit(str(first_breach)) + ')') if first_breach else 'NULL'},
                               {lit(latest_val)},{lit(expected)},{lit(persistence)},
                               {lit(sev)},'PENDING_HUMAN_CONFIRMATION',NULL""")
                    q(session, f"""CALL AUDIT.LOG_EVENT('BREACH_DETECTED','BREACH',{lit(breach_id)},
                        'SYSTEM',{lit('reality_challenger')},NULL,'PENDING_HUMAN_CONFIRMATION',
                        {lit(chal_id)},{lit(run_id)},
                        {lit('Deterministic breach threshold sustained for ' + str(persistence) + ' days. Awaiting human confirmation.')},NULL)""")

            results.append({
                'assumption_id': aid, 'name': c['NAME'], 'status': status,
                'prior_status': prior_status,
                'observation_date': str(latest_date),
                'observed_value': round(latest_val, 6), 'expected_value': expected,
                'deviation': round(deviation, 6),
                'deviation_pct': round(deviation_pct, 6) if deviation_pct is not None else None,
                'persistence_days': persistence, 'persistence_required': need,
                'confidence': round(confidence, 4),
                'robust_z': round(z, 3) if z is not None else None,
                'change_point_date': str(cp_date) if cp_date else None,
                'change_point_basis': cp_basis,
                'affected_segments': segments[:5],
                'evidence_ids': evidence_ids,
                'challenge_id': chal_id, 'breach_id': breach_id,
            })

        summary = {'run_id': run_id, 'evaluated': len(results),
                   'breached': [r['assumption_id'] for r in results if r.get('status') == 'BREACHED'],
                   'challenged': [r['assumption_id'] for r in results if r.get('status') == 'CHALLENGED'],
                   'watch': [r['assumption_id'] for r in results if r.get('status') == 'WATCH'],
                   'results': results}
        q(session, f"""UPDATE AUDIT.AGENT_RUNS SET FINISHED_AT=CURRENT_TIMESTAMP(),
            STATUS='SUCCESS', OUTPUT_SUMMARY={lit(json.dumps({k: summary[k] for k in ('evaluated','breached','challenged','watch')}))}
            WHERE RUN_ID={lit(run_id)}""")
        return summary
    except Exception as e:
        q(session, f"""UPDATE AUDIT.AGENT_RUNS SET FINISHED_AT=CURRENT_TIMESTAMP(),
            STATUS='FAILED', ERROR_MESSAGE={lit(str(e)[:2000])} WHERE RUN_ID={lit(run_id)}""")
        raise
$$;

-- ===========================================================================
-- RUN_IMPACT_SIMULATION : simplified, transparent, drillable risk propagation
-- ===========================================================================
CREATE OR REPLACE PROCEDURE APP.RUN_IMPACT_SIMULATION(
  P_ASSUMPTION_ID STRING, P_RETENTION FLOAT, P_SCENARIO_TYPE STRING,
  P_NAME STRING, P_ACTOR STRING, P_RUN_ID STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json, uuid

DISCLAIMER = 'Hackathon POC - illustrative simplified risk calculation.'

def lit(v):
    if v is None: return 'NULL'
    if isinstance(v, bool): return 'TRUE' if v else 'FALSE'
    if isinstance(v, (int, float)): return repr(v)
    # Escape backslashes BEFORE quotes: Snowflake processes backslash escapes inside
    # single-quoted literals, so LLM-generated text containing a backslash would
    # otherwise corrupt the statement.
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"

def run(session, p_assumption_id, p_retention, p_scenario_type, p_name, p_actor, p_run_id):
    run_id = p_run_id or ('RUN-' + uuid.uuid4().hex[:16])
    li = session.sql("SELECT * FROM CORE.LIQUIDITY_INPUTS ORDER BY AS_OF_DATE DESC LIMIT 1").collect()[0]
    prm = {r['PARAM_KEY']: float(r['PARAM_VALUE'])
           for r in session.sql("SELECT PARAM_KEY, PARAM_VALUE FROM CORE.SIM_PARAMETERS").collect()}

    sens      = prm['RETENTION_RUNOFF_SENSITIVITY']
    cap_ratio = prm['INFLOW_CAP_RATIO']
    nim       = prm['BASE_NIM_PCT']
    ref       = prm['APPROVED_RETENTION_REFERENCE']

    hqla        = float(li['HQLA_AMOUNT'])
    stable      = float(li['RETAIL_STABLE_DEPOSITS'])
    less_stable = float(li['RETAIL_LESS_STABLE_DEPOSITS'])
    wholesale   = float(li['WHOLESALE_FUNDING'])
    other_out   = float(li['OTHER_OUTFLOWS'])
    inflows     = float(li['EXPECTED_INFLOWS'])
    rr_stable   = float(li['STABLE_RUNOFF_RATE'])
    rr_less     = float(li['LESS_STABLE_RUNOFF_RATE'])
    rr_whole    = float(li['WHOLESALE_RUNOFF_RATE'])
    spread_bps  = float(li['REPLACEMENT_FUNDING_SPREAD_BPS'])
    total_dep   = stable + less_stable + wholesale

    retention = float(p_retention)
    shortfall = max(0.0, ref - retention)

    # --- the one line that carries the assumption into the risk number -------
    eff_rr_stable = rr_stable + shortfall * sens

    gross_outflows = (stable * eff_rr_stable + less_stable * rr_less
                      + wholesale * rr_whole + other_out)
    capped_inflows = min(inflows, cap_ratio * gross_outflows)
    nco = gross_outflows - capped_inflows
    lcr = hqla / nco * 100.0 if nco > 0 else None

    funding_gap  = stable * shortfall
    incr_cost    = funding_gap * spread_bps / 10000.0
    base_nii     = total_dep * nim
    nii          = base_nii - incr_cost

    scenario_id = 'SCN-' + uuid.uuid4().hex[:16]
    inputs = {
        'retention_input': retention, 'approved_retention_reference': ref,
        'retention_shortfall': round(shortfall, 6),
        'retention_runoff_sensitivity': sens,
        'effective_stable_runoff_rate': round(eff_rr_stable, 6),
        'hqla': hqla, 'retail_stable_deposits': stable,
        'retail_less_stable_deposits': less_stable, 'wholesale_funding': wholesale,
        'other_outflows': other_out, 'expected_inflows': inflows,
        'capped_inflows': round(capped_inflows, 2),
        'stable_runoff_rate': rr_stable, 'less_stable_runoff_rate': rr_less,
        'wholesale_runoff_rate': rr_whole,
        'replacement_funding_spread_bps': spread_bps,
        'base_nim_pct': nim,
    }
    session.sql(f"""INSERT INTO CORE.SCENARIOS
        (SCENARIO_ID, RUN_ID, ASSUMPTION_ID, SCENARIO_TYPE, NAME, RETENTION_INPUT, INPUTS, CREATED_BY)
        SELECT {lit(scenario_id)},{lit(run_id)},{lit(p_assumption_id)},{lit(p_scenario_type)},
               {lit(p_name)},{lit(retention)},TRY_PARSE_JSON({lit(json.dumps(inputs))}),{lit(p_actor or 'SYSTEM')}""").collect()

    metrics = [
        ('LCR', 'Liquidity Coverage Ratio', lcr, 'PCT',
         'LCR = HQLA / (stressed gross outflows - min(expected inflows, 75% x gross outflows)) x 100',
         lcr is not None and lcr < 110.0),
        ('STRESSED_OUTFLOW_30D', 'Stressed 30-Day Net Cash Outflow', nco / 1e6, 'USD_M',
         'NCO = stable x (base stable runoff + retention shortfall x sensitivity) '
         '+ less stable x runoff + wholesale x runoff + other outflows - capped inflows', False),
        ('FUNDING_GAP_90D', 'Ninety-Day Funding Gap', funding_gap / 1e6, 'USD_M',
         'Funding gap = retail stable deposits x max(0, approved retention - scenario retention)',
         funding_gap / 1e6 > 150.0),
        ('NII_12M', 'Twelve-Month Net Interest Income', nii / 1e6, 'USD_M',
         'NII = total deposits x base NIM - funding gap x replacement spread', False),
    ]
    out = []
    for mid, mname, mval, unit, formula, breaches in metrics:
        rid = 'RES-' + uuid.uuid4().hex[:16]
        session.sql(f"""INSERT INTO CORE.SCENARIO_RESULTS
            (RESULT_ID, SCENARIO_ID, METRIC_ID, METRIC_NAME, METRIC_VALUE, UNIT, FORMULA,
             INPUTS, BREACHES_LIMIT, POC_DISCLAIMER)
            SELECT {lit(rid)},{lit(scenario_id)},{lit(mid)},{lit(mname)},{lit(mval)},{lit(unit)},
                   {lit(formula)},TRY_PARSE_JSON({lit(json.dumps(inputs))}),{lit(bool(breaches))},{lit(DISCLAIMER)}""").collect()
        out.append({'metric_id': mid, 'metric_name': mname,
                    'value': round(mval, 4) if mval is not None else None,
                    'unit': unit, 'formula': formula, 'breaches_limit': bool(breaches)})

    session.sql(f"""CALL AUDIT.LOG_EVENT('IMPACT_SIMULATED','SCENARIO',{lit(scenario_id)},
        'SYSTEM',{lit(p_actor or 'impact_engine')},NULL,{lit(p_scenario_type)},NULL,{lit(run_id)},
        {lit(f'Scenario {p_scenario_type} at retention {retention:.4f}. ' + DISCLAIMER)},
        TRY_PARSE_JSON({lit(json.dumps({'metrics': out}))}))""").collect()

    return {'run_id': run_id, 'scenario_id': scenario_id, 'scenario_type': p_scenario_type,
            'name': p_name, 'retention_input': retention, 'inputs': inputs,
            'metrics': out, 'disclaimer': DISCLAIMER}
$$;

-- Convenience: baseline (approved premise) vs observed reality, side by side.
CREATE OR REPLACE PROCEDURE APP.RUN_IMPACT_FOR_ASSUMPTION(P_ASSUMPTION_ID STRING, P_ACTOR STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json, uuid

def run(session, p_assumption_id, p_actor):
    run_id = 'RUN-' + uuid.uuid4().hex[:16]
    row = session.sql(f"""
        SELECT EXPECTED_VALUE, LATEST_OBSERVED_VALUE
        FROM CORE.V_ASSUMPTION_CURRENT WHERE ASSUMPTION_ID = '{p_assumption_id}'""").collect()
    if not row:
        return {'error': 'unknown assumption ' + str(p_assumption_id)}
    approved = float(row[0]['EXPECTED_VALUE'])
    observed = float(row[0]['LATEST_OBSERVED_VALUE'])

    def sim(retention, stype, name):
        r = session.call('APP.RUN_IMPACT_SIMULATION', p_assumption_id, retention, stype, name,
                         p_actor or 'impact_engine', run_id)
        return json.loads(r) if isinstance(r, str) else r

    base = sim(approved, 'BASELINE', 'Approved premise (' + format(approved, '.2%') + ' retention)')
    obs  = sim(observed, 'OBSERVED_BEHAVIOUR', 'Observed reality (' + format(observed, '.2%') + ' retention)')

    def m(s, mid):
        for x in s['metrics']:
            if x['metric_id'] == mid:
                return x['value']
        return None

    delta = {mid: (None if m(obs, mid) is None or m(base, mid) is None
                   else round(m(obs, mid) - m(base, mid), 4))
             for mid in ('LCR', 'STRESSED_OUTFLOW_30D', 'FUNDING_GAP_90D', 'NII_12M')}
    return {'run_id': run_id, 'assumption_id': p_assumption_id,
            'approved_retention': approved, 'observed_retention': observed,
            'baseline': base, 'observed': obs, 'delta': delta,
            'disclaimer': 'Hackathon POC - illustrative simplified risk calculation.'}
$$;

SELECT 'challenger + impact engine ready' AS STATUS;
