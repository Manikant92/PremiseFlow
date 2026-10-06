"""Page 3 - Assumption Detail."""
from __future__ import annotations

import json

import altair as alt
import pandas as pd
import streamlit as st

from components import ui
from services import data, actions


def _picker() -> str:
    a = data.assumptions()
    ids = a.ASSUMPTION_ID.tolist()
    cur = st.session_state.get("selected_assumption", ids[0] if ids else None)
    idx = ids.index(cur) if cur in ids else 0
    pick = st.selectbox("Assumption", ids, index=idx,
                        format_func=lambda x: f"{x} - {a[a.ASSUMPTION_ID == x].iloc[0].NAME}")
    st.session_state.selected_assumption = pick
    return pick


def render() -> None:
    ui.masthead("Assumption Detail")
    aid = _picker()
    row = data.assumption(aid)
    if row is None:
        st.warning("Assumption not found.")
        return

    st.markdown(
        f"""<div class="pf-hero {'pf-hero-ok' if row.STATUS == 'VALID' else ''}">
          <div style="font-size:1.05rem;font-weight:700">{row.ASSUMPTION_ID} &middot; {row.NAME}</div>
          <div class="pf-meta" style="margin:0.4rem 0">{row.STATEMENT}</div>
          <div>{ui.badge(row.STATUS)} &nbsp; {ui.badge(row.MATERIALITY, ui.MATERIALITY_COLOURS)}
            &nbsp;<span class="pf-meta">{row.DOMAIN} &middot; Owner {row.OWNER_ROLE}
            &middot; Version {int(row.VERSION_NUMBER)} approved by {row.APPROVED_BY or '-'}</span></div>
        </div>""", unsafe_allow_html=True)

    k = st.columns(6)
    with k[0]: ui.kpi("Approved", ui.fmt_pct(row.EXPECTED_VALUE), "expected value")
    with k[1]: ui.kpi("Challenge at", ui.fmt_pct(row.CHALLENGE_THRESHOLD), "investigate")
    with k[2]: ui.kpi("Breach at", ui.fmt_pct(row.BREACH_THRESHOLD),
                      f"for {int(row.PERSISTENCE_DAYS)} days")
    with k[3]: ui.kpi("Observed", ui.fmt_pct(row.LATEST_OBSERVED_VALUE), str(row.LATEST_OBSERVATION_DATE),
                      tone="bad" if row.STATUS in ("BREACHED", "CHALLENGED") else "good")
    with k[4]: ui.kpi("Persistence", f"{int(row.OBSERVED_PERSISTENCE_DAYS or 0)} d", "consecutive")
    with k[5]: ui.kpi("Confidence", f"{float(row.LATEST_CONFIDENCE or 0):.0%}",
                      f"change point {row.CHANGE_POINT_DATE or '-'}")

    tabs = st.tabs(["Trend", "Cohort drivers", "Validity envelope", "Evidence",
                    "Versions", "Dependencies", "Documents", "Audit"])

    # ---- Trend -----------------------------------------------------------
    with tabs[0]:
        s = data.observation_series(aid)
        if s.empty:
            st.info("No observations yet.")
        else:
            s = s.copy()
            s["OBSERVATION_DATE"] = pd.to_datetime(s["OBSERVATION_DATE"])
            base = alt.Chart(s).mark_line(strokeWidth=2.2, color="#1F5FA8").encode(
                x=alt.X("OBSERVATION_DATE:T", title=None),
                y=alt.Y("OBSERVED_VALUE:Q", title=row.METRIC_CODE,
                        scale=alt.Scale(zero=False)),
                tooltip=["OBSERVATION_DATE:T", alt.Tooltip("OBSERVED_VALUE:Q", format=".4f")])
            lines = []
            for val, colour, label in (
                (row.EXPECTED_VALUE, "#0B6B4F", "approved"),
                (row.CHALLENGE_THRESHOLD, "#A33C00", "challenge"),
                (row.BREACH_THRESHOLD, "#A11B1B", "breach"),
            ):
                if val is not None and pd.notna(val):
                    d = pd.DataFrame({"y": [float(val)], "label": [label]})
                    lines.append(alt.Chart(d).mark_rule(
                        color=colour, strokeDash=[6, 4]).encode(y="y:Q"))
            cp = row.CHANGE_POINT_DATE
            if cp is not None and pd.notna(cp):
                lines.append(alt.Chart(pd.DataFrame({"d": [pd.to_datetime(cp)]})).mark_rule(
                    color="#5A6779", strokeDash=[3, 3]).encode(x="d:T"))
            st.altair_chart(alt.layer(base, *lines).properties(height=330),
                            use_container_width=True)
            st.caption("Green = approved premise. Amber = challenge threshold. Red = breach threshold. "
                       "Grey vertical = detected change point. Status is decided by deterministic "
                       "threshold plus persistence rules, never by the language model.")

    # ---- Cohort drivers --------------------------------------------------
    with tabs[1]:
        if aid != "A-DEP-001":
            st.info("Cohort decomposition is available for A-DEP-001, which is wired to the "
                    "synthetic banking data.")
        else:
            seg = data.retention_by_dimension()
            if seg.empty:
                st.info("No decomposition available.")
            else:
                overall = seg[seg.GRAIN == "OVERALL"]
                ov = float(overall.iloc[0].RETENTION_RATE) if not overall.empty else None
                for grain, label in (("ACQUISITION_CHANNEL", "By acquisition channel"),
                                     ("TENURE_BAND", "By tenure band"),
                                     ("CUSTOMER_SEGMENT", "By customer segment")):
                    sub = seg[seg.GRAIN == grain].copy()
                    if sub.empty:
                        continue
                    st.markdown(f"**{label}**")
                    sub["Retention"] = sub.RETENTION_RATE.astype(float)
                    ch = alt.Chart(sub).mark_bar().encode(
                        y=alt.Y("DIM_VALUE:N", sort="x", title=None),
                        x=alt.X("Retention:Q", title="90-day retention",
                                scale=alt.Scale(domain=[0.5, 1.0])),
                        color=alt.Color("Retention:Q", legend=None,
                                        scale=alt.Scale(scheme="redyellowgreen", domain=[0.6, 0.95])),
                        tooltip=[alt.Tooltip("DIM_VALUE:N", title="Cohort"),
                                 alt.Tooltip("Retention:Q", format=".2%"),
                                 alt.Tooltip("ACCOUNTS:Q", title="Accounts", format=",.0f"),
                                 alt.Tooltip("BALANCE_CHANGE:Q", title="Balance change", format=",.0f")])
                    layers = [ch]
                    if ov:
                        layers.append(alt.Chart(pd.DataFrame({"x": [ov]})).mark_rule(
                            color="#0E1726", strokeDash=[4, 3]).encode(x="x:Q"))
                    st.altair_chart(alt.layer(*layers).properties(height=26 * len(sub) + 60),
                                    use_container_width=True)
                st.caption("Dark vertical line is the portfolio average. Attrition is concentrated in "
                           "aggregator- and digitally-acquired, shorter-tenure, more rate-aware customers.")

    # ---- Validity envelope ----------------------------------------------
    with tabs[2]:
        env = row.VALIDITY_ENVELOPE
        try:
            env = json.loads(env) if isinstance(env, str) else (env or {})
        except (ValueError, TypeError):
            env = {}
        ctx = data.context_now()
        st.markdown("**Conditions under which this assumption was validated**")
        if not env:
            st.info("No validity envelope recorded.")
        else:
            rows = []
            cur = ctx.iloc[0] if not ctx.empty else None
            for key, val in env.items():
                observed, verdict = "-", "-"
                if cur is not None:
                    if key == "promotional_funding_share_max":
                        observed = f"{float(cur.PROMOTIONAL_FUNDING_SHARE):.2%}"
                        verdict = "BREACHED" if float(cur.PROMOTIONAL_FUNDING_SHARE) > float(val) else "HOLDS"
                    elif key == "deposit_concentration_max":
                        observed = f"{float(cur.DEPOSIT_CONCENTRATION):.2%}"
                        verdict = "BREACHED" if float(cur.DEPOSIT_CONCENTRATION) > float(val) else "HOLDS"
                    elif key == "policy_rate_pct" and isinstance(val, dict):
                        observed = f"{float(cur.POLICY_RATE_PCT):.2f}%"
                        lo, hi = float(val.get("min", -1e9)), float(val.get("max", 1e9))
                        verdict = "HOLDS" if lo <= float(cur.POLICY_RATE_PCT) <= hi else "BREACHED"
                rows.append({"Condition": key,
                             "Approved tolerance": json.dumps(val) if isinstance(val, (dict, list)) else str(val),
                             "Observed now": observed, "Verdict": verdict})
            ev = pd.DataFrame(rows)
            st.dataframe(ev, use_container_width=True, hide_index=True)
            if (ev.Verdict == "BREACHED").any():
                st.error("One or more validity conditions no longer hold. Per policy section 4.3 the "
                         "assumption must be re-evidenced before continued reliance, independently of "
                         "whether the headline metric is within tolerance.")

    # ---- Evidence --------------------------------------------------------
    with tabs[3]:
        st.markdown(f'<div class="pf-quote">{row.EVIDENCE_SUMMARY or "No summary recorded."}</div>',
                    unsafe_allow_html=True)
        ev = data.evidence(aid)
        if ev.empty:
            st.info("No structured evidence records.")
        else:
            st.dataframe(ev, use_container_width=True, hide_index=True)

    # ---- Versions --------------------------------------------------------
    with tabs[4]:
        vs = data.versions(aid)
        st.dataframe(
            vs[["VERSION_NUMBER", "VERSION_ID", "APPROVAL_STATUS", "IS_CURRENT", "EXPECTED_VALUE",
                "CHALLENGE_THRESHOLD", "BREACH_THRESHOLD", "PERSISTENCE_DAYS",
                "APPROVED_BY", "APPROVED_AT", "VALID_FROM", "VALID_TO", "SUPERSEDES_VERSION_ID"]],
            use_container_width=True, hide_index=True)
        st.caption("Superseded versions keep their original approval facts and statement text. "
                   "Only IS_CURRENT and VALID_TO change, so history is never rewritten.")
        for _, v in vs.iterrows():
            with st.expander(f"v{int(v.VERSION_NUMBER)} statement - {v.APPROVAL_STATUS}"
                             + (" (CURRENT)" if v.IS_CURRENT else "")):
                st.write(v.STATEMENT)
                st.caption(v.EVIDENCE_SUMMARY or "")

    # ---- Dependencies ----------------------------------------------------
    with tabs[5]:
        br = data.blast_radius(aid)
        if br.empty:
            st.info("No downstream dependencies recorded.")
        else:
            st.dataframe(
                br[["DEPTH", "SOURCE_OBJECT", "RELATIONSHIP_TYPE", "TARGET_OBJECT",
                    "TARGET_TYPE", "MATERIALITY", "SENSITIVITY_NOTE"]],
                use_container_width=True, hide_index=True)
        dec = data.affected_decisions(aid)
        if not dec.empty:
            st.markdown("**Decisions that relied on this assumption**")
            st.dataframe(
                dec[["DECISION_REF", "TITLE", "RELIANCE_STRENGTH", "RELIED_ON_VERSION_ID",
                     "GOVERNANCE_STATUS", "DECISION_DATE"]],
                use_container_width=True, hide_index=True)

    # ---- Documents -------------------------------------------------------
    with tabs[6]:
        docs = data.documents_for(aid)
        if docs.empty:
            st.info("No source documents mention this assumption.")
        else:
            for _, d in docs.iterrows():
                with st.expander(f"{d.DOC_TITLE} ({d.DOC_REFERENCE or 'n/a'}) - {d.SECTION}"):
                    st.caption(f"{d.DOC_CATEGORY} &middot; {d.RELATIVE_PATH}")
                    st.markdown(d.CHUNK_TEXT)

    # ---- Audit -----------------------------------------------------------
    with tabs[7]:
        tl = data.audit_timeline(aid)
        if tl.empty:
            st.info("No events for this object yet.")
        else:
            st.dataframe(tl, use_container_width=True, hide_index=True)

    # ---- Actions ---------------------------------------------------------
    st.markdown("## Human governance actions")
    st.caption("PremiseFlow detects, evidences, quantifies and recommends. Confirming a breach and "
               "approving a revised assumption are reserved to a human governance owner.")
    actor = st.session_state.get("actor_id", "manikant.kella")
    role = st.session_state.get("actor_role", "Head of Treasury Risk")

    br_df = data.breaches(aid)
    pending = br_df[br_df.CONFIRMATION_STATUS == "PENDING_HUMAN_CONFIRMATION"]

    c = st.columns(4)
    with c[0]:
        if st.button("Re-test now", use_container_width=True):
            with st.spinner("Re-testing..."):
                actions.run_challenger(aid, None, "app_user")
            st.rerun()
    with c[1]:
        disabled = pending.empty
        if st.button("Confirm breach", type="primary", use_container_width=True, disabled=disabled,
                     help="No breach awaiting confirmation" if disabled else None):
            with st.spinner("Confirming breach, simulating impact and reopening decisions..."):
                res = actions.confirm_breach(str(pending.iloc[0].BREACH_ID), actor, role,
                                             "Confirmed from Assumption Detail.")
            st.success(f"Breach confirmed. Decisions reopened: "
                       f"{', '.join((res.get('reassessment') or {}).get('decisions_reopened') or []) or 'none'}")
            st.rerun()
    with c[2]:
        if st.button("Dismiss challenge", use_container_width=True):
            actions.dismiss_challenge(aid, actor, role, "Dismissed from Assumption Detail.")
            st.rerun()
    with c[3]:
        if st.button("Request more evidence", use_container_width=True):
            actions.request_more_evidence(aid, actor, role, "More evidence requested.")
            st.rerun()

    if not pending.empty:
        ui.lifecycle_strip("BREACH CONFIRMED")
