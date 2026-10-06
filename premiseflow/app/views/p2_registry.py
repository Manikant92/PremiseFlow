"""Page 2 - Assumption Registry."""
from __future__ import annotations

import pandas as pd
import streamlit as st

from components import ui
from services import data, actions


def render() -> None:
    ui.masthead("Assumption Registry")
    a = data.assumptions()
    if a.empty:
        st.info("No assumptions registered.")
        return

    f = st.columns(5)
    domains = ["All"] + sorted(a.DOMAIN.dropna().unique().tolist())
    mats = ["All"] + [m for m in ["CRITICAL", "HIGH", "MEDIUM", "LOW"] if m in a.MATERIALITY.values]
    stats = ["All"] + sorted(a.STATUS.dropna().unique().tolist())
    owners = ["All"] + sorted(a.OWNER_ROLE.dropna().unique().tolist())

    domain = f[0].selectbox("Domain", domains)
    mat = f[1].selectbox("Materiality", mats)
    status = f[2].selectbox("Status", stats)
    owner = f[3].selectbox("Owner", owners)
    search = f[4].text_input("Search", placeholder="id or name")

    v = a.copy()
    if domain != "All": v = v[v.DOMAIN == domain]
    if mat != "All": v = v[v.MATERIALITY == mat]
    if status != "All": v = v[v.STATUS == status]
    if owner != "All": v = v[v.OWNER_ROLE == owner]
    if search:
        s = search.lower()
        v = v[v.ASSUMPTION_ID.str.lower().str.contains(s) | v.NAME.str.lower().str.contains(s)]

    st.caption(f"{len(v)} of {len(a)} assumptions. "
               "Only A-DEP-001 is wired end to end to the synthetic banking data; "
               "A-DEP-002 is data-driven from the rate series; the remainder carry representative series.")

    grid = v[[
        "ASSUMPTION_ID", "NAME", "DOMAIN", "MATERIALITY", "STATUS", "OWNER_ROLE",
        "VERSION_NUMBER", "EXPECTED_VALUE", "LATEST_OBSERVED_VALUE", "DEVIATION_PCT",
        "OBSERVED_PERSISTENCE_DAYS", "LATEST_OBSERVATION_DATE", "LAST_VALIDATED_AT",
        "DEPENDENT_DECISION_COUNT",
    ]].rename(columns={
        "ASSUMPTION_ID": "ID", "NAME": "Assumption", "DOMAIN": "Domain",
        "MATERIALITY": "Materiality", "STATUS": "Status", "OWNER_ROLE": "Owner",
        "VERSION_NUMBER": "Ver", "EXPECTED_VALUE": "Approved",
        "LATEST_OBSERVED_VALUE": "Observed", "DEVIATION_PCT": "Deviation",
        "OBSERVED_PERSISTENCE_DAYS": "Persist (d)",
        "LATEST_OBSERVATION_DATE": "Last observed", "LAST_VALIDATED_AT": "Last validated",
        "DEPENDENT_DECISION_COUNT": "Decisions",
    })

    st.dataframe(
        grid, use_container_width=True, hide_index=True,
        column_config={
            "Approved": st.column_config.NumberColumn(format="%.4f"),
            "Observed": st.column_config.NumberColumn(format="%.4f"),
            "Deviation": st.column_config.NumberColumn(format="%.2f%%", help="Relative to the approved premise"),
            "Last validated": st.column_config.DatetimeColumn(format="YYYY-MM-DD"),
        },
    )

    st.markdown("## Status distribution")
    counts = a.groupby(["MATERIALITY", "STATUS"]).size().reset_index(name="n")
    order = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}
    counts["o"] = counts.MATERIALITY.map(order)
    st.bar_chart(counts.sort_values("o").pivot(index="MATERIALITY", columns="STATUS", values="n").fillna(0))

    st.markdown("## Open an assumption")
    pick = st.selectbox(
        "Assumption",
        v.ASSUMPTION_ID.tolist() if not v.empty else a.ASSUMPTION_ID.tolist(),
        format_func=lambda x: f"{x} - {a[a.ASSUMPTION_ID == x].iloc[0].NAME}")
    cols = st.columns([1, 1, 4])
    if cols[0].button("Open detail", type="primary", use_container_width=True):
        st.session_state.selected_assumption = pick
        st.session_state.nav = "Assumption Detail"
        st.rerun()
    if cols[1].button("Re-test this one", use_container_width=True):
        with st.spinner(f"Re-testing {pick}..."):
            res = actions.run_challenger(pick, None, "app_user")
        r = (res.get("results") or [{}])[0]
        st.success(f"{pick}: {r.get('status')} (observed {r.get('observed_value')}, "
                   f"persistence {r.get('persistence_days')}/{r.get('persistence_required')} days)")
        st.rerun()
