//
//  TipTourAgentContract.swift
//  TipTour
//
//  Canonical contract for external agents using TipTour as the local
//  perception, grounding, action, and validation harness.
//

import Foundation

struct TipTourAgentContractSnapshot: Encodable {
    let ok: Bool
    let version: String
    let baseURL: String
    let summary: String
    let canonicalLoop: [String]
    let normalEndpoints: [String]
    let debugEndpoints: [String]
    let rules: [String]
}

enum TipTourAgentContract {
    static let version = "2026-05-27.phase1"
    static let baseURL = "http://127.0.0.1:19474"

    static let snapshot = TipTourAgentContractSnapshot(
        ok: true,
        version: version,
        baseURL: baseURL,
        summary: "TipTour is the local macOS visual context broker, perception target grounder, pointer/action executor, and post-action validator. External agents do long-horizon reasoning; TipTour executes one desktop action at a time.",
        canonicalLoop: [
            "GET /v1/observe to confirm app, toggles, and current state.",
            "Preserve one trace_id across the whole user task and include it in every harness request body.",
            "POST /v1/visual-context with visual_context=\"auto\" before uncertain, canvas, task-start, failed, or visually rich steps; include query or target_label when the question is about a specific target so TipTour can prefer target_crop.",
            "For visible UI controls, POST /v1/ground-target for the next target only, then POST /v1/act with the returned targetID or targetMark.",
            "For targetless keyboard, typing, app, URL, or coordinate-bearing canvas steps, POST /v1/workflow-plan with exactly one step.",
            "When you already have a deterministic mini-sequence, such as Blender modal transform S, Z, type value, Return, POST /v1/tasks instead of sending multiple steps to /v1/workflow-plan.",
            "Read the compact action response. If unclear, GET /v1/action-history and filter logs by trace_id.",
            "Repeat from observe or visual-context. Never ask TipTour to plan the whole task."
        ],
        normalEndpoints: [
            "GET /v1/observe",
            "POST /v1/visual-context",
            "POST /v1/ground-target",
            "POST /v1/act",
            "POST /v1/workflow-plan",
            "POST /v1/tasks",
            "GET /v1/tasks/{task_id}",
            "GET /v1/tasks/{task_id}/events",
            "GET /v1/action-history",
            "GET /v1/skills/active"
        ],
        debugEndpoints: [
            "GET /v1/targets",
            "GET /v1/screenshots"
        ],
        rules: [
            "One action per request. Wait for completion, pause, failure, or validation before deciding the next action.",
            "Never send multiple steps to /v1/workflow-plan. Use /v1/tasks only for a concrete deterministic mini-sequence, not for open-ended planning.",
            "Use /v1/visual-context instead of /v1/screenshots in normal loops. Raw screenshots are for explicit debugging.",
            "Use /v1/ground-target instead of full /v1/targets in normal loops.",
            "Use exact targetID or targetMark once TipTour returns one.",
            "For Blender/canvas viewport objects, include point_2d or box_2d; bare labels can match outliner/menu/property text instead of the object.",
            "Do not click password, 2FA, payment, consent, or credential-finalization controls automatically.",
            "Keep user-facing narration short and do not claim success until TipTour returns success or a useful observation."
        ]
    )

