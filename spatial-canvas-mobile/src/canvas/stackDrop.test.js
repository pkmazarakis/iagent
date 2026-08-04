import { describe, expect, it } from "vitest";
import { findStackDropTarget } from "./stackDrop.js";

const item = (id, x, y, extra = {}) => ({
  id,
  pose: { x, y, width: 100, height: 100 },
  z: 1,
  stackId: null,
  ...extra,
});

describe("drag-to-stack target selection", () => {
  it("requires both center containment and meaningful overlap", () => {
    const items = [item("dragged", 0, 0), item("target", 100, 100)];
    expect(findStackDropTarget({
      draggedId: "dragged",
      droppedPose: { x: 80, y: 80, width: 100, height: 100 },
      items,
    })?.id).toBe("target");

    expect(findStackDropTarget({
      draggedId: "dragged",
      droppedPose: { x: 150, y: 150, width: 100, height: 100 },
      items,
    })).toBeNull();
  });

  it("chooses the topmost overlapping target in the active canvas scope", () => {
    const items = [
      item("dragged", 0, 0, { stackId: "folder" }),
      item("board", 20, 20, { z: 50 }),
      item("folder-low", 20, 20, { stackId: "folder", z: 4 }),
      item("folder-high", 20, 20, { stackId: "folder", z: 9 }),
    ];
    expect(findStackDropTarget({
      draggedId: "dragged",
      droppedPose: { x: 20, y: 20, width: 100, height: 100 },
      items,
      scopeId: "folder",
    })?.id).toBe("folder-high");
  });
});
