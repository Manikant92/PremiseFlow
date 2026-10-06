-- PremiseFlow :: 17_assumption_miner.sql
-- Extracts CANDIDATE assumption contracts from the governance document corpus.
--
-- Candidates are never promoted automatically. They land in
-- CORE.CANDIDATE_ASSUMPTIONS with status PROPOSED_BY_MINER and must be promoted
-- by a human, which is the same governance boundary applied everywhere else.

USE DATABASE PREMISEFLOW;
USE SCHEMA CORE;

CREATE TABLE IF NOT EXISTS CORE.CANDIDATE_ASSUMPTIONS (
  CANDIDATE_ID      STRING,
  RUN_ID            STRING,
  SOURCE_DOCUMENT   STRING,
  SOURCE_REFERENCE  STRING,
  SOURCE_SECTION    STRING,
  CHUNK_ID          STRING,
  QUOTED_TEXT       STRING,
  PROPOSED_NAME     STRING,
  PROPOSED_STATEMENT STRING,
  PROPOSED_DOMAIN   STRING,
  PROPOSED_METRIC   STRING,
  PROPOSED_EXPECTED_VALUE FLOAT,
  PROPOSED_DIRECTION STRING,
  PROPOSED_MATERIALITY STRING,
  PROPOSED_OWNER_ROLE STRING,
  VALIDITY_CONDITIONS STRING,
  IS_QUANTIFIED     BOOLEAN,
  MATCHES_EXISTING  STRING,
  CONFIDENCE        FLOAT,
  STATUS            STRING,   -- PROPOSED_BY_MINER | PROMOTED | REJECTED | DUPLICATE
  REVIEWED_BY       STRING,
  REVIEWED_AT       TIMESTAMP_NTZ,
  CREATED_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE APP.MINE_ASSUMPTIONS(P_QUERY STRING, P_LIMIT FLOAT, P_ACTOR STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json, uuid

MODEL = 'claude-sonnet-4-5'
PROMPT_VERSION = 'miner-v1.1'

def lit(v):
    if v is None: return 'NULL'
    if isinstance(v, bool): return 'TRUE' if v else 'FALSE'
    if isinstance(v, (int, float)): return repr(v)
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"

SCHEMA_HINT = """
Return STRICT JSON only, no prose, no markdown fence. Shape:
{"candidates":[{
  "name": "short title, max 60 chars",
  "statement": "one sentence of what must remain true, quantified if the text quantifies it",
  "domain": "LIQUIDITY|IRRBB|CREDIT|MARKET|CAPITAL|OPERATIONAL",
  "metric_code": "UPPER_SNAKE_CASE measurable metric name",
  "expected_value": 0.9,
  "direction": "LOWER_IS_WORSE|UPPER_IS_WORSE|TWO_SIDED",
  "materiality": "CRITICAL|HIGH|MEDIUM|LOW",
  "owner_role": "team accountable, if stated in the text, else null",
  "validity_conditions": "conditions the text says must hold, else null",
  "is_quantified": true,
  "quoted_text": "the exact sentence from the source that carries the assumption",
  "confidence": 0.0
}]}
Rules:
- Only extract statements that assert something must REMAIN TRUE for a calculation,
  model or decision to stay valid. Do not extract definitions, process steps,
  responsibilities or governance boilerplate.
- expected_value must be a number when the text quantifies a threshold, else null.
  Express percentages as decimals (90% -> 0.9).
- quoted_text must be copied verbatim from the provided source.
- If nothing qualifies, return {"candidates":[]}.
"""

def _coerce_json(raw):
    """AI_COMPLETE returns its text JSON-encoded, so the payload typically arrives
    as a quoted string wrapping a markdown-fenced JSON document. Unwrap the
    layers in the right order -- outer string first, then fence, then any prose
    around the object -- because stripping the fence first leaves backslash-
    escaped quotes that will not parse."""
    body = raw
    for _ in range(5):
        if not isinstance(body, str):
            break
        s = body.strip()
        if not s:
            raise ValueError('empty model response')
        if s[0] == '"':                              # JSON-encoded string wrapper
            body = json.loads(s)
            continue
        if s.startswith('```'):                      # markdown fence
            parts = s.split('```')
            s = parts[1] if len(parts) > 1 else s
            if s.lstrip().lower().startswith('json'):
                s = s.lstrip()[4:]
            body = s.strip()
            continue
        if not s.startswith('{') and '{' in s and '}' in s:   # prose around the object
            body = s[s.index('{'): s.rindex('}') + 1]
            continue
        return json.loads(s)
    if isinstance(body, str):
        return json.loads(body)
    return body


def run(session, p_query, p_limit, p_actor):
    run_id = 'RUN-' + uuid.uuid4().hex[:16]
    limit = int(p_limit or 8)
    query = p_query or ('assumption that must remain true threshold retention rate ceiling '
                        'behavioural stability condition of validity')

    session.sql(f"""INSERT INTO AUDIT.AGENT_RUNS
        (RUN_ID, RUN_TYPE, STARTED_AT, STATUS, TRIGGERED_BY, MODEL_NAME, WORKFLOW_VERSION,
         PROMPT_REF, INPUT_SUMMARY)
        SELECT {lit(run_id)},'MINER',CURRENT_TIMESTAMP(),'RUNNING',{lit(p_actor or 'SYSTEM')},
               {lit(MODEL)},{lit(PROMPT_VERSION)},{lit(PROMPT_VERSION)},{lit(query[:1000])}""").collect()

    payload = json.dumps({'query': query,
                          'columns': ['CHUNK_TEXT','DOC_TITLE','DOC_REFERENCE','SECTION',
                                      'RELATIVE_PATH','CHUNK_ID'],
                          'limit': limit})
    raw = session.sql("""SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            'PREMISEFLOW.AI.PREMISEFLOW_DOC_SEARCH', ?) AS R""", params=[payload]).collect()[0]['R']
    hits = json.loads(raw).get('results', [])

    existing = {r['METRIC_CODE']: r['ASSUMPTION_ID'] for r in session.sql(
        "SELECT ASSUMPTION_ID, METRIC_CODE FROM CORE.ASSUMPTIONS").collect()}
    existing_statements = {r['ASSUMPTION_ID']: (r['STATEMENT'] or '').lower() for r in session.sql(
        "SELECT ASSUMPTION_ID, STATEMENT FROM CORE.ASSUMPTIONS").collect()}

    session.sql(f"DELETE FROM CORE.CANDIDATE_ASSUMPTIONS WHERE STATUS='PROPOSED_BY_MINER'").collect()

    mined, errors = [], []
    for h in hits:
        text = h.get('CHUNK_TEXT') or ''
        if len(text.strip()) < 120:
            continue
        prompt = (f"You extract governed assumptions from bank risk documentation.\n{SCHEMA_HINT}\n"
                  f"SOURCE DOCUMENT: {h.get('DOC_TITLE')} ({h.get('DOC_REFERENCE')}), "
                  f"section: {h.get('SECTION')}\n\nSOURCE TEXT:\n{text[:5000]}\n")
        try:
            out = session.sql(f"SELECT AI_COMPLETE({lit(MODEL)}, {lit(prompt)})::STRING AS A").collect()[0]['A']
            try:
                parsed = _coerce_json(out)
            except Exception as pe:
                raise ValueError(f'{pe} | raw[:300]={str(out)[:300]!r}')
            if not isinstance(parsed, dict):
                raise ValueError(f'expected a JSON object, got {type(parsed).__name__}')
        except Exception as e:
            errors.append({'chunk': h.get('CHUNK_ID'), 'error': str(e)[:600]})
            continue

        cands = parsed.get('candidates') or []
        if not isinstance(cands, list):
            errors.append({'chunk': h.get('CHUNK_ID'), 'error': 'candidates was not a list'})
            continue
        for c in cands:
            if not isinstance(c, dict):
                continue
            metric = (c.get('metric_code') or '').upper().replace(' ', '_')
            stmt = c.get('statement') or ''
            match = existing.get(metric)
            if not match:
                # crude duplicate check on distinctive wording
                for aid, es in existing_statements.items():
                    if es and stmt and len(set(es.split()) & set(stmt.lower().split())) > 9:
                        match = aid
                        break
            cid = 'CND-' + uuid.uuid4().hex[:12]
            session.sql(f"""INSERT INTO CORE.CANDIDATE_ASSUMPTIONS
                (CANDIDATE_ID, RUN_ID, SOURCE_DOCUMENT, SOURCE_REFERENCE, SOURCE_SECTION, CHUNK_ID,
                 QUOTED_TEXT, PROPOSED_NAME, PROPOSED_STATEMENT, PROPOSED_DOMAIN, PROPOSED_METRIC,
                 PROPOSED_EXPECTED_VALUE, PROPOSED_DIRECTION, PROPOSED_MATERIALITY,
                 PROPOSED_OWNER_ROLE, VALIDITY_CONDITIONS, IS_QUANTIFIED, MATCHES_EXISTING,
                 CONFIDENCE, STATUS)
                SELECT {lit(cid)},{lit(run_id)},{lit(h.get('RELATIVE_PATH'))},
                       {lit(h.get('DOC_REFERENCE'))},{lit(h.get('SECTION'))},{lit(h.get('CHUNK_ID'))},
                       {lit((c.get('quoted_text') or '')[:2000])},{lit((c.get('name') or '')[:200])},
                       {lit(stmt[:2000])},{lit(c.get('domain'))},{lit(metric)},
                       {lit(c.get('expected_value'))},{lit(c.get('direction'))},
                       {lit(c.get('materiality'))},{lit(c.get('owner_role'))},
                       {lit((c.get('validity_conditions') or '')[:1500] or None)},
                       {lit(bool(c.get('is_quantified')))},{lit(match)},
                       {lit(c.get('confidence'))},'PROPOSED_BY_MINER'""").collect()
            mined.append({'candidate_id': cid, 'name': c.get('name'), 'metric_code': metric,
                          'expected_value': c.get('expected_value'),
                          'is_quantified': bool(c.get('is_quantified')),
                          'matches_existing': match,
                          'source': f"{h.get('DOC_REFERENCE')} / {h.get('SECTION')}"})

    new_count = sum(1 for m in mined if not m['matches_existing'])
    summary = {'run_id': run_id, 'documents_searched': len(hits), 'candidates': len(mined),
               'new_candidates': new_count,
               'already_governed': len(mined) - new_count,
               'errors': errors,
               'results': mined,
               'note': 'Candidates are PROPOSED_BY_MINER only. Promotion to the governed registry '
                       'requires a human action; the miner cannot create a governed assumption.'}
    session.sql(f"""UPDATE AUDIT.AGENT_RUNS SET FINISHED_AT=CURRENT_TIMESTAMP(), STATUS='SUCCESS',
        OUTPUT_SUMMARY={lit(json.dumps({k: summary[k] for k in
            ('documents_searched','candidates','new_candidates','already_governed')}))}
        WHERE RUN_ID={lit(run_id)}""").collect()
    session.sql(f"""CALL AUDIT.LOG_EVENT('ASSUMPTIONS_MINED','DOCUMENT_CORPUS','PREMISEFLOW.AI.DOCS',
        'AGENT',{lit(MODEL)},NULL,NULL,NULL,{lit(run_id)},
        {lit('Mined ' + str(len(mined)) + ' candidate assumptions; ' + str(new_count) + ' not already governed.')},
        NULL)""").collect()
    return summary
$$;

CREATE OR REPLACE VIEW CORE.V_CANDIDATE_ASSUMPTIONS AS
SELECT CANDIDATE_ID, PROPOSED_NAME, PROPOSED_STATEMENT, PROPOSED_DOMAIN, PROPOSED_METRIC,
       PROPOSED_EXPECTED_VALUE, PROPOSED_DIRECTION, PROPOSED_MATERIALITY, PROPOSED_OWNER_ROLE,
       VALIDITY_CONDITIONS, IS_QUANTIFIED,
       MATCHES_EXISTING,
       IFF(MATCHES_EXISTING IS NULL, 'NEW', 'ALREADY_GOVERNED') AS NOVELTY,
       CONFIDENCE, STATUS, SOURCE_REFERENCE, SOURCE_SECTION, SOURCE_DOCUMENT, QUOTED_TEXT, CREATED_AT
FROM CORE.CANDIDATE_ASSUMPTIONS
ORDER BY IFF(MATCHES_EXISTING IS NULL, 0, 1), CONFIDENCE DESC NULLS LAST;

GRANT SELECT ON TABLE CORE.CANDIDATE_ASSUMPTIONS TO ROLE PREMISEFLOW_VIEWER;
GRANT SELECT ON VIEW CORE.V_CANDIDATE_ASSUMPTIONS TO ROLE PREMISEFLOW_VIEWER;
GRANT USAGE ON PROCEDURE APP.MINE_ASSUMPTIONS(STRING, FLOAT, STRING) TO ROLE PREMISEFLOW_ANALYST;

SELECT 'assumption miner ready' AS STATUS;
