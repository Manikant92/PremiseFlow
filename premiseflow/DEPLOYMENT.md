# PremiseFlow Deployment

Account deployed to: **VJ24543** (org `VMMFGXC`, account `XJ76982`),
region `AWS_US_EAST_2`, Snowflake `10.34.101`.
Deployed by `MANIKANT92` using `ACCOUNTADMIN`.

> Synthetic data / illustrative risk calculations for hackathon demonstration.

## 1. What exists

| Object | Name |
|---|---|
| Warehouse | `PREMISEFLOW_WH` (XSMALL, auto-suspend 120s, auto-resume) |
| Database | `PREMISEFLOW` |
| Schemas | `RAW`, `CORE`, `AI`, `APP`, `AUDIT`, `TEST` |
| Stages | `AI.DOCS` (documents), `APP.APP_STAGE` (app + SQL artifacts) |
| Tables | 45 base tables |
| Views | 79 (including 5 dynamic tables) |
| Dynamic tables | `CORE.DT_GOVERNED_DAILY`, `DT_RETENTION_DAILY`, `DT_DEPOSIT_DAILY`, `DT_ASSUMPTION_CONTEXT`, `DT_ASSUMPTION_OBSERVATIONS` |
| Semantic view | `AI.PREMISEFLOW_SEMANTIC` |
| Cortex Search | `AI.PREMISEFLOW_DOC_SEARCH` |
| Cortex Agent | `AI.PREMISEFLOW_AGENT` |
| Streamlit app | `APP.PREMISEFLOW_APP` |
| Procedures | 25 |
| Tasks | `APP.T_PREMISEFLOW_MONITOR` (**started**, daily 06:00 UTC), `APP.T_PREMISEFLOW_MONITOR_DEMO` (**suspended**, 10 min) |
| Roles | `PREMISEFLOW_VIEWER`, `PREMISEFLOW_ANALYST`, `PREMISEFLOW_APPROVER` |

### Opening the app

Snowsight → **Projects → Streamlit** → *PremiseFlow - Continuous Assumption
Intelligence*.

Direct URL:
`https://app.snowflake.com/VMMFGXC/XJ76982/#/streamlit-apps/PREMISEFLOW.APP.PREMISEFLOW_APP`

## 2. No CLI was available

Neither `snow` nor `cortex` is installed on the build machine, so deployment does
not use the Snowflake CLI. Instead:

1. SQL scripts are authored locally in `sql/`.
2. They are uploaded with `PUT` to `@PREMISEFLOW.APP.APP_STAGE/sql/`.
3. They are executed with `EXECUTE IMMEDIATE FROM @.../<script>.sql`.

Streamlit files are uploaded the same way to
`@PREMISEFLOW.APP.APP_STAGE/premiseflow/` and the app points at that root.

**Files must be written without a UTF-8 BOM.** `EXECUTE IMMEDIATE FROM` fails with
`syntax error ... unexpected 'S'` on a BOM, and Python fails with
`invalid non-printable character U+FEFF`. PowerShell's `Set-Content -Encoding utf8`
adds one; use `[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))`.
The app lint (`TEST.LINT_APP`) catches this for Python files and did in fact catch
it during this build.

## 3. Full redeploy from scratch

Run in order. Every script is idempotent.

```sql
-- 1. Upload
PUT 'file://<repo>/premiseflow/sql/*.sql' @PREMISEFLOW.APP.APP_STAGE/sql/
    AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- 2. Foundation and model
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/01_database.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/02_raw_tables.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/03_core_tables.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/04_audit_tables.sql;

USE WAREHOUSE PREMISEFLOW_WH;

-- 3. Data (approx 3-5 minutes on XSMALL)
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/06_generate_synthetic_data.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/05_seed_reference_data.sql;

-- 4. Observation layer and views
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/07_dynamic_tables.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/08_views.sql;

-- 5. Engines and governance
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/10_procedures.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/10b_governance_procedures.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/10c_demo_and_qa.sql;

-- 6. Documents, search, semantic layer, agent
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/12_cortex_search.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/09_semantic_view.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/13_agent.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/17_assumption_miner.sql;

-- 7. Scheduling, roles, actor registry  (grants before the actor registry,
--    because 10d grants to the roles that 14 creates)
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/11_tasks.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/14_grants.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/10d_governance_actors.sql;

-- 8. Test harness
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/15_validation.sql;
EXECUTE IMMEDIATE FROM @PREMISEFLOW.APP.APP_STAGE/sql/16_app_lint.sql;
```

