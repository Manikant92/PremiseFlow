-- PremiseFlow :: 12_cortex_search.sql
-- Document ingestion + searchable knowledge base over the synthetic governance
-- corpus. Ingestion attempts AI_PARSE_DOCUMENT first and falls back to direct
-- text read, so the pipeline works regardless of parser availability for a
-- given file type. The parse route actually used is recorded per document.

USE DATABASE PREMISEFLOW;
USE SCHEMA AI;

CREATE TABLE IF NOT EXISTS AI.DOCUMENTS (
  DOCUMENT_ID    STRING,
  RELATIVE_PATH  STRING,
  DOC_CATEGORY   STRING,
  DOC_TITLE      STRING,
  DOC_REFERENCE  STRING,
  CONTENT        STRING,
  PARSE_METHOD   STRING,
  SIZE_BYTES     NUMBER(18,0),
  INGESTED_AT    TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS AI.DOCUMENT_CHUNKS (
  CHUNK_ID       STRING,
  DOCUMENT_ID    STRING,
  RELATIVE_PATH  STRING,
  DOC_CATEGORY   STRING,
  DOC_TITLE      STRING,
  DOC_REFERENCE  STRING,
  SECTION        STRING,
  CHUNK_INDEX    NUMBER(9,0),
  CHUNK_TEXT     STRING,
  MENTIONS_ASSUMPTIONS ARRAY,
  INGESTED_AT    TIMESTAMP_NTZ
);

CREATE OR REPLACE PROCEDURE AI.INGEST_DOCUMENTS()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python')
HANDLER='run'
AS
$$
import json, re, uuid
from snowflake.snowpark.files import SnowflakeFile

STAGE = '@PREMISEFLOW.AI.DOCS'
ASSUMPTION_PATTERN = re.compile(r'\bA-(?:DEP|LIQ|CRD|IRR|MKT|CAP)-\d{3}\b')

CATEGORY = {
    'liquidity_policy': 'POLICY',
    'model_methodology': 'MODEL_METHODOLOGY',
    'alco': 'COMMITTEE_DECISION',
    'validation': 'VALIDATION',
}

def lit(v):
    if v is None: return 'NULL'
    if isinstance(v, bool): return 'TRUE' if v else 'FALSE'
    if isinstance(v, (int, float)): return repr(v)
    # Escape backslashes BEFORE quotes: Snowflake processes backslash escapes inside
    # single-quoted literals, so LLM-generated text containing a backslash would
    # otherwise corrupt the statement.
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"

def parse_with_cortex(session, path):
    """Preferred route: Snowflake's document parser."""
    row = session.sql(f"""
        SELECT TO_VARCHAR(
                 AI_PARSE_DOCUMENT(TO_FILE('{STAGE}', '{path}'), {{'mode':'LAYOUT'}}):content
               ) AS C""").collect()
    txt = row[0]['C'] if row else None
    if not txt or len(txt.strip()) < 50:
        raise ValueError('parser returned insufficient content')
    return txt

def parse_direct(session, path):
    """Fallback route: read the staged file as text."""
    with SnowflakeFile.open(f"{STAGE}/{path}", 'r', require_scoped_url=False) as f:
        return f.read()

def title_and_ref(text, path):
    title, ref = None, None
    for line in text.splitlines():
        s = line.strip()
        if title is None and s.startswith('# '):
            title = s[2:].strip()
        m = re.search(r'\*\*(?:Document reference|Report reference|Model reference|Reference|Assumption reference):\*\*\s*(\S+)', s)
        if m and ref is None:
            ref = m.group(1)
    return (title or path.split('/')[-1]), ref

def chunk(text, target=1300, overlap=180):
    """Split on markdown headings, then pack to a target size with overlap so a
    retrieved chunk almost always carries its own heading context."""
    blocks, cur, cur_head = [], [], 'Preamble'
    for line in text.splitlines():
        if re.match(r'^#{1,3}\s+\S', line):
            if cur:
                blocks.append((cur_head, '\n'.join(cur).strip()))
                cur = []
            cur_head = line.lstrip('#').strip()
        cur.append(line)
    if cur:
        blocks.append((cur_head, '\n'.join(cur).strip()))

    out = []
    for head, body in blocks:
        if not body:
            continue
        if len(body) <= target:
            out.append((head, body))
            continue
        start = 0
        while start < len(body):
            piece = body[start:start + target]
            out.append((head, piece.strip()))
            if start + target >= len(body):
                break
            start += target - overlap
    return out

def run(session):
    files = session.sql(f"SELECT RELATIVE_PATH, SIZE FROM DIRECTORY({STAGE}) ORDER BY 1").collect()
    session.sql("DELETE FROM AI.DOCUMENTS").collect()
    session.sql("DELETE FROM AI.DOCUMENT_CHUNKS").collect()

    report = []
    for f in files:
        path = f['RELATIVE_PATH']
        size = int(f['SIZE'] or 0)
        method = 'AI_PARSE_DOCUMENT'
        try:
            text = parse_with_cortex(session, path)
        except Exception as e:
            method = 'DIRECT_TEXT_FALLBACK'
            try:
                text = parse_direct(session, path)
            except Exception as e2:
                report.append({'path': path, 'status': 'FAILED', 'error': str(e2)[:200]})
                continue

        folder = path.split('/')[0] if '/' in path else 'other'
        category = CATEGORY.get(folder, 'OTHER')
        title, ref = title_and_ref(text, path)
        doc_id = 'DOC-' + uuid.uuid4().hex[:12]

        session.sql(f"""INSERT INTO AI.DOCUMENTS
            (DOCUMENT_ID, RELATIVE_PATH, DOC_CATEGORY, DOC_TITLE, DOC_REFERENCE,
             CONTENT, PARSE_METHOD, SIZE_BYTES, INGESTED_AT)
            SELECT {lit(doc_id)},{lit(path)},{lit(category)},{lit(title)},{lit(ref)},
                   {lit(text)},{lit(method)},{lit(size)},CURRENT_TIMESTAMP()""").collect()

        pieces = chunk(text)
        for i, (head, body) in enumerate(pieces):
            mentions = sorted(set(ASSUMPTION_PATTERN.findall(body)))
            cid = f"{doc_id}-C{i:03d}"
            session.sql(f"""INSERT INTO AI.DOCUMENT_CHUNKS
                (CHUNK_ID, DOCUMENT_ID, RELATIVE_PATH, DOC_CATEGORY, DOC_TITLE, DOC_REFERENCE,
                 SECTION, CHUNK_INDEX, CHUNK_TEXT, MENTIONS_ASSUMPTIONS, INGESTED_AT)
                SELECT {lit(cid)},{lit(doc_id)},{lit(path)},{lit(category)},{lit(title)},{lit(ref)},
                       {lit(head)},{lit(i)},{lit(body)},
                       TRY_PARSE_JSON({lit(json.dumps(mentions))})::ARRAY,CURRENT_TIMESTAMP()""").collect()

        report.append({'path': path, 'status': 'OK', 'method': method,
                       'title': title, 'reference': ref, 'chunks': len(pieces)})

    return {'documents': len(report), 'detail': report,
            'total_chunks': session.sql("SELECT COUNT(*) C FROM AI.DOCUMENT_CHUNKS").collect()[0]['C']}
$$;

CALL AI.INGEST_DOCUMENTS();

-- ---------------------------------------------------------------------------
-- Searchable knowledge base
-- ---------------------------------------------------------------------------
CREATE OR REPLACE CORTEX SEARCH SERVICE AI.PREMISEFLOW_DOC_SEARCH
  ON CHUNK_TEXT
  ATTRIBUTES DOC_CATEGORY, DOC_TITLE, DOC_REFERENCE, RELATIVE_PATH, SECTION, CHUNK_ID
  WAREHOUSE = PREMISEFLOW_WH
  TARGET_LAG = '1 hour'
  COMMENT = 'Synthetic governance corpus: liquidity policy, model methodology, ALCO packs, validation reports, assumption approval records.'
AS
SELECT CHUNK_ID, CHUNK_TEXT, DOC_CATEGORY, DOC_TITLE, DOC_REFERENCE, RELATIVE_PATH, SECTION
FROM AI.DOCUMENT_CHUNKS;

-- Convenience view linking assumptions to the documents that mention them.
CREATE OR REPLACE VIEW AI.V_ASSUMPTION_DOCUMENTS AS
SELECT DISTINCT
  f.value::STRING AS ASSUMPTION_ID,
  c.DOCUMENT_ID, c.RELATIVE_PATH, c.DOC_CATEGORY, c.DOC_TITLE, c.DOC_REFERENCE,
  c.SECTION, c.CHUNK_ID, c.CHUNK_TEXT
FROM AI.DOCUMENT_CHUNKS c,
     LATERAL FLATTEN(input => c.MENTIONS_ASSUMPTIONS) f;

SELECT 'knowledge base ready' AS STATUS,
  (SELECT COUNT(*) FROM AI.DOCUMENTS) AS DOCUMENTS,
  (SELECT COUNT(*) FROM AI.DOCUMENT_CHUNKS) AS CHUNKS,
  (SELECT COUNT(DISTINCT PARSE_METHOD) FROM AI.DOCUMENTS) AS PARSE_METHODS,
  (SELECT COUNT(*) FROM AI.V_ASSUMPTION_DOCUMENTS WHERE ASSUMPTION_ID='A-DEP-001') AS ADEP001_MENTIONS;
