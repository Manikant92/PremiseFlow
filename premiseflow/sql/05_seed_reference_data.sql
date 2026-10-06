-- PremiseFlow :: 05_seed_reference_data.sql
-- Seeds the governed layer: assumption registry + immutable v1 versions,
-- models, risk metrics, prior decisions, the dependency graph and the
-- simplified liquidity inputs used by the impact simulator.
-- Idempotent: fully re-seeds the reference rows it owns.

USE DATABASE PREMISEFLOW;
USE SCHEMA CORE;

-- ---------------------------------------------------------------------------
-- 1. Assumption registry (10 assumptions so this reads as a platform)
-- ---------------------------------------------------------------------------
DELETE FROM CORE.ASSUMPTIONS;
INSERT INTO CORE.ASSUMPTIONS
 (ASSUMPTION_ID, NAME, STATEMENT, DOMAIN, OWNER_ROLE, MATERIALITY, STATUS,
  CURRENT_VERSION, METRIC_CODE, LAST_VALIDATED_AT)
SELECT column1, column2, column3, column4, column5, column6, column7, column8, column9,
       DATEADD(day, column10, CURRENT_TIMESTAMP())
FROM VALUES
 ('A-DEP-001','Retail Salary Deposit Stability',
  'Retail salary-account deposits retain at least 90% of incumbent balances over a rolling 90-day horizon under normal operating conditions.',
  'LIQUIDITY','Treasury Risk','CRITICAL','VALID',1,'INCUMBENT_SALARY_RETENTION_90D',-210),
 ('A-DEP-002','Deposit Beta Ceiling',
  'Blended retail deposit beta remains at or below 0.45 through the current policy-rate cycle.',
  'LIQUIDITY','Treasury ALM','HIGH','VALID',1,'DEPOSIT_BETA_ROLLING',-195),
 ('A-DEP-003','Term Deposit Rollover',
  'At least 75% of maturing retail term deposits roll over into a comparable tenor.',
  'LIQUIDITY','Treasury ALM','MEDIUM','VALID',1,'TERM_ROLLOVER_RATE',-160),
 ('A-DEP-004','Digital Cohort Behavioural Equivalence',
  'Digitally-acquired retail customers exhibit deposit behaviour statistically equivalent to branch-acquired cohorts of comparable tenure.',
  'LIQUIDITY','Deposit Analytics','HIGH','VALID',1,'DIGITAL_COHORT_DIVERGENCE',-140),
 ('A-LIQ-001','HQLA Composition',
  'Level 1 assets comprise at least 70% of the high-quality liquid asset buffer.',
  'LIQUIDITY','Treasury Front Office','MEDIUM','VALID',1,'LEVEL1_HQLA_SHARE',-120),
 ('A-CRD-001','Revolving Line Utilisation Under Stress',
  'Committed revolving credit-line utilisation remains at or below 45% in the modelled stress scenario.',
  'CREDIT','Credit Risk','HIGH','VALID',1,'REVOLVER_UTILISATION_STRESS',-175),
 ('A-CRD-002','Mortgage Prepayment Range',
  'Mortgage prepayment speed remains within a 6% to 11% conditional prepayment rate band.',
  'CREDIT','Credit Risk Modelling','MEDIUM','VALID',1,'MORTGAGE_CPR',-150),
 ('A-IRR-001','Non-Maturity Deposit Repricing Lag',
  'Administered-rate non-maturity deposits reprice with a lag of at least 3 months relative to policy rate moves.',
  'IRRBB','Treasury ALM','HIGH','VALID',1,'NMD_REPRICING_LAG_MONTHS',-185),
 ('A-MKT-001','Collateral Liquidation Horizon',
  'Pledged collateral can be liquidated within 5 business days without material price concession.',
  'MARKET','Treasury Front Office','MEDIUM','VALID',1,'COLLATERAL_LIQUIDATION_DAYS',-130),
 ('A-CAP-001','Operational Loss Frequency Stability',
  'Operational loss event frequency remains within the historically observed Poisson intensity band.',
  'OPERATIONAL','Operational Risk','LOW','VALID',1,'OPRISK_LOSS_FREQUENCY',-100);

