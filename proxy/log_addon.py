"""mitmproxy addon: dump each /v1/* request+response to a JSONL file.

Captures exactly what opencode SENDS (full prompt: system+messages+tools)
and what it RECEIVES (final JSON, or the reassembled SSE stream when
stream=true). One JSON object per line in /logs/traffic.jsonl.
"""
import json
import time

from mitmproxy import http

LOG = "/logs/traffic.jsonl"


def _write(obj):
    with open(LOG, "a") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def response(flow: http.HTTPFlow):
    req = flow.request
    resp = flow.response
    if "/v1/" not in req.path:
        return
    try:
        req_body = req.get_text()
        try:
            req_json = json.loads(req_body)
        except Exception:
            req_json = req_body

        resp_body = resp.get_text()  # for SSE this is the concatenated event stream
        try:
            resp_json = json.loads(resp_body)
        except Exception:
            resp_json = resp_body  # streamed SSE stays as raw text

        _write({
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "path": req.path,
            "status": resp.status_code,
            "duration_ms": int((flow.response.timestamp_end - flow.request.timestamp_start) * 1000),
            "request": req_json,
            "response": resp_json,
        })
    except Exception as e:  # never break the proxy on a logging error
        _write({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "path": req.path, "error": str(e)})
