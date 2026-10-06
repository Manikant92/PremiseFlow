-- PremiseFlow :: 01_database.sql
-- Idempotent foundation: warehouse, database, schemas, stages.
-- Synthetic data / illustrative risk calculations for hackathon demonstration.

CREATE WAREHOUSE IF NOT EXISTS PREMISEFLOW_WH
  WITH WAREHOUSE_SIZE='XSMALL'
       AUTO_SUSPEND=120
       AUTO_RESUME=TRUE
       INITIALLY_SUSPENDED=FALSE
       COMMENT='PremiseFlow POC compute';

CREATE DATABASE IF NOT EXISTS PREMISEFLOW
  COMMENT='PremiseFlow - Continuous Assumption Intelligence (fully synthetic POC)';

CREATE SCHEMA IF NOT EXISTS PREMISEFLOW.RAW   COMMENT='Synthetic source-system landing zone';
CREATE SCHEMA IF NOT EXISTS PREMISEFLOW.CORE  COMMENT='Governed assumption model';
CREATE SCHEMA IF NOT EXISTS PREMISEFLOW.AI    COMMENT='Cortex Search / Agent / semantic assets';
CREATE SCHEMA IF NOT EXISTS PREMISEFLOW.APP   COMMENT='Application procedures + Streamlit';
CREATE SCHEMA IF NOT EXISTS PREMISEFLOW.AUDIT COMMENT='Immutable audit + agent run history';
CREATE SCHEMA IF NOT EXISTS PREMISEFLOW.TEST  COMMENT='Automated test harness';

CREATE STAGE IF NOT EXISTS PREMISEFLOW.AI.DOCS
  DIRECTORY=(ENABLE=TRUE) ENCRYPTION=(TYPE='SNOWFLAKE_SSE')
  COMMENT='Synthetic governance documents';

CREATE STAGE IF NOT EXISTS PREMISEFLOW.APP.APP_STAGE
  DIRECTORY=(ENABLE=TRUE) ENCRYPTION=(TYPE='SNOWFLAKE_SSE')
  COMMENT='Streamlit app + SQL deployment artifacts';

-- Generic text writer used to materialise documents / app files onto stages
-- without requiring a local CLI.
CREATE OR REPLACE PROCEDURE PREMISEFLOW.APP.WRITE_FILE(STAGE_PATH STRING, FILE_NAME STRING, CONTENT STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import io
def run(session, stage_path, file_name, content):
    data = io.BytesIO(content.encode('utf-8'))
    session.file.put_stream(data, f"{stage_path}/{file_name}", auto_compress=False, overwrite=True)
    return f"wrote {stage_path}/{file_name} ({len(content)} bytes)"
$$;

SELECT 'PremiseFlow foundation ready' AS STATUS;
