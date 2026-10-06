# MCP Setup for PremiseFlow External Actions

> **No secrets appear in this repository or in Snowflake.** Nothing below asks you
> to commit a token.

## Current state

No MCP servers are configured in this workspace. PremiseFlow therefore does **not**
attempt a live external call. Instead every external action is queued:

```sql
SELECT ACTION_ID, TARGET_SYSTEM, ACTION_TYPE, STATUS, DEDUPE_KEY, CREATED_AT
FROM PREMISEFLOW.CORE.ACTION_OUTBOX ORDER BY CREATED_AT DESC;

SELECT TARGET_SYSTEM, ACTION_TYPE, OBJECT_ID, STATUS, NOTE
FROM PREMISEFLOW.AUDIT.INTEGRATION_ACTIONS ORDER BY CREATED_AT DESC;
```

Currently queued: **2 Jira `CREATE_ISSUE` and 2 Slack `POST_ALERT`**, one pair per
open reassessment, with status `PENDING` / `QUEUED_OUTBOX`.

The outbox is idempotent on `DEDUPE_KEY` (`jira:<reassessment id>`,
`slack:<reassessment id>`), so repeated testing cannot spam a real target system.

## The queued Jira payload

```sql
SELECT PAYLOAD FROM PREMISEFLOW.CORE.ACTION_OUTBOX
WHERE TARGET_SYSTEM='JIRA' ORDER BY CREATED_AT DESC LIMIT 1;
```

Contains: `summary`, `assumption_id`, `assumption_name`, `approved_value`,
`observed_value`, `approved_version_id`, `affected_decision`,
`affected_decision_title`, `lcr_approved_premise_pct`,
`lcr_reality_adjusted_pct`, `funding_gap_usd_m`, `impact_summary`,
`evidence_reference` (the breach id), `premiseflow_reassessment_id`, `issue_type`,
`priority`, `labels`, and a synthetic-data note.

Title format:

```
[PremiseFlow] Critical assumption A-DEP-001 requires reassessment
```

---

## Wiring a real Jira MCP server

### 1. Create a Jira API token

In Jira: **Account settings → Security → API tokens → Create API token.** Keep it
out of the repository.

### 2. Store the credential locally

Use Cortex Code's secret store so the value never appears in a prompt, a file or a
tool call:

```
cortex secret store jira_api_token --from-file <path to a file containing only the token>
cortex secret store jira_email     --from-file <path to a file containing only your Jira email>
```

### 3. Register the MCP server

Add a Jira MCP server to your Cortex Code MCP configuration, referencing the
stored secrets by name rather than by value. A typical shape:

```json
{
  "mcpServers": {
    "jira": {
      "command": "npx",
      "args": ["-y", "<your-chosen-jira-mcp-package>"],
      "env": {
        "JIRA_BASE_URL": "https://<your-domain>.atlassian.net",
        "JIRA_EMAIL":     "${secret:jira_email}",
        "JIRA_API_TOKEN": "${secret:jira_api_token}",
        "JIRA_PROJECT_KEY": "<PROJECT>"
      }
    }
  }
}
```

Consult your MCP client's documentation for the exact configuration file location
and secret-reference syntax; do not paste the token inline.

### 4. Test connectivity with a read first

Before any write, confirm the connection with a safe read — list projects, or fetch
one existing issue. Only then attempt a create.

### 5. Deliver the queued actions

Read the pending payload, create the issue through the MCP tool, then record the
external id so the outbox is not re-sent:

```sql
-- 1. read
SELECT ACTION_ID, PAYLOAD FROM PREMISEFLOW.CORE.ACTION_OUTBOX
WHERE TARGET_SYSTEM='JIRA' AND STATUS='PENDING';

-- 2. create the issue via the Jira MCP tool, then:
CALL PREMISEFLOW.APP.MARK_OUTBOX_SENT(
  '<ACTION_ID>', '<JIRA-1234>', 'https://<your-domain>.atlassian.net/browse/JIRA-1234');
```

`MARK_OUTBOX_SENT` sets the outbox row to `SENT` and records `EXTERNAL_ID` and
`EXTERNAL_URL` in `AUDIT.INTEGRATION_ACTIONS`.

### 6. Avoid duplicates while testing

Create **one** controlled test issue. The dedupe key prevents a second queued
action for the same reassessment, but repeated manual creates are on you. To
re-test cleanly, reset the demo first:

```sql
CALL PREMISEFLOW.APP.RESET_DEMO();   -- clears PENDING outbox rows
```

---

## Wiring Slack or Teams (optional)

Same pattern. Store an incoming-webhook URL or bot token as a secret, register the
MCP server, read the queued `POST_ALERT` payload:

```sql
SELECT ACTION_ID, PAYLOAD FROM PREMISEFLOW.CORE.ACTION_OUTBOX
WHERE TARGET_SYSTEM='SLACK' AND STATUS='PENDING';
```

The payload carries `channel` (default `#treasury-risk-alerts`), `text` (already
formatted with the assumption, the affected decision and the LCR movement) and
`reassessment_id`. Send it, then call `APP.MARK_OUTBOX_SENT`.

---

## Alternative: deliver from inside Snowflake, no MCP

If you would rather not use MCP at all, the same payload can be delivered
server-side with a notification integration and an external access integration.
This requires account-level privileges and a network rule for your Jira or Slack
host, so it is documented rather than deployed here:

1. `CREATE NETWORK RULE` for the target host on port 443.
2. `CREATE SECRET` of type `GENERIC_STRING` holding the token.
3. `CREATE EXTERNAL ACCESS INTEGRATION` binding the rule and the secret.
4. A Python stored procedure with `EXTERNAL_ACCESS_INTEGRATIONS=(...)` that reads
   `CORE.ACTION_OUTBOX` where `STATUS='PENDING'`, POSTs each payload, and calls
   `APP.MARK_OUTBOX_SENT`.

Secrets live in Snowflake's secret objects, never in source.

---

## Why the outbox exists at all

An assumption breach that reopens a committee decision has to reach a human
workflow, and the platform should not lose that action because a connector is
missing. The outbox makes the intent durable and auditable: you can see exactly
what *would* have been raised, when, and on what evidence, and you can replay it
once a connector exists.

It also keeps the test suite honest. Tests J1–J4 verify the outbox behaviour and
pass. Tests J5–J6 — live Jira and live Slack delivery — are reported as
`PASS_FEATURE_UNAVAILABLE` and are explicitly **not** counted as passes of the live
integration.