Documents must be staged before `12_cortex_search.sql`:

```sql
PUT 'file://<repo>/premiseflow/documents/liquidity_policy/*.md'   @PREMISEFLOW.AI.DOCS/liquidity_policy/   AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://<repo>/premiseflow/documents/model_methodology/*.md'  @PREMISEFLOW.AI.DOCS/model_methodology/  AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://<repo>/premiseflow/documents/alco/*.md'               @PREMISEFLOW.AI.DOCS/alco/               AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://<repo>/premiseflow/documents/validation/*.md'         @PREMISEFLOW.AI.DOCS/validation/         AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
ALTER STAGE PREMISEFLOW.AI.DOCS REFRESH;
```

Streamlit deploy:

```sql
PUT 'file://<repo>/premiseflow/app/streamlit_app.py'   @PREMISEFLOW.APP.APP_STAGE/premiseflow/            AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://<repo>/premiseflow/app/components/*.py'    @PREMISEFLOW.APP.APP_STAGE/premiseflow/components/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://<repo>/premiseflow/app/services/*.py'      @PREMISEFLOW.APP.APP_STAGE/premiseflow/services/   AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://<repo>/premiseflow/app/views/*.py'         @PREMISEFLOW.APP.APP_STAGE/premiseflow/views/      AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

CREATE OR REPLACE STREAMLIT PREMISEFLOW.APP.PREMISEFLOW_APP
  ROOT_LOCATION = '@PREMISEFLOW.APP.APP_STAGE/premiseflow'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = PREMISEFLOW_WH
  TITLE = 'PremiseFlow - Continuous Assumption Intelligence';
```

Then verify:

```sql
CALL PREMISEFLOW.TEST.RUN_ALL(NULL);
CALL PREMISEFLOW.TEST.LINT_APP();
```

## 4. Operating the scheduler

```sql
-- suspend / resume the production monitor
ALTER TASK PREMISEFLOW.APP.T_PREMISEFLOW_MONITOR SUSPEND;
ALTER TASK PREMISEFLOW.APP.T_PREMISEFLOW_MONITOR RESUME;

-- run one cycle immediately
EXECUTE TASK PREMISEFLOW.APP.T_PREMISEFLOW_MONITOR;
CALL PREMISEFLOW.APP.MONITORING_CYCLE();     -- or synchronously

-- 10-minute demo cadence: resume only during a demo, then suspend again
ALTER TASK PREMISEFLOW.APP.T_PREMISEFLOW_MONITOR_DEMO RESUME;
ALTER TASK PREMISEFLOW.APP.T_PREMISEFLOW_MONITOR_DEMO SUSPEND;

-- history
SELECT NAME, SCHEDULED_TIME, STATE, ERROR_MESSAGE
FROM TABLE(PREMISEFLOW.INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME=>'T_PREMISEFLOW_MONITOR'))
ORDER BY SCHEDULED_TIME DESC;
```

## 5. Permissions

No `ACCOUNTADMIN` is required to *use* the platform. Grant one of:

| Role | Can |
|---|---|
| `PREMISEFLOW_VIEWER` | Read everything; change nothing |
| `PREMISEFLOW_ANALYST` | Viewer + run challenger, narrate, simulate, ask, propose a version |
| `PREMISEFLOW_APPROVER` | Analyst + confirm breach, approve/reject version, resolve reassessment, reset/run demo |

```sql
GRANT ROLE PREMISEFLOW_APPROVER TO USER <user>;
```

A human must **also** be registered in `CORE.GOVERNANCE_ACTORS` to perform a
governed action — RBAC alone is not sufficient, by design:

```sql
INSERT INTO PREMISEFLOW.CORE.GOVERNANCE_ACTORS
  (ACTOR_ID, FULL_NAME, ACTOR_ROLE, CAN_CONFIRM_BREACH, CAN_APPROVE_VERSION, ACTIVE)
SELECT 'jane.doe','Jane Doe','Head of Treasury Risk',TRUE,TRUE,TRUE;
```

