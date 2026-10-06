-- PremiseFlow :: 09_semantic_view.sql
-- Governed semantic layer so natural-language analysis understands the business
-- entities: assumptions, cohorts, retention, deposits, decisions, scenarios.

USE DATABASE PREMISEFLOW;
USE SCHEMA AI;

-- Dynamic tables have no natural key; wrap them with surrogate keys so they can
-- participate in semantic-view relationships.
CREATE OR REPLACE VIEW AI.SV_OBSERVATIONS AS
SELECT ASSUMPTION_ID||'|'||TO_VARCHAR(OBSERVATION_DATE,'YYYYMMDD') AS OBSERVATION_KEY,
       ASSUMPTION_ID, METRIC_CODE, OBSERVATION_DATE, OBSERVED_VALUE, SAMPLE_SIZE, WINDOW_DAYS, SOURCE
FROM CORE.DT_ASSUMPTION_OBSERVATIONS;

CREATE OR REPLACE VIEW AI.SV_RETENTION AS
SELECT TO_VARCHAR(OBSERVATION_DATE,'YYYYMMDD')||'|'||GRAIN||'|'||DIM_VALUE AS RETENTION_KEY,
       OBSERVATION_DATE, GRAIN, DIM_VALUE, WINDOW_DAYS,
       CURRENT_BALANCE, WINDOW_START_BALANCE, RETENTION_RATE, BALANCE_CHANGE, ACCOUNTS
FROM CORE.DT_RETENTION_DAILY;

CREATE OR REPLACE VIEW AI.SV_DEPOSITS AS
SELECT BALANCE_DATE, BREAK_DATE, IS_POST_BREAK,
       TOTAL_DEPOSITS, INCUMBENT_DEPOSITS, NEW_CUSTOMER_DEPOSITS, PROMOTIONAL_DEPOSITS,
       GOVERNED_STABLE_DEPOSITS, TERM_DEPOSITS, WHOLESALE_LIKE_DEPOSITS, ACTIVE_CUSTOMERS,
       TOTAL_DEPOSIT_GROWTH, GOVERNED_DEPOSIT_GROWTH, PROMOTIONAL_FUNDING_SHARE
FROM CORE.V_DEPOSIT_MASKING;

