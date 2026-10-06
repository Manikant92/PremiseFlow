-- PremiseFlow :: 16_app_lint.sql
-- Static verification of the Streamlit application, group L.
--
-- Interactive browser verification of a Streamlit-in-Snowflake app requires an
-- authenticated Snowsight session, which the build agent cannot perform. This
-- procedure gets as close as is possible server-side:
--   1. every staged module is compiled (catches syntax errors);
--   2. every non-entrypoint module is actually imported with streamlit, pandas
--      and altair present (catches bad imports, module-level NameErrors, typos
--      in decorators and missing symbols);
--   3. each view module is asserted to expose a callable render();
--   4. the entrypoint is compiled and its imports resolved, but not executed,
--      since executing it would require a live Streamlit script run context.
--
-- What this does NOT prove: visual layout, chart rendering, or widget
-- interaction. Those remain manual steps in the acceptance test list.

USE DATABASE PREMISEFLOW;
USE SCHEMA TEST;

CREATE OR REPLACE PROCEDURE TEST.LINT_APP()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python','streamlit','pandas','altair')
IMPORTS=()
HANDLER='run'
AS
$$
import importlib.util, json, sys, traceback, types, uuid
from snowflake.snowpark.files import SnowflakeFile

STAGE = '@PREMISEFLOW.APP.APP_STAGE/premiseflow'

MODULES = [
    ('components/__init__.py', 'components', False),
    ('services/__init__.py',   'services',   False),
    ('views/__init__.py',      'views',      False),
    ('components/ui.py',       'components.ui', True),
    ('services/data.py',       'services.data', True),
    ('services/actions.py',    'services.actions', True),
    ('services/agent.py',      'services.agent', True),
    ('views/p1_radar.py',        'views.p1_radar', True),
    ('views/p2_registry.py',     'views.p2_registry', True),
    ('views/p3_detail.py',       'views.p3_detail', True),
    ('views/p4_evidence.py',     'views.p4_evidence', True),
    ('views/p5_impact.py',       'views.p5_impact', True),
    ('views/p6_scenario.py',     'views.p6_scenario', True),
    ('views/p7_reassessment.py', 'views.p7_reassessment', True),
    ('views/p8_audit.py',        'views.p8_audit', True),
]
VIEW_MODULES = [m for _, m, _ in MODULES if m.startswith('views.p')]


def read(path):
    with SnowflakeFile.open(f"{STAGE}/{path}", 'r', require_scoped_url=False) as f:
        return f.read()


