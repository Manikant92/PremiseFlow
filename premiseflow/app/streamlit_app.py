"""PremiseFlow - Continuous Assumption Intelligence.

Streamlit in Snowflake entrypoint. Navigation is an explicit sidebar router
rather than Streamlit's automatic multipage discovery: the eight page modules
live in `views/` so that adding a `pages/` directory does not produce a second,
competing navigation control alongside this one.

Synthetic data / illustrative risk calculations for hackathon demonstration.
"""
from __future__ import annotations

import sys
from pathlib import Path

import streamlit as st

st.set_page_config(page_title="PremiseFlow", page_icon="◈", layout="wide",
                   initial_sidebar_state="expanded")

# Make sibling packages importable when running from a Snowflake stage.
sys.path.insert(0, str(Path(__file__).parent))

from components import compat                                # noqa: E402,F401  (must load before views)
from components import ui                                    # noqa: E402
from services import data, actions                           # noqa: E402
from views import (p1_radar, p2_registry, p3_detail, p4_evidence,   # noqa: E402
                   p5_impact, p6_scenario, p7_reassessment, p8_audit)

PAGES = {
    "Executive Risk Radar":   p1_radar.render,
    "Assumption Registry":    p2_registry.render,
    "Assumption Detail":      p3_detail.render,
    "Evidence & Investigation": p4_evidence.render,
    "Impact Graph":           p5_impact.render,
    "Scenario Simulator":     p6_scenario.render,
    "Decision Reassessment":  p7_reassessment.render,
    "Audit Trail":            p8_audit.render,
}

ui.inject_theme()

st.session_state.setdefault("nav", "Executive Risk Radar")
st.session_state.setdefault("selected_assumption", "A-DEP-001")
st.session_state.setdefault("actor_id", "manikant.kella")
st.session_state.setdefault("actor_role", "Head of Treasury Risk")

with st.sidebar:
    st.markdown("### ◈ PremiseFlow")
    st.caption("Continuous Assumption Intelligence")

    choice = st.radio("Navigate", list(PAGES.keys()),
                      index=list(PAGES.keys()).index(st.session_state.nav),
                      label_visibility="collapsed")
    if choice != st.session_state.nav:
        st.session_state.nav = choice
        st.rerun()

    st.divider()
    try:
        h = data.health().iloc[0]
        st.metric("Breached assumptions", int(h.BREACHED_COUNT))
        st.metric("Decisions to reassess", int(h.DECISIONS_REQUIRING_REASSESSMENT))
    except Exception as e:
        st.warning(f"Status unavailable: {e}")

    st.divider()
    st.markdown("**Acting as**")
    try:
        actors = data.q("SELECT ACTOR_ID, FULL_NAME, ACTOR_ROLE FROM PREMISEFLOW.CORE.V_GOVERNANCE_ACTORS")
        ids = actors.ACTOR_ID.tolist()
        default = st.session_state.actor_id if st.session_state.actor_id in ids else ids[0]
        chosen = st.selectbox(
            "Governance actor", ids, index=ids.index(default), label_visibility="collapsed",
            format_func=lambda x: f"{actors[actors.ACTOR_ID == x].iloc[0].FULL_NAME}")
        st.session_state.actor_id = chosen
        st.session_state.actor_role = actors[actors.ACTOR_ID == chosen].iloc[0].ACTOR_ROLE
        st.caption(f"{st.session_state.actor_role}")
    except Exception:
        st.session_state.actor_id = st.text_input("Actor id", st.session_state.actor_id,
                                                 label_visibility="collapsed")
        st.session_state.actor_role = st.text_input("Role", st.session_state.actor_role,
                                                    label_visibility="collapsed")
    st.caption("Governed actions are authorised against CORE.GOVERNANCE_ACTORS. Unregistered "
               "identities and all AI or system actors are rejected.")

    st.divider()
    with st.expander("Demo controls"):
        st.caption("Reproducible presentation flow. Reset preserves audit history.")
        if st.button("Reset demo to baseline", use_container_width=True):
            with st.spinner("Restoring approved baseline..."):
                res = actions.reset_demo()
            st.success(f"Reset complete. {res.get('valid')} of {res.get('assumptions')} "
                       "assumptions valid.")
            st.rerun()
        if st.button("Run full demo scenario", type="primary", use_container_width=True):
            with st.spinner("Replaying valid -> challenged -> breached -> impact -> reassessment..."):
                res = actions.run_demo(st.session_state.actor_id)
            st.session_state.demo_result = res
            st.success("Demo advanced. See the Executive Risk Radar.")
            st.rerun()
        if st.button("Run monitoring cycle", use_container_width=True):
            with st.spinner("Refreshing observations and re-testing all assumptions..."):
                res = actions.monitoring_cycle()
            st.success(f"Breached: {', '.join(res.get('breached') or []) or 'none'}")
            st.rerun()
        if st.button("Clear caches", use_container_width=True):
            data.clear_caches()
            st.rerun()
        st.caption(f"Streamlit runtime {compat.STREAMLIT_VERSION}")

    if st.session_state.get("demo_result"):
        with st.expander("Last demo run"):
            for s in st.session_state.demo_result.get("stages", []):
                st.markdown(f"**{s.get('stage')}**")
                for k, v in s.items():
                    if k in ("stage", "narrative"):
                        continue
                    st.caption(f"{k}: {str(v)[:160]}")
                st.caption(s.get("narrative", ""))

try:
    PAGES[st.session_state.nav]()
except Exception as exc:  # surface errors rather than showing a blank page
    st.error(f"Page '{st.session_state.nav}' failed to render.")
    st.exception(exc)

st.divider()
st.caption("PremiseFlow · Continuous Assumption Intelligence · Fully synthetic data. "
           "Illustrative simplified risk calculations for hackathon demonstration only. "
           "Not a regulatory calculation and not investment or risk advice.")
