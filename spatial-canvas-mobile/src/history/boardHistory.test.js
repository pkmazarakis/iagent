import { describe, expect, it } from "vitest";
import {
  HISTORY_LIMIT,
  appendHistory,
  boardHistorySnapshot,
  sanitizeHistorySnapshot,
} from "./boardHistory.js";

describe("board history", () => {
  it("retains immutable item references without cloning the board", () => {
    const items = [{ id: "one" }];
    expect(boardHistorySnapshot(items, ["one"]).items).toBe(items);
  });

  it("prunes selection ids that no longer exist", () => {
    expect(sanitizeHistorySnapshot({ items: [{ id: "one" }], selectedIds: ["one", "gone"] }))
      .toEqual({ items: [{ id: "one" }], selectedIds: ["one"] });
  });

  it("bounds the undo chain", () => {
    let stack = [];
    for (let index = 0; index < HISTORY_LIMIT + 4; index += 1) {
      stack = appendHistory(stack, { items: [{ id: String(index) }], selectedIds: [] });
    }
    expect(stack).toHaveLength(HISTORY_LIMIT);
    expect(stack[0].items[0].id).toBe("4");
  });
});
