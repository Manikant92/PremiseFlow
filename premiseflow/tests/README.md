# tests/

The test logic lives **in Snowflake**, for the same reason the engines do: it has
to assert against 3.2 million rows and it has to be runnable by the scheduler and
by a reviewer who has only a SQL connection. The files here are entrypoints and
the mapping from the requested structure to the groups that exist.

```sql
CALL PREMISEFLOW.TEST.RUN_ALL(NULL);      -- groups A-K  (123 assertions)
CALL PREMISEFLOW.TEST.RUN_ALL('D,E,K');   -- selected groups
CALL PREMISEFLOW.TEST.LINT_APP();         -- group L     (38 assertions)
```

Results accumulate in `PREMISEFLOW.TEST.TEST_RESULTS` with expected value, actual
value, diagnostic detail, criticality and duration.

## Entrypoints in this directory

| File | Purpose |
|---|---|
| `sql/run_all.sql` | Full suite plus a per-group summary and a list of anything that did not pass |
| `regression/primary_scenario.sql` | Permanent guard on the seeded structural break, the masking effect and consequence propagation |
| `demo/replay.sql` | Reset, run the demo, then verify every stage landed |

## Mapping to the requested layout

| Requested | Implemented as | Where |
|---|---|---|
| `tests/sql/` | Groups A, B, C, I — schema, referential integrity, ground truth, every application query | `sql/15_validation.sql` |
| `tests/unit/` | Group D — the deterministic challenger decision rules, exercised through `RUN_CHALLENGER` with an explicit as-of date, including a single-outlier injection | `sql/15_validation.sql` |
| `tests/integration/` | Groups E, F, G, H, J — impact propagation, the governance boundary and versioning, grounded Q&A, document retrieval, the external-action outbox | `sql/15_validation.sql` |
| `tests/regression/` | Group K + `regression/primary_scenario.sql` | `sql/15_validation.sql` |
| `tests/demo/` | `demo/replay.sql` | this directory |
| (additional) | Group L — static application verification: compile, import with streamlit/pandas/altair, `render()` present, no direct DML in the app layer | `sql/16_app_lint.sql` |

## Why group D is a unit test without a unit-test framework

The decision rules are pure arithmetic — `breach_side`, `consecutive_run`,
`robust_z`, `change_point` — but they live inside a Snowflake Python procedure and
there is no local Python runtime on the build machine. They are therefore exercised
through their public surface with a controlled input: `RUN_CHALLENGER` takes an
explicit `AS_OF` date, so the same series can be replayed at a date before the
break (expect `VALID`), mid-deterioration (expect `CHALLENGED`), on the first day
below the breach threshold (expect **not** `BREACHED`, persistence 1 of 5) and at
the latest date (expect `BREACHED`). Test D5 goes further and injects a single
extreme outlier into an unrelated healthy assumption to prove one noisy point
cannot raise a breach, then rolls it back and asserts the rollback (D5b).

## What is not covered automatically

| Area | Why |
|---|---|
| Visual layout, charts, widget interaction | Requires an authenticated Snowsight session |
| Cortex Agent answer quality | Agents are REST-only; group G asserts against `APP.ASK_PREMISEFLOW`, which reads the same evidence sources |
| Live Jira / Slack delivery | No MCP server configured. Reported as `PASS_FEATURE_UNAVAILABLE`, never as a pass |

See `../TEST_PLAN.md` for the full assertion list and for the five real bugs this
suite caught during the build.
