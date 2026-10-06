"""Page 8 - Audit Trail."""
from __future__ import annotations

import pandas as pd
import streamlit as st

from components import ui
from services import data

STAGE_LABEL = {
    "ASSUMPTION_CREATED": "Assumption created",
    "EVIDENCE_ATTACHED": "Evidence attached",
    "VERSION_APPROVED": "Version approved",
    "OBSERVATION_GENERATED": "Observation generated",
    "STATUS_CHANGED": "Status changed",
    "CHALLENGE_DETECTED": "Challenge detected",
    "CHALLENGE_DISMISSED": "Challenge dismissed",
    "MORE_EVIDENCE_REQUESTED": "More evidence requested",
    "BREACH_DETECTED": "Breach detected",
    "BREACH_CONFIRMED": "Breach confirmed by human",
    "AI_EXPLANATION_GENERATED": "AI explanation generated",
    "IMPACT_SIMULATED": "Impact simulated",
    "DECISION_REOPENED": "Decision reopened",
    "NEW_VERSION_PROPOSED": "New version proposed",
    "NEW_VERSION_APPROVED": "New version approved",
    "NEW_VERSION_REJECTED": "New version rejected",
    "REASSESSMENT_RESOLVED": "Reassessment resolved",
    "DEMO_RESET": "Demo reset",
}
ACTOR_COLOUR = {"HUMAN": "#0B6B4F", "AGENT": "#4B3A8F", "SYSTEM": "#1F5FA8", "TASK": "#8A5B00"}


