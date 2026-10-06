# PremiseFlow Architecture

> Synthetic data / illustrative risk calculations for hackathon demonstration.

## 1. Shape of the system

```
                    SYNTHETIC SOURCE DATA                 SYNTHETIC DOCUMENTS
              RAW.RAW_CUSTOMERS / ACCOUNTS /            @PREMISEFLOW.AI.DOCS
              DAILY_BALANCES / TRANSACTIONS /            (policy, methodology,
              MARKET_RATES / GROUND_TRUTH                 ALCO packs, validation)
                          |                                       |
                          v                                       v
            +-------------------------------+        AI_PARSE_DOCUMENT -> chunks
            |     OBSERVATION LAYER          |                     |
            |  (Dynamic Tables, 60 min lag)  |                     v
            |  DT_GOVERNED_DAILY             |         CORTEX SEARCH SERVICE
            |  DT_RETENTION_DAILY            |        AI.PREMISEFLOW_DOC_SEARCH
            |  DT_DEPOSIT_DAILY              |                     |
            |  DT_ASSUMPTION_CONTEXT         |                     |
            |  DT_ASSUMPTION_OBSERVATIONS    |                     |
            +-------------------------------+                      |
                          |                                        |
                          v                                        |
            +-----------------------------------+                  |
            |     REALITY CHALLENGER            |                  |
            |  APP.RUN_CHALLENGER (deterministic)|                 |
            |  thresholds + persistence run      |                 |
            |  median/MAD robust z               |                 |
            |  max mean-shift change point       |                 |
            |  cohort decomposition              |                 |
            +-----------------------------------+                  |
                          |                                        |
        status: VALID | WATCH | CHALLENGED | UNDER_REVIEW | BREACHED
                          |                                        |
        +-----------------+----------------+                       |
        v                                  v                       |
  APP.EXPLAIN_CHALLENGE            CORE.ASSUMPTION_BREACHES         |
  (LLM narrates only)              PENDING_HUMAN_CONFIRMATION       |
        |                                  |                        |
        |                        [ HUMAN CONFIRMS ] <-- IS_HUMAN_ACTOR
        |                                  |                        |
        |                                  v                        |
        |                  APP.TRIGGER_REASSESSMENTS                 |
        |                          |              |                 |
        |                          v              v                 |
        |            IMPACT SIMULATION      DECISIONS ->             |
        |      APP.RUN_IMPACT_SIMULATION    REASSESSMENT_REQUIRED    |
        |         LCR / outflow /                  |                 |
        |         funding gap / NII                v                 |
        |                          |        CORE.ACTION_OUTBOX       |
        |                          |        (Jira / Slack payloads)  |
        v                          v                                 v
   +--------------------------------------------------------------------+
   |            AUDIT (append-only): AUDIT_EVENTS, AGENT_RUNS,          |
   |            HUMAN_ACTIONS, INTEGRATION_ACTIONS                      |
   +--------------------------------------------------------------------+
                          |                        |
                          v                        v
        AI.PREMISEFLOW_SEMANTIC          APP.PREMISEFLOW_APP (Streamlit, 8 pages)
        AI.PREMISEFLOW_AGENT (Cortex Agent: semantic view + search)
```

Scheduling: `APP.T_PREMISEFLOW_MONITOR` (daily 06:00 UTC) calls
`APP.MONITORING_CYCLE`, which refreshes the dynamic tables, re-tests every active
assumption, narrates new critical breaches and pre-computes their impact. It
deliberately stops before creating reassessments, because that requires human
confirmation of the breach.

## 2. Schemas

| Schema | Contents |
|---|---|
| `RAW` | Synthetic source systems, generation config, recorded ground truth |
| `CORE` | Governed model: assumptions, versions, evidence, dependencies, observations, challenges, breaches, models, metrics, decisions, reassessments, scenarios, governance actors, outbox |
| `AI` | Document corpus and chunks, Cortex Search service, semantic view, Cortex Agent, verified queries |
| `APP` | Stored procedures (engines and governed actions), Streamlit app, app stage |
| `AUDIT` | Append-only events, agent runs, human actions, integration actions |
| `TEST` | Test harness and recorded results |

## 3. Where the intelligence lives, and why

### Deterministic core

`APP.RUN_CHALLENGER` is a Python stored procedure containing only arithmetic:

- `breach_side(direction, value, expected, threshold)` — which side of a threshold
  a value falls on, honouring `LOWER_IS_WORSE`, `UPPER_IS_WORSE` and `TWO_SIDED`.
- `consecutive_run(series, predicate)` — the unbroken run of threshold breaches
  ending at the latest observation. This is what prevents a single noisy point
  from being reported as a breach.
- `robust_z(baseline, value)` — median/MAD deviation against the regime the
  version was validated in. The scale is floored at 0.5% of the median because
  these series are extremely smooth and an unfloored MAD produces meaningless
  four-figure z-scores.
- `change_point(series)` — the split that maximises `|mean(after) - mean(before)|`.
  For A-DEP-001 this runs on the **daily log-return of the governed deposit
  pool**, not on the retention ratio. A rolling ratio is a lagging transform, so a
  change point found on it lands weeks late; the log-return mean shifts on the day
  behaviour changes. Measured against the recorded ground truth, detection lands
  within ~8 days of the seeded break.

