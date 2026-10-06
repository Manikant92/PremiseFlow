"""Page 1 - Executive Risk Radar."""
from __future__ import annotations

import altair as alt
import pandas as pd
import streamlit as st

from components import ui
from services import data, actions


def render() -> None:
    ui.masthead("Executive Risk Radar")

    h = data.health().iloc[0]
    a = data.assumptions()
    dep = data.deposit_masking()
    gt = data.ground_truth()

    c = st.columns(7)
    with c[0]: ui.kpi("Active", f"{int(h.ACTIVE_ASSUMPTIONS)}", "assumptions monitored")
    with c[1]: ui.kpi("Valid", f"{int(h.VALID_COUNT)}", "supported by reality", tone="good")
    with c[2]: ui.kpi("Watch", f"{int(h.WATCH_COUNT)}", "drifting")
    with c[3]: ui.kpi("Challenged", f"{int(h.CHALLENGED_COUNT)}", "threshold crossed", tone="warn")
    with c[4]: ui.kpi("Breached", f"{int(h.BREACHED_COUNT)}", "no longer supported", tone="bad")
    with c[5]: ui.kpi("Decisions to reassess", f"{int(h.DECISIONS_REQUIRING_REASSESSMENT)}",
                      "governance status changed", tone="bad" if h.DECISIONS_REQUIRING_REASSESSMENT else None)
    with c[6]: ui.kpi("Critical exposure", f"{int(h.CRITICAL_EXPOSURE_COUNT)}",
                      "critical + breached", tone="bad" if h.CRITICAL_EXPOSURE_COUNT else "good")

    st.markdown("## The aggregate view says everything is fine")

    if not dep.empty:
        brk = pd.to_datetime(dep["BREAK_DATE"].iloc[0])
        latest, first = dep.iloc[-1], dep.iloc[0]
        at_break = dep[pd.to_datetime(dep["BALANCE_DATE"]) == brk]
        base = at_break.iloc[0] if not at_break.empty else first

        k = st.columns(4)
        with k[0]:
            ui.kpi("Total deposits", ui.fmt_musd(latest.TOTAL_DEPOSITS / 1e6),
                   f"{(latest.TOTAL_DEPOSITS / base.TOTAL_DEPOSITS - 1) * 100:+.2f}% since the behaviour change",
                   tone="good")
        with k[1]:
            ui.kpi("Deposits underpinning the assumption",
                   ui.fmt_musd(latest.GOVERNED_STABLE_DEPOSITS / 1e6),
                   f"{(latest.GOVERNED_STABLE_DEPOSITS / base.GOVERNED_STABLE_DEPOSITS - 1) * 100:+.2f}% since the behaviour change",
                   tone="bad")
        with k[2]:
            ui.kpi("Promotional inflow", ui.fmt_musd(latest.PROMOTIONAL_DEPOSITS / 1e6),
                   f"{latest.PROMOTIONAL_FUNDING_SHARE * 100:.1f}% of funding (policy limit 5%)", tone="warn")
        with k[3]:
            ui.kpi("Customers", f"{int(latest.ACTIVE_CUSTOMERS):,}", "synthetic population")

        long = dep.melt(
            id_vars=["BALANCE_DATE"],
            value_vars=["TOTAL_DEPOSITS", "GOVERNED_STABLE_DEPOSITS", "PROMOTIONAL_DEPOSITS"],
            var_name="Pool", value_name="Balance")
        long["Pool"] = long["Pool"].map({
            "TOTAL_DEPOSITS": "Total deposits (what monitoring watches)",
            "GOVERNED_STABLE_DEPOSITS": "Deposits the assumption is about",
            "PROMOTIONAL_DEPOSITS": "New promotional money (the mask)"})
        long["Balance"] = long["Balance"] / 1e6

        chart = (
            alt.Chart(long)
            .mark_line(strokeWidth=2.2)
            .encode(
                x=alt.X("BALANCE_DATE:T", title=None),
                y=alt.Y("Balance:Q", title="USD millions"),
                color=alt.Color("Pool:N", title=None,
                                scale=alt.Scale(range=["#1F5FA8", "#A11B1B", "#8A5B00"]),
                                legend=alt.Legend(orient="bottom", columns=1)),
                tooltip=["BALANCE_DATE:T", "Pool:N", alt.Tooltip("Balance:Q", format=",.1f")])
            .properties(height=300)
        )
        rule = (alt.Chart(pd.DataFrame({"d": [brk]})).mark_rule(
            color="#5A6779", strokeDash=[5, 4]).encode(x="d:T"))
        st.altair_chart(chart + rule, use_container_width=True)
        st.caption(
            "Dashed line marks the onset of the behaviour change. Total deposits keep rising while the "
            "specific pool the assumption is about falls away. This is why aggregate monitoring misses it.")

    st.markdown("## Critical exposure")

    crit = a[(a.STATUS == "BREACHED") & (a.MATERIALITY == "CRITICAL")]
    target = crit.iloc[0] if not crit.empty else (a.iloc[0] if not a.empty else None)

    if target is None:
        st.info("No assumptions registered.")
        return

    dec = data.affected_decisions(target.ASSUMPTION_ID)
    reassess = dec[dec.GOVERNANCE_STATUS == "REASSESSMENT_REQUIRED"]
    scen = data.scenario_comparison(target.ASSUMPTION_ID)
    lcr_base = lcr_obs = None
    if not scen.empty:
        lcr = scen[scen.METRIC_ID == "LCR"]
        b = lcr[lcr.SCENARIO_TYPE == "BASELINE"]
        o = lcr[lcr.SCENARIO_TYPE == "OBSERVED_BEHAVIOUR"]
        lcr_base = None if b.empty else float(b.iloc[0].METRIC_VALUE)
        lcr_obs = None if o.empty else float(o.iloc[0].METRIC_VALUE)

    ok = target.STATUS == "VALID"
    st.markdown(
        f"""<div class="pf-hero {'pf-hero-ok' if ok else ''}">
          <div style="font-size:1.1rem;font-weight:700;color:{ui.INK}">
            {target.ASSUMPTION_ID} &nbsp; {target.NAME.upper()}
          </div>
          <div class="pf-meta" style="margin:0.35rem 0 0.6rem 0">{target.STATEMENT}</div>
          <div>{ui.badge(target.STATUS)} &nbsp; {ui.badge(target.MATERIALITY, ui.MATERIALITY_COLOURS)}
               &nbsp; <span class="pf-meta">Owner: {target.OWNER_ROLE} &middot; Version {int(target.VERSION_NUMBER)}</span></div>
        </div>""",
        unsafe_allow_html=True)

    m = st.columns(5)
    with m[0]: ui.kpi("Approved premise", ui.fmt_pct(target.EXPECTED_VALUE), "governed threshold")
    with m[1]:
        ui.kpi("Observed", ui.fmt_pct(target.LATEST_OBSERVED_VALUE),
               f"as at {target.LATEST_OBSERVATION_DATE}", tone="bad" if not ok else "good")
    with m[2]:
        pd_ = target.OBSERVED_PERSISTENCE_DAYS
        ui.kpi("Persistence", f"{int(pd_) if pd.notna(pd_) else 0} d",
               f"requires {int(target.PERSISTENCE_DAYS)} d", tone="bad" if not ok else None)
    with m[3]:
        ui.kpi("LCR on approved premise", ui.fmt_pct_pts(lcr_base), "illustrative POC", tone="good")
    with m[4]:
        ui.kpi("LCR reality-adjusted", ui.fmt_pct_pts(lcr_obs),
               "internal limit 110% / reg min 100%", tone="bad")

    n = st.columns(3)
    with n[0]:
        ui.kpi("Impacted decisions", f"{len(reassess)}", "moved to REASSESSMENT_REQUIRED",
               tone="bad" if len(reassess) else None)
    with n[1]:
        ui.kpi("Downstream objects", f"{int(target.DIRECT_DEPENDENCY_COUNT)}", "direct dependencies")
    with n[2]:
        ui.kpi("Detection confidence", f"{float(target.LATEST_CONFIDENCE or 0):.0%}",
               f"change point {target.CHANGE_POINT_DATE or '-'}")

    if not gt.empty:
        g = gt.iloc[0]
        with st.expander("Seeded ground truth (POC only - proves the detection is real, not asserted)"):
            st.write(f"**Phenomenon:** {g.PHENOMENON}")
            st.write(f"**Behaviour change begins:** {g.BREAK_START_DATE}")
            st.write(f"**Designed pre/post value:** {g.EXPECTED_PRE_VALUE:.1%} -> {g.EXPECTED_POST_VALUE:.1%}")
            st.write(f"**Masking mechanism:** {g.MASKING_MECHANISM}")
            st.write(f"**Detected change point:** {target.CHANGE_POINT_DATE}")

    st.markdown("### ")
    b = st.columns([1, 1, 1, 3])
    with b[0]:
        if st.button("Investigate", type="primary", use_container_width=True):
            st.session_state.selected_assumption = target.ASSUMPTION_ID
            st.session_state.nav = "Assumption Detail"
            st.rerun()
    with b[1]:
        if st.button("Re-test now", use_container_width=True):
            with st.spinner("Re-testing assumptions against current reality..."):
                res = actions.run_challenger(None, None, "app_user")
            st.success(f"Evaluated {res.get('evaluated')} assumptions. "
                       f"Breached: {', '.join(res.get('breached') or []) or 'none'}.")
            st.rerun()
    with b[2]:
        if st.button("Impact graph", use_container_width=True):
            st.session_state.selected_assumption = target.ASSUMPTION_ID
            st.session_state.nav = "Impact Graph"
            st.rerun()

    ui.lifecycle_strip("DECISIONS REASSESSMENT REQUIRED" if len(reassess) else "ASSUMPTION VALID")