No secrets are stored anywhere in this repository or in Snowflake.

## 6. Deviations from the requested specification

| Requested | Actual | Reason |
|---|---|---|
| `app/pages/` | `app/views/` | A `pages/` directory next to a Streamlit entrypoint triggers automatic multipage discovery and would produce a second navigation control competing with the sidebar router. |
| `src/` engine packages | Snowflake stored procedures (`sql/10*.sql`, `sql/17_*.sql`); `src/README.md` maps them | Engines must execute server-side inside the governance boundary. Duplicating them as untested local modules would be misleading. |
| `sql/00_environment.sql` | Environment discovery was performed interactively and recorded in this document | Nothing needed to be created; the output is the capability matrix in section 7. |
| Single `10_procedures.sql` | `10_`, `10b_`, `10c_`, `10d_` | Split by responsibility. |
| Verified queries inside the semantic view | `AI.VERIFIED_QUERIES` table | Semantic *view* DDL has no verified-query clause; that belongs to the YAML semantic model format. |
| Jira / Slack MCP | `CORE.ACTION_OUTBOX` + `MCP_SETUP.md` | No MCP server is configured in this workspace. |

## 7. Capability matrix as discovered

| Capability | Status |
|---|---|
| Cortex AI functions (`AI_COMPLETE`, model `claude-sonnet-4-5`) | Available |
| `AI_PARSE_DOCUMENT` | Available — used for all 6 documents |
| Cortex Search | Available |
| Cortex Agents | Available (REST invocation only) |
| Semantic views | Available |
| Dynamic tables | Available |
| Tasks | Available |
| Streamlit in Snowflake | Available |
| `claude-4-sonnet` model alias | **Legacy/rejected** — use `claude-sonnet-4-5` |
| `snow` CLI / `cortex` CLI | **Not installed** — deployment uses PUT + EXECUTE IMMEDIATE FROM |
| MCP servers (Jira, Slack, Teams) | **None configured** |
| Git | Available (2.48.1); the workspace is not a git repository |

## 8. Known limitations

1. **External integrations are queued, not delivered.** No Jira/Slack/Teams MCP
   server is configured. Two Jira and two Slack payloads sit in
   `CORE.ACTION_OUTBOX` with status `PENDING`, and `AUDIT.INTEGRATION_ACTIONS`
   records them as `QUEUED_OUTBOX`. Tests J5/J6 are reported as
   `PASS_FEATURE_UNAVAILABLE`, **not** as passes of the live integration.
2. **The UI has not been visually verified by the build process.** Opening a
   Streamlit-in-Snowflake app requires an authenticated Snowsight session. What
   *was* verified: all 15 modules compile and import cleanly with streamlit,
   pandas and altair present; all 8 views expose `render()`; the app layer
   contains no direct DML; and all 28 queries the UI issues execute and return
   rows. Visual layout, chart rendering and widget interaction remain manual
   steps — see `MANUAL TEST STEPS` in the build report.
3. **Two of ten registry assumptions are data-driven.** A-DEP-001 (retention) and
   A-DEP-002 (deposit beta) are computed from generated data. The other eight
   carry representative series in `CORE.STATIC_OBSERVATIONS` so the registry reads
   as a platform. This is stated in the app's registry page.
4. **The risk calculation is illustrative.** A four-category runoff model with a
   single linear retention sensitivity. It is not an LCR calculation.
5. **Miner duplicate detection is heuristic** (metric-code match plus word
   overlap), so a rephrased duplicate can be reported as new.
6. **`RAW_ALM_RESULTS`, `RAW_MODEL_RESULTS`, `RAW_ALCO_DECISIONS` and
   `RAW_ASSUMPTION_SOURCE_DATA` are empty.** They exist to complete the
   source-system picture; the governed equivalents in `CORE` are what the
   platform reads.
7. **Cortex Agent answer quality is not asserted automatically.** Agents are
   REST-only, so test group G asserts against `APP.ASK_PREMISEFLOW`, which reads
   the same evidence. The agent itself is exercised manually from the app.
8. **Change-point dates on stationary assumptions are meaningless.** The detector
   always returns its best split; only interpret it when a challenge exists.
