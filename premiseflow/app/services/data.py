"""Read-side data access for PremiseFlow.

Every query is centralised here so pages stay declarative and so caching is
applied consistently. Caches are short-lived: this is a monitoring product and
stale numbers would undermine the whole premise.
"""
from __future__ import annotations

import pandas as pd
import streamlit as st

try:
    from snowflake.snowpark.context import get_active_session
except Exception:  # pragma: no cover - only outside Snowflake
    get_active_session = None


def session():
    # get_active_session() is already a process-wide singleton; caching it in
    # session_state only adds a failure mode.
    return get_active_session()


def q(sql: str, params: list | None = None) -> pd.DataFrame:
    df = session().sql(sql, params=params).to_pandas() if params else session().sql(sql).to_pandas()
    return df


@st.cache_data(ttl=60, show_spinner=False)
def health() -> pd.DataFrame:
    return q("SELECT * FROM PREMISEFLOW.CORE.V_ASSUMPTION_HEALTH")


@st.cache_data(ttl=60, show_spinner=False)
def assumptions() -> pd.DataFrame:
    return q("""
        SELECT ASSUMPTION_ID, NAME, STATEMENT, DOMAIN, OWNER_ROLE, MATERIALITY, STATUS,
               VERSION_NUMBER, VERSION_ID, EXPECTED_VALUE, CHALLENGE_THRESHOLD, BREACH_THRESHOLD,
               PERSISTENCE_DAYS, DIRECTION, LOWER_BOUND, UPPER_BOUND,
               LATEST_OBSERVED_VALUE, LATEST_OBSERVATION_DATE, DEVIATION, DEVIATION_PCT,
               OBSERVED_PERSISTENCE_DAYS, LATEST_CONFIDENCE, CHANGE_POINT_DATE,
               LATEST_EXPLANATION, VALIDITY_ENVELOPE, EVIDENCE_SUMMARY,
               APPROVED_BY, APPROVED_AT, LAST_VALIDATED_AT, METRIC_CODE,
               DIRECT_DEPENDENCY_COUNT, DEPENDENT_DECISION_COUNT
        FROM PREMISEFLOW.CORE.V_ASSUMPTION_CURRENT
        ORDER BY CASE STATUS WHEN 'BREACHED' THEN 1 WHEN 'CHALLENGED' THEN 2
                             WHEN 'UNDER_REVIEW' THEN 3 WHEN 'WATCH' THEN 4 ELSE 5 END,
                 CASE MATERIALITY WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2
                                  WHEN 'MEDIUM' THEN 3 ELSE 4 END, ASSUMPTION_ID""")


@st.cache_data(ttl=60, show_spinner=False)
def assumption(aid: str) -> pd.Series | None:
    df = assumptions()
    hit = df[df["ASSUMPTION_ID"] == aid]
    return None if hit.empty else hit.iloc[0]


@st.cache_data(ttl=60, show_spinner=False)
def observation_series(aid: str) -> pd.DataFrame:
    return q("""
        SELECT OBSERVATION_DATE, OBSERVED_VALUE, SAMPLE_SIZE, WINDOW_DAYS
        FROM PREMISEFLOW.CORE.DT_ASSUMPTION_OBSERVATIONS
        WHERE ASSUMPTION_ID = ? ORDER BY OBSERVATION_DATE""", [aid])


@st.cache_data(ttl=60, show_spinner=False)
def retention_by_dimension(grain: str | None = None) -> pd.DataFrame:
    sql = """
        SELECT OBSERVATION_DATE, GRAIN, DIM_VALUE, RETENTION_RATE, BALANCE_CHANGE, ACCOUNTS,
               CURRENT_BALANCE, WINDOW_START_BALANCE
        FROM PREMISEFLOW.CORE.DT_RETENTION_DAILY
        WHERE OBSERVATION_DATE = (SELECT MAX(OBSERVATION_DATE) FROM PREMISEFLOW.CORE.DT_RETENTION_DAILY)
    """
    if grain:
        sql += " AND GRAIN = ?"
        return q(sql + " ORDER BY RETENTION_RATE", [grain])
    return q(sql + " ORDER BY GRAIN, RETENTION_RATE")


@st.cache_data(ttl=60, show_spinner=False)
def retention_history_by_dimension(grain: str) -> pd.DataFrame:
    return q("""
        SELECT OBSERVATION_DATE, DIM_VALUE, RETENTION_RATE
        FROM PREMISEFLOW.CORE.DT_RETENTION_DAILY
        WHERE GRAIN = ? ORDER BY OBSERVATION_DATE""", [grain])


