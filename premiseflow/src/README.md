# src/ — where the engines actually live

This directory intentionally contains **no Python modules**.

Every PremiseFlow engine runs server-side as a Snowflake stored procedure, next to
the 3.2 million rows it reads and inside the governance boundary it enforces.
Shipping a second, local copy here would be duplicated code that nothing executes
and no test covers, which is worse than a pointer.

| Requested module | Actual implementation | File |
|---|---|---|
| `assumption_miner/` | `APP.MINE_ASSUMPTIONS` — Cortex Search + `AI_COMPLETE`, writes `CORE.CANDIDATE_ASSUMPTIONS` | `sql/17_assumption_miner.sql` |
| `challenger/` | `APP.RUN_CHALLENGER` — deterministic thresholds, persistence runs, median/MAD robust z, max mean-shift change point, cohort decomposition | `sql/10_procedures.sql` |
| `impact_engine/` | `APP.RUN_IMPACT_FOR_ASSUMPTION` — baseline vs observed comparison and deltas | `sql/10_procedures.sql` |
| `simulation/` | `APP.RUN_IMPACT_SIMULATION` — the disclosed LCR / outflow / funding gap / NII calculation | `sql/10_procedures.sql` |
| `governance/` | `APP.IS_HUMAN_ACTOR`, `CONFIRM_BREACH`, `DISMISS_CHALLENGE`, `REQUEST_MORE_EVIDENCE`, `PROPOSE_NEW_VERSION`, `APPROVE_NEW_VERSION`, `REJECT_NEW_VERSION`, `RESOLVE_REASSESSMENT`, `TRIGGER_REASSESSMENTS` | `sql/10b_governance_procedures.sql`, `sql/10d_governance_actors.sql` |
| `integrations/` | `APP.QUEUE_OUTBOX_ACTION`, `APP.MARK_OUTBOX_SENT` → `CORE.ACTION_OUTBOX`, `AUDIT.INTEGRATION_ACTIONS` | `sql/10b_governance_procedures.sql` |

Also relevant:

| Concern | Implementation |
|---|---|
| Observation / reality layer | `sql/07_dynamic_tables.sql` (5 dynamic tables) |
| Grounded Q&A + demo control | `sql/10c_demo_and_qa.sql` |
| Document ingestion | `AI.INGEST_DOCUMENTS` in `sql/12_cortex_search.sql` |
| Test harness | `sql/15_validation.sql` (groups A–K), `sql/16_app_lint.sql` (group L) |

## Why server-side is the right call, not just the convenient one

1. **Data gravity.** The challenger reads a 3.2M-row balance history and a set of
   dynamic tables. Pulling that to a client to make a threshold comparison would be
   absurd.
2. **The governance boundary must be non-bypassable.** `IS_HUMAN_ACTOR` is a SQL
   function evaluated inside the procedures that mutate governed state. A client-side
   guard could be bypassed by calling the procedure directly; a server-side one
   cannot.
3. **Auditability.** Every engine writes to `AUDIT.AUDIT_EVENTS` and
   `AUDIT.AGENT_RUNS` in the same transaction context as the state change it made.
4. **Scheduling.** `APP.T_PREMISEFLOW_MONITOR` calls `APP.MONITORING_CYCLE` with no
   external runtime, no container and no credential.

## Reading the engine code

The Python handler bodies are inline in the SQL files, delimited by `$$`. To read
the deployed version instead:

```sql
SELECT PROCEDURE_NAME, ARGUMENT_SIGNATURE, PROCEDURE_DEFINITION
FROM PREMISEFLOW.INFORMATION_SCHEMA.PROCEDURES
WHERE PROCEDURE_SCHEMA = 'APP' ORDER BY PROCEDURE_NAME;
```
