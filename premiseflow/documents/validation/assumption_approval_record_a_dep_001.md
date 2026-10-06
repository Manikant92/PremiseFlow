# Assumption Approval Record

**Assumption reference:** A-DEP-001
**Assumption name:** Retail Salary Deposit Stability
**Version:** 1
**Domain:** Liquidity
**Materiality:** CRITICAL
**Owner role:** Treasury Risk
**Approval forum:** Asset and Liability Committee
**Approved by:** ALCO Chair (synthetic: A. Rahman)

> SYNTHETIC DOCUMENT prepared for the PremiseFlow hackathon proof of concept.

## 1. Approved statement

> Retail salary-account deposits retain at least **90%** of incumbent balances
> over a rolling **90-day** horizon under normal operating conditions.

## 2. Governed parameters

| Parameter | Value |
|---|---|
| Expected value (approved premise) | 0.90 |
| Lower bound of approved range | 0.88 |
| Upper bound of approved range | 1.00 |
| Challenge threshold | 0.88 |
| Breach threshold | 0.85 |
| Persistence requirement | 5 observation days |
| Direction | Lower is worse |
| Measurement metric | `INCUMBENT_SALARY_RETENTION_90D` |

A single observation below a threshold does not constitute a breach. The
persistence requirement of five observation days exists to prevent operational
noise from triggering governance action (see MV-2025-042 Finding 4).

## 3. Validity envelope

Reliance on this assumption is valid only while all of the following hold:

| Condition | Approved tolerance |
|---|---|
| Policy rate | 4.00% to 5.25% |
| Promotional funding share of total deposits | not more than 5% |
| Deposit concentration | not more than 18% |
| Digitally-acquired share of cohort | not more than 45% |
| Operating conditions | normal; no idiosyncratic stress; no material competitor repricing campaign |

If any condition ceases to hold, the assumption must be re-evidenced before
continued reliance, **even if the headline retention metric remains within
tolerance**.

## 4. Evidence relied upon at approval

| Evidence | Type | Source | Result |
|---|---|---|---|
| EVD-A-DEP-001-01 | Structured data | Eight-quarter cohort study, 4,800 incumbent payroll customers | Mean retention 92.1%, minimum 90.4% |
| EVD-A-DEP-001-02 | Document | Liquidity Risk Policy LRP-2026-v4 section 4.2 | Defines the 90% / 90-day behavioural stability test |
| EVD-A-DEP-001-03 | Model result | Independent validation MV-2025-042 | Reproduced retention at 91.8%; rated Fit for Purpose |
| EVD-A-DEP-001-04 | Document | This approval record | Fixes the governed threshold at 90% |

## 5. Downstream reliance declared at approval

| Dependent object | Type | Materiality |
|---|---|---|
| LIQUIDITY_STRESS_MODEL | Model | Critical |
| STRESSED_OUTFLOW_30D | Metric | Critical |
| LCR | Metric | Critical |
| FTP_FUNDING_FORECAST | Model | High |
| FUNDING_GAP_90D | Metric | High |
| NII_12M | Metric | High |
| ALCO_FORECAST_MODEL | Model | Critical |
| ALCO_DECISION_2026_017 | Decision | Critical |
| ALCO_DECISION_2026_011 | Decision | High |
| DEPOSIT_BEHAVIOUR_MODEL | Model | High |
| LRP-2026-v4 | Policy | High |

## 6. Sensitivity of the LCR to this assumption

The stable retail runoff rate applied in the 30-day liquidity stress is a direct
function of this premise:

```
effective stable runoff rate = 0.05 + max(0, 0.90 - observed retention) x 0.80
```

Each percentage point of retention shortfall therefore adds approximately 0.8
percentage points to the stable runoff rate applied to the retail stable deposit
pool.

## 7. Monitoring obligations

1. Continuous monitoring against `INCUMBENT_SALARY_RETENTION_90D`.
2. Decomposition by acquisition channel, tenure band and wealth segment at every
   evaluation.
3. Side-by-side reporting of incumbent retention and aggregate deposit movement
   whenever promotional funding exceeds 5% of total deposits.
4. Monthly attestation by the owner role that the validity envelope still holds.

## 8. Governance reservation

Detection, evidencing, impact quantification and recommendation may be performed
by automated monitoring. **Confirmation of a breach, and approval of any revised
version of this assumption, are reserved to the accountable human governance
owner.** No automated process may approve a revised assumption or publish a new
current version.

## 9. Re-approval trigger

This assumption must be brought back for re-approval on any of:

- sustained observed retention below the breach threshold of 85%;
- any validity envelope condition ceasing to hold;
- a material change to the acquisition mix of the governed cohort;
- the scheduled annual review, whichever occurs first.
