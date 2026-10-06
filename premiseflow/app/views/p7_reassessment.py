"""Page 7 - Decision Reassessment (the human governance workspace)."""
from __future__ import annotations

import streamlit as st

from components import ui
from services import data, actions


def render() -> None:
    ui.masthead("Decision Reassessment")
    ra = data.reassessments()

    if ra.empty:
        st.success("No open reassessments. Every governed decision currently rests on an "
                   "assumption that reality still supports.")
        st.caption("Run the demo from the sidebar, or confirm a breach on the Assumption Detail "
                   "page, to create one.")
        return

    open_ra = ra[ra.STATUS.isin(["OPEN", "IN_REVIEW"])]
    st.caption(f"{len(open_ra)} open of {len(ra)} total reassessments.")

    pick = st.selectbox(
        "Reassessment",
        ra.REASSESSMENT_ID.tolist(),
        format_func=lambda x: (f"{ra[ra.REASSESSMENT_ID == x].iloc[0].DECISION_REF} - "
                               f"{ra[ra.REASSESSMENT_ID == x].iloc[0].TITLE} "
                               f"[{ra[ra.REASSESSMENT_ID == x].iloc[0].STATUS}]"))
    r = ra[ra.REASSESSMENT_ID == pick].iloc[0]

    st.markdown(
        f"""<div class="pf-hero">
          <div style="font-size:1.05rem;font-weight:700">{r.DECISION_REF} &middot; {r.TITLE}</div>
          <div style="margin:0.4rem 0">
            {ui.badge(r.GOVERNANCE_STATUS, ui.DECISION_COLOURS)} &nbsp;
            {ui.badge(r.MATERIALITY, ui.MATERIALITY_COLOURS)} &nbsp;
            <span class="pf-meta">decided {r.DECISION_DATE} by {r.APPROVED_BY}
            &middot; reopened {r.TRIGGERED_AT}</span>
          </div>
        </div>""", unsafe_allow_html=True)

    left, right = st.columns(2)
    with left:
        st.markdown("### What was decided")
        st.markdown(f'<div class="pf-quote">{r.DECISION_TEXT}</div>', unsafe_allow_html=True)
        st.markdown("### What was believed at the time")
        st.markdown(f'<div class="pf-quote">{r.RATIONALE}</div>', unsafe_allow_html=True)
        st.caption(f"Assumption version relied upon: `{r.ORIGINAL_VERSION_ID}`. "
                   "The original decision record is preserved unchanged; only its governance "
                   "status has moved.")

        st.markdown("### Old evidence")
        ev = data.evidence(r.ASSUMPTION_ID)
        old = ev[ev.VERSION_ID == r.ORIGINAL_VERSION_ID] if not ev.empty else ev
        if old.empty:
            st.info("No approval-time evidence recorded.")
        else:
            for _, e in old.iterrows():
                st.markdown(f"- **{e.EVIDENCE_TYPE}** ({e.SOURCE_REF}): {e.SUMMARY}")

    with right:
        st.markdown("### What changed")
        m = st.columns(2)
        with m[0]:
            ui.kpi("Approved premise", ui.fmt_pct(r.APPROVED_VALUE), "at decision time")
        with m[1]:
            ui.kpi("Observed now", ui.fmt_pct(r.OBSERVED_VALUE), "reality", tone="bad")
        st.caption(r.TRIGGER_REASON)

        st.markdown("### Quantified impact")
        st.markdown(f'<div class="pf-quote">{r.IMPACT_SUMMARY}</div>', unsafe_allow_html=True)

        st.markdown("### AI recommendation")
        st.markdown(f'<div class="pf-quote">{r.AI_RECOMMENDATION}</div>', unsafe_allow_html=True)
        st.caption("Recommendation only. PremiseFlow cannot approve a revised assumption or a "
                   "revised decision.")

    st.divider()
    st.markdown("## Human controls")
    actor = st.session_state.get("actor_id", "manikant.kella")
    role = st.session_state.get("actor_role", "Head of Treasury Risk")
    st.caption(f"Acting as **{actor}** ({role}). Change this in the sidebar.")

    aid = r.ASSUMPTION_ID
    vs = data.versions(aid)
    cur_v = vs[vs.IS_CURRENT].iloc[0] if not vs[vs.IS_CURRENT].empty else vs.iloc[0]
    proposed = vs[vs.APPROVAL_STATUS == "PROPOSED"]
    row = data.assumption(aid)
    observed = float(r.OBSERVED_VALUE)

    tab1, tab2, tab3 = st.tabs(["Propose a revised assumption", "Approve or reject a proposal",
                                "Close the reassessment"])

    with tab1:
        st.caption("A revised assumption creates a NEW immutable version in PROPOSED state. "
                   "It does not become current until a human approves it.")
        suggested = max(0.50, round(observed - 0.02, 2))
        c = st.columns(4)
        exp = c[0].number_input("Expected value", 0.0, 1.0, float(suggested), 0.005, format="%.3f")
        chal = c[1].number_input("Challenge threshold", 0.0, 1.0,
                                 float(max(0.0, suggested - 0.02)), 0.005, format="%.3f")
        brc = c[2].number_input("Breach threshold", 0.0, 1.0,
                                float(max(0.0, suggested - 0.05)), 0.005, format="%.3f")
        pers = c[3].number_input("Persistence (days)", 1, 60, int(cur_v.PERSISTENCE_DAYS))
        c2 = st.columns(2)
        lower = c2[0].number_input("Lower bound", 0.0, 1.0, float(max(0.0, suggested - 0.02)), 0.005, format="%.3f")
        upper = c2[1].number_input("Upper bound", 0.0, 1.0, 1.0, 0.005, format="%.3f")

        default_stmt = (
            f"Retail salary-account deposits retain at least {exp:.0%} of incumbent balances over a "
            f"rolling 90-day horizon, measured on the incumbent cohort and decomposed by acquisition "
            f"channel, tenure band and wealth segment. Reliance is conditional on promotional funding "
            f"remaining within the revised envelope.")
        stmt = st.text_area("Revised statement", value=default_stmt, height=110)
        evsum = st.text_area(
            "Evidence summary",
            value=(f"Observed rolling 90-day incumbent retention of {observed:.2%} sustained for "
                   f"{int(row.OBSERVED_PERSISTENCE_DAYS or 0)} consecutive days. Attrition concentrated in "
                   f"aggregator- and digitally-acquired, shorter-tenure cohorts. Promotional funding share "
                   f"has exceeded the previously approved 5% envelope condition."),
            height=90)
        rationale = st.text_area("Rationale for the change", height=70,
                                 value="Approved premise is no longer supported by observed behaviour; "
                                       "revising to an evidence-based threshold and tightening the "
                                       "validity envelope.")

        if st.button("Propose new version", type="primary"):
            res = actions.propose_new_version(aid, stmt, exp, chal, brc, lower, upper,
                                              int(pers), evsum, actor, rationale)
            if isinstance(res, dict) and res.get("version_id"):
                st.success(f"Proposed {res['version_id']} (v{res['version_number']}). "
                           "It is NOT current until approved.")
            else:
                st.error(f"Could not propose: {res}")
            st.rerun()

    with tab2:
        if proposed.empty:
            st.info("No proposed versions awaiting a decision.")
        else:
            pv = st.selectbox("Proposed version", proposed.VERSION_ID.tolist())
            p = proposed[proposed.VERSION_ID == pv].iloc[0]
            cc = st.columns(3)
            with cc[0]: ui.kpi("Current", f"v{int(cur_v.VERSION_NUMBER)}",
                               f"expected {float(cur_v.EXPECTED_VALUE):.2%}")
            with cc[1]: ui.kpi("Proposed", f"v{int(p.VERSION_NUMBER)}",
                               f"expected {float(p.EXPECTED_VALUE):.2%}", tone="warn")
            with cc[2]: ui.kpi("Proposed by", str(p.PROPOSED_BY), str(p.PROPOSED_AT))
            st.markdown(f'<div class="pf-quote">{p.STATEMENT}</div>', unsafe_allow_html=True)
            st.caption(p.EVIDENCE_SUMMARY or "")
            note = st.text_input("Approval note", value="Reviewed evidence; revised premise accepted.")
            g = st.columns([1, 1, 4])
            if g[0].button("Approve version", type="primary", use_container_width=True):
                res = actions.approve_new_version(pv, actor, role, note)
                if isinstance(res, dict) and res.get("approved_version_id"):
                    st.success(f"Approved {res['approved_version_id']}. Superseded "
                               f"{res.get('superseded_version_id')}. Monitoring restarted against "
                               "the new version.")
                else:
                    st.error(f"Could not approve: {res}")
                st.rerun()
            if g[1].button("Reject version", use_container_width=True):
                actions.reject_new_version(pv, actor, role, note)
                st.rerun()

    with tab3:
        st.caption("Closing the reassessment records the committee outcome against the decision.")
        resolution = st.selectbox(
            "Decision outcome",
            ["REAFFIRMED", "SUPERSEDED", "APPROVED"],
            format_func=lambda x: {
                "REAFFIRMED": "Reaffirm the original decision on revised evidence",
                "SUPERSEDED": "Supersede the decision with a new one",
                "APPROVED": "Return to approved (no change needed)"}[x])
        note = st.text_area("Resolution note", height=80,
                            value="Committee reviewed the revised assumption and the reality-adjusted "
                                  "liquidity position.")
        if st.button("Resolve reassessment", type="primary"):
            actions.resolve_reassessment(pick, resolution, actor, role, note)
            st.success(f"Reassessment resolved as {resolution}.")
            st.rerun()

    st.divider()
    st.markdown("## Version history for this assumption")
    st.dataframe(
        vs[["VERSION_NUMBER", "VERSION_ID", "APPROVAL_STATUS", "IS_CURRENT", "EXPECTED_VALUE",
            "CHALLENGE_THRESHOLD", "BREACH_THRESHOLD", "APPROVED_BY", "APPROVED_AT",
            "VALID_FROM", "VALID_TO", "SUPERSEDES_VERSION_ID"]],
        use_container_width=True, hide_index=True)
    st.caption("Version 1 remains APPROVED with its original approver, timestamp and statement. "
               "Superseding only sets IS_CURRENT and VALID_TO - approved history is never overwritten.")

    ui.lifecycle_strip("HUMAN REVIEWS")