Status is assigned by rule, never by a model:

```
BREACHED   if beyond breach threshold AND run >= persistence requirement
CHALLENGED if beyond challenge threshold AND run >= persistence requirement
WATCH      if a threshold is touched but not yet persistent, or outside approved bounds
VALID      otherwise
```

### LLM, strictly bounded

| Procedure | Model role |
|---|---|
| `APP.EXPLAIN_CHALLENGE` | Narrates a status that already exists. Writes `EXPLANATION` only. |
| `APP.ASK_PREMISEFLOW` | Answers questions from retrieved evidence. Read-only. |
| `APP.MINE_ASSUMPTIONS` | Proposes *candidate* contracts with `PROPOSED_BY_MINER`. |
| `AI.PREMISEFLOW_AGENT` | Investigation only. Has no tool that can write. |

Every AI call records model name, workflow/prompt version, timestamp and evidence
references in `AUDIT.AGENT_RUNS`.

Implementation note: `AI_COMPLETE` returns `VARIANT`, so a Snowpark fetch yields
the JSON representation of the string (leading quote, escaped newlines). Every
call therefore casts `::STRING` in SQL and additionally unwraps in Python.

### Two Q&A paths, deliberately

`AI.PREMISEFLOW_AGENT` is the real Cortex Agent and is what a user talks to; it is
invoked over REST from Streamlit via `_snowflake.send_snow_api_request`.
`APP.ASK_PREMISEFLOW` is a server-side grounded Q&A procedure over the same two
evidence sources. It exists because agents are REST-only and cannot be asserted
on from a SQL test harness, so it is what test group G exercises, and it is the
app's fallback path. Both are read-only.

## 4. The governance boundary

Enforced in three independent places:

1. **`APP.IS_HUMAN_ACTOR`** — allowlist membership of `CORE.GOVERNANCE_ACTORS`,
   plus a denylist of automated-looking identifiers as defence in depth.
   `CONFIRM_BREACH`, `APPROVE_NEW_VERSION`, `REJECT_NEW_VERSION`,
   `DISMISS_CHALLENGE`, `REQUEST_MORE_EVIDENCE` and `RESOLVE_REASSESSMENT` all
   reject non-human actors, raising `GOVERNANCE_VIOLATION`.
2. **Tool surface** — the Cortex Agent is given only
   `cortex_analyst_text_to_sql` and `cortex_search`. It has no tool that can write.
3. **RBAC** — `PREMISEFLOW_VIEWER` (read), `PREMISEFLOW_ANALYST` (detect, explain,
   simulate, propose), `PREMISEFLOW_APPROVER` (confirm, approve, resolve).

Immutability: approving a new version sets only `IS_CURRENT=FALSE` and `VALID_TO`
on the predecessor. Its `APPROVAL_STATUS`, `APPROVED_BY`, `APPROVED_AT` and
`STATEMENT` are left exactly as approved, which is asserted by test F8.

## 5. The impact calculation

Fully disclosed, in `CORE.LIQUIDITY_INPUTS` and `CORE.SIM_PARAMETERS`:

```
effective stable runoff = base stable runoff (0.05)
                        + max(0, approved retention - scenario retention) x sensitivity (0.80)

gross stressed outflows = retail stable        x effective stable runoff
                        + retail less stable   x 0.12
                        + wholesale funding    x 0.25
                        + other outflows

net cash outflow (NCO)  = gross outflows - min(expected inflows, 0.75 x gross outflows)
LCR                     = HQLA / NCO x 100

funding gap (90d)       = retail stable x max(0, approved retention - scenario retention)
NII (12m)               = total deposits x base NIM - funding gap x replacement spread
```

HQLA is calibrated once so that the **approved** premise yields 118%, which is the
number the ALCO decision was actually taken on. Everything else follows from the
retention input. Each `SCENARIO_RESULTS` row stores its formula, resolved inputs
and a POC disclaimer so the UI can drill all the way down.

## 6. Semantic layer and verified queries

`AI.PREMISEFLOW_SEMANTIC` exposes 15 logical tables, 11 relationships, ~60
dimensions, 22 facts and 20 metrics with business synonyms (cohort, retention,
stable deposits, blast radius, reassessment, LCR).

Semantic **view** DDL has no verified-query clause — verified queries belong to
the YAML semantic *model* format. The eight curated question/SQL pairs are
therefore registered in `AI.VERIFIED_QUERIES` and surfaced by the app and the
agent instructions. Test I28 executes one of them to prove they stay valid.

## 7. Deviations from the requested layout

| Requested | Actual | Why |
|---|---|---|
| `app/pages/` | `app/views/` | A `pages/` directory adjacent to a Streamlit entrypoint triggers automatic multipage discovery, which would create a second navigation control competing with the sidebar router. |
| `src/` engine modules | Snowflake stored procedures in `sql/10*.sql`, `sql/17_*.sql` | The engines must run server-side, next to the data and inside the governance boundary. See `src/README.md` for the mapping rather than duplicated, untested copies. |
| `sql/10_procedures.sql` only | also `10b`, `10c`, `10d` | Split by responsibility: engines, governance, demo/Q&A, actor registry. |
| `sql/15_validation.sql` only | also `16_app_lint.sql`, `17_assumption_miner.sql` | Static app verification and the miner are separable concerns. |
