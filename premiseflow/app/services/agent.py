"""Cortex Agent client.

Agents are invoked over the Snowflake REST API. Inside Streamlit in Snowflake
that call is made with `_snowflake.send_snow_api_request`, which requires no
credentials. If the agent is unreachable (permissions, or running outside SiS),
the caller falls back to the server-side grounded Q&A procedure, which reads the
same two evidence sources.
"""
from __future__ import annotations

import json

AGENT_PATH = "/api/v2/databases/PREMISEFLOW/schemas/AI/agents/PREMISEFLOW_AGENT:run"


def agent_available() -> bool:
    try:
        import _snowflake  # noqa: F401
        return True
    except Exception:
        return False


def ask_agent(question: str, timeout_ms: int = 60000) -> dict:
    """Returns {'ok': bool, 'text': str, 'tools': [...], 'error': str|None}."""
    try:
        import _snowflake
    except Exception as e:
        return {"ok": False, "text": None, "tools": [], "error": f"_snowflake unavailable: {e}"}

    body = {"messages": [{"role": "user", "content": [{"type": "text", "text": question}]}]}
    try:
        resp = _snowflake.send_snow_api_request(
            "POST", AGENT_PATH, {}, {}, body, None, timeout_ms
        )
    except Exception as e:
        return {"ok": False, "text": None, "tools": [], "error": str(e)}

    status = resp.get("status")
    if status != 200:
        return {"ok": False, "text": None, "tools": [],
                "error": f"HTTP {status}: {str(resp.get('content'))[:600]}"}

    return _parse_agent_stream(resp.get("content"))


def _events(content) -> list[tuple[str, object]]:
    """Normalise the agent:run payload into (event_name, data) pairs.

    The endpoint streams server-sent events:
        event: response.text.delta   data: {"content_index":0,"text":"..."}
        event: response.text         data: {"content_index":0,"text":"<full>"}
        event: response.tool_use     data: {"name":"premiseflow_analyst",...}
        event: response              data: {"role":"assistant","content":[...]}
        event: error                 data: {"code":"...","message":"..."}
    Depending on runtime, send_snow_api_request hands this back either as the
    raw SSE text or as an already-parsed list of {"event":..,"data":..}.
    """
    def load(v):
        if isinstance(v, str):
            try:
                return json.loads(v)
            except ValueError:
                return v
        return v

    content = load(content)
    out: list[tuple[str, object]] = []
    if isinstance(content, list):
        for item in content:
            if isinstance(item, dict) and ("event" in item or "data" in item):
                out.append((str(item.get("event", "")), load(item.get("data"))))
            else:
                out.append(("", item))
        return out
    if isinstance(content, dict):
        return [("response", content)]
    if isinstance(content, str):
        event = ""
        for line in content.splitlines():
            line = line.strip()
            if line.startswith("event:"):
                event = line[6:].strip()
            elif line.startswith("data:"):
                payload = line[5:].strip()
                if payload and payload != "[DONE]":
                    out.append((event, load(payload)))
    return out


def _parse_agent_stream(content) -> dict:
    events = _events(content)
    final_text, full_texts, deltas, tools, errors = [], [], [], [], []

    for name, data in events:
        if not isinstance(data, dict):
            continue
        if name == "error" or ("code" in data and "message" in data and "text" not in data):
            errors.append(f"{data.get('code', '')} {data.get('message', '')}".strip())
        elif name == "response.text.delta":
            deltas.append(str(data.get("text", "")))
        elif name == "response.text":
            full_texts.append(str(data.get("text", "")))
        elif name == "response.tool_use" and data.get("name"):
            tools.append(str(data["name"]))
        elif name in ("response", "") and isinstance(data.get("content"), list):
            for block in data["content"]:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text" and block.get("text"):
                    final_text.append(block["text"])
                elif block.get("type") == "tool_use":
                    tu = block.get("tool_use") or block
                    if tu.get("name"):
                        tools.append(str(tu["name"]))

    # Prefer the final assembled message, then whole text events, then deltas.
    text = ("\n\n".join(final_text) or "\n\n".join(full_texts) or "".join(deltas)).strip()
    tools = list(dict.fromkeys(tools))

    if errors and not text:
        return {"ok": False, "text": None, "tools": tools,
                "error": "agent error: " + "; ".join(errors)}
    if not text:
        snippet = content if isinstance(content, str) else json.dumps(content, default=str)
        return {"ok": False, "text": None, "tools": tools,
                "error": f"agent returned no text content ({len(events)} events). "
                         f"Raw start: {str(snippet)[:400]}"}
    return {"ok": True, "text": text, "tools": tools, "error": None}
