---
name: blender
description: Use when controlling Blender UI, menus, modal transforms, object creation, movement, scaling, rotation, and keyboard workflows.
---

# Blender

Blender is mostly a canvas app, so native macOS accessibility often cannot see its menus, viewport controls, or modal tool state. Prefer TipTour's local OCR/YOLO grounding for visible menu items and use Blender's keyboard modal commands for transform operations.

For one-action-at-a-time control:

- Add objects through the visible `Add` menu, then `Mesh`, then the object type.
- After opening `Add` or any submenu, refresh visible targets before selecting the next menu item. In the TipTour harness this means call `/v1/targets`, then choose the menu item by `target_id` or `target_mark` when possible.
- Do not rely on bare letter menu accelerators such as `M`, `P`, or `C` unless the correct Blender popup/submenu is visibly open and was just observed. Visible menu target clicks are safer for `Add > Mesh > Cube/Plane/Cone`.
- For modal transforms, send physical key actions in sequence: `G` for grab/move, `S` for scale, `R` for rotate, then optional axis keys like `X`, `Y`, or `Z`, then numeric input, then `Return`.
- Each modal transform token is its own TipTour action. For example, scaling by 3 requires separate actions: `S`, type `3`, `Return`. Moving up 1.5 on Z requires separate actions: `G`, `Z`, type `1.5`, `Return`.
- Never send `S`, a numeric value, and `Return` in one workflow plan. Never press `S` twice unless the previous scale command was cancelled.
- Numeric transform input must behave like real keyboard typing. Do not paste numbers into Blender modal transform input.
- When selecting from an open Blender menu, prefer the menu popup region over duplicate labels in the right outliner or properties sidebar.
- For deleting objects in Blender, use `A` to select all when needed, `X` to delete selected objects, then confirm with `Return`. Do not use a fuzzy OCR click to confirm deletion.

## Reliable House Recipe

When the user asks to make a simple house in Blender through TipTour, use a small, reliable primitive-building loop. Do not try to send a multi-step plan. Every bullet below is one action followed by waiting for TipTour's response and observing/refreshing targets when the visible UI changes.

1. Switch/open Blender.
2. Select all objects with `A`.
3. Delete selected objects with `X`.
4. Confirm delete with `Return` if Blender asks. Do not click a guessed OCR target for this.
5. Open the Add menu with `Shift+A`.
6. Refresh targets and choose visible `Mesh`.
7. Refresh targets and choose visible `Cube` for the house body.
8. Scale the selected cube: `S`, type `3`, `Return`.
9. Flatten/shape the body on Z: `S`, `Z`, type `0.7`, `Return`.
10. Open Add with `Shift+A`, choose `Mesh`, then choose `Cone` for a roof. If the cone options are easy to edit, use 4 vertices for a pyramid roof; otherwise use the default cone as a recognizable roof.
11. Move the roof up: `G`, `Z`, type `1.1`, `Return`.
12. Scale the roof wider: `S`, type `2.4`, `Return`.
13. Add small cubes for a door and windows through `Add > Mesh > Cube`, then use `S`, axis-constrained scaling, `G`, axis-constrained movement, and `Return` to place them on the front.

For house tasks, prefer progress over perfection: create a body, a roof, a door, and at least one window. If a menu item is not visible or a transform state is uncertain, observe/refresh targets before continuing.

```tiptour-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["org.blenderfoundation.blender"],
    "names": ["Blender"]
  },
  "commandAliases": [
    {
      "phrases": ["select all", "select all objects", "select all shapes"],
      "type": "pressKey",
      "label": "A"
    },
    {
      "phrases": ["delete", "delete selected", "delete objects", "delete all objects", "delete all shapes"],
      "type": "pressKey",
      "label": "X"
    },
    {
      "phrases": ["scale"],
      "type": "pressKey",
      "label": "S"
    },
    {
      "phrases": ["grab", "move"],
      "type": "pressKey",
      "label": "G"
    },
    {
      "phrases": ["rotate"],
      "type": "pressKey",
      "label": "R"
    },
    {
      "phrases": ["x axis", "constrain to x axis"],
      "type": "pressKey",
      "label": "X"
    },
    {
      "phrases": ["y axis", "constrain to y axis"],
      "type": "pressKey",
      "label": "Y"
    },
    {
      "phrases": ["z axis", "constrain to z axis"],
      "type": "pressKey",
      "label": "Z"
    },
    {
      "phrases": ["confirm", "apply", "enter", "confirm transform"],
      "type": "pressKey",
      "label": "Return"
    },
    {
      "phrases": ["escape", "cancel"],
      "type": "pressKey",
      "label": "Escape"
    }
  ],
  "inputPolicies": [
    {
      "kind": "numericModalText",
      "delivery": "physicalKeys",
      "maxLength": 16,
      "characters": "0123456789.-+*/"
    }
  ],
  "targetPolicies": {
    "menuSelection": {
      "preferLeftMenuRegionMaxX": 0.72
    }
  },
  "plannerInstructions": [
    "Use one TipTour action at a time.",
    "After opening Add or a Blender submenu, call /v1/targets before choosing Mesh, Cube, Plane, Cone, or other visible menu items.",
    "Prefer visible menu target clicks with target_id or target_mark for Add > Mesh selections; do not rely on bare M/P/C menu accelerator keys unless the relevant submenu is visibly open and freshly observed.",
    "For Blender transforms, use key sequences like G, Z, type numeric value, Return.",
    "Each transform token is a separate TipTour action: S, type 3, Return must be sent as three separate /v1/workflow-plan requests.",
    "Never send S, a numeric value, and Return in one workflow plan. Never press S twice unless the previous scale command was cancelled.",
    "For Blender delete confirmations, press Return as a targetless key action; do not use /v1/plan-next-action to click a fuzzy OCR confirmation target.",
    "For numeric transform input, send a type step with the value only, for example {\"type\":\"type\",\"value\":\"2\"}.",
    "When choosing objects from Add > Mesh, ask TipTour for visible targets and choose the open menu item, not duplicate labels in the outliner.",
    "For a simple house: clear the scene, add a Cube for the body, scale it, add a Cone or Cube roof, move it up, then add small Cube door/window details. Wait for TipTour after every single action."
  ]
}
```
