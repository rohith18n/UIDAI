"""
Presentation layer for the bench.

Palette follows qctool's cream/amber so the two tools look like one product. The font
stack is deliberately local — qctool pulls DM Sans from Google Fonts, which the README's
offline goal rules out for anything meant to run on a demo machine with no network.
"""

import streamlit as st

STATUS_TONE = {
    "pass": ("#1e6f45", "#e6f4ec", "PASS"),
    "warn": ("#8a5b11", "#fff3d7", "WARN"),
    "fail": ("#b33a33", "#fbeae9", "FAIL"),
    "skip": ("#5b6470", "#eef0f3", "N/A"),
}

CSS = """
<style>
:root {
    --bg: #f7f2e8;
    --panel: #fffdfa;
    --stroke: rgba(184, 120, 0, 0.16);
    --stroke-strong: rgba(184, 120, 0, 0.32);
    --text: #1b1d21;
    --muted: #5b6470;
    --amber: #e0a020;
    --amber-deep: #b87800;
    --amber-soft: #fff3d7;
    --green: #1e6f45;
    --red: #b33a33;
    --shadow: 0 14px 34px rgba(110, 79, 19, 0.08);
    --radius-lg: 18px;
    --radius-md: 12px;
}

.stApp {
    background: linear-gradient(180deg, #fffaf3 0%, #f7f2e8 48%, #f2ecdf 100%);
    color: var(--text);
    font-family: "Segoe UI", "Inter", "Helvetica Neue", Arial, sans-serif;
}

.block-container { max-width: 1420px; padding-top: 1.2rem; padding-bottom: 3rem; }
#MainMenu, footer { visibility: hidden; }

.lab-header {
    display: flex; align-items: center; justify-content: space-between;
    gap: 1rem; padding: 1.05rem 1.3rem; margin-bottom: 1.1rem;
    border-radius: var(--radius-lg);
    background: linear-gradient(135deg, #ffffff, #fff7e7);
    border: 1px solid var(--stroke);
    box-shadow: var(--shadow);
}
.lab-title { margin: 0; font-size: 1.6rem; font-weight: 800; line-height: 1.1; }
.lab-sub { margin-top: .2rem; color: var(--amber-deep); font-size: .87rem; font-weight: 700; }
.lab-pill {
    display: inline-flex; align-items: center; gap: .4rem;
    padding: .45rem .8rem; border-radius: 999px;
    background: var(--amber-soft); border: 1px solid var(--stroke-strong);
    color: #6e4700; font-size: .82rem; font-weight: 800; white-space: nowrap;
}

/* ── Stage cards ─────────────────────────────────────────────────────────── */
.stage-card {
    border: 1px solid var(--stroke); border-radius: var(--radius-lg);
    background: var(--panel); box-shadow: var(--shadow);
    padding: .95rem 1.15rem; margin-bottom: .35rem;
}
.stage-top { display: flex; align-items: center; gap: .7rem; flex-wrap: wrap; }
.stage-ref {
    font-family: ui-monospace, "Cascadia Mono", Consolas, monospace;
    font-size: .76rem; font-weight: 800; letter-spacing: .04em;
    padding: .22rem .5rem; border-radius: 6px;
    background: #1b1d21; color: #fff7e7;
}
.stage-title { font-size: 1.02rem; font-weight: 800; margin: 0; }
.stage-chip {
    margin-left: auto; font-size: .72rem; font-weight: 800; letter-spacing: .05em;
    padding: .24rem .62rem; border-radius: 999px;
}
.stage-time {
    font-family: ui-monospace, "Cascadia Mono", Consolas, monospace;
    font-size: .78rem; color: var(--muted); font-weight: 700;
}
.stage-summary { margin-top: .45rem; color: var(--muted); font-size: .9rem; line-height: 1.45; }

/* ── Metric cards ────────────────────────────────────────────────────────── */
.metric-card {
    border: 1px solid var(--stroke); border-radius: var(--radius-md);
    background: var(--panel); padding: .7rem .85rem; height: 100%;
}
.metric-card--pass { border-left: 4px solid var(--green); }
.metric-card--warn { border-left: 4px solid var(--amber); }
.metric-card--fail { border-left: 4px solid var(--red); }
.metric-card--skip { border-left: 4px solid #b6bdc7; }
.metric-label { font-size: .72rem; font-weight: 800; letter-spacing: .06em;
                text-transform: uppercase; color: var(--muted); }
.metric-value { font-size: 1.28rem; font-weight: 800; margin-top: .15rem; }
.metric-hint  { font-size: .76rem; color: var(--muted); margin-top: .1rem; }

/* ── Identity card ───────────────────────────────────────────────────────── */
.id-card {
    border-radius: var(--radius-lg); padding: 1.15rem 1.35rem;
    background: linear-gradient(135deg, #ffffff, #eaf6ef);
    border: 1px solid rgba(30, 111, 69, 0.28);
    box-shadow: 0 16px 36px rgba(30, 111, 69, 0.12);
}
.id-card--reject {
    background: linear-gradient(135deg, #ffffff, #fbeae9);
    border-color: rgba(179, 58, 51, 0.28);
    box-shadow: 0 16px 36px rgba(179, 58, 51, 0.10);
}
.id-hi { font-size: 1.9rem; font-weight: 800; margin: 0 0 .15rem 0; }
.id-row { display: flex; gap: .5rem; font-size: .92rem; margin-top: .28rem; }
.id-key { color: var(--muted); font-weight: 700; min-width: 132px; }
.id-val { font-weight: 700; }
.id-val--mono { font-family: ui-monospace, "Cascadia Mono", Consolas, monospace; }

.note {
    border-left: 3px solid var(--amber); background: var(--amber-soft);
    padding: .6rem .8rem; border-radius: 8px; font-size: .84rem;
    color: #6e4700; margin: .5rem 0;
}
</style>
"""


