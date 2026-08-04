import { describe, expect, it } from "vitest";
import { autoOrganizeItems } from "./autoOrganize.js";
import { autoOrganizeItemsAsync } from "./autoOrganizeWorkerClient.js";

describe("auto-organize worker client", () => {
  it("matches the deterministic solver on the immediate path", async () => {
    const items = [
      { id: "a", x: 3, y: 8, width: 120, height: 90, rotation: 2 },
      { id: "b", x: 145, y: 12, width: 100, height: 80, rotation: -1 },
      { id: "c", x: 274, y: 0, width: 130, height: 100, rotation: 0 },
    ];
    await expect(autoOrganizeItemsAsync(items, { gridSize: 20, gap: 20 }))
      .resolves.toEqual(autoOrganizeItems(items, { gridSize: 20, gap: 20 }));
  });
});
