import { describe, expect, it } from "vitest";
import {
  panCamera,
  screenToWorld,
  worldToScreen,
  zoomCameraAt,
} from "./camera.js";
import {
  rectFromPoints,
  rectsIntersect,
  resizeRectFromHandle,
} from "./geometry.js";
import {
  applyMarqueeSelection,
  idsInMarquee,
  marqueeSelection,
} from "./selection.js";

describe("camera geometry", () => {
  it("keeps the cursor's world point fixed while zooming", () => {
    const camera = { x: 40, y: -20, zoom: 1.5 };
    const cursor = { x: 320, y: 180 };
    const before = screenToWorld(cursor, camera);
    const next = zoomCameraAt(camera, cursor, 2.75);

    const after = screenToWorld(cursor, next);
    const projected = worldToScreen(before, next);
    expect(after.x).toBeCloseTo(before.x, 10);
    expect(after.y).toBeCloseTo(before.y, 10);
    expect(projected.x).toBeCloseTo(cursor.x, 10);
    expect(projected.y).toBeCloseTo(cursor.y, 10);
  });

  it("pans in screen pixels independently of zoom", () => {
    const next = panCamera({ x: 10, y: 20, zoom: 3 }, { x: -5, y: 8 });
    expect(next.x).toBeCloseTo(11.6666666667);
    expect(next.y).toBeCloseTo(17.3333333333);
    expect(next.zoom).toBe(3);
  });
});

describe("rect geometry", () => {
  it("normalizes a reverse drag marquee", () => {
    expect(rectFromPoints({ x: 100, y: 80 }, { x: 20, y: 10 })).toEqual({
      x: 20,
      y: 10,
      width: 80,
      height: 70,
    });
  });

  it("treats touching marquee edges as an intersection", () => {
    expect(
      rectsIntersect(
        { x: 0, y: 0, width: 10, height: 10 },
        { x: 10, y: 5, width: 10, height: 10 },
      ),
    ).toBe(true);
  });

  it("holds the opposite edge while enforcing a minimum resize", () => {
    expect(
      resizeRectFromHandle(
        { x: 10, y: 20, width: 100, height: 80 },
        "nw",
        { x: 200, y: 200 },
        { minWidth: 40, minHeight: 30 },
      ),
    ).toEqual({ x: 70, y: 70, width: 40, height: 30 });
  });
});

describe("live marquee selection", () => {
  const items = [
    { id: "a", x: 0, y: 0, width: 50, height: 50 },
    { id: "b", x: 60, y: 0, width: 50, height: 50 },
    { id: "c", x: 120, y: 0, width: 50, height: 50 },
  ];

  it("supports intersection and containment modes", () => {
    const marquee = { x: 45, y: 10, width: 30, height: 20 };
    expect(idsInMarquee(items, marquee, "intersect")).toEqual(["a", "b"]);
    expect(idsInMarquee(items, marquee, "contain")).toEqual([]);
  });

  it("applies toggle against the pointer-down selection every frame", () => {
    const first = applyMarqueeSelection(["a"], ["a", "b"], "toggle");
    const second = applyMarqueeSelection(["a"], ["a", "b"], "toggle");
    expect([...first]).toEqual(["b"]);
    expect([...second]).toEqual(["b"]);
  });

  it("adds hits without discarding the base selection", () => {
    expect(
      [...marqueeSelection(items, { x: 55, y: -5, width: 60, height: 60 }, {
        baseSelection: ["c"],
        operation: "add",
      })],
    ).toEqual(["c", "b"]);
  });
});
