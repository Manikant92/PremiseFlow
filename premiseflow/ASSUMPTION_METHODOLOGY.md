# PremiseFlow Assumption Methodology

How an assumption becomes a governed object, how it is tested, and what happens
when it stops being true.

> Synthetic data / illustrative risk calculations for hackathon demonstration.

## 1. The Assumption Contract

An assumption is not a threshold in a spreadsheet. A contract answers eleven
questions, and PremiseFlow stores an answer to each:

| Question | Where it lives |
|---|---|
| **What** must remain true | `ASSUMPTION_VERSIONS.STATEMENT` |
| **Who** owns it | `ASSUMPTIONS.OWNER_ROLE` |
| **What evidence** supports it | `ASSUMPTION_EVIDENCE`, `VERSIONS.EVIDENCE_SUMMARY` |
| **Under which conditions** it was validated | `VERSIONS.VALIDITY_ENVELOPE` |
| **How** validity is measured | `ASSUMPTIONS.METRIC_CODE` → `DT_ASSUMPTION_OBSERVATIONS` |
| **What threshold** constitutes a challenge | `VERSIONS.CHALLENGE_THRESHOLD` |
| **What threshold** constitutes a breach | `VERSIONS.BREACH_THRESHOLD` |
| **How long** a breach must persist | `VERSIONS.PERSISTENCE_DAYS` |
| **What objects** depend on it | `ASSUMPTION_DEPENDENCIES` |
| **What decisions** relied on it | `DECISION_DEPENDENCIES` (including the exact version) |
| **When** it was last validated | `ASSUMPTIONS.LAST_VALIDATED_AT` |

`DIRECTION` (`LOWER_IS_WORSE`, `UPPER_IS_WORSE`, `TWO_SIDED`) tells the challenger
which side of a threshold is bad, so one engine serves retention floors, beta
ceilings and two-sided bands alike.

### A-DEP-001 as an instance

```
Statement    Retail salary-account deposits retain at least 90% of incumbent
             balances over a rolling 90-day horizon under normal operating conditions.
Metric       INCUMBENT_SALARY_RETENTION_90D
Direction    LOWER_IS_WORSE
Expected     0.90       Challenge  0.88       Breach  0.85
Persistence  5 observation days
Envelope     policy rate 4.00-5.25%; promotional funding share <= 5%;
             deposit concentration <= 18%; digital acquisition share <= 45%;
             normal operating conditions, no material competitor repricing campaign
Owner        Treasury Risk          Materiality  CRITICAL
Approved by  ALCO Chair (synthetic: A. Rahman)
Evidence     8-quarter cohort study (4,800 customers, mean 92.1%, min 90.4%);
             policy LRP-2026-v4 s4.2; validation MV-2025-042 (reproduced 91.8%);
             approval record AAR-A-DEP-001
```

Note the approved value is the **conservative lower edge** of the observed
distribution (90.4% minimum), not the central estimate (92.1%). That is why the
assumption held for months before it broke.

## 2. How the metric is defined

Retention is **balance-weighted**, not customer-count weighted:

```
Retention(t) = B_incumbent(t) / B_incumbent(t - 90)
```

where `B_incumbent` is the aggregate balance of accounts belonging to customers
already on book at `t - 90`. Accounts opened inside the window are excluded by
construction — which is precisely why new promotional money cannot flatter the
metric, even though it flatters the aggregate.

Three implementation decisions matter:

**Fixed population.** The governed pool is restricted to accounts open before the
history start date, so the population is constant across every window. That makes
aggregate-then-ratio exact, and it is far cheaper than an account-level self-join
over 3.2 million rows.

**30-day trailing average.** Salary accounts receive a month-start payroll credit,
so a point-in-time ratio taken 90 days apart picks up a day-of-month artifact of
up to 2%. Before smoothing, the pre-break minimum fell to 0.900 — a spurious
threshold crossing caused purely by calendar alignment. A 30-day trailing average
removes it, and for an exponential balance path the ratio of two 30-day averages
taken 90 days apart is mathematically identical to the underlying point ratio, so
nothing is biased.

**Always decomposed.** Every evaluation also computes retention by acquisition
channel, tenure band and customer segment. A portfolio number without a
decomposition cannot answer "who", and "who" is what determines the response.

## 3. Detection: deterministic first

No numeric threshold outcome is ever decided by a language model.

### Status rule

```
BREACHED    beyond the breach threshold AND unbroken run >= persistence requirement
CHALLENGED  beyond the challenge threshold AND unbroken run >= persistence requirement
WATCH       a threshold is touched but not yet persistent,
            or the value sits outside the approved bounds
VALID       otherwise
```

Lifecycle: `VALID → WATCH → CHALLENGED → UNDER_REVIEW → BREACHED → RETIRED`.
`UNDER_REVIEW` is reachable only by a human requesting more evidence.

### Why persistence exists

Balance-weighted metrics are volatile; a handful of large movements can dominate a
single day. Escalating on one observation would generate false positives and train
people to ignore the alerts. The independent validation report (MV-2025-042,
Finding 4) makes exactly this point, and the platform implements it: the breach
condition must hold on an unbroken run of observation days.

