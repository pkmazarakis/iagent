import { describe, expect, it } from "vitest";
import {
  folderCanonicalPose,
  folderDisplayPose,
  folderLayout,
  folderOpenOffset,
} from "./folderLayout.js";

const member = (id, x, y, width = 100, height = 80) => ({
  id,
  pose: { x, y, width, height, rotation: 0 },
});

describe("folder canvas layout", () => {
  it("centers the retained child group once in the visible world", () => {
    const members = [member("a", 100, 120), member("b", 260, 220, 140, 100)];
    const offset = folderOpenOffset(
      members,
      { x: -200, y: 40, zoom: 0.5 },
      { width: 1000, height: 600 },
    );

    // Visible world is {-200, 40, 2000, 1200}; member bounds are
    // {100, 120, 300, 200}, so the translated group is centered exactly.
    expect(offset).toEqual({ x: 550, y: 420 });
    expect(folderLayout(members, offset).get("a")).toEqual({
      x: 650,
      y: 540,
      width: 100,
      height: 80,
      rotation: 0,
    });
  });

  it("round-trips live dragged geometry back into folder-local coordinates", () => {
    const canonical = { x: -720, y: 410, width: 230, height: 180, rotation: 0 };
    const offset = { x: 1320, y: -260 };
    expect(folderCanonicalPose(folderDisplayPose(canonical, offset), offset)).toEqual(canonical);
  });
});
