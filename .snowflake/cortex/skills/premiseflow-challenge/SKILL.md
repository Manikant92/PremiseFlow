---
name: premiseflow-challenge
description: Re-test PremiseFlow governed assumptions against current reality and report evidence-backed challenge results. Use when asked to challenge an assumption, re-test assumptions, check assumption health, find breached assumptions, or explain why an assumption broke. Triggers: challenge assumption, re-test assumption, assumption health, is A-DEP-001 still valid, why did the assumption break, run the reality challenger.
---

# PremiseFlow: Challenge Assumptions

Re-tests active assumptions against observed data and reports the outcome with
evidence. Threshold outcomes are decided deterministically inside Snowflake; the
language model only narrates a decision that has already been made.

## Preconditions

Confirm the platform is present before doing anything else:

```sql
SELECT COUNT(*) AS N FROM PREMISEFLOW.CORE.ASSUMPTIONS;
```

If this errors, PremiseFlow is not deployed in the active account. Stop and say so.

## Steps

### 1. Refresh reality, then re-test

For a single assumption:

```sql
CALL PREMISEFLOW.APP.RUN_CHALLENGER('A-DEP-001', 'coco_skill', NULL);
```

For every active assumption:

```sql
CALL PREMISEFLOW.APP.RUN_CHALLENGER(NULL, 'coco_skill', NULL);
```

To replay the assumption as at a historical date (this is how the
VALID -> CHALLENGED -> BREACHED progression is demonstrated):

```sql
CALL PREMISEFLOW.APP.RUN_CHALLENGER('A-DEP-001', 'coco_skill', '2026-08-06'::DATE);
```

If observations look stale, refresh first:

```sql
CALL PREMISEFLOW.APP.MONITORING_CYCLE();
```

### 2. Read the result

```sql
SELECT ASSUMPTION_ID, NAME, MATERIALITY, STATUS,
       EXPECTED_VALUE, ROUND(LATEST_OBSERVED_VALUE,4) AS OBSERVED,
       ROUND(DEVIATION_PCT,4) AS DEVIATION_PCT,
       OBSERVED_PERSISTENCE_DAYS, PERSISTENCE_DAYS AS PERSISTENCE_REQUIRED,
       ROUND(LATEST_CONFIDENCE,3) AS CONFIDENCE, CHANGE_POINT_DATE,
       DEPENDENT_DECISION_COUNT
FROM PREMISEFLOW.CORE.V_ASSUMPTION_CURRENT
ORDER BY CASE STATUS WHEN 'BREACHED' THEN 1 WHEN 'CHALLENGED' THEN 2
                     WHEN 'UNDER_REVIEW' THEN 3 WHEN 'WATCH' THEN 4 ELSE 5 END;
```

### 3. Decompose the driver (A-DEP-001)

Never report only the headline number. Show which cohort moved:

```sql
SELECT GRAIN, DIM_VALUE, ROUND(RETENTION_RATE,4) AS RETENTION,
       ROUND(BALANCE_CHANGE/1e6,2) AS BALANCE_CHANGE_USD_M, ACCOUNTS
FROM PREMISEFLOW.CORE.DT_RETENTION_DAILY
WHERE OBSERVATION_DATE = (SELECT MAX(OBSERVATION_DATE) FROM PREMISEFLOW.CORE.DT_RETENTION_DAILY)
ORDER BY RETENTION_RATE;
```

### 4. Check whether the aggregate hides it

This contrast is the core insight of the product and should always be reported
for a deposit-behaviour assumption:

```sql
SELECT BALANCE_DATE,
       ROUND(TOTAL_DEPOSITS/1e6,1)            AS TOTAL_USD_M,
       ROUND(GOVERNED_STABLE_DEPOSITS/1e6,1)  AS GOVERNED_STABLE_USD_M,
       ROUND(TOTAL_DEPOSIT_GROWTH*100,2)      AS TOTAL_GROWTH_PCT,
       ROUND(GOVERNED_DEPOSIT_GROWTH*100,2)   AS GOVERNED_GROWTH_PCT,
       ROUND(PROMOTIONAL_FUNDING_SHARE*100,2) AS PROMO_FUNDING_SHARE_PCT
FROM PREMISEFLOW.CORE.V_DEPOSIT_MASKING
ORDER BY BALANCE_DATE DESC LIMIT 1;
```

### 5. Test the validity envelope separately

An assumption can be inside tolerance on its headline metric and still be
unusable because the conditions it was validated under no longer hold:

```sql
SELECT v.VALIDITY_ENVELOPE,
       ROUND(c.PROMOTIONAL_FUNDING_SHARE,4) AS PROMO_SHARE_NOW,
       ROUND(c.DEPOSIT_CONCENTRATION,4)     AS CONCENTRATION_NOW,
       ROUND(c.POLICY_RATE_PCT,3)           AS POLICY_RATE_NOW
FROM PREMISEFLOW.CORE.ASSUMPTION_VERSIONS v
CROSS JOIN (SELECT * FROM PREMISEFLOW.CORE.DT_ASSUMPTION_CONTEXT
            ORDER BY OBSERVATION_DATE DESC LIMIT 1) c
WHERE v.ASSUMPTION_ID = 'A-DEP-001' AND v.IS_CURRENT;
```

### 6. Narrate (optional)

```sql
CALL PREMISEFLOW.APP.EXPLAIN_CHALLENGE('A-DEP-001', 'coco_skill');
```

## Reporting rules

- Always distinguish the **approved premise** from the **observed value**.
- Always state persistence as `observed/required` days. A single excursion is
  not a breach and must not be described as one.
- State that status was decided by deterministic threshold and persistence rules.
- Label every risk figure as an illustrative simplified POC calculation over
  synthetic data.

## Boundaries

This skill must not confirm a breach, approve an assumption version, or change a
decision status. Those are human actions. If asked, direct the user to the
Decision Reassessment page of the Streamlit app or to the `premiseflow-reassess`
skill, which prepares the pack but does not approve it.