-- ---------------------------------------------------------------------------
-- 2. Immutable version 1 records (all APPROVED, all IS_CURRENT)
-- ---------------------------------------------------------------------------
DELETE FROM CORE.ASSUMPTION_VERSIONS;
INSERT INTO CORE.ASSUMPTION_VERSIONS
 (VERSION_ID, ASSUMPTION_ID, VERSION_NUMBER, STATEMENT, EXPECTED_VALUE, LOWER_BOUND, UPPER_BOUND,
  CHALLENGE_THRESHOLD, BREACH_THRESHOLD, PERSISTENCE_DAYS, DIRECTION,
  VALID_FROM, VALID_TO, VALIDITY_ENVELOPE, EVIDENCE_SUMMARY,
  APPROVAL_STATUS, APPROVED_BY, APPROVED_AT, PROPOSED_BY, PROPOSED_AT,
  SUPERSEDES_VERSION_ID, IS_CURRENT)
SELECT
  a.ASSUMPTION_ID||'-V1', a.ASSUMPTION_ID, 1, a.STATEMENT,
  v.EXPECTED_VALUE, v.LOWER_BOUND, v.UPPER_BOUND, v.CHALLENGE_THRESHOLD, v.BREACH_THRESHOLD,
  v.PERSISTENCE_DAYS, v.DIRECTION,
  a.LAST_VALIDATED_AT, NULL,
  TRY_PARSE_JSON(v.ENVELOPE_JSON), v.EVIDENCE_SUMMARY,
  'APPROVED', v.APPROVED_BY, a.LAST_VALIDATED_AT, v.APPROVED_BY,
  DATEADD(day,-14,a.LAST_VALIDATED_AT), NULL, TRUE