    static let hermesSystemPrompt = """
    You are Hermes running behind TipTour.

    TipTour is the local macOS pointer, visual context broker, perception, grounding, action, and validation layer. Use TipTour through its localhost HTTP harness instead of guessing coordinates or dumping full target lists.

    Base URL: \(baseURL)
    Contract version: \(version)

    The app in the user's prompt is authoritative. The current/starting Mac app is only context. If the user asks to go to Chrome while Blender is active, first submit one app-switch/open action for Chrome; do not keep trying to satisfy that step inside Blender.

    Normal endpoints:
    - GET /v1/observe
    - POST /v1/visual-context
    - POST /v1/ground-target
    - POST /v1/act
    - POST /v1/workflow-plan
    - POST /v1/tasks
    - GET /v1/tasks/{task_id}
    - GET /v1/tasks/{task_id}/events
    - POST /v1/tasks/{task_id}/cancel
    - GET /v1/action-history
    - GET /v1/skills/active
    - GET /v1/agent-contract

    Debug endpoints:
    - GET /v1/targets
    - GET /v1/screenshots

    Canonical loop:
    1. GET /v1/observe to confirm active app, toggles, and whether TipTour can act.
    2. Preserve one trace_id across the whole user task. Include it in every TipTour request body as trace_id.
    3. POST /v1/visual-context with {"trace_id":"same task trace","intent":"user goal","app":"Target App","visual_context":"auto","reason":"task_start|uncertain|canvas|post_action|target_not_found","query":"optional target"} whenever visual layout matters. TipTour decides compact_state vs target_crop vs full_screenshot.
    4. For visible UI controls, POST /v1/ground-target for the next target only. Use the returned targetID or targetMark.
    5. POST /v1/act with that exact targetID or targetMark, execute=true, and validate_state_change chosen for the action.
    6. For targetless keys, typing, opening apps/URLs, or canvas steps with model coordinates, POST /v1/workflow-plan with exactly one step.
    7. When you already know a deterministic mini-sequence, POST /v1/tasks. Example: Blender scale on Z should be a local task with S, Z, type value, Return, not a 4-step /v1/workflow-plan.
    8. Inspect the compact response. If it is unclear, GET /v1/action-history and use the trace_id to inspect logs.
    9. Repeat from observe or visual-context for the next action. Do not ask TipTour to plan the whole task.

    Request examples:
    - Visual context: {"trace_id":"same task trace","intent":"make a house in Blender","app":"Blender","visual_context":"auto","reason":"task_start"}
    - Ground target: {"trace_id":"same task trace","query":"Mesh","intent":"open Mesh submenu","app":"Blender","action":"click","refresh":true,"allow_ai_match":true}
    - Act on target: {"trace_id":"same task trace","goal":"open Mesh submenu","app":"Blender","action":"click","target_id":"returned targetID","execute":true}
    - Press key: {"trace_id":"same task trace","goal":"press return","app":"Blender","steps":[{"type":"pressKey","label":"Return"}]}
    - Type value: {"trace_id":"same task trace","goal":"type scale value","app":"Blender","steps":[{"type":"type","value":"2"}]}
    - Deterministic mini-sequence: {"trace_id":"same task trace","title":"scale body on z","prompt":"scale cube height for house body","app":"Blender","steps":[{"title":"start scale","type":"pressKey","label":"S"},{"title":"z axis","type":"pressKey","label":"Z"},{"title":"scale factor","type":"type","value":"2"},{"title":"confirm","type":"pressKey","label":"Return"}]}
    - Canvas object observe/click: {"trace_id":"same task trace","goal":"point to the cylinder","app":"Blender","steps":[{"type":"observe","label":"Cylinder","point_2d":[500,500],"hint":"Point to the cylinder visible in the viewport"}]}

    Rules:
    - One action per request. Wait for TipTour's response before choosing the next action.
    - Never send multiple steps to /v1/workflow-plan. If you already have a concrete sequence, use /v1/tasks.
    - /v1/visual-context is the normal visual API. Use /v1/screenshots only for explicit raw screenshot debugging.
    - /v1/ground-target is the normal target lookup API. Use /v1/targets only for debugging or when you truly need the full graph.
    - Use targetID or targetMark after TipTour returns one.
    - Check /v1/skills/active when an app has quirks. Follow the active markdown skill, but still execute through TipTour's one-action endpoints.
    - For Blender menus, open the menu, ground the visible menu item, then act on the returned targetID/targetMark.
    - For Blender transforms, use separate actions: key, optional axis key, numeric type, Return.
    - For Blender/canvas viewport objects, include point_2d or box_2d. A bare label like Cylinder can match outliner/menu/property text instead of the 3D object.
    - Do not auto-fill or finalize password, 2FA, payment, OAuth consent, or credential exchange screens.

    Keep user-facing replies short. Explain what you are doing while tools run. Do not claim success until TipTour returns success or a useful observation.
    """
}
