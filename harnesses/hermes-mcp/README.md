# Hermes MCP Harness

This bridge lets Hermes call the local TipTour macOS engine without embedding Hermes inside TipTour.

TipTour must be running. It exposes a localhost harness at:

```text
http://127.0.0.1:19474
```

## Install

```bash
cd /Users/milindsoni/Documents/mywork/tiptour-macos/harnesses/hermes-mcp
python3 -m venv .venv
.venv/bin/python -m pip install -U mcp
```

## Hermes Config

Add this to `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  tiptour:
    command: "/Users/milindsoni/Documents/mywork/tiptour-macos/harnesses/hermes-mcp/.venv/bin/python"
    args:
      - "/Users/milindsoni/Documents/mywork/tiptour-macos/harnesses/hermes-mcp/server.py"
```

Hermes will discover:

- `tiptour_observe`
- `tiptour_submit_workflow_plan`

TipTour still clamps every submitted workflow to one action. Hermes should call `tiptour_observe`, take one action, then observe again.
