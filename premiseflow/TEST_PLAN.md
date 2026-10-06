# PremiseFlow Test Plan

Harness: `PREMISEFLOW.TEST.RUN_ALL(<groups>)` and `PREMISEFLOW.TEST.LINT_APP()`.
Results land in `PREMISEFLOW.TEST.TEST_RESULTS` with expected value, actual value,
diagnostic detail, criticality and duration, so a failure is diagnosable without
re-running.

```sql
CALL PREMISEFLOW.TEST.RUN_ALL(NULL);      -- groups A-K
CALL PREMISEFLOW.TEST.RUN_ALL('D,E,K');   -- selected groups
CALL PREMISEFLOW.TEST.LINT_APP();         -- group L
```

## Outcome vocabulary

| Outcome | Meaning |
|---|---|
| `PASS` | Assertion held |
| `PASS_FEATURE_UNAVAILABLE` | An optional capability is absent; core unaffected. **Never used to claim a blocked integration works.** |
| `FAIL` | Assertion did not hold |
| `BLOCKED` | Could not be evaluated. Counted as a critical failure, never as a pass. |

## Latest result

| Group | Area | Total | Pass | Unavailable | Fail | Blocked |
|---|---|---|---|---|---|---|
| A | Environment | 9 | 9 | 0 | 0 | 0 |
| B | Referential integrity | 10 | 10 | 0 | 0 | 0 |
| C | Synthetic ground truth | 11 | 11 | 0 | 0 | 0 |
| D | Assumption engine | 10 | 10 | 0 | 0 | 0 |
| E | Impact propagation | 9 | 9 | 0 | 0 | 0 |
| F | Governance | 16 | 16 | 0 | 0 | 0 |
| G | Agent / grounded Q&A | 9 | 9 | 0 | 0 | 0 |
| H | Document search | 7 | 7 | 0 | 0 | 0 |
| I | Application queries | 28 | 28 | 0 | 0 | 0 |
| J | External integration | 6 | 4 | 2 | 0 | 0 |
| K | Regression | 8 | 8 | 0 | 0 | 0 |
| **A–K total** | | **123** | **121** | **2** | **0** | **0** |
| L | Static app verification | 38 | 38 | 0 | 0 | 0 |
| **ALL** | | **161** | **159** | **2** | **0** | **0** |

Critical failures: **0**.

## What each group asserts

### A — Environment (9)
Six schemas exist; a warehouse is active; 16 core tables and 4 audit tables
present; at least 5 dynamic tables; at least 6 staged documents; the semantic view
answers a query; the monitoring task exists; the Streamlit object is queryable.

### B — Referential integrity (10)
No orphan accounts, transactions or daily balances. No balance predating its
account's opening date. Exactly one current version per assumption. No dangling
dependency, decision-dependency or reassessment references. No negative balances.

### C — Synthetic ground truth (11)
The planted break behaves as designed: minimum pre-break retention ≥ 0.90;
latest retention within 0.74–0.82; total range ≥ 10pp; total deposits since the
break ≥ −0.5% (the masking); governed pool since the break ≤ −15%; promotional
deposits exist; promotional funding share > 5% (envelope condition breached);
ground-truth record present; channel retention spread ≥ 5pp (heterogeneous, so
decomposition is diagnostic); 5k–12k customers; ≥ 20k transactions.

### D — Assumption engine (10)
- **D1** As-of a date before the break → `VALID`.
- **D2** As-of break + 40 days → `CHALLENGED`.
- **D3** As-of the **first** day below the breach threshold → **not** `BREACHED`,
  because persistence is 1 of 5.
- **D4** As-of the latest date → `BREACHED` with persistence satisfied.
- **D5** A single injected outlier (A-LIQ-001 driven to 0.10 on one day only)
  must not create a breach.
- **D5b** That injection is rolled back cleanly and the assumption returns to `VALID`.
- **D6** Detected change point within 21 days of the seeded break (actual: ~8).
- **D7** A two-sided assumption within its bounds stays `VALID`.
- **D8** A-DEP-002 (deposit beta) is independently detected as challenged/breached.
- **D9** Challenge records carry a method and evidence ids.

### E — Impact propagation (9)
Baseline LCR in 112–124%; observed LCR in 92–104%; reduction ≥ 12pp; observed LCR
below the 110% internal limit; a funding gap opens; NII falls; the dependency chain
reaches all five expected downstream objects; every scenario result carries a POC
disclaimer and a formula.

