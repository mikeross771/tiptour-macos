# TipTour Agent Contract

TipTour is the local macOS visual context broker, perception target grounder, pointer/action executor, and post-action validator. External agents do long-horizon reasoning. TipTour executes one desktop action at a time.

Base URL:

```text
http://127.0.0.1:19474
```

Machine-readable contract:

```bash
curl http://127.0.0.1:19474/v1/agent-contract
```

## Canonical Loop

1. `GET /v1/observe` to confirm active app, toggles, and current state.
2. Preserve one `trace_id` across the whole user task and include it in every harness request body.
3. `POST /v1/visual-context` with `visual_context:"auto"` before uncertain, canvas, task-start, failed, or visually rich steps. Include `query` or `target_label` when asking about one specific target so TipTour can prefer `target_crop`.
4. For visible UI controls, `POST /v1/ground-target` for the next target only.
5. `POST /v1/act` with the returned `targetID` or `targetMark`.
6. For targetless keyboard, typing, app, URL, or coordinate-bearing canvas steps, `POST /v1/workflow-plan` with exactly one step.
7. When you already know a deterministic mini-sequence, such as Blender modal transform `S`, `Z`, type value, `Return`, use `POST /v1/tasks` instead of multiple steps in `/v1/workflow-plan`.
8. Read the compact response. If unclear, `GET /v1/action-history` and filter logs by `trace_id`.
9. Repeat from observe or visual-context. Do not ask TipTour to plan the whole task.

## Normal Endpoints

- `GET /v1/observe`
- `POST /v1/visual-context`
- `POST /v1/ground-target`
- `POST /v1/act`
- `POST /v1/workflow-plan`
- `POST /v1/tasks`
- `GET /v1/tasks/{task_id}`
- `GET /v1/tasks/{task_id}/events`
- `GET /v1/action-history`
- `GET /v1/skills/active`

## Debug Endpoints

- `GET /v1/targets`
- `GET /v1/screenshots`

## Rules

- One action per request. Wait for completion, pause, failure, or validation before deciding the next action.
- Never send multiple steps to `/v1/workflow-plan`. Use `/v1/tasks` only for a concrete deterministic mini-sequence, not for open-ended planning.
- Use `/v1/visual-context` instead of `/v1/screenshots` in normal loops. Raw screenshots are for explicit debugging.
- Use `/v1/ground-target` instead of full `/v1/targets` in normal loops.
- Use exact `targetID` or `targetMark` once TipTour returns one.
- For Blender/canvas viewport objects, include `point_2d` or `box_2d`; bare labels can match outliner/menu/property text instead of the object.
- Do not click password, 2FA, payment, consent, or credential-finalization controls automatically.
- Every action response/log path should carry `trace_id` so one request can be followed through grounding, execution, and validation.
