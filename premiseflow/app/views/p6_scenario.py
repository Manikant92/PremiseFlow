"""Page 6 - Scenario Simulator."""
from __future__ import annotations

import json

import altair as alt
import pandas as pd
import streamlit as st

from components import ui
from services import data, actions

METRIC_ORDER = ["LCR", "STRESSED_OUTFLOW_30D", "FUNDING_GAP_90D", "NII_12M"]


def render() -> None:
    ui.masthead("Scenario Simulator")
    ui.poc_note("The formulation below is deliberately simple and fully disclosed so the "
                "propagation from assumption to risk number is auditable.")

    a = data.assumptions()
    ids = a.ASSUMPTION_ID.tolist()
    cur = st.session_state.get("selected_assumption", "A-DEP-001")
    idx = ids.index(cur) if cur in ids else 0
    aid = st.selectbox("Assumption", ids, index=idx,
                       format_func=lambda x: f"{x} - {a[a.ASSUMPTION_ID == x].iloc[0].NAME}")
    st.session_state.selected_assumption = aid
    row = data.assumption(aid)

    approved = float(row.EXPECTED_VALUE)
    observed = float(row.LATEST_OBSERVED_VALUE) if row.LATEST_OBSERVED_VALUE is not None else approved

    st.markdown("## Inputs")
    c = st.columns([2, 1, 1])
    with c[0]:
        user_retention = st.slider(
            "User-defined retention assumption", min_value=0.60, max_value=1.00,
            value=round(observed, 4), step=0.005, format="%.3f",
            help="Drag to test any premise. The stable-deposit runoff rate moves with it.")
    with c[1]:
        st.metric("Approved premise", ui.fmt_pct(approved))
    with c[2]:
        st.metric("Observed reality", ui.fmt_pct(observed),
                  delta=f"{(observed - approved) * 100:+.2f} pp")

    b = st.columns([1, 1, 3])
    run_all = b[0].button("Run scenarios", type="primary", use_container_width=True)
    if b[1].button("Baseline vs observed only", use_container_width=True):
        with st.spinner("Simulating..."):
            actions.run_impact_for_assumption(aid, "app_user")
        st.rerun()

    if run_all:
        with st.spinner("Running approved, observed and user-defined scenarios..."):
            actions.run_impact_for_assumption(aid, "app_user")
            actions.run_scenario(aid, user_retention, "USER_DEFINED",
                                 f"User-defined ({user_retention:.2%} retention)", "app_user")
        st.rerun()

    scen = data.scenario_comparison(aid)
    if scen.empty:
        st.info("No scenarios yet. Press Run scenarios.")
        return

    # Most recent result per (scenario type, metric)
    latest = (scen.sort_values("CREATED_AT", ascending=False)
                  .drop_duplicates(subset=["SCENARIO_TYPE", "METRIC_ID"]))

    st.markdown("## Results")
    types = [t for t in ["BASELINE", "OBSERVED_BEHAVIOUR", "USER_DEFINED", "PROPOSED_ASSUMPTION"]
             if t in latest.SCENARIO_TYPE.values]
    labels = {"BASELINE": "Approved premise", "OBSERVED_BEHAVIOUR": "Observed reality",
              "USER_DEFINED": "User defined", "PROPOSED_ASSUMPTION": "Proposed assumption"}

    cols = st.columns(len(types))
    for i, t in enumerate(types):
        sub = latest[latest.SCENARIO_TYPE == t]
        lcr = sub[sub.METRIC_ID == "LCR"]
        ret = float(sub.iloc[0].RETENTION_INPUT)
        val = None if lcr.empty else float(lcr.iloc[0].METRIC_VALUE)
        breach = bool(lcr.iloc[0].BREACHES_LIMIT) if not lcr.empty else False
        with cols[i]:
            ui.kpi(labels[t], ui.fmt_pct_pts(val),
                   f"retention {ret:.2%}" + (" &middot; below internal limit" if breach else ""),
                   tone="bad" if breach else "good")

    pivot = latest.pivot_table(index="METRIC_ID", columns="SCENARIO_TYPE",
                              values="METRIC_VALUE", aggfunc="first")
    pivot = pivot.reindex([m for m in METRIC_ORDER if m in pivot.index])
    units = latest.drop_duplicates("METRIC_ID").set_index("METRIC_ID")["UNIT"].to_dict()
    names = latest.drop_duplicates("METRIC_ID").set_index("METRIC_ID")["METRIC_NAME"].to_dict()

    table = pivot.copy()
    table.insert(0, "Metric", [names.get(i, i) for i in table.index])
    table.insert(1, "Unit", [units.get(i, "") for i in table.index])
    if "BASELINE" in pivot.columns and "OBSERVED_BEHAVIOUR" in pivot.columns:
        table["Change vs approved"] = pivot["OBSERVED_BEHAVIOUR"] - pivot["BASELINE"]
    st.dataframe(table.rename(columns=labels), use_container_width=True)

    if "LCR" in pivot.index:
        lcr_row = pivot.loc["LCR"].reset_index()
        lcr_row.columns = ["Scenario", "LCR"]
        lcr_row["Scenario"] = lcr_row.Scenario.map(labels).fillna(lcr_row.Scenario)
        chart = alt.Chart(lcr_row).mark_bar(size=46).encode(
            x=alt.X("Scenario:N", title=None, sort=list(labels.values())),
            y=alt.Y("LCR:Q", title="LCR %", scale=alt.Scale(domain=[80, 130])),
            color=alt.condition(alt.datum.LCR < 110, alt.value("#A11B1B"), alt.value("#0B6B4F")),
            tooltip=["Scenario:N", alt.Tooltip("LCR:Q", format=".1f")])
        lim = alt.Chart(pd.DataFrame({"y": [110.0], "l": ["internal limit 110%"]})).mark_rule(
            color="#A33C00", strokeDash=[6, 4]).encode(y="y:Q")
        reg = alt.Chart(pd.DataFrame({"y": [100.0], "l": ["regulatory minimum 100%"]})).mark_rule(
            color="#A11B1B").encode(y="y:Q")
        st.altair_chart((chart + lim + reg).properties(height=300), use_container_width=True)
        st.caption("Amber dashed = 110% internal management threshold. Solid red = 100% regulatory minimum.")

    st.markdown("## How the number is produced")
    li = data.liquidity_inputs()
    prm = data.sim_parameters()
    with st.expander("Formula, inputs and drill-down", expanded=False):
        for _, r in latest.drop_duplicates("METRIC_ID").iterrows():
            st.markdown(f"**{r.METRIC_NAME}** (`{r.METRIC_ID}`, {r.UNIT})")
            st.code(r.FORMULA, language="text")
        st.markdown("**Simplified balance sheet inputs**")
        if not li.empty:
            show = li.T.reset_index()
            show.columns = ["Input", "Value"]
            st.dataframe(show, use_container_width=True, hide_index=True)
        st.markdown("**Simulation parameters**")
        st.dataframe(prm, use_container_width=True, hide_index=True)
        first = latest.iloc[0]
        if first.INPUTS is not None:
            try:
                st.markdown("**Resolved inputs for the most recent scenario**")
                st.json(json.loads(first.INPUTS) if isinstance(first.INPUTS, str) else first.INPUTS)
            except (ValueError, TypeError):
                pass

    st.markdown("## Scenario history")
    st.dataframe(
        scen[["CREATED_AT", "SCENARIO_TYPE", "SCENARIO_NAME", "RETENTION_INPUT", "METRIC_ID",
              "METRIC_VALUE", "UNIT", "BREACHES_LIMIT", "CREATED_BY"]].head(60),
        use_container_width=True, hide_index=True)

    ui.lifecycle_strip("DOWNSTREAM IMPACT")
