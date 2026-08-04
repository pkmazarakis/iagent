import { IDBKeyRange, indexedDB } from "fake-indexeddb";
import { afterEach, describe, expect, it } from "vitest";
import { createSpatialRepository } from "../persistence/index.js";
import {
  CLIENT_BOARD_ID,
  PRIMARY_BOARD_ID,
  createDemoBoard,
} from "./demoBoard.js";

describe("demo spaces", () => {
  let repository;

  afterEach(async () => {
    await repository?.deleteDatabase();
  });

  it("persists both independent top-level canvases", async () => {
    repository = createSpatialRepository({
      name: `demo-spaces-${crypto.randomUUID()}`,
      indexedDB,
      IDBKeyRange,
    });
    await repository.initialize({ seed: false });
    await repository.replaceBoardSnapshot(createDemoBoard(PRIMARY_BOARD_ID, "primary", 1));
    await repository.replaceBoardSnapshot(createDemoBoard(CLIENT_BOARD_ID, "client", 2));

    expect((await repository.listBoards()).map(({ id }) => id).sort()).toEqual([
      CLIENT_BOARD_ID,
      PRIMARY_BOARD_ID,
    ].sort());
    expect((await repository.getBoardSnapshot(CLIENT_BOARD_ID))?.items.length).toBeGreaterThan(0);
  });
});