def render() -> None:
    ui.masthead("Audit Trail")
    st.caption("Append-only event history. Nothing material happens in PremiseFlow without an event, "
               "and audit history survives a demo reset.")

    ev = data.audit_timeline(None, 600)
    ha = data.human_actions()
    ar = data.agent_runs()
    ia = data.integration_actions()

    k = st.columns(5)
    with k[0]: ui.kpi("Events", f"{len(ev)}", "audit records")
    with k[1]: ui.kpi("Human actions", f"{len(ha)}", "governed decisions")
    with k[2]: ui.kpi("Automated runs", f"{len(ar)}", "challenger / AI / impact")
    with k[3]: ui.kpi("Integration actions", f"{len(ia)}", "external systems")
    with k[4]:
        breach_confirms = int((ev.EVENT_TYPE == "BREACH_CONFIRMED").sum()) if not ev.empty else 0
        ui.kpi("Breaches confirmed", f"{breach_confirms}", "by a human actor")

    tabs = st.tabs(["Event timeline", "Human actions", "Automated runs", "Integration actions",
                    "Lifecycle view"])

    with tabs[0]:
        if ev.empty:
            st.info("No events recorded.")
        else:
            f = st.columns(4)
            types = ["All"] + sorted(ev.EVENT_TYPE.unique().tolist())
            actors = ["All"] + sorted(ev.ACTOR_TYPE.dropna().unique().tolist())
            objs = ["All"] + sorted(ev.OBJECT_TYPE.dropna().unique().tolist())
            t = f[0].selectbox("Event type", types)
            at = f[1].selectbox("Actor type", actors)
            ot = f[2].selectbox("Object type", objs)
            oid = f[3].text_input("Object id contains", "")

            v = ev.copy()
            if t != "All": v = v[v.EVENT_TYPE == t]
            if at != "All": v = v[v.ACTOR_TYPE == at]
            if ot != "All": v = v[v.OBJECT_TYPE == ot]
            if oid: v = v[v.OBJECT_ID.astype(str).str.contains(oid, case=False, na=False)]

            v = v.copy()
            v["Event"] = v.EVENT_TYPE.map(STAGE_LABEL).fillna(v.EVENT_TYPE)
            st.dataframe(
                v[["EVENT_TS", "Event", "OBJECT_TYPE", "OBJECT_ID", "ACTOR_TYPE", "ACTOR_ID",
                   "OLD_STATE", "NEW_STATE", "EVIDENCE_REFERENCE", "RUN_ID", "RATIONALE"]].rename(
                    columns={"EVENT_TS": "When", "OBJECT_TYPE": "Object type", "OBJECT_ID": "Object",
                             "ACTOR_TYPE": "Actor type", "ACTOR_ID": "Actor",
                             "OLD_STATE": "From", "NEW_STATE": "To",
                             "EVIDENCE_REFERENCE": "Evidence", "RUN_ID": "Run",
                             "RATIONALE": "Rationale"}),
                use_container_width=True, hide_index=True, height=460)

            st.markdown("### Who did what")
            by_actor = ev.groupby("ACTOR_TYPE").size().reset_index(name="events")
            st.bar_chart(by_actor.set_index("ACTOR_TYPE"))
            st.caption("Detection and narration are automated. Confirmation and approval are human. "
                       "That split is the governance control, and it is visible here.")

    with tabs[1]:
        if ha.empty:
            st.info("No human governance actions yet.")
        else:
            st.dataframe(ha, use_container_width=True, hide_index=True)
            st.caption("Only these action types can change governed state: CONFIRM_BREACH, "
                       "DISMISS_CHALLENGE, REQUEST_MORE_EVIDENCE, PROPOSE_NEW_ASSUMPTION, "
                       "APPROVE_NEW_VERSION, REJECT_NEW_VERSION, RESOLVE_REASSESSMENT.")

    with tabs[2]:
        if ar.empty:
            st.info("No automated runs recorded.")
        else:
            st.dataframe(
                ar[["STARTED_AT", "RUN_TYPE", "STATUS", "TRIGGERED_BY", "MODEL_NAME",
                    "WORKFLOW_VERSION", "INPUT_SUMMARY", "ERROR_MESSAGE"]],
                use_container_width=True, hide_index=True, height=340)
            st.caption("AI-generated content records the model name, workflow/prompt version, "
                       "timestamp and evidence references, so a narrative can always be traced "
                       "back to what produced it.")
            pick = st.selectbox("Inspect run output", ar.RUN_ID.tolist())
            r = ar[ar.RUN_ID == pick].iloc[0]
            if r.OUTPUT_SUMMARY:
                st.markdown(f'<div class="pf-quote">{str(r.OUTPUT_SUMMARY)[:4000]}</div>',
                            unsafe_allow_html=True)

    with tabs[3]:
        if ia.empty:
            st.info("No integration actions.")
        else:
            st.dataframe(ia, use_container_width=True, hide_index=True)
        ob = data.outbox()
        st.markdown("### Action outbox")
        if ob.empty:
            st.info("Outbox empty.")
        else:
            st.dataframe(ob[["CREATED_AT", "TARGET_SYSTEM", "ACTION_TYPE", "STATUS",
                             "EXTERNAL_ID", "DEDUPE_KEY"]],
                         use_container_width=True, hide_index=True)
            pick = st.selectbox("Inspect payload", ob.ACTION_ID.tolist())
            st.json(ob[ob.ACTION_ID == pick].iloc[0].PAYLOAD)
            st.caption("No Jira or Slack MCP connector is configured in this account, so actions are "
                       "queued here rather than silently dropped. See MCP_SETUP.md to wire a real "
                       "target system; APP.MARK_OUTBOX_SENT records the external id once delivered.")

    with tabs[4]:
        st.markdown("### The lifecycle, evidenced")
        ui.lifecycle_strip()
        if ev.empty:
            st.info("No events.")
        else:
            order = ["ASSUMPTION_CREATED", "EVIDENCE_ATTACHED", "VERSION_APPROVED",
                     "OBSERVATION_GENERATED", "CHALLENGE_DETECTED", "BREACH_DETECTED",
                     "AI_EXPLANATION_GENERATED", "BREACH_CONFIRMED", "IMPACT_SIMULATED",
                     "DECISION_REOPENED", "NEW_VERSION_PROPOSED", "NEW_VERSION_APPROVED"]
            rows = []
            for et in order:
                sub = ev[ev.EVENT_TYPE == et]
                rows.append({
                    "Stage": STAGE_LABEL.get(et, et),
                    "Events": len(sub),
                    "First": sub.EVENT_TS.min() if not sub.empty else None,
                    "Latest": sub.EVENT_TS.max() if not sub.empty else None,
                    "Actors": ", ".join(sorted(sub.ACTOR_TYPE.dropna().unique().tolist())) if not sub.empty else "-",
                })
            st.dataframe(pd.DataFrame(rows), use_container_width=True, hide_index=True)
            st.caption("A stage with zero events has not happened yet. The demo advances these in order.")