@st.cache_data(ttl=60, show_spinner=False)
def deposit_masking() -> pd.DataFrame:
    return q("""
        SELECT BALANCE_DATE, BREAK_DATE, IS_POST_BREAK, TOTAL_DEPOSITS, INCUMBENT_DEPOSITS,
               NEW_CUSTOMER_DEPOSITS, PROMOTIONAL_DEPOSITS, GOVERNED_STABLE_DEPOSITS,
               TERM_DEPOSITS, WHOLESALE_LIKE_DEPOSITS, ACTIVE_CUSTOMERS,
               TOTAL_DEPOSIT_GROWTH, GOVERNED_DEPOSIT_GROWTH, PROMOTIONAL_FUNDING_SHARE
        FROM PREMISEFLOW.CORE.V_DEPOSIT_MASKING ORDER BY BALANCE_DATE""")


@st.cache_data(ttl=60, show_spinner=False)
def context_now() -> pd.DataFrame:
    return q("""
        SELECT * FROM PREMISEFLOW.CORE.DT_ASSUMPTION_CONTEXT
        ORDER BY OBSERVATION_DATE DESC LIMIT 1""")


@st.cache_data(ttl=60, show_spinner=False)
def blast_radius(root: str) -> pd.DataFrame:
    return q("""
        SELECT SOURCE_OBJECT, SOURCE_TYPE, TARGET_OBJECT, TARGET_TYPE, RELATIONSHIP_TYPE,
               MATERIALITY, SENSITIVITY_NOTE, DEPTH, PATH
        FROM PREMISEFLOW.CORE.V_BLAST_RADIUS WHERE ROOT_OBJECT = ?
        ORDER BY DEPTH, TARGET_TYPE, TARGET_OBJECT""", [root])


@st.cache_data(ttl=60, show_spinner=False)
def affected_decisions(aid: str | None = None) -> pd.DataFrame:
    sql = """
        SELECT ASSUMPTION_ID, RELIED_ON_VERSION_ID, RELIANCE_STRENGTH, RELIANCE_NOTE,
               DECISION_ID, DECISION_REF, TITLE, COMMITTEE, DECISION_DATE, DECISION_TEXT,
               RATIONALE, APPROVED_BY, MATERIALITY, GOVERNANCE_STATUS, STATUS_CHANGED_AT,
               SOURCE_DOCUMENT, REASSESSMENT_ID, REASSESSMENT_STATUS, TRIGGERED_AT,
               IMPACT_SUMMARY, AI_RECOMMENDATION
        FROM PREMISEFLOW.CORE.V_AFFECTED_DECISIONS"""
    if aid:
        return q(sql + " WHERE ASSUMPTION_ID = ? ORDER BY DECISION_REF", [aid])
    return q(sql + " ORDER BY DECISION_REF")


@st.cache_data(ttl=60, show_spinner=False)
def decisions() -> pd.DataFrame:
    return q("""
        SELECT DECISION_ID, DECISION_REF, TITLE, COMMITTEE, DECISION_DATE, DECISION_TEXT,
               RATIONALE, APPROVED_BY, MATERIALITY, GOVERNANCE_STATUS, STATUS_CHANGED_AT
        FROM PREMISEFLOW.CORE.DECISIONS ORDER BY DECISION_REF""")


@st.cache_data(ttl=30, show_spinner=False)
def scenario_comparison(aid: str) -> pd.DataFrame:
    return q("""
        SELECT SCENARIO_ID, SCENARIO_TYPE, SCENARIO_NAME, RETENTION_INPUT, CREATED_AT, CREATED_BY,
               METRIC_ID, METRIC_NAME, METRIC_VALUE, UNIT, FORMULA, BREACHES_LIMIT,
               INTERNAL_LIMIT, REGULATORY_MIN, INPUTS
        FROM PREMISEFLOW.CORE.V_SCENARIO_COMPARISON WHERE ASSUMPTION_ID = ?
        ORDER BY CREATED_AT DESC""", [aid])


@st.cache_data(ttl=30, show_spinner=False)
def reassessments() -> pd.DataFrame:
    return q("""
        SELECT r.REASSESSMENT_ID, r.DECISION_ID, r.ASSUMPTION_ID, r.BREACH_ID, r.TRIGGERED_AT,
               r.TRIGGER_REASON, r.ORIGINAL_VERSION_ID, r.OBSERVED_VALUE, r.APPROVED_VALUE,
               r.IMPACT_SUMMARY, r.MATERIALITY, r.AI_RECOMMENDATION, r.STATUS,
               r.RESOLVED_BY, r.RESOLVED_AT, r.RESOLUTION_NOTE,
               d.DECISION_REF, d.TITLE, d.DECISION_TEXT, d.RATIONALE, d.DECISION_DATE,
               d.APPROVED_BY, d.GOVERNANCE_STATUS
        FROM PREMISEFLOW.CORE.REASSESSMENTS r
        JOIN PREMISEFLOW.CORE.DECISIONS d ON d.DECISION_ID = r.DECISION_ID
        ORDER BY r.TRIGGERED_AT DESC""")


