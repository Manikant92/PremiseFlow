---
name: premiseflow-impact
description: Trace a PremiseFlow assumption's downstream dependencies and run impact scenarios to quantify the consequence of the assumption no longer holding. Use for blast radius, what depends on this assumption, what breaks if retention falls, LCR impact, funding gap, scenario comparison. Triggers: impact of assumption, blast radius, what depends on A-DEP-001, simulate retention, LCR if retention falls, scenario comparison, downstream impact.
---

# PremiseFlow: Assumption Impact and Blast Radius

Traces what an assumption feeds, then quantifies the consequence of replacing the
approved premise with observed reality.

All risk figures are **illustrative simplified POC calculations over fully
synthetic data**. Say so in every answer.

## Steps

### 1. Blast radius

```sql
SELECT DEPTH, SOURCE_OBJECT, RELATIONSHIP_TYPE, TARGET_OBJECT, TARGET_TYPE,
       MATERIALITY, SENSITIVITY_NOTE
FROM PREMISEFLOW.CORE.V_BLAST_RADIUS
WHERE ROOT_OBJECT = 'A-DEP-001'
ORDER BY DEPTH, TARGET_TYPE, TARGET_OBJECT;
```

Report the primary critical chain explicitly, for example:
`A-DEP-001 -> LIQUIDITY_STRESS_MODEL -> STRESSED_OUTFLOW_30D -> LCR -> ALCO_FORECAST_MODEL -> ALCO_DECISION_2026_017`.

### 2. Decisions exposed, and the version they relied on

```sql
SELECT DECISION_REF, TITLE, RELIANCE_STRENGTH, RELIED_ON_VERSION_ID,
       GOVERNANCE_STATUS, DECISION_DATE, RELIANCE_NOTE
FROM PREMISEFLOW.CORE.V_AFFECTED_DECISIONS
WHERE ASSUMPTION_ID = 'A-DEP-001'
ORDER BY DECISION_REF;
```

### 3. Run baseline versus observed

```sql
CALL PREMISEFLOW.APP.RUN_IMPACT_FOR_ASSUMPTION('A-DEP-001', 'coco_skill');
```

### 4. Run a user-specified premise

```sql
CALL PREMISEFLOW.APP.RUN_IMPACT_SIMULATION(
  'A-DEP-001', 0.84, 'USER_DEFINED', 'Sensitivity at 84% retention', 'coco_skill', NULL);
```

### 5. Compare

```sql
SELECT SCENARIO_TYPE, SCENARIO_NAME, ROUND(RETENTION_INPUT,4) AS RETENTION,
       METRIC_ID, METRIC_NAME, ROUND(METRIC_VALUE,3) AS VALUE, UNIT,
       INTERNAL_LIMIT, REGULATORY_MIN, BREACHES_LIMIT
FROM PREMISEFLOW.CORE.V_SCENARIO_COMPARISON
WHERE ASSUMPTION_ID = 'A-DEP-001'
QUALIFY ROW_NUMBER() OVER (PARTITION BY SCENARIO_TYPE, METRIC_ID ORDER BY CREATED_AT DESC) = 1
ORDER BY METRIC_ID, SCENARIO_TYPE;
```

### 6. Show the arithmetic when asked

```sql
SELECT DISTINCT METRIC_ID, FORMULA FROM PREMISEFLOW.CORE.SCENARIO_RESULTS;
SELECT * FROM PREMISEFLOW.CORE.LIQUIDITY_INPUTS;
SELECT * FROM PREMISEFLOW.CORE.SIM_PARAMETERS;
```

The single line that carries the assumption into the risk number is:

```
effective stable runoff rate = base stable runoff + max(0, approved retention - scenario retention) x sensitivity
```

## Reporting rules

- Give LCR against both thresholds: 110% internal limit and 100% regulatory minimum.
- Report the delta, not just the levels.
- Name the objects that are NOT affected too. A bounded blast radius is a result.
- Never describe the output as a regulatory LCR.

## Boundaries

Simulation and reporting only. Do not change a decision status or approve a
revised assumption.
