import { describe, expect, it } from "vitest";
import {
  createSnapTargetIndex,
  dragWithSnapping,
  resizeWithSnapping,
} from "./snap.js";

const start = { x: 0, y: 0, width: 100, height: 100 };

describe("resizeWithSnapping", () => {
  it("snaps a moving edge and exposes a renderable guide/highlight", () => {
    const result = resizeWithSnapping(
      start,
      "e",
      { x: 49, y: 0 },
      [{ id: "reference", x: 150, y: 20, width: 80, height: 60 }],
    );

    expect(result.rect).toEqual({ x: 0, y: 0, width: 150, height: 100 });
    expect(result.snaps.x).toMatchObject({
      kind: "edge",
      sourceEdge: "right",
      targetEdge: "left",
      targetId: "reference",
    });
    expect(result.guides[0]).toMatchObject({
      axis: "x",
      position: 150,
      label: "LEFT",
    });
    expect(result.highlightedIds).toEqual(["reference"]);
  });

  it("uses nearest proximity even when an equal-width snap beats an edge", () => {
    const result = resizeWithSnapping(
      start,
      "e",
      { x: 49.8, y: 0 },
      [
        { id: "edge", x: 153, y: 0, width: 20, height: 20 },
        { id: "width", x: 500, y: 0, width: 151, height: 80 },
      ],
    );

    expect(result.rect.width).toBe(151);
    expect(result.snaps.x).toMatchObject({
      kind: "width",
      targetId: "width",
      label: "WIDTH",
    });
  });

  it("keeps the screen-pixel threshold stable across camera zoom", () => {
    const targets = [{ id: "target", x: 105, y: 0, width: 50, height: 50 }];
    const zoomedOut = resizeWithSnapping(start, "e", { x: 0, y: 0 }, targets, {
      threshold: 8,
      zoom: 1,
    });
    const zoomedIn = resizeWithSnapping(start, "e", { x: 0, y: 0 }, targets, {
      threshold: 8,
      zoom: 2,
    });

    expect(zoomedOut.rect.width).toBe(105);
    expect(zoomedIn.rect.width).toBe(100);
    expect(zoomedIn.snaps.x).toBeNull();
  });

  it("labels bottom-edge snapping on the vertical axis", () => {
    const result = resizeWithSnapping(
      start,
      "s",
      { x: 0, y: 47 },
      [{ id: "target", x: 20, y: 150, width: 80, height: 50 }],
    );
    expect(result.rect.height).toBe(150);
    expect(result.guides[0]).toMatchObject({
      axis: "y",
      label: "TOP",
      targetId: "target",
    });
  });
});

describe("dragWithSnapping", () => {
  it("snaps a dragged edge to a nearby item and returns a full guide", () => {
    const result = dragWithSnapping(
      [{ id: "moving", x: 0, y: 20, width: 100, height: 80 }],
      { x: 47, y: 0 },
      [{ id: "target", x: 150, y: 0, width: 90, height: 140 }],
      { threshold: 8 },
    );

    expect(result.changes).toEqual([{ id: "moving", x: 50, y: 20 }]);
    expect(result.snaps.x).toMatchObject({
      sourceEdge: "right",
      targetEdge: "left",
      targetId: "target",
    });
    expect(result.guides[0]).toMatchObject({
      axis: "x",
      position: 150,
      start: 0,
      end: 140,
    });
  });

  it("moves a multi-selection as one rigid group when its bounds snap", () => {
    const result = dragWithSnapping(
      [
        { id: "a", x: 0, y: 0, width: 50, height: 50 },
        { id: "b", x: 70, y: 10, width: 30, height: 30 },
      ],
      { x: 46, y: 0 },
      [{ id: "target", x: 150, y: 0, width: 50, height: 50 }],
    );

    expect(result.changes).toEqual([
      { id: "a", x: 50, y: 0 },
      { id: "b", x: 120, y: 10 },
    ]);
  });

  it("keeps the drag threshold stable in screen pixels", () => {
    const moving = [{ id: "moving", x: 0, y: 0, width: 100, height: 100 }];
    const targets = [{ id: "target", x: 106, y: 0, width: 50, height: 50 }];
    expect(dragWithSnapping(moving, { x: 0, y: 0 }, targets, { threshold: 8, zoom: 1 }).changes[0].x).toBe(6);
    expect(dragWithSnapping(moving, { x: 0, y: 0 }, targets, { threshold: 8, zoom: 2 }).changes[0].x).toBe(0);
  });

  it("ignores aligned objects outside the nearby screen-space vicinity", () => {
    const moving = [{ id: "moving", x: 0, y: 0, width: 100, height: 100 }];
    const distant = [{ id: "distant", x: 105, y: 1000, width: 50, height: 50 }];
    const result = dragWithSnapping(moving, { x: 0, y: 0 }, distant, {
      threshold: 8,
      proximity: 320,
    });

    expect(result.changes[0].x).toBe(0);
    expect(result.guides).toEqual([]);
  });

  it("can bypass magnetic snapping while preserving live drag geometry", () => {
    const result = dragWithSnapping(
      [{ id: "moving", x: 0, y: 0, width: 100, height: 100 }],
      { x: 5, y: 0 },
      [{ id: "target", x: 105, y: 0, width: 50, height: 50 }],
      { threshold: 8, enabled: false },
    );

    expect(result.changes).toEqual([{ id: "moving", x: 5, y: 0 }]);
    expect(result.guides).toEqual([]);
  });

  it("keeps per-frame candidate work local on a large sparse board", () => {
    const targets = Array.from({ length: 20_000 }, (_, index) => ({
      id: `target-${index}`,
      x: index * 2_000,
      y: index * -2_000,
      width: 120,
      height: 80,
    }));
    const nearby = targets[12_345];
    const targetIndex = createSnapTargetIndex(targets);

    const result = dragWithSnapping(
      [{
        id: "moving",
        x: nearby.x - 220,
        y: nearby.y,
        width: 100,
        height: 80,
      }],
      { x: 119, y: 0 },
      targetIndex,
      { threshold: 8, proximity: 360 },
    );

    expect(result.changes[0].x).toBe(nearby.x - 100);
    expect(targetIndex.lastQueryStats.candidatesTested).toBeLessThanOrEqual(2);
    expect(targetIndex.lastQueryStats.returned).toBeLessThanOrEqual(2);
  });
});
