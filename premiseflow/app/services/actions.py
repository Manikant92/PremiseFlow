"""Write-side actions for PremiseFlow.

Every state change goes through a Snowflake stored procedure. The app never
writes to a governed table directly, so the audit trail and the human-actor
guard cannot be bypassed from the UI.
"""
from __future__ import annotations

import json

from .data import session, clear_caches


def _call(proc: str, *args):
    placeholders = ", ".join("?" for _ in args)
    sql = f"CALL {proc}({placeholders})" if args else f"CALL {proc}()"
    rows = session().sql(sql, params=list(args)).collect()
    clear_caches()
    if not rows:
        return None
    val = rows[0][0]
    if isinstance(val, str):
        try:
            return json.loads(val)
        except (ValueError, TypeError):
            return val
    return val


# ---- monitoring -----------------------------------------------------------
def run_challenger(assumption_id: str | None = None, as_of=None, actor: str = "app_user"):
    return _call("PREMISEFLOW.APP.RUN_CHALLENGER", assumption_id, actor, as_of)


def explain_challenge(assumption_id: str, actor: str = "app_user"):
    return _call("PREMISEFLOW.APP.EXPLAIN_CHALLENGE", assumption_id, actor)


def monitoring_cycle():
    return _call("PREMISEFLOW.APP.MONITORING_CYCLE")


# ---- impact ---------------------------------------------------------------
def run_impact_for_assumption(assumption_id: str, actor: str = "app_user"):
    return _call("PREMISEFLOW.APP.RUN_IMPACT_FOR_ASSUMPTION", assumption_id, actor)


def run_scenario(assumption_id: str, retention: float, scenario_type: str,
                 name: str, actor: str = "app_user", run_id: str | None = None):
    return _call("PREMISEFLOW.APP.RUN_IMPACT_SIMULATION", assumption_id, float(retention),
                 scenario_type, name, actor, run_id)


# ---- human governance ----------------------------------------------------
def confirm_breach(breach_id: str, actor_id: str, actor_role: str, note: str):
    return _call("PREMISEFLOW.APP.CONFIRM_BREACH", breach_id, "HUMAN", actor_id, actor_role, note)


def dismiss_challenge(assumption_id: str, actor_id: str, actor_role: str, note: str):
    return _call("PREMISEFLOW.APP.DISMISS_CHALLENGE", assumption_id, "HUMAN", actor_id, actor_role, note)


def request_more_evidence(assumption_id: str, actor_id: str, actor_role: str, note: str):
    return _call("PREMISEFLOW.APP.REQUEST_MORE_EVIDENCE", assumption_id, "HUMAN", actor_id, actor_role, note)


def propose_new_version(assumption_id: str, statement: str, expected: float, challenge: float,
                        breach: float, lower: float, upper: float, persistence: int,
                        evidence_summary: str, actor_id: str, rationale: str):
    return _call("PREMISEFLOW.APP.PROPOSE_NEW_VERSION", assumption_id, statement,
                 float(expected), float(challenge), float(breach), float(lower), float(upper),
                 float(persistence), evidence_summary, actor_id, rationale)


def approve_new_version(version_id: str, actor_id: str, actor_role: str, note: str):
    return _call("PREMISEFLOW.APP.APPROVE_NEW_VERSION", version_id, "HUMAN", actor_id, actor_role, note)


def reject_new_version(version_id: str, actor_id: str, actor_role: str, note: str):
    return _call("PREMISEFLOW.APP.REJECT_NEW_VERSION", version_id, "HUMAN", actor_id, actor_role, note)


def resolve_reassessment(reassessment_id: str, resolution: str, actor_id: str,
                         actor_role: str, note: str):
    return _call("PREMISEFLOW.APP.RESOLVE_REASSESSMENT", reassessment_id, resolution,
                 "HUMAN", actor_id, actor_role, note)


# ---- Q&A ------------------------------------------------------------------
def ask(question: str, actor: str = "app_user"):
    return _call("PREMISEFLOW.APP.ASK_PREMISEFLOW", question, actor)


# ---- demo -----------------------------------------------------------------
def reset_demo():
    return _call("PREMISEFLOW.APP.RESET_DEMO")


def run_demo(actor: str):
    return _call("PREMISEFLOW.APP.RUN_DEMO", actor)
