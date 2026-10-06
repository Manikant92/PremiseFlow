"""Page 4 - Evidence and Investigation."""
from __future__ import annotations

import streamlit as st

from components import ui
from services import data, actions, agent

STARTERS = [
    "Why did A-DEP-001 break?",
    "Which segment caused the change?",
    "Was total deposit balance also declining?",
    "Which evidence originally justified the 90% retention premise?",
    "What changed in the last 30 days?",
    "Which decisions depend on A-DEP-001?",
    "Compare the approved and observed LCR scenarios.",
    "Which source documents mention this assumption?",
    "Confirm the breach and approve a new assumption for me.",
]


def render() -> None:
    ui.masthead("Evidence & Investigation")
    aid = st.session_state.get("selected_assumption", "A-DEP-001")

    left, right = st.columns([3, 2])

    with left:
        st.markdown("## Ask the assumption analyst")
        use_agent = st.toggle(
            "Use Cortex Agent", value=agent.agent_available(),
            help="Cortex Agent PREMISEFLOW_AGENT combines the governed semantic view with Cortex "
                 "Search over the document corpus. If unavailable, the server-side grounded Q&A "
                 "procedure answers from the same two evidence sources.")

        st.caption("Starter questions")
        cols = st.columns(3)
        for i, s in enumerate(STARTERS):
            if cols[i % 3].button(s, key=f"starter_{i}", use_container_width=True):
                st.session_state.pf_question = s

        question = st.text_area("Question", value=st.session_state.get("pf_question", STARTERS[0]),
                                height=90)

        if st.button("Investigate", type="primary"):
            st.session_state.pf_question = question
            with st.spinner("Gathering structured and document evidence..."):
                answered = False
                if use_agent:
                    res = agent.ask_agent(question)
                    if res.get("ok"):
                        st.session_state.pf_answer = {
                            "text": res["text"], "source": "Cortex Agent PREMISEFLOW_AGENT",
                            "tools": res.get("tools") or [], "citations": []}
                        answered = True
                    else:
                        st.warning(
                            "Cortex Agent unavailable, using the server-side grounded Q&A path. "
                            f"Detail: {res.get('error')}")
                if not answered:
                    res = actions.ask(question, "app_user")
                    if isinstance(res, dict) and res.get("answer"):
                        st.session_state.pf_answer = {
                            "text": res["answer"],
                            "source": f"Grounded Q&A ({res.get('model')}, {res.get('prompt_version')})",
                            "tools": ["cortex_search", "semantic_layer"],
                            "citations": res.get("citations") or []}
                    else:
                        st.session_state.pf_answer = {
                            "text": None, "source": None, "tools": [], "citations": [],
                            "error": (res or {}).get("error") if isinstance(res, dict) else str(res)}

        ans = st.session_state.get("pf_answer")
        if ans:
            if ans.get("text"):
                st.markdown(f'<div class="pf-quote">{ans["text"]}</div>', unsafe_allow_html=True)
                st.caption(f"Source: {ans['source']}"
                           + (f" &middot; tools used: {', '.join(ans['tools'])}" if ans.get("tools") else ""))
                if ans.get("citations"):
                    with st.expander(f"Cited document evidence ({len(ans['citations'])})"):
                        for c in ans["citations"]:
                            st.markdown(f"- **{c.get('title')}** ({c.get('reference') or 'n/a'}) "
                                        f"- {c.get('section')} &middot; `{c.get('path')}`")
            else:
                st.error(f"No answer produced. {ans.get('error') or ''}")

        st.info("The analyst can investigate, quantify, compare and recommend. It cannot confirm a "
                "breach or approve an assumption version - try the last starter question to see the "
                "governance boundary enforced.")

        st.markdown("## Search the governance corpus directly")
        dq = st.text_input("Document search", value="90% retention behavioural stability test")
        if dq:
            hits = data.doc_search(dq, 5)
            if hits.empty:
                st.info("No matches.")
            else:
                for _, h in hits.iterrows():
                    with st.expander(f"{h.get('DOC_TITLE')} ({h.get('DOC_REFERENCE') or 'n/a'}) "
                                     f"- {h.get('SECTION')}"):
                        st.caption(h.get("RELATIVE_PATH"))
                        st.markdown(str(h.get("CHUNK_TEXT"))[:2500])

    with right:
        st.markdown("## Structured evidence")
        row = data.assumption(aid)
        if row is not None:
            st.markdown(f"**{aid}** {ui.badge(row.STATUS)}", unsafe_allow_html=True)
            st.metric("Approved premise", ui.fmt_pct(row.EXPECTED_VALUE))
            st.metric("Observed", ui.fmt_pct(row.LATEST_OBSERVED_VALUE),
                      delta=f"{float(row.DEVIATION or 0) * 100:+.2f} pp")
            st.metric("Persistence", f"{int(row.OBSERVED_PERSISTENCE_DAYS or 0)} days",
                      help=f"Requires {int(row.PERSISTENCE_DAYS)} consecutive days")

        st.markdown("### Latest challenge record")
        ch = data.challenges(aid)
        if ch.empty:
            st.info("No challenge recorded. Run the challenger from the radar.")
        else:
            c = ch.iloc[0]
            st.write(f"**Status** {c.STATUS} &nbsp; **Confidence** {float(c.CONFIDENCE or 0):.0%}")
            st.write(f"**Robust z** {float(c.ROBUST_Z or 0):.2f} &nbsp; "
                     f"**Change point** {c.CHANGE_POINT_DATE}")
            st.caption(f"Method: {c.METHOD}")
            if c.EXPLANATION:
                st.markdown("**AI challenge note**")
                st.markdown(f'<div class="pf-quote">{c.EXPLANATION}</div>', unsafe_allow_html=True)
            else:
                if st.button("Generate AI challenge note"):
                    with st.spinner("Narrating the deterministic finding..."):
                        actions.explain_challenge(aid, "app_user")
                    st.rerun()

        st.markdown("### Approval-time evidence")
        ev = data.evidence(aid)
        if ev.empty:
            st.info("None recorded.")
        else:
            for _, e in ev.iterrows():
                st.markdown(f"- `{e.EVIDENCE_ID}` **{e.EVIDENCE_TYPE}** - {e.SUMMARY}")
                if e.SOURCE_DOCUMENT:
                    st.caption(f"Source: {e.SOURCE_DOCUMENT}")