CREATE OR REPLACE SEMANTIC VIEW AI.PREMISEFLOW_SEMANTIC
  TABLES (
    assumptions AS CORE.ASSUMPTIONS PRIMARY KEY (ASSUMPTION_ID)
      WITH SYNONYMS = ('assumption','assumptions','premise','premises','assumption registry','governed assumption')
      COMMENT = 'Registry of governed assumptions that financial models and decisions depend upon.',

    versions AS CORE.ASSUMPTION_VERSIONS PRIMARY KEY (VERSION_ID)
      WITH SYNONYMS = ('assumption version','version','contract','assumption contract','approved version')
      COMMENT = 'Immutable version history of each assumption, including approved thresholds and validity envelope.',

    challenges AS CORE.ASSUMPTION_CHALLENGES PRIMARY KEY (CHALLENGE_ID)
      WITH SYNONYMS = ('challenge','challenges','falsification test','assumption test','challenge result')
      COMMENT = 'Result of each Reality Challenger evaluation of an assumption against observed data.',

    breaches AS CORE.ASSUMPTION_BREACHES PRIMARY KEY (BREACH_ID)
      WITH SYNONYMS = ('breach','breaches','assumption breach','confirmed breach')
      COMMENT = 'Breach records awaiting or having received human confirmation.',

    observations AS AI.SV_OBSERVATIONS PRIMARY KEY (OBSERVATION_KEY)
      WITH SYNONYMS = ('observation','observations','observed value','reality','measurement')
      COMMENT = 'Daily observed value of the metric governing each assumption.',

    retention AS AI.SV_RETENTION PRIMARY KEY (RETENTION_KEY)
      WITH SYNONYMS = ('retention','retention rate','cohort retention','deposit retention','incumbent retention')
      COMMENT = 'Rolling 90-day incumbent retail salary deposit retention, overall and decomposed by cohort dimension.',

    deposits AS AI.SV_DEPOSITS PRIMARY KEY (BALANCE_DATE)
      WITH SYNONYMS = ('deposits','deposit balance','balances','funding','deposit book')
      COMMENT = 'Daily deposit balances split into incumbent, new customer, promotional and governed stable pools.',

    decisions AS CORE.DECISIONS PRIMARY KEY (DECISION_ID)
      WITH SYNONYMS = ('decision','decisions','committee decision','ALCO decision','governance decision')
      COMMENT = 'Previously approved committee decisions and their governance status.',

    decision_deps AS CORE.DECISION_DEPENDENCIES PRIMARY KEY (DECISION_DEP_ID)
      WITH SYNONYMS = ('decision dependency','decision reliance','which decisions rely on an assumption')
      COMMENT = 'Which assumption version each decision relied upon, and how strongly.',

    reassessments AS CORE.REASSESSMENTS PRIMARY KEY (REASSESSMENT_ID)
      WITH SYNONYMS = ('reassessment','reassessments','decision reassessment','reopened decision')
      COMMENT = 'Reassessment records created when a confirmed breach invalidates the basis of a prior decision.',

    scenarios AS CORE.SCENARIOS PRIMARY KEY (SCENARIO_ID)
      WITH SYNONYMS = ('scenario','scenarios','simulation','what-if')
      COMMENT = 'Impact simulation scenarios: baseline approved premise, observed behaviour, or user defined.',

    scenario_results AS CORE.SCENARIO_RESULTS PRIMARY KEY (RESULT_ID)
      WITH SYNONYMS = ('scenario result','simulation result','impact result','metric outcome')
      COMMENT = 'Metric values produced by each scenario. Illustrative simplified POC calculations.',

    models AS CORE.MODELS PRIMARY KEY (MODEL_ID)
      WITH SYNONYMS = ('model','models','risk model','downstream model')
      COMMENT = 'Models that consume governed assumptions.',

    metrics AS CORE.RISK_METRICS PRIMARY KEY (METRIC_ID)
      WITH SYNONYMS = ('risk metric','metric','LCR','liquidity coverage ratio','NSFR','limit')
      COMMENT = 'Risk metrics with internal limits and regulatory minimums.',

    dependencies AS CORE.ASSUMPTION_DEPENDENCIES PRIMARY KEY (DEPENDENCY_ID)
      WITH SYNONYMS = ('dependency','dependencies','lineage','blast radius','impact chain','what depends on')
      COMMENT = 'Logical lineage edges from assumptions to models, metrics, reports, policies and decisions.'
  )

  RELATIONSHIPS (
    versions_to_assumption      AS versions(ASSUMPTION_ID)      REFERENCES assumptions,
    challenges_to_assumption    AS challenges(ASSUMPTION_ID)    REFERENCES assumptions,
    breaches_to_assumption      AS breaches(ASSUMPTION_ID)      REFERENCES assumptions,
    observations_to_assumption  AS observations(ASSUMPTION_ID)  REFERENCES assumptions,
    decision_deps_to_decision   AS decision_deps(DECISION_ID)   REFERENCES decisions,
    decision_deps_to_assumption AS decision_deps(ASSUMPTION_ID) REFERENCES assumptions,
    reassessments_to_decision   AS reassessments(DECISION_ID)   REFERENCES decisions,
    reassessments_to_assumption AS reassessments(ASSUMPTION_ID) REFERENCES assumptions,
    scenarios_to_assumption     AS scenarios(ASSUMPTION_ID)     REFERENCES assumptions,
    results_to_scenario         AS scenario_results(SCENARIO_ID) REFERENCES scenarios,
    results_to_metric           AS scenario_results(METRIC_ID)  REFERENCES metrics
  )

  FACTS (
    versions.expected_value        AS EXPECTED_VALUE,
    versions.challenge_threshold_f AS CHALLENGE_THRESHOLD,
    versions.breach_threshold_f    AS BREACH_THRESHOLD,
    versions.persistence_required  AS PERSISTENCE_DAYS,
    challenges.observed_value_f    AS OBSERVED_VALUE,
    challenges.deviation_f         AS DEVIATION,
    challenges.deviation_pct_f     AS DEVIATION_PCT,
    challenges.persistence_f       AS PERSISTENCE_DAYS,
    challenges.confidence_f        AS CONFIDENCE,
    challenges.robust_z_f          AS ROBUST_Z,
    observations.observed_value_f  AS OBSERVED_VALUE,
    retention.retention_rate_f     AS RETENTION_RATE,
    retention.balance_change_f     AS BALANCE_CHANGE,
    retention.accounts_f           AS ACCOUNTS,
    deposits.total_deposits_f      AS TOTAL_DEPOSITS,
    deposits.governed_stable_f     AS GOVERNED_STABLE_DEPOSITS,
    deposits.promotional_f         AS PROMOTIONAL_DEPOSITS,
    deposits.new_customer_f        AS NEW_CUSTOMER_DEPOSITS,
    deposits.incumbent_f           AS INCUMBENT_DEPOSITS,
    scenario_results.metric_value_f AS METRIC_VALUE,
    metrics.internal_limit_f       AS INTERNAL_LIMIT,
    metrics.regulatory_min_f       AS REGULATORY_MIN
  )

  DIMENSIONS (
    assumptions.assumption_id   AS ASSUMPTION_ID   WITH SYNONYMS=('assumption code','assumption reference','premise id'),
    assumptions.assumption_name AS NAME            WITH SYNONYMS=('assumption name','premise name'),
    assumptions.statement       AS STATEMENT       WITH SYNONYMS=('assumption statement','what must remain true'),
    assumptions.domain          AS DOMAIN          WITH SYNONYMS=('risk domain','risk type','area')
      COMMENT='LIQUIDITY, IRRBB, CREDIT, MARKET, OPERATIONAL.',
    assumptions.owner_role      AS OWNER_ROLE      WITH SYNONYMS=('owner','accountable team','assumption owner'),
    assumptions.materiality     AS MATERIALITY     WITH SYNONYMS=('criticality','importance','severity tier')
      COMMENT='CRITICAL, HIGH, MEDIUM or LOW.',
    assumptions.status          AS STATUS          WITH SYNONYMS=('assumption status','health','state')
      COMMENT='VALID, WATCH, CHALLENGED, UNDER_REVIEW, BREACHED or RETIRED.',
    assumptions.metric_code     AS METRIC_CODE     WITH SYNONYMS=('measured metric','governing metric'),

    versions.version_id         AS VERSION_ID      WITH SYNONYMS=('version identifier'),
    versions.version_number     AS VERSION_NUMBER  WITH SYNONYMS=('version','revision number'),
    versions.approval_status    AS APPROVAL_STATUS WITH SYNONYMS=('approval state')
      COMMENT='DRAFT, PROPOSED, APPROVED, REJECTED.',
    versions.approved_by        AS APPROVED_BY     WITH SYNONYMS=('approver','who approved'),
    versions.is_current_version AS IS_CURRENT      WITH SYNONYMS=('current version flag','active version'),
    versions.direction          AS DIRECTION       WITH SYNONYMS=('threshold direction'),
    versions.evidence_summary   AS EVIDENCE_SUMMARY WITH SYNONYMS=('supporting evidence','justification'),

    challenges.challenge_status AS STATUS          WITH SYNONYMS=('challenge outcome','test result'),
    challenges.observation_date AS OBSERVATION_DATE WITH SYNONYMS=('as of date','evaluation date'),
    challenges.change_point     AS CHANGE_POINT_DATE WITH SYNONYMS=('when did it change','structural break date'),
    challenges.method           AS METHOD          WITH SYNONYMS=('detection method'),
    challenges.explanation      AS EXPLANATION     WITH SYNONYMS=('why','narrative','challenge note'),

    breaches.confirmation_status AS CONFIRMATION_STATUS WITH SYNONYMS=('breach confirmed','confirmation state'),
    breaches.severity            AS SEVERITY,
    breaches.first_breach_date   AS FIRST_BREACH_DATE WITH SYNONYMS=('when did the breach start'),
    breaches.root_cause          AS ROOT_CAUSE_SUMMARY WITH SYNONYMS=('root cause','cause'),

    observations.observation_day AS OBSERVATION_DATE WITH SYNONYMS=('date','day'),
    observations.source          AS SOURCE,

    retention.retention_date     AS OBSERVATION_DATE WITH SYNONYMS=('date','day'),
    retention.cohort_grain       AS GRAIN          WITH SYNONYMS=('dimension','breakdown','cohort type')
      COMMENT='OVERALL, CUSTOMER_SEGMENT, ACQUISITION_CHANNEL or TENURE_BAND.',
    retention.cohort             AS DIM_VALUE      WITH SYNONYMS=('cohort','segment','customer cohort','channel','tenure band'),

    deposits.deposit_date        AS BALANCE_DATE   WITH SYNONYMS=('date','day','as of'),
    deposits.is_post_break       AS IS_POST_BREAK  WITH SYNONYMS=('after the behaviour change'),

    decisions.decision_id        AS DECISION_ID,
    decisions.decision_ref       AS DECISION_REF   WITH SYNONYMS=('decision reference','paper reference'),
    decisions.decision_title     AS TITLE          WITH SYNONYMS=('decision title'),
    decisions.committee          AS COMMITTEE,
    decisions.decision_date      AS DECISION_DATE  WITH SYNONYMS=('when was it decided'),
    decisions.governance_status   AS GOVERNANCE_STATUS WITH SYNONYMS=('decision status','reassessment required')
      COMMENT='APPROVED, REASSESSMENT_REQUIRED, REAFFIRMED or SUPERSEDED.',
    decisions.decision_rationale AS RATIONALE      WITH SYNONYMS=('why was it decided','basis'),
    decisions.decision_materiality AS MATERIALITY,

    decision_deps.reliance_strength AS RELIANCE_STRENGTH WITH SYNONYMS=('how strongly it relied','reliance')
      COMMENT='MATERIAL, SUPPORTING or CONTEXTUAL.',

    reassessments.reassessment_status AS STATUS    WITH SYNONYMS=('reassessment state'),
    reassessments.trigger_reason      AS TRIGGER_REASON WITH SYNONYMS=('why was it reopened'),
    reassessments.impact_summary      AS IMPACT_SUMMARY WITH SYNONYMS=('impact','consequence'),
    reassessments.recommendation      AS AI_RECOMMENDATION WITH SYNONYMS=('recommendation','suggested action'),

    scenarios.scenario_type      AS SCENARIO_TYPE  WITH SYNONYMS=('scenario kind')
      COMMENT='BASELINE, OBSERVED_BEHAVIOUR, PROPOSED_ASSUMPTION or USER_DEFINED.',
    scenarios.scenario_name      AS NAME           WITH SYNONYMS=('scenario name'),

    scenario_results.result_metric_id   AS METRIC_ID WITH SYNONYMS=('metric code'),
    scenario_results.result_metric_name AS METRIC_NAME WITH SYNONYMS=('metric'),
    scenario_results.unit               AS UNIT,
    scenario_results.formula            AS FORMULA  WITH SYNONYMS=('how it is calculated','calculation'),
    scenario_results.breaches_limit     AS BREACHES_LIMIT WITH SYNONYMS=('limit breach','above limit'),

    models.model_id   AS MODEL_ID,
    models.model_name AS NAME WITH SYNONYMS=('model name'),
    models.model_tier AS TIER WITH SYNONYMS=('model tier'),

    metrics.metric_id   AS METRIC_ID,
    metrics.metric_name AS NAME WITH SYNONYMS=('metric name'),

    dependencies.source_object      AS SOURCE_OBJECT WITH SYNONYMS=('upstream object','from'),
    dependencies.source_type        AS SOURCE_TYPE,
    dependencies.target_object      AS TARGET_OBJECT WITH SYNONYMS=('downstream object','to','dependent object'),
    dependencies.target_type        AS TARGET_TYPE   WITH SYNONYMS=('dependency kind')
      COMMENT='MODEL, METRIC, REPORT, DECISION, CALCULATION or POLICY.',
    dependencies.relationship_type  AS RELATIONSHIP_TYPE,
    dependencies.dependency_materiality AS MATERIALITY WITH SYNONYMS=('dependency importance')
  )

  METRICS (
    assumptions.assumption_count      AS COUNT(assumptions.ASSUMPTION_ID)
      WITH SYNONYMS=('number of assumptions','how many assumptions'),
    assumptions.breached_count        AS COUNT_IF(assumptions.STATUS = 'BREACHED')
      WITH SYNONYMS=('breached assumptions','how many breached'),
    assumptions.challenged_count      AS COUNT_IF(assumptions.STATUS = 'CHALLENGED')
      WITH SYNONYMS=('challenged assumptions'),
    assumptions.valid_count           AS COUNT_IF(assumptions.STATUS = 'VALID')
      WITH SYNONYMS=('valid assumptions','healthy assumptions'),
    assumptions.critical_breached_count AS COUNT_IF(assumptions.STATUS='BREACHED' AND assumptions.MATERIALITY='CRITICAL')
      WITH SYNONYMS=('critical exposure','critical breached assumptions'),

    retention.avg_retention_rate      AS AVG(retention.RETENTION_RATE)
      WITH SYNONYMS=('average retention','mean retention rate'),
    retention.min_retention_rate      AS MIN(retention.RETENTION_RATE)
      WITH SYNONYMS=('lowest retention','worst retention'),
    retention.latest_accounts         AS SUM(retention.ACCOUNTS)
      WITH SYNONYMS=('account count'),
    retention.total_balance_change     AS SUM(retention.BALANCE_CHANGE)
      WITH SYNONYMS=('balance movement','how much balance was lost'),

    deposits.total_deposit_balance     AS SUM(deposits.TOTAL_DEPOSITS)
      WITH SYNONYMS=('total deposits'),
    deposits.governed_stable_balance   AS SUM(deposits.GOVERNED_STABLE_DEPOSITS)
      WITH SYNONYMS=('stable deposits','governed deposits','incumbent stable deposits'),
    deposits.promotional_balance       AS SUM(deposits.PROMOTIONAL_DEPOSITS)
      WITH SYNONYMS=('promotional deposits','new promotional money'),

    challenges.avg_confidence          AS AVG(challenges.CONFIDENCE)
      WITH SYNONYMS=('average confidence'),
    challenges.worst_deviation_pct     AS MIN(challenges.DEVIATION_PCT)
      WITH SYNONYMS=('largest shortfall'),

    decisions.decision_count           AS COUNT(decisions.DECISION_ID)
      WITH SYNONYMS=('number of decisions'),
    decisions.reassessment_required_count AS COUNT_IF(decisions.GOVERNANCE_STATUS = 'REASSESSMENT_REQUIRED')
      WITH SYNONYMS=('decisions requiring reassessment','reopened decisions','affected decisions'),

    reassessments.open_reassessment_count AS COUNT_IF(reassessments.STATUS IN ('OPEN','IN_REVIEW'))
      WITH SYNONYMS=('open reassessments','unresolved reassessments'),

    scenario_results.metric_result      AS AVG(scenario_results.METRIC_VALUE)
      WITH SYNONYMS=('scenario metric value','simulated value','LCR value'),

    dependencies.dependency_count       AS COUNT(dependencies.DEPENDENCY_ID)
      WITH SYNONYMS=('number of dependencies','blast radius size','how many things depend on it')
  )

  COMMENT = 'PremiseFlow governed semantic layer. Continuous Assumption Intelligence over a fully synthetic bank. Risk calculations are illustrative simplified POC formulations, not regulatory calculations.';

