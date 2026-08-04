// @ts-check

import Dexie from "dexie";

export const DATABASE_VERSION = 2;
export const DEFAULT_DATABASE_NAME = "spatial-local";

export class SpatialDatabase extends Dexie {
  /**
   * @param {string} [name]
   * @param {{indexedDB?: IDBFactory, IDBKeyRange?: typeof IDBKeyRange}} [dependencies]
   */
  constructor(name = DEFAULT_DATABASE_NAME, dependencies) {
    super(name, dependencies);

    this.version(1).stores({
      boards: "id, title, updatedAt, createdAt",
      items: "id, boardId, stackId, kind, z, updatedAt, [boardId+z]",
      settings: "key, updatedAt",
    });

    this.version(DATABASE_VERSION).stores({
      boards: "id, title, updatedAt, createdAt",
      items: "id, boardId, stackId, kind, z, updatedAt, [boardId+z]",
      settings: "key, updatedAt",
      assets: "id, boardId, createdAt",
    });

    /** @type {import("dexie").Table<import("../domain/types.js").BoardRecord, string>} */
    this.boards = this.table("boards");
    /** @type {import("dexie").Table<import("../domain/types.js").BoardItemRecord, string>} */
    this.items = this.table("items");
    /** @type {import("dexie").Table<import("../domain/types.js").SettingRecord, string>} */
    this.settings = this.table("settings");
    /** @type {import("dexie").Table<import("../domain/types.js").AssetRecord, string>} */
    this.assets = this.table("assets");
  }
}

/**
 * @param {{name?: string, indexedDB?: IDBFactory, IDBKeyRange?: typeof IDBKeyRange}} [options]
 */
export function createSpatialDatabase(options = {}) {
  const dependencies =
    options.indexedDB && options.IDBKeyRange
      ? { indexedDB: options.indexedDB, IDBKeyRange: options.IDBKeyRange }
      : undefined;

  return new SpatialDatabase(options.name ?? DEFAULT_DATABASE_NAME, dependencies);
}
