# PremiseFlow Data Model

> Synthetic data only. No real PII. Every identifier is generated.

## 1. RAW — synthetic source systems

| Table | Rows (built) | Notes |
|---|---|---|
| `RAW_GEN_CONFIG` | 10 | Generation parameters. Single source of truth for the timeline. |
| `RAW_GROUND_TRUTH` | 1 | What was deliberately injected, so detection can be verified. |
| `RAW_CUSTOMERS` | 9,600 | 8,000 incumbent + 1,600 promotional-new. |
| `RAW_ACCOUNTS` | 14,727 | 5 product types. |
| `RAW_DAILY_BALANCES` | 3,228,390 | 240 days x accounts open on that day. |
| `RAW_TRANSACTIONS` | 117,816 | 6 transaction types. |
| `RAW_MARKET_RATES` | 240 | Policy rate, interbank, peer and own deposit rate, deposit beta. |
| `RAW_ALM_RESULTS`, `RAW_MODEL_RESULTS`, `RAW_ALCO_DECISIONS`, `RAW_ASSUMPTION_SOURCE_DATA` | 0 | Declared for completeness of the source-system picture; the governed equivalents in `CORE` are the ones the platform actually reads. |

### Key customer fields

`CUSTOMER_ID`, `CUSTOMER_SEGMENT` (RETAIL_MASS, RETAIL_AFFLUENT, SME, CORPORATE),
`TENURE_MONTHS`, `PAYROLL_CUSTOMER_FLAG`, `ACQUISITION_CHANNEL` (BRANCH, DIGITAL,
PARTNER, AGGREGATOR), `JOIN_DATE`, `RISK_SEGMENT`, `COHORT` (INCUMBENT,
PROMOTIONAL_NEW), `HOME_REGION_CODE`.

### Key account fields

`ACCOUNT_ID`, `CUSTOMER_ID`, `PRODUCT_TYPE` (SALARY_CURRENT, SAVINGS_RETAIL,
TERM_DEPOSIT, SME_CURRENT, PROMO_SAVINGS), `OPEN_DATE`, `CURRENT_BALANCE`,
`OPENING_BALANCE`, `INTEREST_RATE`, `PROMOTIONAL_FLAG`, `CURRENCY_CODE`, `STATUS`.

## 2. How the hidden structural break is generated

The balance path is **closed-form**, so the dataset is fast to build and exactly
reproducible. Pseudo-randomness uses `HASH()` rather than `RANDOM()`.

```
balance(account, day) = opening_balance
                      x drift(account, day)
                      x idiosyncratic noise (±1.2%, HASH(account, day))
                      x market noise        (±0.35%, HASH(day))
                      x month-start salary bump (+2.2% on days 1-5, salary accounts)
```

with piecewise-constant multiplicative drift:

```
governed accounts   drift = PRE^(days before break) x POST^(days after break x intensity)
                            PRE  = 0.99908   (~92% over 90 days)
                            POST = 0.99690   (~78% over 90 days)
promotional savings drift = ramp over 14 days x (1 + 0.0016 x days since opening)
everything else     drift = 1.00026 ^ days
```

"Governed accounts" = `COHORT='INCUMBENT'` AND `PAYROLL_CUSTOMER_FLAG` AND
`PRODUCT_TYPE IN ('SALARY_CURRENT','SAVINGS_RETAIL')`.

### Attrition is heterogeneous, by design

The post-break decay exponent is scaled by a per-customer intensity multiplier so
that cohort decomposition is diagnostically useful rather than uniform:

| Dimension | Category | Multiplier |
|---|---|---|
| Channel | BRANCH / PARTNER / DIGITAL / AGGREGATOR | 0.62 / 0.95 / 1.35 / 1.60 |
| Tenure | <2y / 2-5y / 5y+ | 1.30 / 1.05 / 0.88 |
| Segment | RETAIL_MASS / RETAIL_AFFLUENT | 0.95 / 1.20 |

