-- PremiseFlow :: 10d_governance_actors.sql
-- Authorised human governance actors.
--
-- The original actor guard was a denylist of suspicious identifiers. That is the
-- wrong control: any model or service name not yet on the list passes, and the
-- list can never be complete (the automated test caught 'claude-sonnet-4-5'
-- being accepted as a human). Replaced with an explicit allowlist registry,
-- which is how a real governance system authorises an approver, with the
-- denylist retained only as defence in depth.

USE DATABASE PREMISEFLOW;
USE SCHEMA CORE;

CREATE TABLE IF NOT EXISTS CORE.GOVERNANCE_ACTORS (
  ACTOR_ID             STRING NOT NULL,
  FULL_NAME            STRING,
  ACTOR_ROLE           STRING,
  CAN_CONFIRM_BREACH   BOOLEAN DEFAULT FALSE,
  CAN_APPROVE_VERSION  BOOLEAN DEFAULT FALSE,
  ACTIVE               BOOLEAN DEFAULT TRUE,
  REGISTERED_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  NOTE                 STRING
);

MERGE INTO CORE.GOVERNANCE_ACTORS t
USING (
  SELECT * FROM VALUES
    ('manikant.kella','Manikant Kella','Head of Treasury Risk', TRUE, TRUE, TRUE,
     'Primary demo governance owner.'),
    ('a.rahman','A. Rahman (synthetic)','ALCO Chair', TRUE, TRUE, TRUE,
     'Synthetic persona. Original approver of A-DEP-001 v1.'),
    ('s.iyer','S. Iyer (synthetic)','Head of ALM', TRUE, TRUE, TRUE,
     'Synthetic persona.'),
    ('d.okafor','D. Okafor (synthetic)','Treasurer', TRUE, TRUE, TRUE,
     'Synthetic persona.'),
    ('m.chen','M. Chen (synthetic)','Deposit Analytics Lead', TRUE, FALSE, TRUE,
     'Synthetic persona. May confirm a breach but not approve a revised assumption.')
  AS v(ACTOR_ID, FULL_NAME, ACTOR_ROLE, CAN_CONFIRM_BREACH, CAN_APPROVE_VERSION, ACTIVE, NOTE)
) s ON t.ACTOR_ID = s.ACTOR_ID
WHEN MATCHED THEN UPDATE SET
  t.FULL_NAME=s.FULL_NAME, t.ACTOR_ROLE=s.ACTOR_ROLE,
  t.CAN_CONFIRM_BREACH=s.CAN_CONFIRM_BREACH, t.CAN_APPROVE_VERSION=s.CAN_APPROVE_VERSION,
  t.ACTIVE=s.ACTIVE, t.NOTE=s.NOTE
WHEN NOT MATCHED THEN INSERT
  (ACTOR_ID, FULL_NAME, ACTOR_ROLE, CAN_CONFIRM_BREACH, CAN_APPROVE_VERSION, ACTIVE, NOTE)
  VALUES (s.ACTOR_ID, s.FULL_NAME, s.ACTOR_ROLE, s.CAN_CONFIRM_BREACH, s.CAN_APPROVE_VERSION,
          s.ACTIVE, s.NOTE);

-- Allowlist first, denylist second. An identifier must be a registered active
-- human AND must not look like an automated actor.
CREATE OR REPLACE FUNCTION APP.IS_HUMAN_ACTOR(ACTOR_TYPE STRING, ACTOR_ID STRING)
RETURNS BOOLEAN
LANGUAGE SQL
AS
$$
  UPPER(NVL(ACTOR_TYPE,'')) = 'HUMAN'
  AND EXISTS (
    SELECT 1 FROM PREMISEFLOW.CORE.GOVERNANCE_ACTORS g
    WHERE LOWER(g.ACTOR_ID) = LOWER(NVL(ACTOR_ID,'')) AND g.ACTIVE
  )
  AND NOT (
       UPPER(NVL(ACTOR_ID,'')) LIKE '%AGENT%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%CORTEX%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%CHALLENGER%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%ENGINE%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%SYSTEM%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%TASK%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%BOT%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%LLM%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%MODEL%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%CLAUDE%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%GPT%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%LLAMA%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%MISTRAL%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%GEMINI%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%SONNET%'
    OR UPPER(NVL(ACTOR_ID,'')) LIKE '%ARCTIC%'
  )
$$;

CREATE OR REPLACE VIEW CORE.V_GOVERNANCE_ACTORS AS
SELECT ACTOR_ID, FULL_NAME, ACTOR_ROLE, CAN_CONFIRM_BREACH, CAN_APPROVE_VERSION, ACTIVE, NOTE
FROM CORE.GOVERNANCE_ACTORS WHERE ACTIVE ORDER BY ACTOR_ID;

GRANT SELECT ON TABLE CORE.GOVERNANCE_ACTORS TO ROLE PREMISEFLOW_VIEWER;
GRANT SELECT ON VIEW CORE.V_GOVERNANCE_ACTORS TO ROLE PREMISEFLOW_VIEWER;
GRANT USAGE ON FUNCTION APP.IS_HUMAN_ACTOR(STRING, STRING) TO ROLE PREMISEFLOW_VIEWER;

SELECT 'governance actor registry ready' AS STATUS,
  (SELECT COUNT(*) FROM CORE.GOVERNANCE_ACTORS WHERE ACTIVE) AS ACTIVE_ACTORS,
  APP.IS_HUMAN_ACTOR('HUMAN','manikant.kella')     AS HUMAN_ALLOWED,
  APP.IS_HUMAN_ACTOR('HUMAN','claude-sonnet-4-5')  AS MODEL_NAME_REJECTED_EXPECT_FALSE,
  APP.IS_HUMAN_ACTOR('AGENT','premiseflow_agent')  AS AGENT_REJECTED_EXPECT_FALSE,
  APP.IS_HUMAN_ACTOR('HUMAN','some.random.person') AS UNREGISTERED_REJECTED_EXPECT_FALSE;