FROM CORE.ASSUMPTIONS a
JOIN (
  SELECT * FROM VALUES
   ('A-DEP-001', 0.90, 0.88, 1.00, 0.88, 0.85, 5, 'LOWER_IS_WORSE',
    '{"policy_rate_pct":{"min":4.00,"max":5.25},"promotional_funding_share_max":0.05,'||
    '"deposit_concentration_max":0.18,"digital_acquisition_share_max":0.45,'||
    '"conditions":"normal operating conditions; no idiosyncratic stress event; no material competitor repricing campaign"}',
    'Eight-quarter cohort study of 4,800 incumbent payroll customers. Rolling 90-day balance retention observed '||
    'in a 91%-93% band with no quarter below 90.4%. Independently validated in MV-2025-042.',
    'ALCO Chair (synthetic: A. Rahman)'),
   ('A-DEP-002', 0.45, 0.00, 0.45, 0.50, 0.55, 5, 'UPPER_IS_WORSE',
    '{"policy_rate_pct":{"min":4.00,"max":5.25},"conditions":"orderly competitive environment"}',
    'Historical pass-through regression across the prior two tightening cycles; blended beta 0.38-0.44.',
    'Head of ALM (synthetic: S. Iyer)'),
   ('A-DEP-003', 0.75, 0.75, 1.00, 0.72, 0.68, 7, 'LOWER_IS_WORSE',
    '{"conditions":"no promotional rate war"}',
    'Three-year maturity-ladder rollover study; observed 77%-83%.',
    'Head of ALM (synthetic: S. Iyer)'),
   ('A-DEP-004', 0.05, 0.00, 0.05, 0.08, 0.12, 7, 'UPPER_IS_WORSE',
    '{"conditions":"tenure-matched comparison; minimum cohort size 500"}',
    'Kolmogorov-Smirnov comparison of balance-change distributions across acquisition channels; divergence < 0.04.',
    'Deposit Analytics Lead (synthetic: M. Chen)'),
   ('A-LIQ-001', 0.70, 0.70, 1.00, 0.68, 0.65, 3, 'LOWER_IS_WORSE',
    '{"conditions":"month-end buffer composition"}',
    'Twelve-month HQLA composition review; Level 1 share 74%-81%.',
    'Treasurer (synthetic: D. Okafor)'),
   ('A-CRD-001', 0.45, 0.00, 0.45, 0.48, 0.52, 5, 'UPPER_IS_WORSE',
    '{"conditions":"modelled severe-but-plausible downturn"}',
    'Drawdown behaviour study over two recessionary episodes; stressed utilisation 39%-44%.',
    'Chief Credit Officer (synthetic: L. Duarte)'),
   ('A-CRD-002', 0.085, 0.06, 0.11, 0.115, 0.125, 7, 'TWO_SIDED',
    '{"conditions":"stable mortgage spread environment"}',
    'Prepayment model recalibration MV-2025-031; observed CPR 7.2%-10.4%.',
    'Credit Risk Modelling (synthetic: P. Novak)'),
   ('A-IRR-001', 3.0, 3.0, 12.0, 2.5, 2.0, 5, 'LOWER_IS_WORSE',
    '{"conditions":"administered-rate products only"}',
    'Repricing lag estimated from historical rate-move response; 3.1-4.2 months.',
    'Head of ALM (synthetic: S. Iyer)'),
   ('A-MKT-001', 5.0, 0.0, 5.0, 6.0, 7.0, 3, 'UPPER_IS_WORSE',
    '{"conditions":"orderly market conditions"}',
    'Collateral liquidity assessment across pledged portfolio; 2-4 business days.',
    'Treasury Front Office (synthetic: R. Bianchi)'),
   ('A-CAP-001', 12.0, 8.0, 16.0, 17.0, 19.0, 10, 'UPPER_IS_WORSE',
    '{"conditions":"rolling 12-month loss event count"}',
    'Operational loss database intensity fit; 10-14 events per annum.',
    'Operational Risk (synthetic: K. Aluko)')
  AS t(ASSUMPTION_ID, EXPECTED_VALUE, LOWER_BOUND, UPPER_BOUND, CHALLENGE_THRESHOLD,
       BREACH_THRESHOLD, PERSISTENCE_DAYS, DIRECTION, ENVELOPE_JSON, EVIDENCE_SUMMARY, APPROVED_BY)
) v ON v.ASSUMPTION_ID = a.ASSUMPTION_ID;

-- ---------------------------------------------------------------------------
-- 3. Approval-time evidence
-- ---------------------------------------------------------------------------
DELETE FROM CORE.ASSUMPTION_EVIDENCE;
INSERT INTO CORE.ASSUMPTION_EVIDENCE
 (EVIDENCE_ID, ASSUMPTION_ID, VERSION_ID, EVIDENCE_TYPE, SOURCE_REF, SOURCE_DOCUMENT,
  OBSERVED_VALUE, SAMPLE_SIZE, PERIOD_START, PERIOD_END, SUMMARY)
SELECT column1, column2, column3, column4, column5, column6, column7, column8,
       DATEADD(day, column9, CURRENT_DATE), DATEADD(day, column10, CURRENT_DATE), column11