This is tested by injecting a single extreme outlier into an otherwise healthy
assumption and asserting that no breach is raised (test D5).

### Supporting statistics

| Technique | Purpose |
|---|---|
| Median/MAD robust z | How far the current value sits from the regime the version was validated in, without a few outliers distorting the scale. Floored at 0.5% of the median, because these series are smooth enough that an unfloored MAD yields meaningless four-figure z-scores. |
| Maximum mean-shift change point | When behaviour changed. Chooses the split maximising \|mean(after) − mean(before)\|. |
| Cohort decomposition | Which population drove it. |
| Confidence | `0.50 + 0.25 × min(1, persistence/required) + 0.25 × min(1, \|z\|/6)`. Deliberately simple and explainable rather than a calibrated probability. |

**Change point runs on the driver, not the ratio.** A rolling 90-day retention
ratio is a lagging transform of the balance path, so a change point found on it
lands weeks after behaviour actually shifted. For A-DEP-001 the detector therefore
runs on the daily log-return of the governed deposit pool, whose mean shifts on the
day behaviour changes. Measured against the recorded ground truth, this reduced the
detection error from 80 days to about 8.

## 4. The validity envelope is a separate test

An assumption can be inside tolerance on its headline metric and still be
unusable, because the conditions it was evidenced under no longer hold. Policy
LRP-2026-v4 section 4.3 states this, and the Assumption Detail page evaluates each
condition independently against `DT_ASSUMPTION_CONTEXT`.

In the current demo state the promotional funding share is **11.2%** against an
approved ceiling of **5%**. That alone invalidates continued reliance, before
retention is considered at all. This is the failure mode that quantitative
monitoring alone never catches.

## 5. Where the LLM is allowed

| Task | Model | Constraint |
|---|---|---|
| Explain a challenge | `claude-sonnet-4-5` | Narrates a status that already exists. Prompt supplies only facts; it is instructed not to recommend approving or rejecting. |
| Answer questions | `claude-sonnet-4-5` | Reads the semantic layer plus retrieved documents. Read-only. |
| Mine candidate assumptions | `claude-sonnet-4-5` | Output is `PROPOSED_BY_MINER`, never governed. |

Every call records model name, workflow/prompt version, timestamp and evidence
references in `AUDIT.AGENT_RUNS`, so any narrative can be traced to what produced
it.

## 6. From breach to decision

```
BREACHED detected                 (deterministic)
  -> breach recorded PENDING_HUMAN_CONFIRMATION
  -> AI narrates the cause        (narrative only)
  -> [HUMAN CONFIRMS]             <- IS_HUMAN_ACTOR, allowlist
       -> impact simulated: LCR, stressed outflow, funding gap, NII
       -> materiality assessed
       -> exposed decisions identified
       -> REASSESSMENT created per decision
       -> decision GOVERNANCE_STATUS -> REASSESSMENT_REQUIRED
       -> external action queued to the outbox
```

Reassessment reaches a decision when reliance is `MATERIAL`, or when reliance is
`SUPPORTING` **and** the assumption itself is `CRITICAL`. Decisions that declared
no dependency are untouched — a bounded blast radius is a result, and is asserted
by test K6.

What is preserved on the reopened decision: the decision text, the rationale, the
approver, the date, the evidence that existed, and the assumption **version** that
was relied on. Only `GOVERNANCE_STATUS` moves. Governance is not editing history.

## 7. Revising an assumption

1. **Propose** (`APP.PROPOSE_NEW_VERSION`) — open to an analyst or an AI. Creates a
   new version with `APPROVAL_STATUS='PROPOSED'`, `IS_CURRENT=FALSE`. The validity
   envelope is inherited and annotated with the conditions observed at proposal
   time, so the record shows what had changed.
2. **Approve** (`APP.APPROVE_NEW_VERSION`) — **human only**. Sets the new version
   approved and current, and on the predecessor sets **only** `IS_CURRENT=FALSE`
   and `VALID_TO`. Its `APPROVAL_STATUS`, `APPROVED_BY`, `APPROVED_AT` and
   `STATEMENT` remain exactly as approved.
3. **Monitor** — the challenger immediately re-runs against the new version.

Test F8 asserts the predecessor row is unchanged after supersession.

## 8. Mining new assumptions from documents

`APP.MINE_ASSUMPTIONS` searches the corpus and extracts statements asserting that
something must remain true. In practice the most valuable finds are not headline
thresholds, which are already governed, but **conditions of validity** buried in
prose. On the current corpus it surfaced the promotional-funding ceiling, the
concentration limit, the digital-acquisition cap and the policy-rate range as
candidate assumptions in their own right — each of which can silently invalidate
A-DEP-001 while its headline metric still looks acceptable.

Candidates are never promoted automatically. Duplicate detection against the
existing registry is a metric-code plus word-overlap heuristic, so it can miss a
rephrased duplicate; the list is for human review.