Normalised by `ATTRITION_NORMALISER = 1.1040` so the balance-weighted pool still
lands on the target retention. Observed result at the demo end date: aggregator
67.6%, digital 71.5%, partner 78.7%, branch 85.1%.

### Timeline

| Marker | Date | Meaning |
|---|---|---|
| Spine start | 2026-01-29 | First day of daily balance history |
| Break date | 2026-06-27 | Behaviour change begins (demo end − 90) |
| Demo end | 2026-09-25 | Last day of history |

### Verified outcome

| Property | Value |
|---|---|
| Pre-break retention (minimum) | 91.7% — supports the ≥90% premise |
| First observation below 88% (challenge) | 2026-08-02 |
| First observation below 85% (breach) | 2026-08-18 |
| Consecutive breach days at demo end | 39 (requirement: 5) |
| Retention at demo end | 78.4% |
| Total deposits since break | **+4.6%** |
| Governed stable deposits since break | **−23.9%** |
| Promotional funding share | 11.2% (envelope limit 5%) |

## 3. CORE — the governed model

### Assumption registry

`ASSUMPTIONS` — one row per governed assumption: `ASSUMPTION_ID`, `NAME`,
`STATEMENT`, `DOMAIN`, `OWNER_ROLE`, `MATERIALITY`, `STATUS`, `CURRENT_VERSION`,
`METRIC_CODE`, `LAST_VALIDATED_AT`.

`ASSUMPTION_VERSIONS` — **immutable** version history. Carries the contract:
`EXPECTED_VALUE`, `LOWER_BOUND`, `UPPER_BOUND`, `CHALLENGE_THRESHOLD`,
`BREACH_THRESHOLD`, `PERSISTENCE_DAYS`, `DIRECTION`, `VALIDITY_ENVELOPE` (VARIANT),
`EVIDENCE_SUMMARY`, `APPROVAL_STATUS`, `APPROVED_BY`, `APPROVED_AT`, `PROPOSED_BY`,
`PROPOSED_AT`, `SUPERSEDES_VERSION_ID`, `VALID_FROM`, `VALID_TO`, `IS_CURRENT`.

Superseding sets **only** `IS_CURRENT` and `VALID_TO`.

`ASSUMPTION_EVIDENCE` — what justified the version at approval time, typed
`STRUCTURED_DATA | DOCUMENT | MODEL_RESULT | EXPERT_JUDGEMENT | OBSERVATION`.

### Lineage

`ASSUMPTION_DEPENDENCIES` — `SOURCE_OBJECT`, `SOURCE_TYPE`, `TARGET_OBJECT`,
`TARGET_TYPE`, `RELATIONSHIP_TYPE`, `MATERIALITY`, `VALID_FROM`, `VALID_TO`.
Types: `ASSUMPTION | MODEL | METRIC | REPORT | DECISION | CALCULATION | POLICY`.
25 edges seeded. `V_BLAST_RADIUS` walks this recursively (depth-capped at 6, cycle
guarded via the path string).

The primary chain:

```
A-DEP-001 -> LIQUIDITY_STRESS_MODEL -> STRESSED_OUTFLOW_30D -> LCR
          -> FTP_FUNDING_FORECAST   -> FUNDING_GAP_90D / NII_12M
          -> ALCO_FORECAST_MODEL    -> ALCO_DECISION_2026_017
          -> ALCO_DECISION_2026_011
          -> LRP-2026-v4 (policy)
```

### Detection and consequence

`ASSUMPTION_OBSERVATIONS` (what the challenger acted on) ·
`ASSUMPTION_CHALLENGES` (every evaluation: observed, expected, deviation,
persistence, confidence, robust z, change point, affected segments, evidence ids,
status, method, explanation) ·
`ASSUMPTION_BREACHES` (with `CONFIRMATION_STATUS`) ·
`REASSESSMENTS` · `SCENARIOS` / `SCENARIO_RESULTS` (with `FORMULA` and `INPUTS`).

### Supporting

