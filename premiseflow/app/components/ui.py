"""PremiseFlow shared UI: enterprise risk-management styling and components."""
from __future__ import annotations

import streamlit as st

# PremiseFlow palette. Deliberately restrained: risk teams read these screens
# for hours and saturated colour is read as noise.
INK = "#0E1726"
SLATE = "#5A6779"
LINE = "#E1E6ED"
CANVAS = "#F6F8FB"
ACCENT = "#1F5FA8"

STATUS_COLOURS = {
    "VALID":        ("#0B6B4F", "#E4F4EE"),
    "WATCH":        ("#8A5B00", "#FBF0DC"),
    "CHALLENGED":   ("#A33C00", "#FCEADF"),
    "UNDER_REVIEW": ("#4B3A8F", "#EDE9F8"),
    "BREACHED":     ("#A11B1B", "#FBE4E4"),
    "RETIRED":      ("#5A6779", "#EEF1F5"),
}
DECISION_COLOURS = {
    "APPROVED":               ("#0B6B4F", "#E4F4EE"),
    "REASSESSMENT_REQUIRED":  ("#A11B1B", "#FBE4E4"),
    "REAFFIRMED":             ("#1F5FA8", "#E7EFF9"),
    "SUPERSEDED":             ("#5A6779", "#EEF1F5"),
}
MATERIALITY_COLOURS = {
    "CRITICAL": ("#A11B1B", "#FBE4E4"),
    "HIGH":     ("#A33C00", "#FCEADF"),
    "MEDIUM":   ("#8A5B00", "#FBF0DC"),
    "LOW":      ("#5A6779", "#EEF1F5"),
}

POC_BANNER = (
    "Synthetic data / illustrative risk calculations for hackathon demonstration. "
    "Not a regulatory calculation."
)


def inject_theme() -> None:
    st.markdown(
        f"""
        <style>
          .stApp {{ background: {CANVAS}; }}
          .block-container {{ padding-top: 1.6rem; max-width: 1400px; }}
          h1, h2, h3, h4 {{ color: {INK}; letter-spacing: -0.01em; }}
          h1 {{ font-size: 1.75rem; font-weight: 700; }}
          h2 {{ font-size: 1.25rem; font-weight: 650; margin-top: 1.4rem; }}
          h3 {{ font-size: 1.05rem; font-weight: 600; }}

          .pf-masthead {{
            background: linear-gradient(95deg, {INK} 0%, #1B2B45 55%, {ACCENT} 100%);
            color: #fff; padding: 1.1rem 1.4rem; border-radius: 10px; margin-bottom: 0.5rem;
          }}
          .pf-masthead .pf-name {{ font-size: 1.35rem; font-weight: 700; letter-spacing: -0.02em; }}
          .pf-masthead .pf-tag  {{ font-size: 0.9rem; opacity: 0.88; margin-top: 0.15rem; }}

          .pf-poc {{
            background: #FFF8E1; border: 1px solid #EBD9A3; color: #6B5415;
            padding: 0.5rem 0.8rem; border-radius: 7px; font-size: 0.8rem; margin: 0.6rem 0 1.1rem 0;
          }}

          .pf-card {{
            background: #fff; border: 1px solid {LINE}; border-radius: 10px;
            padding: 0.95rem 1.1rem; height: 100%;
          }}
          .pf-card-label {{ font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.07em;
                            color: {SLATE}; font-weight: 650; }}
          .pf-card-value {{ font-size: 1.85rem; font-weight: 700; color: {INK}; line-height: 1.15;
                            margin-top: 0.2rem; }}
          .pf-card-sub   {{ font-size: 0.78rem; color: {SLATE}; margin-top: 0.15rem; }}

          .pf-badge {{
            display: inline-block; padding: 0.16rem 0.55rem; border-radius: 999px;
            font-size: 0.72rem; font-weight: 700; letter-spacing: 0.03em;
          }}

          .pf-hero {{
            background: #fff; border: 1px solid {LINE}; border-left: 5px solid #A11B1B;
            border-radius: 10px; padding: 1.1rem 1.3rem;
          }}
          .pf-hero-ok {{ border-left-color: #0B6B4F; }}

          .pf-flow {{ font-size: 0.78rem; color: {SLATE}; letter-spacing: 0.02em; }}
          .pf-flow b {{ color: {INK}; }}

          .pf-quote {{
            background: #fff; border-left: 3px solid {ACCENT}; padding: 0.7rem 1rem;
            border-radius: 0 7px 7px 0; font-size: 0.88rem; color: {INK};
          }}
          .pf-meta {{ font-size: 0.78rem; color: {SLATE}; }}
          div[data-testid="stMetricValue"] {{ font-size: 1.5rem; }}
          .stTabs [data-baseweb="tab"] {{ font-size: 0.88rem; }}
        </style>
        """,
        unsafe_allow_html=True,
    )


def masthead(page_title: str) -> None:
    st.markdown(
        f"""
        <div class="pf-masthead">
          <div class="pf-name">PremiseFlow &nbsp;&middot;&nbsp; {page_title}</div>
          <div class="pf-tag">Continuously test what must remain true for financial decisions to remain valid.</div>
        </div>
        """,
        unsafe_allow_html=True,
    )
    st.markdown(f'<div class="pf-poc">{POC_BANNER}</div>', unsafe_allow_html=True)


def badge(text: str, palette: dict | None = None) -> str:
    palette = palette or STATUS_COLOURS
    fg, bg = palette.get(str(text).upper(), (SLATE, "#EEF1F5"))
    return f'<span class="pf-badge" style="color:{fg};background:{bg}">{text}</span>'


def kpi(label: str, value: str, sub: str = "", tone: str | None = None) -> None:
    colour = INK
    if tone == "bad":
        colour = "#A11B1B"
    elif tone == "good":
        colour = "#0B6B4F"
    elif tone == "warn":
        colour = "#A33C00"
    st.markdown(
        f"""<div class="pf-card">
              <div class="pf-card-label">{label}</div>
              <div class="pf-card-value" style="color:{colour}">{value}</div>
              <div class="pf-card-sub">{sub}</div>
            </div>""",
        unsafe_allow_html=True,
    )


LIFECYCLE = [
    "ASSUMPTION VALID", "REALITY CHANGES", "ASSUMPTION CHALLENGED", "BREACH CONFIRMED",
    "DOWNSTREAM IMPACT", "DECISIONS REASSESSMENT REQUIRED", "HUMAN REVIEWS",
    "NEW ASSUMPTION VERSION", "MONITORING CONTINUES",
]


def lifecycle_strip(active: str | None = None) -> None:
    """The narrative spine of the product, shown as a breadcrumb."""
    parts = []
    for stage in LIFECYCLE:
        if active and stage == active:
            parts.append(f"<b>{stage}</b>")
        else:
            parts.append(stage)
    st.markdown('<div class="pf-flow">' + " &rarr; ".join(parts) + "</div>", unsafe_allow_html=True)


def poc_note(text: str = "") -> None:
    st.caption("Hackathon POC - illustrative simplified risk calculation. " + text)


def fmt_pct(v, digits: int = 2) -> str:
    return "-" if v is None else f"{float(v) * 100:.{digits}f}%"


def fmt_pct_pts(v, digits: int = 1) -> str:
    return "-" if v is None else f"{float(v):.{digits}f}%"


def fmt_musd(v, digits: int = 1) -> str:
    return "-" if v is None else f"${float(v):,.{digits}f}m"