@st.cache_data(ttl=60, show_spinner=False)
def versions(aid: str) -> pd.DataFrame:
    return q("""
        SELECT VERSION_ID, VERSION_NUMBER, STATEMENT, EXPECTED_VALUE, CHALLENGE_THRESHOLD,
               BREACH_THRESHOLD, PERSISTENCE_DAYS, DIRECTION, APPROVAL_STATUS, APPROVED_BY,
               APPROVED_AT, PROPOSED_BY, PROPOSED_AT, VALID_FROM, VALID_TO, IS_CURRENT,
               SUPERSEDES_VERSION_ID, EVIDENCE_SUMMARY, VALIDITY_ENVELOPE
        FROM PREMISEFLOW.CORE.ASSUMPTION_VERSIONS
        WHERE ASSUMPTION_ID = ? ORDER BY VERSION_NUMBER""", [aid])


@st.cache_data(ttl=60, show_spinner=False)
def evidence(aid: str) -> pd.DataFrame:
    return q("""
        SELECT EVIDENCE_ID, VERSION_ID, EVIDENCE_TYPE, SOURCE_REF, SOURCE_DOCUMENT,
               OBSERVED_VALUE, SAMPLE_SIZE, PERIOD_START, PERIOD_END, SUMMARY
        FROM PREMISEFLOW.CORE.ASSUMPTION_EVIDENCE WHERE ASSUMPTION_ID = ?
        ORDER BY EVIDENCE_ID""", [aid])


@st.cache_data(ttl=60, show_spinner=False)
def documents_for(aid: str) -> pd.DataFrame:
    return q("""
        SELECT DOC_TITLE, DOC_REFERENCE, DOC_CATEGORY, SECTION, RELATIVE_PATH, CHUNK_TEXT
        FROM PREMISEFLOW.AI.V_ASSUMPTION_DOCUMENTS WHERE ASSUMPTION_ID = ?
        ORDER BY DOC_CATEGORY, SECTION""", [aid])


@st.cache_data(ttl=30, show_spinner=False)
def challenges(aid: str) -> pd.DataFrame:
    return q("""
        SELECT CHALLENGE_ID, RUN_ID, EVALUATED_AT, OBSERVATION_DATE, OBSERVED_VALUE,
               EXPECTED_VALUE, DEVIATION, DEVIATION_PCT, PERSISTENCE_DAYS, CONFIDENCE,
               ROBUST_Z, CHANGE_POINT_DATE, STATUS, METHOD, EXPLANATION, AFFECTED_SEGMENTS
        FROM PREMISEFLOW.CORE.ASSUMPTION_CHALLENGES WHERE ASSUMPTION_ID = ?
        ORDER BY EVALUATED_AT DESC""", [aid])


@st.cache_data(ttl=30, show_spinner=False)
def breaches(aid: str | None = None) -> pd.DataFrame:
    sql = """
        SELECT BREACH_ID, ASSUMPTION_ID, VERSION_ID, CHALLENGE_ID, DETECTED_AT, FIRST_BREACH_DATE,
               OBSERVED_VALUE, EXPECTED_VALUE, PERSISTENCE_DAYS, SEVERITY, CONFIRMATION_STATUS,
               CONFIRMED_BY, CONFIRMED_AT, ROOT_CAUSE_SUMMARY
        FROM PREMISEFLOW.CORE.ASSUMPTION_BREACHES"""
    if aid:
        return q(sql + " WHERE ASSUMPTION_ID = ? ORDER BY DETECTED_AT DESC", [aid])
    return q(sql + " ORDER BY DETECTED_AT DESC")


