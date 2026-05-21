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

TipTour clamps every external request to one step. Hermes should observe after each action and decide the next step.

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
