import { describe, expect, it } from "vitest";
import { cullItemsForViewport } from "./culling.js";
import { createSpatialPageIndex } from "./pagination.js";

const item = (id, x, y, extra = {}) => ({
  id,
  pose: { x, y, width: 100, height: 100 },
  ...extra,
});

describe("viewport scene culling", () => {
  it("mounts the viewport plus overscan and preserves selected items", () => {
    const items = [
      item("visible", 50, 50),
      item("overscan", 900, 50),
      item("far", 5000, 5000),
      item("selected-far", 6000, 6000),
    ];

    expect(cullItemsForViewport({
      items,
      camera: { x: 0, y: 0, zoom: 1 },
      viewport: { width: 800, height: 600 },
      selectedIds: ["selected-far"],
    }).map(({ id }) => id)).toEqual(["visible", "overscan", "selected-far"]);
  });

  it("culls collapsed stack members using the stack pose", () => {
    const stack = item("stack", 100, 100);
    const member = item("member", 5000, 5000, { stackId: "stack" });
    const input = {
      items: [stack, member],
      camera: { x: 0, y: 0, zoom: 1 },
      viewport: { width: 800, height: 600 },
      stacks: new Map([[stack.id, stack]]),
    };

    expect(cullItemsForViewport(input).map(({ id }) => id)).toEqual(["stack", "member"]);
    expect(cullItemsForViewport({ ...input, expandedStackId: "stack" }).map(({ id }) => id)).toEqual(["stack"]);
  });

  it("queries retained spatial pages while pinning offscreen selections", () => {
    const items = [
      item("visible", -40, -40),
      item("same-page-buffer", 420, 420),
      item("far", 8000, 8000),
      item("selected-far", -9000, 12000),
    ];
    const pageIndex = createSpatialPageIndex({ pageSize: 512 }).rebuild(items);

    expect(cullItemsForViewport({
      items,
      pageIndex,
      camera: { x: 0, y: 0, zoom: 1 },
      viewport: { width: 300, height: 240 },
      selectedIds: ["selected-far"],
      overscan: 0,
    }).map(({ id }) => id)).toEqual([
      "visible",
      "same-page-buffer",
      "selected-far",
    ]);

    expect(cullItemsForViewport({
      items,
      pageIndex,
      camera: { x: 0, y: 0, zoom: 1 },
      viewport: { width: 300, height: 240 },
      selectedIds: ["selected-far"],
      pinSelected: false,
      overscan: 0,
    }).map(({ id }) => id)).toEqual(["visible", "same-page-buffer"]);
  });

  it("does not retain every hidden member of a large collapsed stack", () => {
    const memberIds = Array.from({ length: 10_000 }, (_, index) => `member-${index}`);
    const stack = item("stack", 100, 100, {
      kind: "stack",
      content: { memberIds },
    });
    const members = Array.from({ length: 10_000 }, (_, index) => item(
      `member-${index}`,
      5000 + index * 120,
      5000,
      { stackId: "stack" },
    ));
    const items = [stack, ...members];
    const stacks = new Map([[stack.id, stack]]);
    const pageIndex = createSpatialPageIndex({ pageSize: 512 }).rebuild(items);
    const input = {
      items,
      pageIndex,
      camera: { x: 0, y: 0, zoom: 1 },
      viewport: { width: 800, height: 600 },
      stacks,
      overscan: 0,
    };

    expect(cullItemsForViewport(input).map(({ id }) => id)).toEqual([
      "stack",
      "member-9996",
      "member-9997",
      "member-9998",
      "member-9999",
    ]);
    expect(cullItemsForViewport({
      ...input,
      camera: { x: 5000, y: 5000, zoom: 1 },
      transitionStackId: "stack",
    }).length).toBeLessThan(30);
  });

  it("queries translated folder pages without retaining every member", () => {
    const members = Array.from({ length: 1000 }, (_, index) => item(
      `folder-member-${index}`,
      20_000 + (index % 50) * 120,
      20_000 + Math.floor(index / 50) * 120,
      { stackId: "folder" },
    ));
    const folder = item("folder", 100, 100, {
      kind: "folder",
      content: { memberIds: members.map(({ id }) => id) },
    });
    const items = [folder, ...members];
    const result = cullItemsForViewport({
      items,
      itemById: new Map(items.map((entry) => [entry.id, entry])),
      pageIndex: createSpatialPageIndex({ pageSize: 512 }).rebuild(items),
      camera: { x: 0, y: 0, zoom: 1 },
      viewport: { width: 800, height: 600 },
      stacks: new Map([[folder.id, folder]]),
      expandedStackId: folder.id,
      expandedGroupOffset: { x: -20_000, y: -20_000 },
      overscan: 0,
    });
    expect(result.some((entry) => entry.id === "folder-member-0")).toBe(true);
    expect(result.length).toBeLessThan(120);
  });

  it("keeps both inline and translated canvas pages mounted during the handoff", () => {
    const members = [
      item("inline-visible", 120, 120, { stackId: "folder" }),
      item("canvas-visible", 20_120, 20_120, { stackId: "folder" }),
      ...Array.from({ length: 4 }, (_, index) => item(
        `pile-${index}`,
        40_000 + index * 120,
        40_000,
        { stackId: "folder" },
      )),
    ];
    const folder = item("folder", 80, 80, {
      kind: "folder",
      content: { memberIds: members.map(({ id }) => id) },
    });
    const items = [folder, ...members];

    const result = cullItemsForViewport({
      items,
      itemById: new Map(items.map((entry) => [entry.id, entry])),
      pageIndex: createSpatialPageIndex({ pageSize: 512 }).rebuild(items),
      camera: { x: 0, y: 0, zoom: 1 },
      viewport: { width: 800, height: 600 },
      stacks: new Map([[folder.id, folder]]),
      expandedStackId: folder.id,
      transitionStackId: folder.id,
      expandedGroupOffset: null,
      transitionGroupOffset: { x: -20_000, y: -20_000 },
      overscan: 0,
    });

    const ids = result.map(({ id }) => id);
    expect(ids).toContain("inline-visible");
    expect(ids).toContain("canvas-visible");
  });

  it("uses the caller's retained id lookup instead of rescanning the whole board", () => {
    const stack = item("stack", 100, 100, {
      kind: "stack",
      content: { memberIds: ["member"] },
    });
    const member = item("member", 5000, 5000, { stackId: "stack" });
    const source = [stack, member];
    const pageIndex = createSpatialPageIndex({ pageSize: 512 }).rebuild(source);
    const guardedItems = [...source];
    guardedItems.map = () => {
      throw new Error("global item map should not be rebuilt during culling");
    };

    expect(cullItemsForViewport({
      items: guardedItems,
      itemById: new Map(source.map((entry) => [entry.id, entry])),
      pageIndex,
      camera: { x: 0, y: 0, zoom: 1 },
      viewport: { width: 800, height: 600 },
      stacks: new Map([[stack.id, stack]]),
      overscan: 0,
    }).map(({ id }) => id)).toEqual(["stack", "member"]);
  });
});