@st.cache_data(ttl=30, show_spinner=False)
def audit_timeline(object_id: str | None = None, limit: int = 400) -> pd.DataFrame:
    if object_id:
        return q("""
            SELECT EVENT_TS, EVENT_TYPE, OBJECT_TYPE, OBJECT_ID, ACTOR_TYPE, ACTOR_ID,
                   OLD_STATE, NEW_STATE, EVIDENCE_REFERENCE, RUN_ID, RATIONALE
            FROM PREMISEFLOW.AUDIT.V_AUDIT_TIMELINE
            WHERE OBJECT_ID = ? ORDER BY EVENT_TS DESC LIMIT ?""", [object_id, limit])
    return q("""
        SELECT EVENT_TS, EVENT_TYPE, OBJECT_TYPE, OBJECT_ID, ACTOR_TYPE, ACTOR_ID,
               OLD_STATE, NEW_STATE, EVIDENCE_REFERENCE, RUN_ID, RATIONALE
        FROM PREMISEFLOW.AUDIT.V_AUDIT_TIMELINE ORDER BY EVENT_TS DESC LIMIT ?""", [limit])


@st.cache_data(ttl=30, show_spinner=False)
def human_actions() -> pd.DataFrame:
    return q("""
        SELECT ACTION_TS, ACTION_TYPE, OBJECT_TYPE, OBJECT_ID, ACTOR_ID, ACTOR_ROLE, DECISION, NOTE
        FROM PREMISEFLOW.AUDIT.HUMAN_ACTIONS ORDER BY ACTION_TS DESC LIMIT 200""")


@st.cache_data(ttl=30, show_spinner=False)
def agent_runs() -> pd.DataFrame:
    return q("""
        SELECT RUN_ID, RUN_TYPE, STARTED_AT, FINISHED_AT, STATUS, TRIGGERED_BY, MODEL_NAME,
               WORKFLOW_VERSION, INPUT_SUMMARY, OUTPUT_SUMMARY, ERROR_MESSAGE
        FROM PREMISEFLOW.AUDIT.AGENT_RUNS ORDER BY STARTED_AT DESC LIMIT 100""")


@st.cache_data(ttl=30, show_spinner=False)
def outbox() -> pd.DataFrame:
    return q("""
        SELECT ACTION_ID, ACTION_TYPE, TARGET_SYSTEM, STATUS, CREATED_AT, PROCESSED_AT,
               EXTERNAL_ID, DEDUPE_KEY, PAYLOAD
        FROM PREMISEFLOW.CORE.ACTION_OUTBOX ORDER BY CREATED_AT DESC""")


@st.cache_data(ttl=30, show_spinner=False)
def integration_actions() -> pd.DataFrame:
    return q("""
        SELECT CREATED_AT, TARGET_SYSTEM, ACTION_TYPE, OBJECT_TYPE, OBJECT_ID, STATUS,
               EXTERNAL_ID, EXTERNAL_URL, NOTE
        FROM PREMISEFLOW.AUDIT.INTEGRATION_ACTIONS ORDER BY CREATED_AT DESC""")


@st.cache_data(ttl=300, show_spinner=False)
def liquidity_inputs() -> pd.DataFrame:
    return q("SELECT * FROM PREMISEFLOW.CORE.LIQUIDITY_INPUTS ORDER BY AS_OF_DATE DESC LIMIT 1")


@st.cache_data(ttl=300, show_spinner=False)
def sim_parameters() -> pd.DataFrame:
    return q("SELECT PARAM_KEY, PARAM_VALUE, DESCRIPTION FROM PREMISEFLOW.CORE.SIM_PARAMETERS")


@st.cache_data(ttl=300, show_spinner=False)
def verified_queries() -> pd.DataFrame:
    return q("SELECT VQ_ID, QUESTION, SQL_TEXT, NOTES FROM PREMISEFLOW.AI.VERIFIED_QUERIES ORDER BY VQ_ID")


@st.cache_data(ttl=300, show_spinner=False)
def ground_truth() -> pd.DataFrame:
    return q("SELECT * FROM PREMISEFLOW.RAW.RAW_GROUND_TRUTH")


@st.cache_data(ttl=300, show_spinner=False)
def gen_config() -> pd.DataFrame:
    return q("SELECT * FROM PREMISEFLOW.RAW.V_GEN_CONFIG")


def doc_search(query: str, limit: int = 5) -> pd.DataFrame:
    """Cortex Search over the synthetic governance corpus."""
    import json
    payload = json.dumps({
        "query": query,
        "columns": ["CHUNK_TEXT", "DOC_TITLE", "DOC_REFERENCE", "SECTION", "RELATIVE_PATH"],
        "limit": limit,
    })
    raw = session().sql(
        "SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW('PREMISEFLOW.AI.PREMISEFLOW_DOC_SEARCH', ?) AS R",
        params=[payload],
    ).collect()[0]["R"]
    return pd.DataFrame(json.loads(raw).get("results", []))


def clear_caches() -> None:
    st.cache_data.clear()