FROM VALUES
 ('EVD-A-DEP-001-01','A-DEP-001','A-DEP-001-V1','STRUCTURED_DATA','COHORT_STUDY_2025Q1_Q4','model_methodology/deposit_behaviour_model_methodology.md',
  0.921, 4800, -730, -240,'Eight-quarter rolling 90-day incumbent balance retention: mean 92.1%, min 90.4%, max 93.2%.'),
 ('EVD-A-DEP-001-02','A-DEP-001','A-DEP-001-V1','DOCUMENT','LRP-2026-v4 s4.2','liquidity_policy/liquidity_risk_policy.md',
  NULL, NULL, -400, -400,'Liquidity Risk Policy defines behaviourally stable retail deposits as requiring >=90% retention over 90 days.'),
 ('EVD-A-DEP-001-03','A-DEP-001','A-DEP-001-V1','MODEL_RESULT','MV-2025-042','validation/model_validation_report_mv_2025_042.md',
  0.918, 4800, -730, -240,'Independent model validation reproduced the retention estimate at 91.8% and rated the assumption Fit for Purpose.'),
 ('EVD-A-DEP-001-04','A-DEP-001','A-DEP-001-V1','DOCUMENT','AAR-A-DEP-001','validation/assumption_approval_record_a_dep_001.md',
  0.900, NULL, -210, -210,'Formal approval record fixing the governed threshold at 90% with a 90-day rolling horizon.'),
 ('EVD-A-DEP-002-01','A-DEP-002','A-DEP-002-V1','STRUCTURED_DATA','BETA_REGRESSION_2024','model_methodology/deposit_behaviour_model_methodology.md',
  0.412, 12, -1100, -210,'Pass-through regression across two tightening cycles; blended beta 0.41.'),
 ('EVD-A-DEP-004-01','A-DEP-004','A-DEP-004-V1','STRUCTURED_DATA','KS_CHANNEL_TEST','model_methodology/deposit_behaviour_model_methodology.md',
  0.038, 6200, -700, -200,'Channel-level distribution divergence 0.038, below the 0.05 equivalence tolerance.'),
 ('EVD-A-CRD-001-01','A-CRD-001','A-CRD-001-V1','STRUCTURED_DATA','REVOLVER_STRESS_2025','model_methodology/deposit_behaviour_model_methodology.md',
  0.431, 890, -900, -200,'Stressed revolver utilisation 43.1% across two downturn episodes.');

-- ---------------------------------------------------------------------------
-- 4. Downstream governed objects
-- ---------------------------------------------------------------------------
DELETE FROM CORE.MODELS;
INSERT INTO CORE.MODELS (MODEL_ID, NAME, MODEL_TYPE, OWNER_ROLE, TIER, LAST_VALIDATED, STATUS, DESCRIPTION)
SELECT column1, column2, column3, column4, column5, DATEADD(day, column6, CURRENT_DATE), column7, column8
FROM VALUES
 ('LIQUIDITY_STRESS_MODEL','Liquidity Stress Model','STRESS_TESTING','Treasury Risk','TIER_1',-240,'APPROVED',
  'Thirty-day survival and stressed-outflow engine. Consumes retail behavioural retention assumptions to set runoff rates.'),
 ('DEPOSIT_BEHAVIOUR_MODEL','Deposit Behaviour Model','BEHAVIOURAL','Deposit Analytics','TIER_1',-260,'APPROVED',
  'Estimates retention, beta and repricing behaviour by cohort. Source of the A-DEP family of assumptions.'),
 ('FTP_FUNDING_FORECAST','FTP and Funding Forecast','FORECAST','Treasury ALM','TIER_2',-200,'APPROVED',
  'Twelve-month funding and transfer-pricing projection; sensitive to stable-deposit volumes.'),
 ('ALCO_FORECAST_MODEL','ALCO Balance Sheet Forecast','FORECAST','Treasury ALM','TIER_2',-180,'APPROVED',
  'Committee-facing balance sheet and liquidity projection pack.'),
 ('IRRBB_EVE_MODEL','IRRBB EVE Model','IRRBB','Treasury ALM','TIER_1',-220,'APPROVED',
  'Economic value of equity sensitivity; consumes NMD repricing assumptions.'),
 ('CREDIT_UTILISATION_MODEL','Revolving Utilisation Model','CREDIT','Credit Risk','TIER_2',-190,'APPROVED',
  'Committed-line drawdown behaviour under stress.');

