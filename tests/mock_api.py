"""Tiny SecAI API mock used by the ``test-github-action`` workflow.

Implements just enough of the public surface for the GitHub Action's
helper scripts to drive an end-to-end happy path without real
credentials or LLM cost:

- ``GET  /healthz``            → ok
- ``GET  /repositories``       → list with one fixture repo
- ``POST /repositories``       → create (echoes a fixed UUID)
- ``POST /scans``              → queue, returns succeeded immediately
- ``GET  /scans/{id}``         → terminal `succeeded` payload
- ``GET  /scans/{id}/findings``→ small fixture list, supports min_severity
- ``GET  /scans/{id}/export``  → minimal but valid SARIF

The mock is deliberately stateless and naive — its only job is to make
the scripts under ``integrations/github-action/scripts`` exercise their
real curl + parsing logic against a SecAI-shaped surface.
"""

from __future__ import annotations

import os
from uuid import UUID

from flask import Flask, Response, jsonify, request

app = Flask(__name__)

FIXTURE_REPO_ID = UUID("11111111-1111-1111-1111-111111111111")
FIXTURE_SCAN_ID = UUID("22222222-2222-2222-2222-222222222222")
FIXTURE_FINDING = {
    "id": "33333333-3333-3333-3333-333333333333",
    "severity": "medium",
    "kind": "sast",
    "title": "Mock finding",
    "description": {"summary": "demo only"},
    "evidence": {"file": "src/app.py", "start_line": 12},
    "location": {"file": "src/app.py", "line_start": 12},
    "cwe": "CWE-89",
    "remediation": {"fix": "use parameterised queries"},
}


def _auth_ok() -> bool:
    header = request.headers.get("Authorization", "")
    return header.startswith("Bearer sok_")


@app.get("/healthz")
def healthz() -> Response:
    return jsonify({"status": "ok"})


@app.get("/repositories")
def list_repositories() -> Response:
    if not _auth_ok():
        return Response(status=401)
    return jsonify(
        [
            {
                "id": str(FIXTURE_REPO_ID),
                "source_kind": "git",
                "git_url": "https://github.com/own2pwn/secai-mock",
                "git_ref": None,
                "blob_key": None,
                "schedule_cron": None,
            }
        ]
    )


@app.post("/repositories")
def create_repository() -> tuple[Response, int]:
    if not _auth_ok():
        return Response(status=401), 401
    payload = request.get_json(silent=True) or {}
    return (
        jsonify(
            {
                "id": str(FIXTURE_REPO_ID),
                "source_kind": "git",
                "git_url": payload.get("git_url"),
                "git_ref": payload.get("git_ref"),
                "blob_key": payload.get("blob_key"),
                "schedule_cron": None,
            }
        ),
        201,
    )


@app.post("/scans")
def create_scan() -> tuple[Response, int]:
    if not _auth_ok():
        return Response(status=401), 401
    return jsonify(_terminal_scan_payload()), 201


@app.get("/scans/<uuid:scan_id>")
def get_scan(scan_id: UUID) -> Response:
    if not _auth_ok():
        return Response(status=401)
    return jsonify(_terminal_scan_payload(scan_id=scan_id))


@app.get("/scans/<uuid:scan_id>/findings")
def list_findings(scan_id: UUID) -> Response:
    if not _auth_ok():
        return Response(status=401)
    min_severity = (request.args.get("min_severity") or "").lower()
    rank = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}
    out = [FIXTURE_FINDING]
    if min_severity:
        threshold = rank.get(min_severity, 99)
        out = [f for f in out if rank.get(f["severity"], 99) <= threshold]
    return jsonify(out)


@app.get("/scans/<uuid:scan_id>/export")
def export_scan(scan_id: UUID) -> Response:
    if not _auth_ok():
        return Response(status=401)
    fmt = (request.args.get("format") or "json").lower()
    if fmt == "sarif":
        body = (
            '{"version": "2.1.0", "runs": [{"tool": {"driver": '
            '{"name": "secai", "version": "0.1.0"}}, "results": []}]}'
        )
        return Response(body, mimetype="application/sarif+json")
    return jsonify([FIXTURE_FINDING])


def _terminal_scan_payload(scan_id: UUID | None = None) -> dict[str, object]:
    return {
        "id": str(scan_id or FIXTURE_SCAN_ID),
        "repository_id": str(FIXTURE_REPO_ID),
        "status": "succeeded",
        "kinds": ["sast", "sca"],
        "cost_tokens": 0,
        "credits_cost": 0,
        "credits_refunded": False,
        "created_at": "2026-01-01T00:00:00Z",
        "started_at": "2026-01-01T00:00:00Z",
        "finished_at": "2026-01-01T00:00:00Z",
    }


if __name__ == "__main__":
    # Bind to 127.0.0.1 only — this is purely a CI-side mock and must
    # not be reachable from the wider runner network.
    port = int(os.environ.get("MOCK_SECAI_PORT", "8765"))
    app.run(host="127.0.0.1", port=port, debug=False)
