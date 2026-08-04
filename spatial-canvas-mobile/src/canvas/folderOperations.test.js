import { describe, expect, it } from "vitest";
import {
  eligibleFolderMemberIds,
  moveItemsToContainer,
  selectionContainerId,
} from "./folderOperations.js";

const leaf = (id, stackId = null) => ({ id, kind: "note", stackId, content: {}, updatedAt: 0 });
const folder = (id, memberIds = []) => ({
  id,
  kind: "folder",
  stackId: null,
  content: { title: id, subtitle: `${memberIds.length} items`, memberIds },
  updatedAt: 0,
});

describe("folder membership transactions", () => {
  it("moves items between folders and repairs both member lists", () => {
    const items = [folder("a", ["one", "two"]), folder("b"), leaf("one", "a"), leaf("two", "a")];
    const next = moveItemsToContainer(items, ["one"], "b", 10);
    expect(next.find((item) => item.id === "one").stackId).toBe("b");
    expect(next.find((item) => item.id === "a").content).toMatchObject({ memberIds: ["two"], subtitle: "1 item" });
    expect(next.find((item) => item.id === "b").content).toMatchObject({ memberIds: ["one"], subtitle: "1 item" });
  });

  it("removes an item from its current folder", () => {
    const items = [folder("a", ["one"]), leaf("one", "a")];
    const next = moveItemsToContainer(items, ["one"], null, 10);
    expect(next.find((item) => item.id === "one").stackId).toBeNull();
    expect(next.find((item) => item.id === "a").content.memberIds).toEqual([]);
  });

  it("never nests stacks or folders", () => {
    const items = [folder("a"), folder("b")];
    expect(moveItemsToContainer(items, ["a"], "b", 10)).toBe(items);
    expect(eligibleFolderMemberIds(items, ["a", "b"])).toEqual([]);
  });

  it("finds a common current container", () => {
    const items = [leaf("one", "a"), leaf("two", "a"), leaf("three", "b")];
    expect(selectionContainerId(items, ["one", "two"])).toBe("a");
    expect(selectionContainerId(items, ["one", "three"])).toBeNull();
  });
});
