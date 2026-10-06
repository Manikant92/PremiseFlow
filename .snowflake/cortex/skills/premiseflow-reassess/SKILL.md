---
name: premiseflow-reassess
description: Prepare a decision reassessment pack for a PremiseFlow assumption breach, including original decision, evidence then versus now, quantified impact and a recommendation. Does not approve anything. Use when a decision needs reassessment, a committee pack is needed, or an assumption breach must be escalated. Triggers: reassessment pack, prepare reassessment, which decisions need reassessing, escalate assumption breach, ALCO pack for breach, revised assumption proposal.
---

# PremiseFlow: Prepare a Decision Reassessment Pack

Assembles everything a committee needs to re-take a decision whose premise no
longer holds. **This skill never approves anything.**

## Governance boundary (read first)

| Action | Who |
|---|---|
| Detect, evidence, quantify, recommend, draft | This skill |
| Confirm a breach | Human governance owner only |
| Approve a revised assumption version | Human governance owner only |
| Resolve a reassessment | Human governance owner only |

`PREMISEFLOW.APP.IS_HUMAN_ACTOR` rejects agent, system and model identities, and
authorises only identities registered in `PREMISEFLOW.CORE.GOVERNANCE_ACTORS`.
Attempting an approval as an agent raises `GOVERNANCE_VIOLATION`. Do not try it
other than to demonstrate the control.

## Steps

### 1. Find what needs reassessing

```sql
SELECT r.REASSESSMENT_ID, r.STATUS, d.DECISION_REF, d.TITLE, d.GOVERNANCE_STATUS,
       r.ASSUMPTION_ID, r.ORIGINAL_VERSION_ID,
       r.APPROVED_VALUE, ROUND(r.OBSERVED_VALUE,4) AS OBSERVED_VALUE,
       r.TRIGGERED_AT, r.MATERIALITY
FROM PREMISEFLOW.CORE.REASSESSMENTS r
JOIN PREMISEFLOW.CORE.DECISIONS d ON d.DECISION_ID = r.DECISION_ID
WHERE r.STATUS IN ('OPEN','IN_REVIEW')
ORDER BY r.TRIGGERED_AT DESC;
```

If none exist, check for a breach awaiting human confirmation and say that the
reassessment cannot be created until a human confirms it:

```sql
SELECT BREACH_ID, ASSUMPTION_ID, SEVERITY, PERSISTENCE_DAYS, CONFIRMATION_STATUS,
       FIRST_BREACH_DATE, ROUND(OBSERVED_VALUE,4) AS OBSERVED, EXPECTED_VALUE
FROM PREMISEFLOW.CORE.ASSUMPTION_BREACHES
WHERE CONFIRMATION_STATUS = 'PENDING_HUMAN_CONFIRMATION';
```

### 2. Assemble the pack

**What was decided, and what was believed at the time:**

```sql
SELECT DECISION_REF, TITLE, COMMITTEE, DECISION_DATE, APPROVED_BY,
       DECISION_TEXT, RATIONALE, SOURCE_DOCUMENT
FROM PREMISEFLOW.CORE.DECISIONS WHERE DECISION_ID = '<decision id>';
```

**The evidence relied on then:**

```sql
SELECT EVIDENCE_ID, EVIDENCE_TYPE, SOURCE_REF, SOURCE_DOCUMENT,
       OBSERVED_VALUE, SAMPLE_SIZE, PERIOD_START, PERIOD_END, SUMMARY
FROM PREMISEFLOW.CORE.ASSUMPTION_EVIDENCE
WHERE VERSION_ID = '<original version id>';
```

**What reality says now, and the quantified impact:**

```sql
SELECT IMPACT_SUMMARY, AI_RECOMMENDATION, TRIGGER_REASON
FROM PREMISEFLOW.CORE.REASSESSMENTS WHERE REASSESSMENT_ID = '<reassessment id>';
```

Then run `premiseflow-impact` for the scenario comparison and the blast radius.

### 3. Draft a revised assumption (proposal only)

```sql
CALL PREMISEFLOW.APP.PROPOSE_NEW_VERSION(
  'A-DEP-001',
  '<revised statement>',
  0.82,     -- expected
  0.80,     -- challenge threshold
  0.77,     -- breach threshold
  0.80,     -- lower bound
  1.00,     -- upper bound
  5,        -- persistence days
  '<evidence summary>',
  'coco_skill',
  '<rationale>');
```

The new version is created with `APPROVAL_STATUS = 'PROPOSED'` and
`IS_CURRENT = FALSE`. Confirm this to the user explicitly.

### 4. Hand over

Tell the user exactly what remains for a human, and where:

- Streamlit app, Decision Reassessment page: confirm breach, approve or reject
  the proposed version, resolve the reassessment.
- Or, for an authorised human identity:
  `CALL PREMISEFLOW.APP.APPROVE_NEW_VERSION('<version id>','HUMAN','<actor>','<role>','<note>');`

## Reporting rules

- Present then-versus-now side by side. Never overwrite or restate history.
- State that the original decision record is preserved unchanged and only its
  governance status moved.
- Give at least two options plus the do-nothing consequence.
- Label risk figures as illustrative simplified POC calculations over synthetic data.
