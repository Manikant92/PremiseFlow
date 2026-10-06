"""Page 5 - Impact Graph (assumption dependency blast radius)."""
from __future__ import annotations

import pandas as pd
import streamlit as st

from components import ui
from services import data

TYPE_STYLE = {
    "ASSUMPTION":  ("#1F5FA8", "premise"),
    "MODEL":       ("#4B3A8F", "model"),
    "METRIC":      ("#0B6B4F", "metric"),
    "DECISION":    ("#A11B1B", "decision"),
    "POLICY":      ("#8A5B00", "policy"),
    "CALCULATION": ("#5A6779", "calculation"),
    "REPORT":      ("#5A6779", "report"),
}


def _node(label: str, ntype: str, extra: str = "", dimmed: bool = False) -> str:
    colour, _ = TYPE_STYLE.get(ntype, ("#5A6779", ""))
    opacity = "0.45" if dimmed else "1"
    return (f'<div style="opacity:{opacity};background:#fff;border:1px solid #E1E6ED;'
            f'border-left:4px solid {colour};border-radius:8px;padding:0.5rem 0.7rem;'
            f'margin:0.3rem 0;">'
            f'<div style="font-size:0.82rem;font-weight:700;color:#0E1726">{label}</div>'
            f'<div style="font-size:0.7rem;color:#5A6779;text-transform:uppercase;'
            f'letter-spacing:0.05em">{ntype}{extra}</div></div>')


def render() -> None:
    ui.masthead("Impact Graph")
    a = data.assumptions()
    ids = a.ASSUMPTION_ID.tolist()
    cur = st.session_state.get("selected_assumption", "A-DEP-001")
    idx = ids.index(cur) if cur in ids else 0
    aid = st.selectbox("Assumption", ids, index=idx,
                       format_func=lambda x: f"{x} - {a[a.ASSUMPTION_ID == x].iloc[0].NAME}")
    st.session_state.selected_assumption = aid

    row = data.assumption(aid)
    br = data.blast_radius(aid)

    if br.empty:
        st.info("No downstream dependencies recorded for this assumption.")
        return

    k = st.columns(4)
    with k[0]: ui.kpi("Downstream objects", f"{br.TARGET_OBJECT.nunique()}", "unique nodes reached")
    with k[1]: ui.kpi("Critical edges", f"{int((br.MATERIALITY == 'CRITICAL').sum())}", "critical materiality",
                      tone="bad" if (br.MATERIALITY == "CRITICAL").any() else None)
    with k[2]: ui.kpi("Max depth", f"{int(br.DEPTH.max())}", "propagation hops")
    with k[3]: ui.kpi("Decisions reached", f"{int((br.TARGET_TYPE == 'DECISION').sum())}",
                      "governed decisions")

    st.markdown("## Propagation by depth")
    st.caption(f"Reading left to right: the premise, then everything that consumes it. "
               f"Assumption status is currently **{row.STATUS}**.")

    max_depth = int(br.DEPTH.max())
    cols = st.columns(max_depth + 1)
    with cols[0]:
        st.markdown("**Premise**")
        st.markdown(_node(aid, "ASSUMPTION", f" &middot; {row.STATUS}"), unsafe_allow_html=True)

    dec_status = {d.DECISION_REF: d.GOVERNANCE_STATUS for _, d in data.decisions().iterrows()}
    dec_by_id = {d.DECISION_ID: d.DECISION_REF for _, d in data.decisions().iterrows()}

    for depth in range(1, max_depth + 1):
        layer = br[br.DEPTH == depth].drop_duplicates(subset=["TARGET_OBJECT"])
        with cols[depth]:
            st.markdown(f"**Depth {depth}**")
            for _, e in layer.iterrows():
                extra = f" &middot; {e.MATERIALITY}"
                if e.TARGET_TYPE == "DECISION":
                    ref = dec_by_id.get(e.TARGET_OBJECT, e.TARGET_OBJECT)
                    stat = dec_status.get(ref)
                    if stat:
                        extra += f" &middot; {stat}"
                st.markdown(_node(e.TARGET_OBJECT, e.TARGET_TYPE, extra), unsafe_allow_html=True)

    st.markdown("## Primary chain")
    chain = br[(br.MATERIALITY == "CRITICAL")].sort_values("DEPTH")
    if not chain.empty:
        longest = chain.loc[chain.PATH.str.len().idxmax()].PATH
        st.markdown(f'<div class="pf-quote">{longest.replace(" > ", " &nbsp;&rarr;&nbsp; ")}</div>',
                    unsafe_allow_html=True)

    st.markdown("## All dependency edges")
    st.dataframe(
        br[["DEPTH", "SOURCE_OBJECT", "SOURCE_TYPE", "RELATIONSHIP_TYPE", "TARGET_OBJECT",
            "TARGET_TYPE", "MATERIALITY", "SENSITIVITY_NOTE"]].rename(columns={
                "DEPTH": "Depth", "SOURCE_OBJECT": "From", "SOURCE_TYPE": "From type",
                "RELATIONSHIP_TYPE": "Relationship", "TARGET_OBJECT": "To",
                "TARGET_TYPE": "To type", "MATERIALITY": "Materiality",
                "SENSITIVITY_NOTE": "Sensitivity"}),
        use_container_width=True, hide_index=True)

    st.markdown("## Decisions at the end of the chain")
    dec = data.affected_decisions(aid)
    if dec.empty:
        st.info("No decisions declared a dependency on this assumption.")
    else:
        for _, d in dec.iterrows():
            st.markdown(
                f"""<div class="pf-card" style="margin-bottom:0.6rem">
                  <div style="font-weight:700">{d.DECISION_REF} &middot; {d.TITLE}</div>
                  <div style="margin:0.35rem 0">
                    {ui.badge(d.GOVERNANCE_STATUS, ui.DECISION_COLOURS)} &nbsp;
                    {ui.badge(d.RELIANCE_STRENGTH, ui.MATERIALITY_COLOURS)} &nbsp;
                    <span class="pf-meta">relied on {d.RELIED_ON_VERSION_ID}
                    &middot; decided {d.DECISION_DATE}</span>
                  </div>
                  <div class="pf-meta">{d.RELIANCE_NOTE}</div>
                </div>""", unsafe_allow_html=True)

    st.markdown("## Objects NOT affected")
    unaffected = data.decisions()
    unaffected = unaffected[~unaffected.DECISION_REF.isin(dec.DECISION_REF.tolist() if not dec.empty else [])]
    if unaffected.empty:
        st.caption("Every registered decision depends on this assumption.")
    else:
        st.caption("Blast radius is bounded. These decisions declared no dependency and are untouched:")
        st.dataframe(unaffected[["DECISION_REF", "TITLE", "GOVERNANCE_STATUS"]],
                     use_container_width=True, hide_index=True)

    ui.lifecycle_strip("DOWNSTREAM IMPACT")
