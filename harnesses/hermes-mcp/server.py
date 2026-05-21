#!/usr/bin/env python3
"""MCP bridge from Hermes to TipTour's local macOS harness."""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any

from mcp.server.fastmcp import FastMCP


TIPTOUR_BASE_URL = "http://127.0.0.1:19474"

mcp = FastMCP("tiptour")


def _request_json(path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    url = f"{TIPTOUR_BASE_URL}{path}"
    data = None
    headers = {"Accept": "application/json"}

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=data, headers=headers)

    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            response_body = response.read().decode("utf-8")
    except urllib.error.URLError as error:
        return {
            "ok": False,
            "reason": "tiptour_unavailable",
            "message": str(error),
        }

    try:
        parsed = json.loads(response_body)
    except json.JSONDecodeError:
        return {
            "ok": False,
            "reason": "invalid_tiptour_response",
            "message": response_body,
        }

    if isinstance(parsed, dict):
        return parsed

    return {"ok": True, "value": parsed}


@mcp.tool()
def tiptour_observe() -> dict[str, Any]:
    """Observe TipTour's current local state without requesting screenshots."""
    return _request_json("/v1/observe")


@mcp.tool()
def tiptour_submit_workflow_plan(
    goal: str,
    app: str | None,
    steps: list[dict[str, Any]],
) -> dict[str, Any]:
    """Submit one desktop action to TipTour.

    Steps use TipTour's workflow shape. Example:
    [{"type": "click", "label": "Add", "hint": "Click the Add menu"}]

    TipTour clamps every request to the first step, executes through its
    existing local grounding/action stack, and returns how many steps were
    accepted or ignored.
    """
    return _request_json(
        "/v1/workflow-plan",
        {
            "goal": goal,
            "app": app,
            "steps": steps,
        },
    )


if __name__ == "__main__":
    mcp.run()
