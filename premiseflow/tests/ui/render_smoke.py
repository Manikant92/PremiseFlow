"""Render smoke test for the PremiseFlow Streamlit app.

Loads the app modules from the stage and calls every page's render() in
Streamlit "bare mode" against live data, twice:
  pass 1 - normal: buttons return False
  pass 2 - clicks: every button/toggle returns True, so every on-click branch
           executes. Governed actions are stubbed so nothing is mutated, and
           st.rerun is stubbed so a click does not abort the page.
Any exception is a failure. Runs under whatever Streamlit version the calling
procedure pins, which is the point: one proc pins the SiS default (1.22.0),
another pins the version in environment.yml.
"""
import importlib.util
import sys
import traceback
import types

from snowflake.snowpark.files import SnowflakeFile

STAGE = '@PREMISEFLOW.APP.APP_STAGE/premiseflow'
MODULES = [
    ('components', None), ('services', None), ('views', None),
    ('components.compat', 'components/compat.py'),
    ('components.ui', 'components/ui.py'),
    ('services.data', 'services/data.py'),
    ('services.actions', 'services/actions.py'),
    ('services.agent', 'services/agent.py'),
] + [(f'views.{n}', f'views/{n}.py') for n in (
    'p1_radar', 'p2_registry', 'p3_detail', 'p4_evidence',
    'p5_impact', 'p6_scenario', 'p7_reassessment', 'p8_audit')]


class _Anything(dict):
    """Stand-in result for stubbed governed actions: any key, any shape."""
    def get(self, k, default=None):
        v = super().get(k, default)
        return v if v is not None else (default if default is not None else _Anything())
    def __getitem__(self, k):
        return self.get(k)
    def __iter__(self):
        return iter([])
    def __bool__(self):
        return True
    def __str__(self):
        return 'stub'
    def __format__(self, spec):
        return 'stub'


class _Rerun(Exception):
    pass


def _load():
    for name in [m for m in list(sys.modules) if m.split('.')[0] in ('components', 'services', 'views')]:
        del sys.modules[name]
    for name, path in MODULES:
        if path is None:
            pkg = types.ModuleType(name)
            pkg.__path__ = []
            sys.modules[name] = pkg
            continue
        with SnowflakeFile.open(f'{STAGE}/{path}', 'r', require_scoped_url=False) as f:
            src = f.read()
        spec = importlib.util.spec_from_loader(name, loader=None)
        mod = importlib.util.module_from_spec(spec)
        mod.__file__ = path
        sys.modules[name] = mod
        exec(compile(src, path, 'exec'), mod.__dict__)
        parent, _, leaf = name.rpartition('.')
        setattr(sys.modules[parent], leaf, mod)


def run(session):
    import streamlit as st
    version = st.__version__
    _load()
    import streamlit as st  # compat has now patched it

    actions = sys.modules['services.actions']
    data = sys.modules['services.data']
    st.session_state['pf_session'] = session

    results = []
    pages = [m for m, _ in MODULES if m.startswith('views.p')]

    for mode in ('render', 'click'):
        originals = {}
        if mode == 'click':
            originals['_call'] = actions._call
            actions._call = lambda *a, **k: _Anything()
            for w in ('button', 'toggle', 'checkbox'):
                originals[w] = getattr(st, w)
                setattr(st, w, (lambda *a, **k: True))
            try:
                from streamlit.delta_generator import DeltaGenerator
                originals['dg_button'] = DeltaGenerator.button
                DeltaGenerator.button = lambda self, *a, **k: True
            except Exception:
                pass
        originals['rerun'] = st.rerun
        def _raise_rerun(*a, **k):
            raise _Rerun()
        st.rerun = _raise_rerun

        for p in pages:
            st.session_state['selected_assumption'] = 'A-DEP-001'
            st.session_state['actor_id'] = 'manikant.kella'
            st.session_state['actor_role'] = 'Head of Treasury Risk'
            st.session_state.pop('pf_answer', None)
            try:
                data.clear_caches()
                sys.modules[p].render()
                results.append({'mode': mode, 'page': p, 'outcome': 'PASS'})
            except _Rerun:
                results.append({'mode': mode, 'page': p, 'outcome': 'PASS', 'note': 'reached st.rerun'})
            except Exception as e:
                results.append({'mode': mode, 'page': p, 'outcome': 'FAIL',
                                'error': f'{type(e).__name__}: {e}'[:400],
                                'trace': traceback.format_exc()[-1500:]})

        st.rerun = originals['rerun']
        if mode == 'click':
            actions._call = originals['_call']
            for w in ('button', 'toggle', 'checkbox'):
                setattr(st, w, originals[w])
            if 'dg_button' in originals:
                from streamlit.delta_generator import DeltaGenerator
                DeltaGenerator.button = originals['dg_button']

    fails = [r for r in results if r['outcome'] != 'PASS']
    return {'streamlit_version': version, 'checks': len(results),
            'passed': len(results) - len(fails), 'failed': len(fails), 'failures': fails}
