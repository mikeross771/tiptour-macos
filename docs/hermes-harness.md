# TipTour Hermes Harness

TipTour should stay the native macOS perception/action engine. Hermes should stay an external orchestrator.

The integration boundary is the local TipTour harness server:

```text
Hermes Agent
  -> MCP bridge or local HTTP client
  -> TipTour Harness Server
  -> TipTourEngine
  -> macOS AX / OCR / local detection / CUA actions
```

TipTour listens only on localhost:

```text
http://127.0.0.1:19474
```

## Endpoints

### Health

```bash
curl http://127.0.0.1:19474/v1/health
```

### Observe

Returns TipTour's current local state without sending screenshots anywhere.

```bash
curl http://127.0.0.1:19474/v1/observe
```

### Local Grounding Targets

Refreshes TipTour's on-device YOLO/OCR perception pass and returns real on-screen targets. External orchestrators should use this before choosing a click target instead of inventing raw coordinates.

```bash
curl http://127.0.0.1:19474/v1/targets
```

### Plan And Execute One Grounded Action

Asks TipTour to choose one local target from the refreshed perception cache. If `execute` is true, TipTour runs the resulting single action through the same workflow/pointer path as voice mode, waits for WorkflowRunner to complete/pause/fail, refreshes local perception again, and reports whether the visible target set changed.

If validation fails, TipTour refreshes local perception and tries one alternate matching local target before returning failure. This is the preferred self-repair path for external harnesses.

```bash
curl -X POST http://127.0.0.1:19474/v1/plan-next-action \
  -H 'content-type: application/json' \
  -d '{
    "goal": "choose Mesh from the Blender Add menu",
    "app": "Blender",
    "target_label": "Mesh",
    "action": "click",
    "execute": true,
    "validate_state_change": true
  }'
```

Prefer this endpoint for harness-driven UI demos. It refuses to guess a raw coordinate when the local target does not exist, which is safer than clicking a stale or approximate `box_2d`.

Set `validate_state_change` to `false` for actions where a visible UI change is not expected, such as clicking into a text field before typing.

### Action History

Returns recent grounded-action attempts, including the chosen target, WorkflowRunner outcome, validation result, and whether a repair retry happened.

```bash
curl http://127.0.0.1:19474/v1/action-history
```

### Submit One Action

External harnesses submit the same single-action workflow shape Gemini uses internally.

```bash
curl -X POST http://127.0.0.1:19474/v1/workflow-plan \
  -H 'content-type: application/json' \
  -d '{
    "goal": "open the Add menu",
    "app": "Blender",
    "steps": [
      {
        "type": "click",
        "label": "Add",
        "hint": "Click the Add menu"
      }
    ]
  }'
```

TipTour clamps every external request to one step. Hermes should observe after each action and decide the next step. Prefer `/v1/plan-next-action` when Hermes has a semantic target label; use `/v1/workflow-plan` only when the caller already has a reliable TipTour workflow step.

External action requests also respect the menu bar connection toggles. If the CUA Driver toggle is off, TipTour rejects action plans instead of silently trying to click/type through the disabled driver.

## Why This Shape

Hermes is good at long-running reasoning, memory, skills, messaging, and tool orchestration.

TipTour is good at:

- local screen perception
- macOS accessibility grounding
- browser DOM fallback
- local OCR/detection grounding
- cursor overlay and user-visible guidance
- safe desktop action execution

Keeping the boundary local and small avoids embedding Hermes inside the macOS app while still letting Hermes use TipTour as a real computer-use harness.

Implementation note: transports such as HTTP and MCP should call `TipTourEngine`, not `CompanionManager`, so the engine can grow without tying plugin/harness code to menu bar UI state.