### F — Governance (16)
The actor guard accepts a registered human and rejects an agent, a spoofed system
id, a model name and an unregistered identity; the registry is populated; an AI
actor attempting `APPROVE_NEW_VERSION` raises `GOVERNANCE_VIOLATION`; the rejected
attempt leaves the version `PROPOSED`; human approval creates a new current
version; **the previous approved version is byte-identical afterwards** (approval
status, approver and statement); exactly one version is current; the superseded
version is no longer current; versioning writes audit events and human actions; no
reassessment exists for an unconfirmed breach; confirmed breaches record a
confirmer.

### G — Agent / grounded Q&A (9)
Six substantive questions must return an answer containing expected evidence
(retention and the 90% premise; MV-2025-042 and the cohort study; what changed for
A-DEP-001; the dependent ALCO decisions; the LCR comparison; the driving cohort).
A seventh asks the system to approve an assumption and requires a refusal
referencing human governance. Plus: the agent object exists; AI runs are auditable
with model and prompt version.

Agents are REST-only, so these assert against `APP.ASK_PREMISEFLOW`, which reads
the same semantic layer and document corpus. The Cortex Agent itself is exercised
manually from the app.

### H — Document search (7)
Four searches must retrieve the right document (policy LRP-2026-v4 for the
stability test; MV-2025-042 for the reproduction; the ALCO pack for the buffer
rationale; the approval record for the validity envelope). Plus ≥ 40 chunks;
A-DEP-001 traceable to ≥ 3 documents; at least one document parsed via
`AI_PARSE_DOCUMENT`.

### I — Application queries (28)
Every query the Streamlit app issues is executed and must return rows. This is the
guard against a page rendering empty or throwing. Includes one verified query
executed from `AI.VERIFIED_QUERIES`.

### J — External integration (6)
A Jira action is queued; its payload carries assumption id, approved value,
observed value, affected decision, evidence reference, reassessment id and impact
summary; the outbox is idempotent on the dedupe key (no duplicates from repeated
testing); the attempt is recorded in `AUDIT.INTEGRATION_ACTIONS`.
**J5 and J6 are `PASS_FEATURE_UNAVAILABLE`** — no Jira or Slack MCP server is
configured, so no live call was attempted and the live integration is explicitly
not claimed as tested.

### K — Regression (8)
The permanent guard on the primary scenario. It fails if PremiseFlow stops
detecting the seeded break:

1. A breached challenge exists for A-DEP-001.
2. A-DEP-001 status is `BREACHED`.
3. Shortfall against the approved premise ≥ 8pp.
4. Total deposits growing **while** the governed pool is down more than 10%.
5. `ALCO_DECISION_2026_017` is `REASSESSMENT_REQUIRED`.
6. `ALCO_DECISION_2026_009` and `_021` remain `APPROVED`.
7. A reassessment exists with quantified impact and a recommendation.
8. All five lifecycle event types are present in the audit trail.

### L — Static application verification (38)
Every staged module compiles; every non-entrypoint module **imports** with
streamlit, pandas and altair present (catching bad imports and module-level
errors); all eight views expose a callable `render()`; the entrypoint registers all
eight page names; the app layer contains no direct DML.

This does **not** prove visual layout, chart rendering or widget behaviour.

## Bugs this suite actually caught

Recorded because they are the argument for the suite existing:

1. **`IS_HUMAN_ACTOR` accepted `claude-sonnet-4-5` as human** (F4). The guard was a
   denylist and a model name slipped through. Replaced with an allowlist over
   `CORE.GOVERNANCE_ACTORS`.
2. **UTF-8 BOM in three `__init__.py` files** (L01–L03). Invalid Python; would have
   broken the deployed app's imports.
3. **Stale-state dependency in D8.** The test read a status left over from a reset
   instead of evaluating the assumption, which looked like a logic failure.
4. **SQL literal escaping.** `lit()` doubled quotes but not backslashes, and
   Snowflake processes backslash escapes, so LLM-generated text could corrupt a
   statement. Surfaced as an intermittent `BLOCKED` in group G.
5. **`AI_COMPLETE` returns `VARIANT`,** so Snowpark handed Python the JSON
   representation. Stored explanations began with a quote and contained literal
   `\n`; the miner's JSON parse failed at character 1.
6. **`IS_HUMAN_ACTOR` was defined in two files,** so the effective guard depended
   on script execution order. Re-running `10b_governance_procedures.sql` after
   `10d_governance_actors.sql` silently reinstated the weak denylist and regressed
   F4 and F4b on a later run. There is now exactly one definition, in `10d`. This
   is the strongest argument in the list for running the suite after *every*
   redeploy rather than once at the end.

## Manual coverage still required

| Area | Why it cannot be automated here |
|---|---|
| Visual layout and charts | Requires an authenticated Snowsight session |
| Widget interaction | Same |
| Cortex Agent answers | REST-only; no server-side invocation |
| Live Jira / Slack delivery | No MCP server configured |
