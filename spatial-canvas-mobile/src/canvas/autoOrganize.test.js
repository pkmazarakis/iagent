import { describe, expect, it } from "vitest";
import { autoOrganizeItems } from "./autoOrganize.js";

function overlapsWithGap(a, b, gap) {
  return a.x < b.x + b.width + gap
    && a.x + a.width + gap > b.x
    && a.y < b.y + b.height + gap
    && a.y + a.height + gap > b.y;
}

function applyLayout(items, layout) {
  const byId = new Map(layout.map((entry) => [entry.id, entry]));
  return items.map((item) => ({ ...item, ...byId.get(item.id) }));
}

function byId(items) {
  return [...items].sort((a, b) => a.id.localeCompare(b.id));
}

describe("autoOrganizeItems", () => {
  it("only grid-snaps isolated items and preserves their rotation", () => {
    const items = [
      { id: "a", x: 13, y: 27, width: 100, height: 80, rotation: 3 },
      { id: "b", x: 413, y: 247, width: 120, height: 90, rotation: -2 },
    ];
    const result = autoOrganizeItems(items, { gridSize: 20, gap: 20 });

    expect(result).toEqual([
      { id: "a", x: 20, y: 20, rotation: 3 },
      { id: "b", x: 420, y: 240, rotation: -2 },
    ]);
  });

  it("separates a mixed-size pile while preserving directional order", () => {
    const items = [
      { id: "wide", x: 0, y: 0, width: 260, height: 80, rotation: 2 },
      { id: "tall", x: 40, y: 20, width: 90, height: 240, rotation: -1 },
      { id: "small", x: 70, y: 40, width: 70, height: 60, rotation: 4 },
    ];
    const layout = autoOrganizeItems(items, { gridSize: 20, gap: 20 });
    const rects = applyLayout(items, layout);

    for (let index = 0; index < rects.length; index += 1) {
      expect(layout[index].rotation).toBe(items[index].rotation);
      for (let next = index + 1; next < rects.length; next += 1) {
        expect(overlapsWithGap(rects[index], rects[next], 20)).toBe(false);
      }
    }
    const centerOrder = (entries) => [...entries]
      .sort((a, b) => (a.x + a.width / 2) - (b.x + b.width / 2))
      .map((item) => item.id);
    expect(centerOrder(rects)).toEqual(centerOrder(items));
  });

  it("equalizes local row gaps with only small corrections", () => {
    const items = [
      { id: "a", x: 0, y: 10, width: 100, height: 80 },
      { id: "b", x: 150, y: 22, width: 80, height: 90 },
      { id: "c", x: 275, y: 5, width: 120, height: 70 },
    ];
    const layout = autoOrganizeItems(items, { gridSize: 20, gap: 20 });
    const rects = applyLayout(items, layout).sort((a, b) => a.x - b.x);
    const gaps = rects.slice(1).map((item, index) => (
      item.x - (rects[index].x + rects[index].width)
    ));

    expect(new Set(gaps).size).toBe(1);
    expect(rects.every((item) => item.y === rects[0].y)).toBe(true);
    expect(Math.max(...rects.map((item) => Math.hypot(
      item.x - items.find((original) => original.id === item.id).x,
      item.y - items.find((original) => original.id === item.id).y,
    )))).toBeLessThanOrEqual(20);
  });

  it("aligns and evenly spaces a local column", () => {
    const items = [
      { id: "a", x: 0, y: 0, width: 100, height: 100 },
      { id: "b", x: 12, y: 150, width: 90, height: 80 },
      { id: "c", x: -8, y: 270, width: 110, height: 120 },
    ];
    const rects = applyLayout(items, autoOrganizeItems(items)).sort((a, b) => a.y - b.y);
    const gaps = rects.slice(1).map((item, index) => (
      item.y - (rects[index].y + rects[index].height)
    ));

    expect(new Set(rects.map((item) => item.x)).size).toBe(1);
    expect(new Set(gaps).size).toBe(1);
  });

  it("does not pull a distant item into a nearby tidy group", () => {
    const items = [
      { id: "a", x: 0, y: 0, width: 100, height: 80 },
      { id: "b", x: 145, y: 10, width: 90, height: 80 },
      { id: "c", x: 270, y: -5, width: 110, height: 80 },
      { id: "outlier", x: 2003, y: 1097, width: 120, height: 90 },
    ];
    const outlier = autoOrganizeItems(items).find((item) => item.id === "outlier");
    expect(outlier).toMatchObject({ x: 2000, y: 1100 });
  });

  it("keeps a long existing lane as a lane instead of making a new grid", () => {
    const items = Array.from({ length: 20 }, (_, index) => ({
      id: `item-${String(index).padStart(2, "0")}`,
      x: index * 150,
      y: index % 2 ? 4 : -4,
      width: 100,
      height: 80,
    }));
    const rects = applyLayout(items, autoOrganizeItems(items)).sort((a, b) => a.x - b.x);

    expect(new Set(rects.map((item) => item.y)).size).toBe(1);
    expect(rects.slice(1).every((item, index) => item.x > rects[index].x)).toBe(true);
    expect(Math.max(...rects.map((item) => Math.abs(
      item.x - items.find((original) => original.id === item.id).x,
    )))).toBeLessThanOrEqual(10);
  });

  it("is idempotent and independent of input order", () => {
    const items = [
      { id: "a", x: -45, y: 18, width: 180, height: 170, rotation: 2 },
      { id: "b", x: -20, y: 30, width: 270, height: 340, rotation: -3 },
      { id: "c", x: 12, y: 24, width: 190, height: 105, rotation: 1 },
    ];
    const first = autoOrganizeItems(items);
    const second = autoOrganizeItems(applyLayout(items, first));
    const shuffled = autoOrganizeItems([items[2], items[0], items[1]]);

    expect(second).toEqual(first);
    expect(byId(shuffled)).toEqual(byId(first));
  });

  it("keeps negative and zero-size geometry finite", () => {
    const items = [
      { id: "zero", x: -43, y: -18, width: 0, height: 0 },
      { id: "card", x: -30, y: -12, width: 120, height: 80 },
    ];
    const result = autoOrganizeItems(items);
    expect(result.flatMap((item) => [item.x, item.y, item.rotation]).every(Number.isFinite)).toBe(true);
  });
});
