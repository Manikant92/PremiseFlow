# Deposit Behaviour Model Methodology

**Model reference:** DEPOSIT_BEHAVIOUR_MODEL
**Model tier:** Tier 1
**Owner:** Deposit Analytics
**Methodology version:** 4.2
**Validation reference:** MV-2025-042

> SYNTHETIC DOCUMENT prepared for the PremiseFlow hackathon proof of concept.
> All figures are generated. No real customer data is described.

## 1. Model purpose

The Deposit Behaviour Model estimates the behavioural characteristics of the
Group's deposit base for use in liquidity stress testing, funds transfer
pricing, and interest rate risk in the banking book. Its three principal
outputs are:

1. **Retention** - the proportion of incumbent balances retained over a defined
   horizon.
2. **Deposit beta** - the pass-through of policy rate changes to administered
   deposit rates.
3. **Repricing lag** - the delay between a policy rate move and the
   corresponding administered rate move.

## 2. Retention estimation

### 2.1 Definition

Retention is measured as a **balance-weighted ratio**, not a customer count
ratio:

```
Retention(t) = B_incumbent(t) / B_incumbent(t - H)
```

where `H` is the horizon (90 days for the retail salary cohort) and
`B_incumbent` is the aggregate balance of accounts belonging to customers who
were on book at `t - H`. Accounts opened after `t - H` are excluded by
construction.

### 2.2 Smoothing

Salary accounts exhibit strong month-start seasonality driven by payroll credit
timing. A point-in-time ratio taken 90 days apart can therefore pick up a
day-of-month artifact of up to 2%. The methodology specifies a **30-day
trailing average balance** at both ends of the window. For an exponential
balance path the ratio of two 30-day averages taken 90 days apart is
mathematically identical to the underlying point ratio, so smoothing removes the
artifact without biasing the estimate.

### 2.3 Cohort definition for the retail salary population

The governed cohort comprises customers where all of the following hold:

- payroll credit relationship present (`PAYROLL_CUSTOMER_FLAG`),
- retail segment (`RETAIL_MASS` or `RETAIL_AFFLUENT`),
- on book prior to the start of the observation period,
- holding a salary current account.

Linked retail savings balances held by the same cohort are included in the
stable-deposit pool for liquidity purposes but the headline retention metric is
measured on salary current accounts.

### 2.4 Historical estimation result

An eight-quarter cohort study covering approximately 4,800 incumbent payroll
customers produced the following rolling 90-day balance retention:

| Period | Retention |
|---|---|
| Q1 | 92.4% |
| Q2 | 91.6% |
| Q3 | 93.2% |
| Q4 | 92.1% |
| Q5 | 90.8% |
| Q6 | 91.9% |
| Q7 | 92.7% |
| Q8 | 90.4% |

Mean 92.1%, minimum 90.4%, maximum 93.2%. No quarter fell below 90%.

On this basis the model recommended, and ALCO approved, a governed retention
premise of **90%** over a rolling ninety-day horizon, being the conservative
lower edge of the observed distribution rather than the central estimate.

## 3. Segment heterogeneity

Retention is materially heterogeneous across acquisition channel, tenure and
wealth segment. The model records the following relative attrition intensities,
normalised so that the balance-weighted pool equals 1.0:

| Dimension | Category | Relative attrition intensity |
|---|---|---|
| Acquisition channel | Branch | 0.62 |
| Acquisition channel | Partner | 0.95 |
| Acquisition channel | Digital | 1.35 |
| Acquisition channel | Aggregator | 1.60 |
| Tenure | Under 2 years | 1.30 |
| Tenure | 2 to 5 years | 1.05 |
| Tenure | Over 5 years | 0.88 |
| Wealth segment | Retail mass | 0.95 |
| Wealth segment | Retail affluent | 1.20 |

**Implication.** Because attrition is concentrated in the aggregator- and
digitally-acquired, shorter-tenure, more rate-aware population, a shift in the
acquisition mix can degrade portfolio retention even with no change in the
behaviour of any individual segment. Monitoring must therefore decompose
retention by channel, tenure and segment, not observe the aggregate alone.

## 4. Deposit beta

Beta is estimated by regressing changes in the blended administered deposit rate
on changes in the policy rate over the prior two tightening cycles. The
estimated blended beta was 0.41, with cycle-level estimates in a 0.38 to 0.44
band. A governed ceiling of **0.45** was approved on this basis.

Beta is not stable under competitive stress. Where peer deposit pricing moves
ahead of the Group's own administered rates, realised beta rises as the Group is
forced to reprice defensively to retain balances. Peer rate gap is therefore
monitored as a leading indicator alongside realised beta.

## 5. Channel equivalence

Pooled cohort estimation is only valid if digitally-acquired customers behave
equivalently to branch-acquired customers of comparable tenure. Equivalence is
tested using a Kolmogorov-Smirnov comparison of balance-change distributions,
with a tolerance of 0.05 on the divergence statistic. The most recent test
returned 0.038 and the pooling assumption was retained.

Where divergence exceeds tolerance, pooled estimation overstates the stability
of the digital population and the cohorts must be estimated separately.

## 6. Known limitations

1. The model is calibrated on a rising-rate environment and has not been
   observed through a full easing cycle.
2. Promotional acquisition is not explicitly modelled. Promotional inflows enter
   the balance series as new-customer balances and are excluded from the
   incumbent retention numerator and denominator, but they **do** inflate
   aggregate deposit totals. Users of aggregate deposit reporting may therefore
   draw incorrect conclusions about behavioural stability.
3. Retention is estimated on balances, not customers. A small number of large
   balance movements can dominate the metric.
4. Segment-level estimates for the aggregator channel rest on a comparatively
   small account population and are correspondingly less precise.
