"""Streamlit version compatibility.

The Streamlit-in-Snowflake warehouse runtime ships an older Streamlit than the
APIs the views use. Rather than pin every call site to the oldest version, this
module back-fills missing APIs and makes widget calls tolerant of keyword
arguments the installed version does not know. Import it before any view.
"""
from __future__ import annotations

import functools
import inspect
import re
import types

import streamlit as st

_UNEXPECTED_KW = re.compile(r"unexpected keyword argument '([^']+)'")


def _tolerant(fn):
    """Retry a Streamlit call, dropping keyword args the runtime rejects."""
    if getattr(fn, "_pf_tolerant", False):
        return fn

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        for _ in range(8):
            try:
                return fn(*args, **kwargs)
            except TypeError as e:
                m = _UNEXPECTED_KW.search(str(e))
                if not m or m.group(1) not in kwargs:
                    raise
                kwargs.pop(m.group(1))
        return fn(*args, **kwargs)

    wrapper._pf_tolerant = True
    return wrapper


def _patch() -> None:
    # --- rerun ------------------------------------------------------------
    if not hasattr(st, "rerun"):
        st.rerun = getattr(st, "experimental_rerun")

    # --- divider ----------------------------------------------------------
    if not hasattr(st, "divider"):
        st.divider = lambda: st.markdown("---")

    # --- toggle -> checkbox -----------------------------------------------
    if not hasattr(st, "toggle"):
        st.toggle = st.checkbox

    # --- column_config: views build configs eagerly, so the attribute must
    #     exist even if dataframe() will then discard it -----------------------
    if not hasattr(st, "column_config"):
        def _noop(*_a, **_k):
            return None
        st.column_config = types.SimpleNamespace(
            NumberColumn=_noop, DatetimeColumn=_noop, TextColumn=_noop,
            ProgressColumn=_noop, Column=_noop)

    # --- cache_data -------------------------------------------------------
    if not hasattr(st, "cache_data"):
        st.cache_data = st.experimental_memo

    # --- keyword-tolerant widgets -----------------------------------------
    for name in ("dataframe", "button", "selectbox", "text_input", "text_area",
                 "number_input", "slider", "radio", "checkbox", "toggle",
                 "altair_chart", "bar_chart", "line_chart", "metric",
                 "expander", "tabs", "columns", "caption", "json", "code"):
        fn = getattr(st, name, None)
        if callable(fn):
            setattr(st, name, _tolerant(fn))

    # Widgets created via column objects (`cols[0].button(...)`) go through
    # DeltaGenerator, so patch the class as well.
    try:
        from streamlit.delta_generator import DeltaGenerator
        for name in ("dataframe", "button", "selectbox", "text_input", "text_area",
                     "number_input", "slider", "radio", "checkbox",
                     "altair_chart", "bar_chart", "metric", "caption", "json"):
            fn = getattr(DeltaGenerator, name, None)
            if callable(fn) and not getattr(fn, "_pf_tolerant", False):
                setattr(DeltaGenerator, name, _tolerant(fn))
        if not hasattr(DeltaGenerator, "toggle"):
            DeltaGenerator.toggle = DeltaGenerator.checkbox
        if not hasattr(DeltaGenerator, "divider"):
            DeltaGenerator.divider = lambda self: self.markdown("---")
    except Exception:
        pass


_patch()

STREAMLIT_VERSION = getattr(st, "__version__", "unknown")