DELETE FROM CORE.RISK_METRICS;
INSERT INTO CORE.RISK_METRICS (METRIC_ID, NAME, METRIC_TYPE, UNIT, INTERNAL_LIMIT, REGULATORY_MIN, OWNER_ROLE, DESCRIPTION)
SELECT * FROM VALUES
 ('LCR','Liquidity Coverage Ratio','LIQUIDITY','PCT',110.0,100.0,'Treasury Risk',
  'HQLA divided by stressed 30-day net cash outflows. POC uses a simplified transparent formulation.'),
 ('STRESSED_OUTFLOW_30D','Stressed 30-Day Net Cash Outflow','LIQUIDITY','USD_M',NULL,NULL,'Treasury Risk',
  'Denominator of the LCR. Directly sensitive to retail retention assumptions.'),
 ('FUNDING_GAP_90D','Ninety-Day Funding Gap','LIQUIDITY','USD_M',150.0,NULL,'Treasury ALM',
  'Stable deposit shortfall requiring wholesale replacement.'),
 ('NII_12M','Twelve-Month Net Interest Income','EARNINGS','USD_M',NULL,NULL,'Treasury ALM',
  'Projected net interest income; reduced by incremental replacement funding cost.'),
 ('NSFR','Net Stable Funding Ratio','LIQUIDITY','PCT',105.0,100.0,'Treasury Risk',
  'Available versus required stable funding.');

-- ---------------------------------------------------------------------------
-- 5. Previously approved committee decisions
-- ---------------------------------------------------------------------------
DELETE FROM CORE.DECISIONS;
INSERT INTO CORE.DECISIONS
 (DECISION_ID, DECISION_REF, TITLE, COMMITTEE, DECISION_DATE, DECISION_TEXT, RATIONALE,
  APPROVED_BY, MATERIALITY, GOVERNANCE_STATUS, STATUS_CHANGED_AT, SOURCE_DOCUMENT)
SELECT column1, column2, column3, column4, DATEADD(day, column5, CURRENT_DATE),
       column6, column7, column8, column9, 'APPROVED',
       DATEADD(day, column5, CURRENT_TIMESTAMP()), column10
FROM VALUES
 ('ALCO_DECISION_2026_017','ALCO-2026-017','Maintain current liquidity buffer strategy','ALCO',-120,
  'Maintain the current liquidity buffer strategy and hold HQLA at the existing level. Do not pre-fund additional '||
  'term wholesale capacity in the coming two quarters.',
  'Modelled LCR remains comfortably above the 110% internal threshold under the approved retail deposit behaviour '||
  'assumptions, including retail salary deposit retention of 90% over a rolling 90-day horizon (A-DEP-001 v1).',
  'ALCO Chair (synthetic: A. Rahman)','CRITICAL','alco/alco_decision_pack_2026_017.md'),
 ('ALCO_DECISION_2026_011','ALCO-2026-011','Retail funds transfer pricing curve refresh','ALCO',-165,
  'Adopt the refreshed retail FTP curve with a stable-deposit credit of 38 basis points for payroll-linked balances.',
  'Stable-deposit credit is calibrated to behavioural retention evidenced by A-DEP-001 v1 and the deposit beta ceiling A-DEP-002 v1.',
  'Head of ALM (synthetic: S. Iyer)','HIGH','alco/alco_decision_pack_2026_017.md'),
 ('ALCO_DECISION_2026_009','ALCO-2026-009','Mortgage prepayment model recalibration cadence','ALCO',-175,
  'Move mortgage prepayment model recalibration from annual to semi-annual cadence.',
  'Driven by prepayment speed variability (A-CRD-002 v1). Independent of retail deposit behaviour.',
  'Chief Credit Officer (synthetic: L. Duarte)','MEDIUM','alco/alco_decision_pack_2026_017.md'),
 ('ALCO_DECISION_2026_021','ALCO-2026-021','Committed revolving facility limit framework','ALCO',-95,
  'Retain the existing committed revolving facility limit framework with no change to sector caps.',
  'Stressed utilisation remains within the approved ceiling (A-CRD-001 v1).',
  'Chief Credit Officer (synthetic: L. Duarte)','MEDIUM','alco/alco_decision_pack_2026_017.md');

DELETE FROM CORE.DECISION_DEPENDENCIES;
INSERT INTO CORE.DECISION_DEPENDENCIES
 (DECISION_DEP_ID, DECISION_ID, ASSUMPTION_ID, VERSION_ID, RELIANCE_STRENGTH, RELIANCE_NOTE)
