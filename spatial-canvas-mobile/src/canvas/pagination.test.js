import { describe, expect, it } from "vitest";
import {
  createSpatialPageIndex,
  viewportWithOverscan,
  worldPageWindow,
  worldPageRange,
} from "./pagination.js";

const item = (id, x, y, width = 40, height = 40) => ({
  id,
  pose: { x, y, width, height },
});

describe("spatial page index", () => {
  it("indexes multi-page items once and filters page candidates by the viewport", () => {
    const spanning = item("spanning", 50, 50, 180, 90);
    const outside = item("outside", 250, 250);
    const index = createSpatialPageIndex({ pageSize: 100 }).rebuild([
      spanning,
      outside,
    ]);

    expect(index.pageCount).toBe(7);
    expect(index.query({
      viewport: { x: 205, y: 70, width: 10, height: 10 },
    })).toEqual([spanning]);
    expect(index.query({
      viewport: { x: 0, y: 0, width: 300, height: 300 },
    })).toEqual([spanning, outside]);
  });

  it("upserts without changing source order and removes stale page membership", () => {
    const first = item("first", 10, 10);
    const second = item("second", 300, 10);
    const movedFirst = item("first", 600, 10);
    const index = createSpatialPageIndex({ pageSize: 100 }).rebuild([
      first,
      second,
    ]);

    index.upsert(movedFirst);
    expect(index.query({
      viewport: { x: 0, y: 0, width: 100, height: 100 },
    })).toEqual([]);
    expect(index.query({
      viewport: { x: 250, y: 0, width: 450, height: 100 },
    })).toEqual([movedFirst, second]);

    expect(index.remove("first")).toBe(true);
    expect(index.remove("missing")).toBe(false);
    expect(index.query({
      viewport: { x: 0, y: 0, width: 700, height: 100 },
    })).toEqual([second]);

    index.rebuild([second, movedFirst]);
    expect(index.query({
      viewport: { x: 0, y: 0, width: 700, height: 100 },
    })).toEqual([second, movedFirst]);
  });

  it("reconciles content and geometry changes without rebuilding stable pages", () => {
    const first = item("first", 10, 10);
    const second = item("second", 300, 10);
    const removed = item("removed", 600, 10);
    const index = createSpatialPageIndex({ pageSize: 100 }).rebuild([
      first,
      second,
      removed,
    ]);
    const updatedFirst = { ...first, content: { title: "Updated" } };
    const movedSecond = item("second", -400, -200);
    const added = item("added", 900, 900);

    index.reconcile([movedSecond, updatedFirst, added]);

    expect(index.lastSyncStats).toEqual({
      added: 1,
      moved: 1,
      updated: 1,
      unchanged: 0,
      removed: 1,
    });
    expect(index.query({
      viewport: { x: 0, y: 0, width: 100, height: 100 },
    })).toEqual([updatedFirst]);
    expect(index.query({
      viewport: { x: -500, y: -300, width: 200, height: 200 },
    })).toEqual([movedSecond]);
    expect(index.has("removed")).toBe(false);
  });

  it("queries overscan and merges pinned/included IDs without duplicates", () => {
    const pinned = item("pinned", 4000, 4000);
    const visible = item("visible", 20, 20);
    const overscan = item("overscan", 125, 20);
    const included = item("included", -4000, -4000);
    const far = item("far", 8000, 8000);
    const index = createSpatialPageIndex({ pageSize: 100 }).rebuild([
      pinned,
      visible,
      overscan,
      included,
      far,
    ]);

    const result = index.query({
      viewport: { x: 0, y: 0, width: 100, height: 100 },
      overscan: 30,
      pinnedIds: ["pinned", "visible"],
      includeIds: ["included", "visible", "missing"],
    });

    expect(result).toEqual([pinned, visible, overscan, included]);
    expect(new Set(result.map(({ id }) => id)).size).toBe(result.length);
  });

  it("supports negative and very large world coordinates without key collisions", () => {
    const negative = item("negative", -1_000_000_075, -500_000_025, 90, 70);
    const huge = item("huge", 1_000_000_000_000, 2_000_000_000_000, 80, 80);
    const index = createSpatialPageIndex({ pageSize: 256 }).rebuild([
      negative,
      huge,
    ]);

    expect(index.query({
      viewport: { x: -1_000_000_100, y: -500_000_050, width: 120, height: 120 },
    })).toEqual([negative]);
    expect(index.query({
      viewport: {
        x: 999_999_999_950,
        y: 1_999_999_999_950,
        width: 160,
        height: 160,
      },
    })).toEqual([huge]);
  });

  it("exposes deterministic page and overscan geometry helpers", () => {
    expect(worldPageRange(
      { x: -101, y: -1, width: 202, height: 2 },
      100,
    )).toEqual({
      minPageX: -2,
      maxPageX: 1,
      minPageY: -1,
      maxPageY: 0,
    });

    expect(viewportWithOverscan(
      { x: 10, y: 20, width: 100, height: 80 },
      { x: 5, top: 10, bottom: 20 },
    )).toEqual({ x: 5, y: 10, width: 110, height: 110 });
  });

  it("changes the page-window signature only after crossing a page boundary", () => {
    const first = worldPageWindow(
      { x: 10, y: 10, width: 20, height: 20 },
      { pageSize: 100, overscan: 10 },
    );
    const movedWithinPage = worldPageWindow(
      { x: 20, y: 20, width: 20, height: 20 },
      { pageSize: 100, overscan: 10 },
    );
    const crossedBoundary = worldPageWindow(
      { x: 85, y: 20, width: 20, height: 20 },
      { pageSize: 100, overscan: 10 },
    );

    expect(movedWithinPage.signature).toBe(first.signature);
    expect(crossedBoundary.signature).not.toBe(first.signature);
    expect(crossedBoundary).toMatchObject({
      minPageX: 0,
      maxPageX: 1,
      minPageY: 0,
      maxPageY: 0,
      pageSize: 100,
    });
  });

  it("examines only local candidates in a sparse trillion-scale world", () => {
    const count = 5_000;
    const spacing = 1_000_000;
    const baseX = 1_000_000_000_123;
    const baseY = -2_000_000_000_321;
    const items = Array.from({ length: count }, (_, index) =>
      item(
        `sparse-${index}`,
        baseX + index * spacing,
        baseY - index * spacing,
        40,
        40,
      ));
    const target = items[3_217];
    const index = createSpatialPageIndex({ pageSize: 512 }).rebuild(items);

    expect(index.query({
      viewport: {
        x: target.pose.x - 10,
        y: target.pose.y - 10,
        width: 60,
        height: 60,
      },
    })).toEqual([target]);
    expect(index.lastQueryStats.candidatesTested).toBe(1);
    expect(index.lastQueryStats.returned).toBe(1);
    expect(index.lastQueryStats.pagesVisited).toBeLessThanOrEqual(4);
  });

  it("keeps candidate work bounded across a long bidirectional traversal", () => {
    const pageSize = 256;
    const count = 20_000;
    const midpoint = count / 2;
    const items = Array.from({ length: count }, (_, index) => {
      const page = index - midpoint;
      return item(
        `page-${page}`,
        page * pageSize + 32,
        -page * pageSize + 32,
        24,
        24,
      );
    });
    const index = createSpatialPageIndex({ pageSize }).rebuild(items);
    let maxCandidates = 0;

    for (let sourceIndex = 0; sourceIndex < count; sourceIndex += 137) {
      const target = items[sourceIndex];
      expect(index.query({
        viewport: {
          x: target.pose.x - 8,
          y: target.pose.y - 8,
          width: 40,
          height: 40,
        },
      })).toEqual([target]);
      maxCandidates = Math.max(
        maxCandidates,
        index.lastQueryStats.candidatesTested,
      );
    }

    expect(index.size).toBe(count);
    expect(maxCandidates).toBeLessThanOrEqual(1);
  });
});
