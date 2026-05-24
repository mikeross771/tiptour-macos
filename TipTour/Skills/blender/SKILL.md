---
name: blender
description: Use when controlling Blender UI, menus, modal transforms, object creation, movement, scaling, rotation, and keyboard workflows.
---

# Blender

Blender is mostly a canvas app, so native macOS accessibility often cannot see its menus, viewport controls, or modal tool state. Prefer TipTour's local OCR/YOLO grounding for visible menu items and use Blender's keyboard modal commands for transform operations.

For one-action-at-a-time control:

- Add objects through the visible `Add` menu, then `Mesh`, then the object type.
- For modal transforms, send physical key actions in sequence: `G` for grab/move, `S` for scale, `R` for rotate, then optional axis keys like `X`, `Y`, or `Z`, then numeric input, then `Return`.
- Numeric transform input must behave like real keyboard typing. Do not paste numbers into Blender modal transform input.
- When selecting from an open Blender menu, prefer the menu popup region over duplicate labels in the right outliner or properties sidebar.
- For deleting objects in Blender, use `A` to select all when needed, `X` to delete selected objects, then confirm with `Return` or the visible delete confirmation if Blender shows one.

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
    "For Blender transforms, use key sequences like G, Z, type numeric value, Return.",
    "For numeric transform input, send a type step with the value only, for example {\"type\":\"type\",\"value\":\"2\"}.",
    "When choosing objects from Add > Mesh, ask TipTour for visible targets and choose the open menu item, not duplicate labels in the outliner."
  ]
}
```
