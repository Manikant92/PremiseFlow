# Liquidity Risk Policy

**Document reference:** LRP-2026-v4
**Owner:** Group Treasury Risk
**Approved by:** Asset and Liability Committee (ALCO)
**Review cycle:** Annual
**Classification:** Internal

> SYNTHETIC DOCUMENT. This policy is fabricated for the PremiseFlow hackathon
> proof of concept. It describes no real institution and must not be relied on.

## 1. Purpose and scope

This policy establishes the framework within which the Group manages liquidity
risk, defines the metrics used to measure it, and sets out the behavioural
assumptions that underpin those metrics. It applies to all deposit-taking
entities within the Group.

## 2. Risk appetite

The Group maintains a Liquidity Coverage Ratio (LCR) above an internal
management threshold of **110%**, providing headroom above the regulatory
minimum of 100%. Breach of the internal threshold requires escalation to ALCO
at the next scheduled meeting; breach of the regulatory minimum requires
immediate escalation to the Chief Risk Officer and the Board Risk Committee.

The Net Stable Funding Ratio (NSFR) is maintained above 105%.

## 3. Behavioural assumptions

### 3.1 Principle

Liquidity metrics are only as reliable as the behavioural assumptions beneath
them. Every behavioural assumption used in a regulatory or internal liquidity
calculation must be (a) documented, (b) evidenced, (c) owned by a named role,
(d) approved by ALCO, and (e) **subject to ongoing monitoring against observed
outcomes**.

### 3.2 Assumption ownership

| Assumption family | Owner |
|---|---|
| Retail deposit retention and stability | Treasury Risk |
| Deposit beta and repricing | Treasury ALM |
| Term deposit rollover | Treasury ALM |
| HQLA composition and monetisation | Treasury Front Office |

## 4. Deposit stability classification

### 4.1 Categories

Retail deposits are classified as **stable** or **less stable** for the purpose
of applying stress runoff rates. Stable retail deposits attract a materially
lower runoff rate in the 30-day stress scenario and therefore have a direct and
significant effect on the LCR denominator.

### 4.2 Behavioural stability test

Retail salary deposits are considered behaviourally stable where historical
analysis demonstrates retention of **at least 90% of incumbent balances over a
rolling ninety-day horizon under normal operating conditions**.

For the avoidance of doubt:

- "Incumbent balances" means balances held by customers already on book at the
  start of the measurement window. Balances acquired during the window are
  **excluded** from the retention calculation.
- "Normal operating conditions" excludes periods of idiosyncratic stress
  affecting the Group and periods of material competitor repricing activity.
- The measurement must be performed on the incumbent cohort. **Aggregate
  deposit balance growth is not evidence of behavioural stability**, because
  new-customer inflows can offset and therefore conceal incumbent attrition.

### 4.3 Conditions of validity

A behavioural stability classification is valid only while the conditions under
which it was evidenced continue to hold. The following conditions are treated as
part of the validity envelope for retail deposit retention assumptions:

1. Policy rate within the range assumed at the time of approval.
2. Promotional funding as a share of total deposits does not exceed **5%**.
3. Deposit concentration does not exceed 18% of total funding.
4. Digitally-acquired customers do not exceed 45% of the relevant cohort.

Where any validity condition ceases to hold, the assumption must be
re-evidenced before continued reliance, irrespective of whether the headline
metric remains within tolerance.

## 5. Monitoring and challenge

### 5.1 Frequency

Behavioural assumptions supporting Tier 1 liquidity models are monitored no less
frequently than monthly. Assumptions classified as CRITICAL materiality are
monitored continuously where data permits.

### 5.2 Thresholds

For each assumption the owner must define:

- an **expected value** (the approved premise),
- a **challenge threshold** at which investigation is mandatory,
- a **breach threshold** at which reliance must be suspended pending review,
- a **persistence requirement** expressed in observation days.

A single observation beyond a threshold does not constitute a breach. The
persistence requirement exists to prevent operational noise from triggering
governance action.

### 5.3 Consequence of breach

On confirmation of a breach the assumption owner must:

1. suspend reliance on the assumption for new calculations;
2. identify all models, metrics, reports and prior decisions that relied on it;
3. quantify the impact on affected metrics;
4. place affected committee decisions into reassessment;
5. propose either a revised assumption or a compensating action.

Confirmation of a breach and approval of any revised assumption are reserved to
the accountable human governance owner. Automated monitoring may detect,
evidence and recommend, but may not approve.

## 6. Simplified LCR formulation

For internal illustration the LCR is expressed as:

```
LCR = HQLA / (stressed gross outflows - capped expected inflows) x 100
```

where stressed gross outflows are the sum of each funding category multiplied by
its assigned runoff rate, and expected inflows are capped at 75% of gross
outflows. The runoff rate applied to stable retail deposits is a direct function
of the approved retention premise: a shortfall in observed retention increases
the applicable runoff rate and therefore reduces the LCR.

## 7. Record keeping

All assumption approvals, challenges, breaches, impact assessments and revisions
must be retained with immutable version history, including the evidence relied
upon at the time of each decision.
