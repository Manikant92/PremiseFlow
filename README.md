# PremiseFlow

**Continuously test what must remain true for financial decisions to remain valid.**

PremiseFlow is a Continuous Assumption Intelligence platform for banks, built
entirely on Snowflake. Ordinary monitoring watches models and metrics. PremiseFlow
watches the **assumptions underneath them**. When reality stops supporting an
assumption, it detects the break, explains it, traces every model and decision
that depends on it, quantifies the impact, and hands the decision back to a human.

> **Hackathon proof of concept.** All data, documents, committees and decisions are
> fully synthetic, with no real PII. The risk calculations are deliberately simplified
> and transparent, and they are **not** regulatory calculations.

## The story in one table

| | Value |
|---|---|
| Total deposits since the behaviour change | **+4.6%** (what normal monitoring sees) |
| Deposits the assumption is actually about | **−24%** (what PremiseFlow sees) |
| Incumbent retention vs approved premise | **78.4% vs 90%** for 39 consecutive days |
| Illustrative LCR, approved vs reality | **118% → ~98%** |
| Prior committee decisions reopened | 2 (2 unrelated decisions untouched) |

*The model didn't drift. Reality drifted away from the assumption underneath it.*

## Built on Snowflake

Dynamic Tables · Python stored procedures · Snowflake Tasks · Cortex AI
(`AI_COMPLETE`, `AI_PARSE_DOCUMENT`) · Cortex Search · Semantic Views ·
Cortex Agents · Streamlit in Snowflake. Built and tested with
**Cortex Code (CoCo) Desktop**.

## Repository layout

```
premiseflow/
  README.md                  full product overview  <- start here
  DEMO_GUIDE.md              3-5 minute presentation script
  ARCHITECTURE.md            how it fits together
  DATA_MODEL.md              tables, synthetic data, the seeded break
  ASSUMPTION_METHODOLOGY.md  assumption contracts, detection, governance
  TEST_PLAN.md               161 automated checks and what they prove
  DEPLOYMENT.md              how to deploy, operate, permissions, limitations
  MCP_SETUP.md               wiring Jira / Slack (no secrets in repo)
  sql/                       numbered, idempotent deployment scripts
  app/                       Streamlit in Snowflake application (8 pages)
  documents/                 synthetic governance corpus
  tests/                     test entrypoints + UI render smoke test
  src/                       pointer: engines live in Snowflake procedures
.snowflake/cortex/skills/    Cortex Code skills: premiseflow-mine, -challenge,
                             -impact, -reassess, -demo
```

## Quick start

Deploy with the steps in [`premiseflow/DEPLOYMENT.md`](premiseflow/DEPLOYMENT.md), then:

```sql
CALL PREMISEFLOW.APP.RESET_DEMO();                 -- approved baseline
CALL PREMISEFLOW.APP.RUN_DEMO('manikant.kella');   -- valid -> breached -> reassessed
CALL PREMISEFLOW.TEST.RUN_ALL(NULL);               -- automated verification
```

Open the app in Snowsight: **Projects → Streamlit → PremiseFlow**.
