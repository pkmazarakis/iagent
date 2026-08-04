import { IDBKeyRange, indexedDB } from "fake-indexeddb";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { INITIAL_BOARD_ID } from "../domain/seed.js";
import { createSpatialDatabase } from "./database.js";
import { SpatialRepository } from "./repository.js";

describe("SpatialRepository", () => {
  let repository;

  beforeEach(() => {
    const database = createSpatialDatabase({
      name: `spatial-test-${crypto.randomUUID()}`,
      indexedDB,
      IDBKeyRange,
    });
    repository = new SpatialRepository(database);
  });

  afterEach(async () => {
    await repository.deleteDatabase();
  });

  it("seeds a deterministic starter board exactly once", async () => {
    await repository.initialize({ now: 1000 });
    await repository.initialize({ now: 2000 });

    const boards = await repository.listBoards();
    const snapshot = await repository.getBoardSnapshot(INITIAL_BOARD_ID);

    expect(boards).toHaveLength(1);
    expect(snapshot.board.createdAt).toBe(1000);
    expect(snapshot.items.map((item) => item.z)).toEqual([1, 2, 3]);
    expect(await repository.getSetting("activeBoardId")).toBe(INITIAL_BOARD_ID);
  });

  it("atomically replaces a board snapshot", async () => {
    await repository.initialize({ now: 1000 });
    const snapshot = await repository.getBoardSnapshot(INITIAL_BOARD_ID);
    const note = {
      ...snapshot.items[1],
      pose: { ...snapshot.items[1].pose, x: 900 },
      updatedAt: 3000,
    };
    const board = { ...snapshot.board, revision: 1, updatedAt: 3000 };

    await repository.replaceBoardSnapshot({ board, items: [note] });
    const updated = await repository.getBoardSnapshot(INITIAL_BOARD_ID);

    expect(updated.board.revision).toBe(1);
    expect(updated.items).toHaveLength(1);
    expect(updated.items[0].pose.x).toBe(900);
  });

  it("updates camera metadata without rewriting board items", async () => {
    await repository.initialize({ now: 1000 });
    const before = await repository.getBoardSnapshot(INITIAL_BOARD_ID);
    const itemKeys = before.items.map((item) => item.id);

    await repository.putBoard({
      ...before.board,
      camera: { x: 1_000_000_000_000, y: -1_000_000_000_000, zoom: 0.75 },
      revision: before.board.revision + 1,
      updatedAt: 2000,
    });
    const after = await repository.getBoardSnapshot(INITIAL_BOARD_ID);

    expect(after.board.camera).toEqual({
      x: 1_000_000_000_000,
      y: -1_000_000_000_000,
      zoom: 0.75,
    });
    expect(after.items.map((item) => item.id)).toEqual(itemKeys);
  });

  it("persists settings and falls back for missing keys", async () => {
    await repository.initialize({ seed: false });
    expect(await repository.getSetting("theme", "system")).toBe("system");

    await repository.setSetting("theme", "dark", 1234);
    expect(await repository.getSetting("theme")).toBe("dark");
  });

  it("stores imported assets outside board item snapshots", async () => {
    await repository.initialize({ now: 1000 });
    const asset = {
      id: "asset-1",
      boardId: INITIAL_BOARD_ID,
      name: "plan.docx",
      mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      size: 5,
      blob: new Blob(["hello"]),
      createdAt: 2000,
    };

    await repository.putAsset(asset);
    const loaded = await repository.getAsset(asset.id);

    expect(loaded.name).toBe("plan.docx");
    expect(await loaded.blob.text()).toBe("hello");
  });

  it("round-trips a cached web screenshot PNG", async () => {
    await repository.initialize({ now: 1000 });
    const bytes = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4]);
    await repository.putAsset({
      id: "asset-web-1",
      boardId: INITIAL_BOARD_ID,
      name: "example.com.png",
      mimeType: "image/png",
      size: bytes.byteLength,
      blob: new Blob([bytes], { type: "image/png" }),
      createdAt: 2000,
    });

    const loaded = await repository.getAsset("asset-web-1");
    expect(loaded.mimeType).toBe("image/png");
    expect(loaded.size).toBe(bytes.byteLength);
    expect([...new Uint8Array(await loaded.blob.arrayBuffer())]).toEqual([...bytes]);
    expect(await repository.getAsset("asset-web-missing")).toBeUndefined();
  });

  it("rejects a nested stack before persistence", async () => {
    await repository.initialize({ now: 1000 });
    const nestedStack = {
      id: "nested-stack",
      boardId: INITIAL_BOARD_ID,
      kind: "stack",
      pose: { x: 0, y: 0, width: 200, height: 220, rotation: 0 },
      z: 10,
      style: {},
      content: { title: "Not allowed", memberIds: [] },
      stackId: "parent-stack",
      createdAt: 1000,
      updatedAt: 1000,
    };

    await expect(repository.putItem(nestedStack)).rejects.toThrow(/cannot belong/);
    expect(await repository.database.items.get("nested-stack")).toBeUndefined();
  });
});