`MODELS` (6) · `RISK_METRICS` (5) · `DECISIONS` (4) ·
`DECISION_DEPENDENCIES` (6, recording the exact **version** relied upon) ·
`LIQUIDITY_INPUTS` · `SIM_PARAMETERS` · `GOVERNANCE_ACTORS` (5) ·
`STATIC_OBSERVATIONS` · `CANDIDATE_ASSUMPTIONS` · `ACTION_OUTBOX`.

## 4. Observation layer (dynamic tables, 60-minute target lag)

| Object | Purpose |
|---|---|
| `DT_GOVERNED_DAILY` | Governed pool balance by segment / channel / tenure band / product. Population is fixed (accounts open before the spine start) so aggregate-then-ratio is exact. |
| `DT_RETENTION_DAILY` | Rolling 90-day retention on a **30-day trailing average** balance, at `OVERALL` grain and by `CUSTOMER_SEGMENT`, `ACQUISITION_CHANNEL`, `TENURE_BAND`. |
| `DT_DEPOSIT_DAILY` | Total vs incumbent vs new-customer vs promotional vs governed-stable vs term vs wholesale-like. |
| `DT_ASSUMPTION_CONTEXT` | Validity-envelope conditions per day: policy rate, deposit beta, peer gap, promotional funding share, concentration. |
| `DT_ASSUMPTION_OBSERVATIONS` | One observed value per active assumption per day. The challenger's only input. |

Why the 30-day average: salary accounts have a month-start payroll bump, so a
point-in-time ratio 90 days apart picks up a day-of-month artifact of up to 2%
(observed pre-break minimum fell to 0.900 before smoothing, which would have
produced spurious threshold crossings). For an exponential balance path the ratio
of two 30-day averages taken 90 days apart is mathematically identical to the
underlying point ratio, so the artifact is removed without biasing the estimate.

## 5. AI schema

`DOCUMENTS` (6, with `PARSE_METHOD`) · `DOCUMENT_CHUNKS` (76, heading-aware with
overlap, carrying `MENTIONS_ASSUMPTIONS`) · `PREMISEFLOW_DOC_SEARCH` (Cortex
Search) · `PREMISEFLOW_SEMANTIC` (semantic view) · `PREMISEFLOW_AGENT` ·
`VERIFIED_QUERIES` (8) · `V_ASSUMPTION_DOCUMENTS`.

## 6. AUDIT schema

`AUDIT_EVENTS` (`EVENT_ID`, `EVENT_TYPE`, `OBJECT_TYPE`, `OBJECT_ID`,
`ACTOR_TYPE`, `ACTOR_ID`, `EVENT_TS`, `OLD_STATE`, `NEW_STATE`,
`EVIDENCE_REFERENCE`, `RUN_ID`, `RATIONALE`, `PAYLOAD`) ·
`AGENT_RUNS` (model name, workflow version, prompt ref, evidence refs) ·
`HUMAN_ACTIONS` · `INTEGRATION_ACTIONS`.

Lifecycle event types: `ASSUMPTION_CREATED`, `EVIDENCE_ATTACHED`,
`VERSION_APPROVED`, `OBSERVATION_GENERATED`, `CHALLENGE_DETECTED`,
`BREACH_DETECTED`, `AI_EXPLANATION_GENERATED`, `BREACH_CONFIRMED`,
`IMPACT_SIMULATED`, `DECISION_REOPENED`, `NEW_VERSION_PROPOSED`,
`NEW_VERSION_APPROVED`, `NEW_VERSION_REJECTED`, `CHALLENGE_DISMISSED`,
`MORE_EVIDENCE_REQUESTED`, `REASSESSMENT_RESOLVED`, `ASSUMPTIONS_MINED`,
`DEMO_RESET`.

## 7. Referential integrity

Asserted by test group B: no orphan accounts, transactions or balances; no
balance predating its account opening; exactly one current version per
assumption; no dangling dependency, decision-dependency or reassessment
references; no negative balances.
