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
def tiptour_targets() -> dict[str, Any]:
    """Refresh and return TipTour's current local YOLO/OCR grounding targets."""
    return _request_json("/v1/targets")


@mcp.tool()
def tiptour_action_history() -> dict[str, Any]:
    """Return recent TipTour grounded-action attempts and validation outcomes."""
    return _request_json("/v1/action-history")


@mcp.tool()
def tiptour_plan_next_action(
    goal: str,
    app: str | None = None,
    target_label: str | None = None,
    action: str = "click",
    execute: bool = True,
    allow_screenshot_planning: bool = False,
    validate_state_change: bool = True,
) -> dict[str, Any]:
    """Ask TipTour to choose one grounded local target and optionally execute it.

    Prefer this over hand-written box_2d coordinates. TipTour refreshes its
    local YOLO/OCR perception cache, matches target_label or goal against real
    on-screen targets, executes one action, refreshes perception, and reports
    whether the visible target set changed. If validation fails, TipTour tries
    one local perception repair before giving up. It refuses to guess raw
    coordinates when no target matches.
    """
    return _request_json(
        "/v1/plan-next-action",
        {
            "goal": goal,
            "app": app,
            "target_label": target_label,
            "action": action,
            "execute": execute,
            "allow_screenshot_planning": allow_screenshot_planning,
            "validate_state_change": validate_state_change,
        },
    )


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
