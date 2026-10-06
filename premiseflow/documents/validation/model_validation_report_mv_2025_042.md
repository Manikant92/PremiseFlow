# Independent Model Validation Report

**Report reference:** MV-2025-042
**Model validated:** DEPOSIT_BEHAVIOUR_MODEL (methodology v4.2)
**Validation team:** Independent Model Validation
**Outcome:** Fit for Purpose, with findings

> SYNTHETIC DOCUMENT prepared for the PremiseFlow hackathon proof of concept.

## 1. Scope

Independent validation of the retention, beta and repricing-lag outputs of the
Deposit Behaviour Model, and of the behavioural assumptions derived from it for
use in liquidity stress testing.

## 2. Reproduction of the retention estimate

The validation team independently reconstructed the incumbent retail salary
retention series from source balance data. The reproduced rolling 90-day
balance retention was **91.8%** against the model owner's reported 92.1%. The
0.3 percentage point difference is attributable to the treatment of accounts
closed mid-window and is not material.

The validation team concurred that the governed premise of **90%** is
appropriately conservative relative to the observed distribution (minimum 90.4%
across eight quarters).

## 3. Conclusion on assumption A-DEP-001

The assumption that *retail salary-account deposits retain at least 90% of
incumbent balances over a rolling ninety-day horizon under normal operating
conditions* is **supported by the evidence available at the validation date** and
is rated **Fit for Purpose**.

## 4. Findings

### Finding 1 - MEDIUM - Aggregate monitoring is not sufficient

The retention assumption is monitored via a management information pack whose
primary deposit exhibit is **total deposit balance**. Total deposit balance is
insensitive to incumbent attrition when new-customer acquisition is running
concurrently. The validation team notes that the Group could experience a
material deterioration in incumbent retention with no visible signal in the
primary deposit exhibit.

*Recommendation.* Monitoring must be performed on the incumbent cohort directly,
and must be decomposed by acquisition channel, tenure band and wealth segment.
Aggregate deposit growth must not be treated as evidence of behavioural
stability.

### Finding 2 - MEDIUM - Acquisition mix shift is unmonitored

Relative attrition intensity varies by a factor of more than 2.5 between the
stickiest and least sticky acquisition channels. A shift in acquisition mix
toward aggregator and digital channels would degrade portfolio retention even if
every individual segment behaved exactly as modelled.

*Recommendation.* Add acquisition mix and promotional funding share to the
validity envelope of the retention assumption, with explicit thresholds.

### Finding 3 - LOW - Promotional acquisition not modelled

Promotional pricing campaigns are not represented in the model. Promotional
inflows are correctly excluded from the incumbent retention calculation, but
their effect on aggregate reporting is not disclosed to consumers of the model
output.

*Recommendation.* Where promotional funding exceeds 5% of total deposits, report
incumbent retention and aggregate balance movement side by side.

### Finding 4 - LOW - Single-observation sensitivity

The monitoring process as designed would escalate on a single observation beyond
threshold. Given the volatility of balance-weighted metrics, this would generate
false positives.

*Recommendation.* Require a persistence condition expressed in observation days
before a threshold excursion is treated as a breach.

## 5. Conditions of continued reliance

Continued reliance on A-DEP-001 is conditional on:

1. the assumption being re-tested against observed outcomes at least monthly;
2. the validity envelope conditions in the Liquidity Risk Policy section 4.3
   continuing to hold, in particular promotional funding remaining below 5% of
   total deposits;
3. monitoring being performed on the incumbent cohort with segment
   decomposition, per Finding 1;
4. any confirmed breach triggering identification and reassessment of all
   downstream models, metrics and prior committee decisions that relied on the
   assumption.

## 6. Re-validation trigger

Immediate re-validation is required if observed incumbent retention falls below
85% on a sustained basis, or if the acquisition mix shifts such that aggregator
and digital channels exceed 45% of the governed cohort.
