import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { TOOLBAR_LAYOUT_TRANSITION, toolbarActionsFor } from "./ContextToolbar.jsx";

const source = readFileSync(new URL("./ContextToolbar.jsx", import.meta.url), "utf8");

describe("context toolbar expansion motion", () => {
  it("keeps stable semantic action sets across toolbar sizes", () => {
    expect(toolbarActionsFor({ selectedCount: 0 })).toEqual([]);
    expect(toolbarActionsFor({ selectedCount: 1, selectedKind: null, canColor: false }))
      .toEqual(["focus", "folder", "trash"]);
    expect(toolbarActionsFor({ selectedCount: 1, selectedKind: null, canColor: true }))
      .toEqual(["copy", "focus", "color", "folder", "trash"]);
    expect(toolbarActionsFor({ selectedCount: 1, selectedKind: "stack" }))
      .toEqual(["unpack", "focus", "trash"]);
    expect(toolbarActionsFor({ selectedCount: 1, selectedKind: "folder" }))
      .toEqual(["open", "rename", "focus", "unpackFolder", "trash"]);
    expect(toolbarActionsFor({ selectedCount: 2, selectedKind: null }))
      .toEqual(["copy", "focus", "stack", "folder", "grid", "color", "trash"]);
  });

  it("uses an overdamped layout spring so the pill never overshoots", () => {
    const criticalDamping = 2 * Math.sqrt(
      TOOLBAR_LAYOUT_TRANSITION.stiffness * TOOLBAR_LAYOUT_TRANSITION.mass,
    );
    expect(TOOLBAR_LAYOUT_TRANSITION.damping).toBeGreaterThanOrEqual(criticalDamping);
  });

  it("animates bar size and retained button positions without remounting the bar", () => {
    expect(source).toContain('layout="size"');
    expect(source).toContain('layout="position"');
    expect(source).toContain('mode="popLayout"');
    expect(source).toContain("layoutDependency={actionSignature}");
    expect(source).toContain("key={key}");
    expect(source).not.toContain("key={actionSignature}");
  });
});