SELECT * FROM VALUES
 ('DD-001','ALCO_DECISION_2026_017','A-DEP-001','A-DEP-001-V1','MATERIAL',
  'The no-pre-funding conclusion rests directly on the 90% retention premise feeding the LCR stressed outflow.'),
 ('DD-002','ALCO_DECISION_2026_017','A-DEP-002','A-DEP-002-V1','SUPPORTING',
  'Deposit beta ceiling supports the projected funding cost path.'),
 ('DD-003','ALCO_DECISION_2026_011','A-DEP-001','A-DEP-001-V1','MATERIAL',
  'The 38bp stable-deposit FTP credit is calibrated off the 90% retention premise.'),
 ('DD-004','ALCO_DECISION_2026_011','A-DEP-002','A-DEP-002-V1','SUPPORTING',
  'Beta ceiling caps the modelled cost of retained balances.'),
 ('DD-005','ALCO_DECISION_2026_009','A-CRD-002','A-CRD-002-V1','MATERIAL',
  'Recalibration cadence is driven purely by prepayment speed variability.'),
 ('DD-006','ALCO_DECISION_2026_021','A-CRD-001','A-CRD-001-V1','MATERIAL',
  'Limit framework relies on the stressed utilisation ceiling.');

-- ---------------------------------------------------------------------------
-- 6. Assumption dependency graph (blast radius)
-- ---------------------------------------------------------------------------
DELETE FROM CORE.ASSUMPTION_DEPENDENCIES;
INSERT INTO CORE.ASSUMPTION_DEPENDENCIES
 (DEPENDENCY_ID, SOURCE_OBJECT, SOURCE_TYPE, TARGET_OBJECT, TARGET_TYPE,
  RELATIONSHIP_TYPE, MATERIALITY, SENSITIVITY_NOTE, VALID_FROM, VALID_TO)
SELECT column1, column2, column3, column4, column5, column6, column7, column8,
       DATEADD(day,-240,CURRENT_TIMESTAMP()), NULL
