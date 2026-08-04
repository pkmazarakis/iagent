import { describe, expect, it } from "vitest";
import {
  interpolateLayouts,
  layoutFan,
  layoutGrid,
  layoutStack,
} from "./stackLayout.js";

const items = [
  { id: "a", width: 100, height: 80 },
  { id: "b", width: 120, height: 90 },
  { id: "c", width: 80, height: 70 },
];

describe("stack layouts", () => {
  it("caps visible stack offsets while preserving z order", () => {
    const result = layoutStack(items, { x: 20, y: 30 }, {
      offsetX: 5,
      offsetY: 3,
      maxVisible: 2,
    });
    expect(result).toEqual([
      { id: "a", x: 20, y: 30, zIndex: 0 },
      { id: "b", x: 20, y: 30, zIndex: 1 },
      { id: "c", x: 25, y: 33, zIndex: 2 },
    ]);
  });

  it("lays out a deterministic grid using the largest item cell", () => {
    expect(layoutGrid(items, { x: 0, y: 0 }, { columns: 2, gapX: 10, gapY: 5 }))
      .toEqual([
        { id: "a", x: 0, y: 0, zIndex: 0 },
        { id: "b", x: 130, y: 0, zIndex: 1 },
        { id: "c", x: 0, y: 95, zIndex: 2 },
      ]);
  });

  it("fans cards using each card's own width", () => {
    expect(layoutFan(items, { x: 10, y: 20 }, { gap: 10, staggerY: 2 }))
      .toEqual([
        { id: "a", x: 10, y: 20, zIndex: 0, rotation: 0 },
        { id: "b", x: 120, y: 22, zIndex: 1, rotation: 0 },
        { id: "c", x: 250, y: 24, zIndex: 2, rotation: 0 },
      ]);
  });

  it("interpolates stack-to-fan geometry without mutating endpoints", () => {
    const from = layoutStack(items, { x: 0, y: 0 });
    const to = layoutFan(items, { x: 0, y: 0 });
    const middle = interpolateLayouts(from, to, 0.5);
    expect(middle[1].x).toBe((from[1].x + to[1].x) / 2);
    expect(from[1].x).toBe(7);
    expect(to[1].x).toBe(116);
  });
});