def inject() -> None:
    st.markdown(CSS, unsafe_allow_html=True)


def header(title: str, subtitle: str, pill: str = "") -> None:
    st.markdown(
        f"""
        <div class="lab-header">
          <div>
            <div class="lab-title">{title}</div>
            <div class="lab-sub">{subtitle}</div>
          </div>
          <div class="lab-pill">{pill}</div>
        </div>
        """,
        unsafe_allow_html=True,
    )


def stage_header(ref: str, title: str, status: str, summary: str,
                 duration_ms: float = None, server_ms: float = None) -> None:
    colour, background, label = STATUS_TONE.get(status, STATUS_TONE["skip"])

    timing = ""
    if duration_ms:
        timing = f'<span class="stage-time">{duration_ms:,.0f} ms round trip</span>'
        if server_ms:
            timing = (f'<span class="stage-time">{duration_ms:,.0f} ms round trip · '
                      f'{server_ms:,.0f} ms server compute</span>')
    elif server_ms:
        timing = f'<span class="stage-time">{server_ms:,.0f} ms server compute</span>'

    st.markdown(
        f"""
        <div class="stage-card">
          <div class="stage-top">
            <span class="stage-ref">{ref}</span>
            <span class="stage-title">{title}</span>
            {timing}
            <span class="stage-chip" style="background:{background};color:{colour};">{label}</span>
          </div>
          <div class="stage-summary">{summary}</div>
        </div>
        """,
        unsafe_allow_html=True,
    )


def metric_card(label: str, value: str, hint: str = "", tone: str = "skip") -> None:
    st.markdown(
        f"""
        <div class="metric-card metric-card--{tone}">
          <div class="metric-label">{label}</div>
          <div class="metric-value">{value}</div>
          <div class="metric-hint">{hint}</div>
        </div>
        """,
        unsafe_allow_html=True,
    )


def note(text: str) -> None:
    st.markdown(f'<div class="note">{text}</div>', unsafe_allow_html=True)