FROM VALUES
 -- primary chain
 ('DEP-001','A-DEP-001','ASSUMPTION','LIQUIDITY_STRESS_MODEL','MODEL','INPUT_TO','CRITICAL',
  'Retention drives the retail stable-deposit runoff rate in the 30-day stress.'),
 ('DEP-002','LIQUIDITY_STRESS_MODEL','MODEL','STRESSED_OUTFLOW_30D','METRIC','FEEDS','CRITICAL',
  'Stressed outflow is the direct model output.'),
 ('DEP-003','STRESSED_OUTFLOW_30D','METRIC','LCR','METRIC','FEEDS','CRITICAL',
  'Stressed net outflow is the LCR denominator.'),
 ('DEP-004','A-DEP-001','ASSUMPTION','LCR','METRIC','CONSTRAINS','CRITICAL',
  'Direct sensitivity: each 1pp of retention shortfall raises the stable runoff rate.'),
 ('DEP-005','A-DEP-001','ASSUMPTION','FTP_FUNDING_FORECAST','MODEL','INPUT_TO','HIGH',
  'Stable-deposit volume assumption sets the replacement funding requirement.'),
 ('DEP-006','FTP_FUNDING_FORECAST','MODEL','FUNDING_GAP_90D','METRIC','FEEDS','HIGH',
  'Funding gap equals the stable deposit shortfall.'),
 ('DEP-007','FTP_FUNDING_FORECAST','MODEL','NII_12M','METRIC','FEEDS','HIGH',
  'Replacement wholesale funding at a spread reduces net interest income.'),
 ('DEP-008','LCR','METRIC','ALCO_FORECAST_MODEL','MODEL','INPUT_TO','CRITICAL',
  'Committee liquidity projection consumes the LCR path.'),
 ('DEP-009','FUNDING_GAP_90D','METRIC','ALCO_FORECAST_MODEL','MODEL','INPUT_TO','HIGH',
  'Funding gap appears in the committee pack.'),
 ('DEP-010','ALCO_FORECAST_MODEL','MODEL','ALCO_DECISION_2026_017','DECISION','JUSTIFIES','CRITICAL',
  'The buffer decision was justified by the forecast LCR headroom.'),
 ('DEP-011','A-DEP-001','ASSUMPTION','ALCO_DECISION_2026_017','DECISION','JUSTIFIES','CRITICAL',
  'Decision rationale cites the 90% retention premise explicitly.'),
 ('DEP-012','A-DEP-001','ASSUMPTION','ALCO_DECISION_2026_011','DECISION','JUSTIFIES','HIGH',
  'Stable-deposit FTP credit is calibrated off this premise.'),
 ('DEP-013','A-DEP-001','ASSUMPTION','LRP-2026-v4','POLICY','CONSTRAINS','HIGH',
  'Policy section 4.2 codifies the 90% behavioural stability test.'),
 ('DEP-014','A-DEP-001','ASSUMPTION','DEPOSIT_BEHAVIOUR_MODEL','MODEL','INPUT_TO','HIGH',
  'Retention is a calibrated output and governed input of the behavioural model.'),
 -- secondary chains
 ('DEP-020','A-DEP-002','ASSUMPTION','FTP_FUNDING_FORECAST','MODEL','INPUT_TO','HIGH',
  'Beta sets the pass-through in the funding cost projection.'),
 ('DEP-021','A-DEP-002','ASSUMPTION','NII_12M','METRIC','CONSTRAINS','HIGH',
  'Higher realised beta compresses net interest income.'),
 ('DEP-022','A-DEP-002','ASSUMPTION','ALCO_DECISION_2026_011','DECISION','JUSTIFIES','MEDIUM',
  'FTP curve refresh assumed the beta ceiling would hold.'),
 ('DEP-023','A-DEP-003','ASSUMPTION','LIQUIDITY_STRESS_MODEL','MODEL','INPUT_TO','MEDIUM',
  'Rollover rate drives term deposit maturity runoff.'),
 ('DEP-024','A-DEP-004','ASSUMPTION','DEPOSIT_BEHAVIOUR_MODEL','MODEL','INPUT_TO','HIGH',
  'Channel equivalence permits pooled cohort estimation.'),
 ('DEP-025','A-LIQ-001','ASSUMPTION','LCR','METRIC','CONSTRAINS','MEDIUM',
  'HQLA composition affects the eligible numerator.'),
 ('DEP-026','A-CRD-001','ASSUMPTION','CREDIT_UTILISATION_MODEL','MODEL','INPUT_TO','HIGH',
  'Utilisation ceiling is the core stress input.'),
 ('DEP-027','A-CRD-001','ASSUMPTION','ALCO_DECISION_2026_021','DECISION','JUSTIFIES','MEDIUM',
  'Limit framework relies on the utilisation ceiling.'),
 ('DEP-028','A-CRD-002','ASSUMPTION','ALCO_DECISION_2026_009','DECISION','JUSTIFIES','MEDIUM',
  'Recalibration cadence driven by prepayment variability.'),
 ('DEP-029','A-IRR-001','ASSUMPTION','IRRBB_EVE_MODEL','MODEL','INPUT_TO','HIGH',
  'Repricing lag drives EVE sensitivity of non-maturity deposits.'),
 ('DEP-030','A-MKT-001','ASSUMPTION','LIQUIDITY_STRESS_MODEL','MODEL','INPUT_TO','MEDIUM',
  'Liquidation horizon determines monetisation capacity of the buffer.');

SELECT 'governed reference data seeded' AS STATUS,
  (SELECT COUNT(*) FROM CORE.ASSUMPTIONS) AS ASSUMPTIONS,
  (SELECT COUNT(*) FROM CORE.ASSUMPTION_VERSIONS) AS VERSIONS,
  (SELECT COUNT(*) FROM CORE.ASSUMPTION_DEPENDENCIES) AS DEPENDENCIES,
  (SELECT COUNT(*) FROM CORE.DECISIONS) AS DECISIONS;
