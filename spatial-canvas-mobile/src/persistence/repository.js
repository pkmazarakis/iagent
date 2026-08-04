// @ts-check

import {
  assertAssetRecord,
  assertBoardItemRecord,
  assertBoardRecord,
  assertSettingRecord,
} from "../domain/types.js";
import { createInitialSeed } from "../domain/seed.js";

export class SpatialRepository {
  /** @param {import("./database.js").SpatialDatabase} database */
  constructor(database) {
    this.database = database;
  }

  /** @param {{seed?: boolean, now?: number}} [options] */
  async initialize(options = {}) {
    const shouldSeed = options.seed ?? true;
    await this.database.open();

    if (!shouldSeed) return;

    await this.database.transaction(
      "rw",
      this.database.boards,
      this.database.items,
      this.database.settings,
      async () => {
        if ((await this.database.boards.count()) > 0) return;

        const seed = createInitialSeed(options.now);
        seed.boards.forEach(assertBoardRecord);
        seed.items.forEach(assertBoardItemRecord);
        seed.settings.forEach(assertSettingRecord);

        await this.database.boards.bulkAdd(seed.boards);
        await this.database.items.bulkAdd(seed.items);
        await this.database.settings.bulkPut(seed.settings);
      },
    );
  }

  async listBoards() {
    return this.database.boards.orderBy("updatedAt").reverse().toArray();
  }

  /** @param {string} boardId */
  async getBoard(boardId) {
    return this.database.boards.get(boardId);
  }

  /** @param {string} boardId @returns {Promise<import("../domain/types.js").BoardSnapshot | undefined>} */
  async getBoardSnapshot(boardId) {
    const board = await this.database.boards.get(boardId);
    if (!board) return undefined;

    const items = await this.database.items.where("boardId").equals(boardId).sortBy("z");
    return { board, items };
  }

  /** @param {import("../domain/types.js").BoardRecord} board */
  async putBoard(board) {
    assertBoardRecord(board);
    await this.database.boards.put(board);
    return board;
  }

  /** @param {import("../domain/types.js").BoardItemRecord} item */
  async putItem(item) {
    assertBoardItemRecord(item);
    await this.assertBoardExists(item.boardId);
    await this.database.items.put(item);
    return item;
  }

  /** @param {import("../domain/types.js").BoardItemRecord[]} items */
  async putItems(items) {
    items.forEach(assertBoardItemRecord);
    const boardIds = [...new Set(items.map((item) => item.boardId))];
    await Promise.all(boardIds.map((boardId) => this.assertBoardExists(boardId)));
    await this.database.items.bulkPut(items);
    return items;
  }

  /**
   * Atomically replace the persisted snapshot for one board.
   * @param {import("../domain/types.js").BoardSnapshot} snapshot
   */
  async replaceBoardSnapshot(snapshot) {
    assertBoardRecord(snapshot.board);
    snapshot.items.forEach(assertBoardItemRecord);

    if (snapshot.items.some((item) => item.boardId !== snapshot.board.id)) {
      throw new Error("all snapshot items must belong to the snapshot board");
    }

    await this.database.transaction(
      "rw",
      this.database.boards,
      this.database.items,
      async () => {
        await this.database.boards.put(snapshot.board);
        await this.database.items.where("boardId").equals(snapshot.board.id).delete();
        if (snapshot.items.length > 0) {
          await this.database.items.bulkPut(snapshot.items);
        }
      },
    );
  }

  /** @param {string[]} itemIds */
  async deleteItems(itemIds) {
    await this.database.items.bulkDelete(itemIds);
  }

  /** @param {string} boardId */
  async deleteBoard(boardId) {
    await this.database.transaction(
      "rw",
      this.database.boards,
      this.database.items,
      this.database.settings,
      this.database.assets,
      async () => {
        await this.database.items.where("boardId").equals(boardId).delete();
        await this.database.assets.where("boardId").equals(boardId).delete();
        await this.database.boards.delete(boardId);

        const activeBoardId = await this.database.settings.get("activeBoardId");
        if (activeBoardId?.value === boardId) {
          await this.database.settings.delete("activeBoardId");
        }
      },
    );
  }

  /** @param {string} key @param {unknown} [fallback] */
  async getSetting(key, fallback) {
    const record = await this.database.settings.get(key);
    return record ? record.value : fallback;
  }

  /** @param {string} key @param {unknown} value @param {number} [now] */
  async setSetting(key, value, now = Date.now()) {
    const record = { key, value, updatedAt: now };
    assertSettingRecord(record);
    await this.database.settings.put(record);
    return record;
  }

  /** @param {import("../domain/types.js").AssetRecord} asset */
  async putAsset(asset) {
    assertAssetRecord(asset);
    await this.assertBoardExists(asset.boardId);
    await this.database.assets.put(asset);
    return asset;
  }

  /** @param {string} assetId */
  async getAsset(assetId) {
    return this.database.assets.get(assetId);
  }

  /** @param {string[]} assetIds */
  async deleteAssets(assetIds) {
    await this.database.assets.bulkDelete(assetIds);
  }

  async clear() {
    await this.database.transaction(
      "rw",
      this.database.boards,
      this.database.items,
      this.database.settings,
      this.database.assets,
      async () => {
        await Promise.all([
          this.database.boards.clear(),
          this.database.items.clear(),
          this.database.settings.clear(),
          this.database.assets.clear(),
        ]);
      },
    );
  }

  close() {
    this.database.close();
  }

  async deleteDatabase() {
    await this.database.delete();
  }

  /** @param {string} boardId */
  async assertBoardExists(boardId) {
    if (!(await this.database.boards.get(boardId))) {
      throw new Error(`board does not exist: ${boardId}`);
    }
  }
}
