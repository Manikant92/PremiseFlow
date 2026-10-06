---
name: premiseflow-mine
description: Extract candidate assumptions from PremiseFlow governance, policy, model methodology and validation documents, and create candidate assumption contracts for human review. Use when asked to mine assumptions, find undocumented assumptions, discover what a policy requires to remain true, or check whether an assumption is already governed. Triggers: mine assumptions, extract assumptions from documents, find hidden assumptions, what assumptions does this policy contain, candidate assumptions, ungoverned assumptions.
---

# PremiseFlow: Mine Candidate Assumptions

Searches the governance document corpus and extracts statements that assert
something must **remain true** for a model, calculation or decision to stay
valid. Output is a set of *candidate* contracts for human review.

## Steps

### 1. Mine

Default sweep:

```sql
CALL PREMISEFLOW.APP.MINE_ASSUMPTIONS(NULL, 8, 'coco_skill');
```

Targeted sweep (pass the topic, and how many document chunks to read):

```sql
CALL PREMISEFLOW.APP.MINE_ASSUMPTIONS(
  'term deposit rollover assumption maturity ladder', 6, 'coco_skill');
```

### 2. Review candidates

```sql
SELECT NOVELTY, PROPOSED_NAME, PROPOSED_METRIC, PROPOSED_EXPECTED_VALUE,
       PROPOSED_DIRECTION, PROPOSED_MATERIALITY, IS_QUANTIFIED,
       MATCHES_EXISTING, SOURCE_REFERENCE, SOURCE_SECTION
FROM PREMISEFLOW.CORE.V_CANDIDATE_ASSUMPTIONS;
```

### 3. Inspect the provenance of any candidate

Always show the verbatim source sentence before proposing anything:

```sql
SELECT PROPOSED_STATEMENT, VALIDITY_CONDITIONS, QUOTED_TEXT,
       SOURCE_DOCUMENT, SOURCE_REFERENCE, SOURCE_SECTION
FROM PREMISEFLOW.CORE.CANDIDATE_ASSUMPTIONS
WHERE CANDIDATE_ID = '<candidate id>';
```

### 4. Separate the genuinely new from the already governed

```sql
SELECT NOVELTY, COUNT(*) AS N
FROM PREMISEFLOW.CORE.V_CANDIDATE_ASSUMPTIONS GROUP BY 1;
```

Compare against the live registry before recommending anything:

```sql
SELECT ASSUMPTION_ID, NAME, METRIC_CODE, STATUS
FROM PREMISEFLOW.CORE.ASSUMPTIONS ORDER BY ASSUMPTION_ID;
```

## What to look for

The most valuable finds are usually not headline thresholds, which are already
governed, but **conditions of validity** stated in prose: a promotional funding
share ceiling, a concentration limit, a policy-rate range, an acquisition-mix
limit, or a "normal operating conditions" qualifier. These are the clauses that
silently invalidate an assumption while its headline metric still looks fine.

## Reporting rules

- Quote the source sentence, document reference and section for every candidate.
- State whether the candidate is quantified. Unquantified conditions still matter
  but cannot be monitored numerically without first defining a metric.
- Flag duplicates against the existing registry rather than proposing them again.
- Duplicate detection is a metric-code plus word-overlap heuristic, so it can
  miss a rephrased duplicate. Review the list rather than trusting the flag.

## Boundaries

The miner cannot create a governed assumption. Candidates carry status
`PROPOSED_BY_MINER` and must be promoted by a human. Never describe a candidate
as governed, approved or monitored.
