# PremiseFlow

**Continuously test what must remain true for financial decisions to remain valid.**

PremiseFlow is a Continuous Assumption Intelligence platform for banks. Ordinary
monitoring watches models, metrics, balances and outcomes. PremiseFlow watches
the layer underneath: **the assumptions those things rest on.**

> **Synthetic data / illustrative risk calculations for hackathon demonstration.**
> Every customer, account, balance, transaction, document, committee and decision
> in this repository is generated. There is no real PII. The liquidity
> calculations are deliberately simplified and transparent so that propagation
> from assumption to risk number is auditable; they are **not** regulatory
> calculations.

---

## The problem, in one screen

At the demo end date the synthetic bank looks healthy:

| What monitoring watches | Value |
|---|---|
| Total deposits | **$1,474m, growing ~4.6% since the behaviour change** |

At the same moment:

| What the assumption is actually about | Value |
|---|---|
| Incumbent retail salary + linked savings deposits | **down ~24%** |
| Rolling 90-day incumbent retention | **78.4% against an approved 90% premise** |
| New promotional money masking the outflow | **$167m, 11.2% of funding** |

Aggregate deposit growth is not evidence of behavioural stability. New-customer
inflows offset and therefore conceal incumbent attrition. PremiseFlow measures
the cohort the assumption is stated about, and it keeps measuring it.

The consequence, once propagated:

| Scenario | Retention premise | Illustrative LCR |
|---|---|---|
| Approved premise (what the committee decided on) | 90.0% | **118.0%** |
| Observed reality | 78.4% | **~98%** |

That crosses both the 110% internal management threshold and the 100%
regulatory minimum, and it reopens two previously approved committee decisions.

**The model did not drift. Reality drifted away from the assumption underneath it.**

---

## What it does

1. **Governs assumptions as first-class objects** - each with an owner, a
   quantified threshold, a challenge level, a breach level, a persistence
   requirement, a validity envelope, supporting evidence and an immutable
   version history.
2. **Continuously attempts to falsify them** using deterministic analytics:
   rolling windows, cohort decomposition, threshold persistence, median/MAD
   robust deviation and maximum mean-shift change-point detection.
3. **Explains what changed** with an LLM that narrates a decision already made
   by deterministic code. The model never decides a threshold outcome.
4. **Traces the blast radius** through models, metrics, reports, policies and
   prior decisions.
5. **Simulates the consequence** with a fully disclosed, drillable calculation.
6. **Reopens affected decisions** into `REASSESSMENT_REQUIRED` without altering
   the historical decision record.
7. **Requires a human** to confirm a breach and to approve any revised
   assumption, enforced by an allowlist of registered governance actors.
8. **Preserves everything** in an append-only audit trail, including which model
   and prompt version produced each piece of AI-generated content.

---

## Repository layout

```
premiseflow/
  sql/          numbered, idempotent deployment scripts (01 -> 17)
  app/          Streamlit in Snowflake application
    components/ shared UI (theme, KPI cards, status badges)
    services/   data access, governed actions, Cortex Agent client
    views/      the eight pages
  documents/    synthetic governance corpus (policy, methodology, ALCO, validation)
  tests/        test harness entrypoints and mapping
  src/          see src/README.md - engines live in Snowflake, not here
.snowflake/cortex/skills/
  premiseflow-mine | -challenge | -impact | -reassess | -demo
```

Docs: [ARCHITECTURE](ARCHITECTURE.md) · [DATA_MODEL](DATA_MODEL.md) ·
[ASSUMPTION_METHODOLOGY](ASSUMPTION_METHODOLOGY.md) · [DEMO_GUIDE](DEMO_GUIDE.md) ·
[TEST_PLAN](TEST_PLAN.md) · [DEPLOYMENT](DEPLOYMENT.md) · [MCP_SETUP](MCP_SETUP.md)

---

## Quick start

Already deployed to the connected account. To open it:

Snowsight → **Projects → Streamlit** → **PremiseFlow - Continuous Assumption Intelligence**
(`PREMISEFLOW.APP.PREMISEFLOW_APP`)

To drive it from SQL:

```sql
-- reset to the approved baseline (audit history is preserved)
CALL PREMISEFLOW.APP.RESET_DEMO();

-- advance the full scenario: valid -> challenged -> breached -> impact -> reassessment
CALL PREMISEFLOW.APP.RUN_DEMO('manikant.kella');

-- re-test every assumption against current reality
CALL PREMISEFLOW.APP.RUN_CHALLENGER(NULL, 'me', NULL);

-- verify the whole platform
CALL PREMISEFLOW.TEST.RUN_ALL(NULL);
CALL PREMISEFLOW.TEST.LINT_APP();
```

To redeploy from scratch, see [DEPLOYMENT.md](DEPLOYMENT.md).

---

## The primary governed assumption

**A-DEP-001 — Retail Salary Deposit Stability** (CRITICAL, Treasury Risk)

> Retail salary-account deposits retain at least **90%** of incumbent balances
> over a rolling **90-day** horizon under normal operating conditions.

| Parameter | Value |
|---|---|
| Expected (approved premise) | 0.90 |
| Challenge threshold | 0.88 |
| Breach threshold | 0.85 |
| Persistence requirement | 5 observation days |
| Metric | `INCUMBENT_SALARY_RETENTION_90D` |

Validity envelope: policy rate 4.00–5.25%, promotional funding share ≤5%,
deposit concentration ≤18%, digital acquisition share ≤45%, normal operating
conditions. **The promotional funding condition is currently breached at 11.2%**,
which independently invalidates reliance even before the headline metric is
considered.

---

## Design decisions worth knowing

- **Deterministic first, LLM second.** No numeric threshold outcome is ever
  decided by a language model. `APP.RUN_CHALLENGER` is pure Python arithmetic;
  `APP.EXPLAIN_CHALLENGE` only writes prose about a result that already exists.
- **Persistence, not point excursions.** A single noisy observation cannot create
  a breach. This is tested explicitly by injecting an outlier (test D5).
- **Allowlist, not denylist, for human authority.** An earlier denylist guard
  accepted `claude-sonnet-4-5` as a human; the automated suite caught it. Authority
  is now membership of `CORE.GOVERNANCE_ACTORS`.
- **Approved history is never overwritten.** Superseding a version sets only
  `IS_CURRENT` and `VALID_TO`. The approver, timestamp and statement of the old
  version remain exactly as approved (test F8).
- **Heterogeneous attrition.** Aggregator- and digitally-acquired, shorter-tenure
  customers leave 2.5x faster than branch-acquired long-tenure customers, so
  cohort decomposition actually answers "who caused this".
- **The metric is smoothed for a reason.** Salary accounts have a month-start
  payroll bump, so a point-in-time ratio 90 days apart picks up a day-of-month
  artifact. A 30-day trailing average removes it, and for exponential decay the
  ratio of two 30-day averages equals the underlying point ratio exactly.

---

## Known limitations

See [DEPLOYMENT.md](DEPLOYMENT.md#known-limitations) for the full list. The
headline ones: no Jira/Slack MCP connector is configured so external actions are
queued in an outbox rather than delivered; the Streamlit UI has been statically
verified (compile + import + every query executed) but not visually inspected by
the build process; and only A-DEP-001 and A-DEP-002 are wired to generated data,
with the remaining eight registry assumptions carrying representative series.