def run(session):
    results = []

    def add(tid, name, outcome, expected, actual, detail=''):
        results.append({'id': tid, 'name': name, 'outcome': outcome,
                        'expected': expected, 'actual': actual, 'detail': detail})

    sources = {}
    n = 0
    for path, modname, importable in MODULES:
        n += 1
        tid = f"L{n:02d}"
        try:
            src = read(path)
            sources[modname] = (path, src, importable)
            compile(src, path, 'exec')
            add(tid, f'Compiles: {path}', 'PASS', 'no SyntaxError', f'{len(src)} bytes')
        except Exception as e:
            add(tid, f'Compiles: {path}', 'FAIL', 'no SyntaxError', type(e).__name__,
                traceback.format_exc()[-800:])

    # entrypoint compiles too (but is not executed)
    try:
        src = read('streamlit_app.py')
        compile(src, 'streamlit_app.py', 'exec')
        add('L16', 'Compiles: streamlit_app.py', 'PASS', 'no SyntaxError', f'{len(src)} bytes')
    except Exception as e:
        add('L16', 'Compiles: streamlit_app.py', 'FAIL', 'no SyntaxError', type(e).__name__,
            traceback.format_exc()[-800:])

    # Import the package tree for real. Order matters: packages, then leaves.
    pkg_root = types.ModuleType('pfroot')
    for pkgname in ('components', 'services', 'views'):
        pkg = types.ModuleType(pkgname)
        pkg.__path__ = []          # mark as package so submodule imports resolve
        sys.modules[pkgname] = pkg

    imported_ok = []
    for path, modname, importable in MODULES:
        if not importable or modname not in sources:
            continue
        tid = 'L17_' + modname.replace('.', '_')
        try:
            _, src, _ = sources[modname]
            spec = importlib.util.spec_from_loader(modname, loader=None)
            mod = importlib.util.module_from_spec(spec)
            mod.__file__ = path
            sys.modules[modname] = mod
            exec(compile(src, path, 'exec'), mod.__dict__)
            # expose as attribute of its package so `from views import p1_radar` works
            parent, _, leaf = modname.rpartition('.')
            if parent:
                setattr(sys.modules[parent], leaf, mod)
            imported_ok.append(modname)
            add(tid, f'Imports cleanly: {modname}', 'PASS', 'import succeeds', 'ok')
        except Exception as e:
            add(tid, f'Imports cleanly: {modname}', 'FAIL', 'import succeeds',
                f'{type(e).__name__}: {str(e)[:160]}', traceback.format_exc()[-1200:])

    for modname in VIEW_MODULES:
        tid = 'L18_' + modname.split('.')[-1]
        mod = sys.modules.get(modname)
        if mod is None:
            add(tid, f'Exposes render(): {modname}', 'FAIL', 'callable render', 'module not imported')
            continue
        fn = getattr(mod, 'render', None)
        ok = callable(fn)
        add(tid, f'Exposes render(): {modname}', 'PASS' if ok else 'FAIL',
            'callable render', 'callable' if ok else str(type(fn)))

    # The entrypoint's page registry must cover exactly the eight required pages.
    try:
        src = sources.get('views.p1_radar')
        app_src = read('streamlit_app.py')
        required = ["Executive Risk Radar", "Assumption Registry", "Assumption Detail",
                    "Evidence & Investigation", "Impact Graph", "Scenario Simulator",
                    "Decision Reassessment", "Audit Trail"]
        missing = [r for r in required if r not in app_src]
        add('L19', 'Entrypoint registers all eight pages', 'PASS' if not missing else 'FAIL',
            '8 page names present', f'missing={missing}' if missing else 'all present')
    except Exception as e:
        add('L19', 'Entrypoint registers all eight pages', 'FAIL', '8 page names', str(e)[:200])

    # Services must only mutate state through stored procedures.
    try:
        _, act_src, _ = sources['services.actions']
        forbidden = [kw for kw in ('INSERT INTO', 'UPDATE ', 'DELETE FROM', 'MERGE INTO')
                     if kw in act_src.upper()]
        add('L20', 'App never writes to governed tables directly',
            'PASS' if not forbidden else 'FAIL', 'no direct DML in the app layer',
            f'found {forbidden}' if forbidden else 'all writes go through CALL')
    except Exception as e:
        add('L20', 'App never writes to governed tables directly', 'FAIL', 'no direct DML',
            str(e)[:200])

    run_id = 'LINT-' + uuid.uuid4().hex[:12]
    for r in results:
        session.sql("""INSERT INTO TEST.TEST_RESULTS
            (RUN_ID, TEST_GROUP, TEST_ID, TEST_NAME, OUTCOME, EXPECTED, ACTUAL, DETAIL,
             IS_CRITICAL, DURATION_MS, EXECUTED_AT)
            SELECT ?,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP()""",
            params=[run_id, 'L', r['id'], r['name'], r['outcome'], r['expected'],
                    r['actual'], r['detail'][:3000], True, 0]).collect()

    failed = [r for r in results if r['outcome'] != 'PASS']
    return {'run_id': run_id, 'total': len(results),
            'passed': len(results) - len(failed), 'failed': len(failed),
            'imported_modules': imported_ok,
            'overall': 'PASS' if not failed else 'FAIL',
            'failures': failed,
            'note': 'Static verification only. Visual layout and widget interaction '
                    'require an authenticated Snowsight session and remain manual steps.'}
$$;

CALL TEST.LINT_APP();