-- ---------------------------------------------------------------------------
-- Verified queries. Semantic view DDL has no verified-query clause, so the
-- curated question/SQL pairs are registered here and surfaced by the app and
-- the agent instructions. See ARCHITECTURE.md.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS AI.VERIFIED_QUERIES (
  VQ_ID STRING, QUESTION STRING, SQL_TEXT STRING, VERIFIED_BY STRING,
  VERIFIED_AT TIMESTAMP_NTZ, NOTES STRING
);
DELETE FROM AI.VERIFIED_QUERIES;
INSERT INTO AI.VERIFIED_QUERIES (VQ_ID, QUESTION, SQL_TEXT, VERIFIED_BY, VERIFIED_AT, NOTES)
SELECT column1, column2, column3, 'PremiseFlow build', CURRENT_TIMESTAMP(), column4
FROM VALUES
 ('VQ-01','What is the current health of all assumptions?',
  'SELECT ASSUMPTION_ID, NAME, DOMAIN, MATERIALITY, STATUS, EXPECTED_VALUE, LATEST_OBSERVED_VALUE, DEVIATION_PCT, OWNER_ROLE FROM CORE.V_ASSUMPTION_CURRENT ORDER BY CASE STATUS WHEN ''BREACHED'' THEN 1 WHEN ''CHALLENGED'' THEN 2 WHEN ''WATCH'' THEN 3 ELSE 4 END',
  'Registry overview for the executive radar.'),
 ('VQ-02','Which assumptions are breached?',
  'SELECT ASSUMPTION_ID, NAME, MATERIALITY, EXPECTED_VALUE, LATEST_OBSERVED_VALUE, OBSERVED_PERSISTENCE_DAYS FROM CORE.V_ASSUMPTION_CURRENT WHERE STATUS=''BREACHED''',
  'Breach list.'),
 ('VQ-03','What is incumbent retail salary deposit retention by cohort?',
  'SELECT GRAIN, DIM_VALUE, RETENTION_RATE, BALANCE_CHANGE, ACCOUNTS FROM CORE.DT_RETENTION_DAILY WHERE OBSERVATION_DATE=(SELECT MAX(OBSERVATION_DATE) FROM CORE.DT_RETENTION_DAILY) ORDER BY RETENTION_RATE',
  'Cohort decomposition identifying the driver of the breach.'),
 ('VQ-04','What depends on assumption A-DEP-001?',
  'SELECT DISTINCT TARGET_OBJECT, TARGET_TYPE, RELATIONSHIP_TYPE, MATERIALITY, DEPTH FROM CORE.V_BLAST_RADIUS WHERE ROOT_OBJECT=''A-DEP-001'' ORDER BY DEPTH, TARGET_TYPE',
  'Downstream blast radius.'),
 ('VQ-05','Which decisions require reassessment and why?',
  'SELECT DECISION_REF, TITLE, GOVERNANCE_STATUS, ASSUMPTION_ID, RELIANCE_STRENGTH, IMPACT_SUMMARY FROM CORE.V_AFFECTED_DECISIONS WHERE GOVERNANCE_STATUS=''REASSESSMENT_REQUIRED''',
  'Affected governed decisions.'),
 ('VQ-06','Compare the approved premise and observed reality scenarios.',
  'SELECT SCENARIO_TYPE, SCENARIO_NAME, RETENTION_INPUT, METRIC_ID, METRIC_NAME, METRIC_VALUE, UNIT, INTERNAL_LIMIT, REGULATORY_MIN, BREACHES_LIMIT FROM CORE.V_SCENARIO_COMPARISON WHERE ASSUMPTION_ID=''A-DEP-001'' ORDER BY METRIC_ID, SCENARIO_TYPE',
  'Scenario impact comparison.'),
 ('VQ-07','Did total deposits grow while incumbent stable deposits fell?',
  'SELECT BALANCE_DATE, TOTAL_DEPOSITS, GOVERNED_STABLE_DEPOSITS, PROMOTIONAL_DEPOSITS, TOTAL_DEPOSIT_GROWTH, GOVERNED_DEPOSIT_GROWTH, PROMOTIONAL_FUNDING_SHARE FROM CORE.V_DEPOSIT_MASKING ORDER BY BALANCE_DATE',
  'The masking effect: aggregate health versus cohort deterioration.'),
 ('VQ-08','Which source documents mention A-DEP-001?',
  'SELECT DISTINCT DOC_TITLE, DOC_REFERENCE, DOC_CATEGORY, SECTION, RELATIVE_PATH FROM AI.V_ASSUMPTION_DOCUMENTS WHERE ASSUMPTION_ID=''A-DEP-001''',
  'Document provenance.');

SELECT 'semantic layer ready' AS STATUS,
  (SELECT COUNT(*) FROM AI.VERIFIED_QUERIES) AS VERIFIED_QUERIES;
