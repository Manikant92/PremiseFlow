---
name: premiseflow-demo
description: Run the deterministic PremiseFlow demo scenario end to end and narrate each stage, or reset it to the approved baseline. Use when asked to run the demo, reset the demo, replay the scenario, show the full flow, or rehearse the presentation. Triggers: run premiseflow demo, reset demo, replay scenario, show the whole flow, demo script, rehearse the pitch, full end to end demo.
---

# PremiseFlow: Run the Demo Scenario

Drives the reproducible demonstration: an approved assumption is valid, reality
drifts beneath it, the platform detects the breach, quantifies the downstream
consequence, and reopens the decisions that depended on it.

The core message: **the model did not drift, reality drifted away from the
assumption underneath it.**

## Reset to the approved baseline

```sql
CALL PREMISEFLOW.APP.RESET_DEMO();
```

Restores A-DEP-001 to approved v1, clears challenges, breaches, reassessments and
scenarios, and returns every decision to `APPROVED`. Audit history is
deliberately **not** cleared - say this, because it is a governance feature, not
an oversight.

Verify:

```sql
SELECT (SELECT COUNT_IF(STATUS='VALID') FROM PREMISEFLOW.CORE.ASSUMPTIONS)            AS VALID_ASSUMPTIONS,
       (SELECT COUNT_IF(GOVERNANCE_STATUS='APPROVED') FROM PREMISEFLOW.CORE.DECISIONS) AS APPROVED_DECISIONS,
       (SELECT COUNT(*) FROM PREMISEFLOW.CORE.REASSESSMENTS)                           AS OPEN_REASSESSMENTS,
       (SELECT COUNT(*) FROM PREMISEFLOW.AUDIT.AUDIT_EVENTS)                           AS AUDIT_EVENTS_PRESERVED;
```

Expect 10 valid assumptions, 4 approved decisions, 0 reassessments, and a
non-zero audit count.

## Advance the scenario

```sql
CALL PREMISEFLOW.APP.RUN_DEMO('manikant.kella');
```

This returns a `stages` array. Narrate it in order:

1. **ASSUMPTION VALID** - replayed as at 10 days before the behaviour change;
   retention about 92% against an approved 90% premise.
2. **ASSUMPTION CHALLENGED** - replayed 40 days after; retention about 87%, below
   the 88% challenge threshold, and persistent.
3. **BREACH DETECTED** - at the current date; retention about 78%, sustained for
   roughly 39 days against a 5-day persistence requirement. Status is
   `PENDING_HUMAN_CONFIRMATION`. Stress that the platform will not self-confirm.
4. **AI INVESTIGATION** - a narrative note explaining the cohort driver. The
   status was already decided deterministically; the model only explains it.
5. **HUMAN CONFIRMS BREACH** - a registered human governance actor.
6. **DOWNSTREAM IMPACT SIMULATED** - illustrative LCR moves from roughly 118% on
   the approved premise to roughly 98% on observed reality, through both the
   110% internal limit and the 100% regulatory minimum.
7. **DECISIONS REASSESSMENT REQUIRED** - ALCO-2026-017 and ALCO-2026-011 move to
   `REASSESSMENT_REQUIRED`; ALCO-2026-009 and ALCO-2026-021 are untouched.
8. **MONITORING CONTINUES** - the whole registry is re-tested.

## The point to make first

Before revealing anything, show that the aggregate view looks healthy:

```sql
SELECT ROUND(TOTAL_DEPOSITS/1e6,1)            AS TOTAL_USD_M,
       ROUND(TOTAL_DEPOSIT_GROWTH*100,2)      AS TOTAL_GROWTH_PCT,
       ROUND(GOVERNED_STABLE_DEPOSITS/1e6,1)  AS GOVERNED_STABLE_USD_M,
       ROUND(GOVERNED_DEPOSIT_GROWTH*100,2)   AS GOVERNED_GROWTH_PCT,
       ROUND(PROMOTIONAL_FUNDING_SHARE*100,2) AS PROMO_FUNDING_SHARE_PCT
FROM PREMISEFLOW.CORE.V_DEPOSIT_MASKING ORDER BY BALANCE_DATE DESC LIMIT 1;
```

Total deposits are growing. The deposits the assumption is actually about are
down more than 20%. New promotional money is the mask.

## Prove the detection is real

The dataset carries a recorded ground truth, so detection can be checked rather
than believed:

```sql
SELECT g.BREAK_START_DATE AS SEEDED_BREAK,
       g.EXPECTED_PRE_VALUE, g.EXPECTED_POST_VALUE,
       c.CHANGE_POINT_DATE AS DETECTED,
       ABS(DATEDIFF(day, g.BREAK_START_DATE, c.CHANGE_POINT_DATE)) AS ERROR_DAYS
FROM PREMISEFLOW.RAW.RAW_GROUND_TRUTH g
CROSS JOIN (SELECT CHANGE_POINT_DATE FROM PREMISEFLOW.CORE.ASSUMPTION_CHALLENGES
            WHERE ASSUMPTION_ID='A-DEP-001' ORDER BY EVALUATED_AT DESC LIMIT 1) c
WHERE g.ASSUMPTION_ID='A-DEP-001';
```

## Full verification

```sql
CALL PREMISEFLOW.TEST.RUN_ALL(NULL);        -- groups A-K
CALL PREMISEFLOW.TEST.LINT_APP();           -- group L, static app verification
```

Then read the summary:

```sql
SELECT TEST_GROUP, COUNT(*) AS TOTAL,
       COUNT_IF(OUTCOME='PASS') AS PASS,
       COUNT_IF(OUTCOME='PASS_FEATURE_UNAVAILABLE') AS UNAVAILABLE,
       COUNT_IF(OUTCOME='FAIL') AS FAIL,
       COUNT_IF(OUTCOME='BLOCKED') AS BLOCKED
FROM PREMISEFLOW.TEST.TEST_RESULTS
WHERE RUN_ID = (SELECT RUN_ID FROM PREMISEFLOW.TEST.TEST_RESULTS ORDER BY EXECUTED_AT DESC LIMIT 1)
GROUP BY 1 ORDER BY 1;
```

## Reporting rules

- Label every risk figure as an illustrative simplified POC calculation over
  fully synthetic data.
- Do not claim the app UI has been visually verified unless you have opened it.
- Never present the two queued external actions (Jira, Slack) as delivered. No
  MCP connector is configured; they sit in `PREMISEFLOW.CORE.ACTION_OUTBOX`.
