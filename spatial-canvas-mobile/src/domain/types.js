// @ts-check

/** @typedef {"image" | "note" | "document" | "web" | "stack" | "folder"} ItemKind */
/** @typedef {"light" | "dark"} BoardTheme */

/**
 * @typedef {object} Camera
 * @property {number} x
 * @property {number} y
 * @property {number} zoom
 */

/**
 * @typedef {object} Pose
 * @property {number} x
 * @property {number} y
 * @property {number} width
 * @property {number} height
 * @property {number} rotation
 */

/**
 * @typedef {object} BoardRecord
 * @property {string} id
 * @property {string} title
 * @property {BoardTheme} theme
 * @property {Camera} camera
 * @property {number} revision
 * @property {number} createdAt
 * @property {number} updatedAt
 */

/**
 * @typedef {object} ItemStyle
 * @property {string=} color
 * @property {string=} glowColor
 * @property {number=} cornerRadius
 * @property {number=} opacity
 */

/**
 * @typedef {object} BoardItemRecord
 * @property {string} id
 * @property {string} boardId
 * @property {ItemKind} kind
 * @property {Pose} pose
 * @property {number} z
 * @property {ItemStyle} style
 * @property {Record<string, unknown>} content
 * @property {string | null} stackId
 * @property {number} createdAt
 * @property {number} updatedAt
 */

/**
 * @typedef {object} SettingRecord
 * @property {string} key
 * @property {unknown} value
 * @property {number} updatedAt
 */

/**
 * Large imported files live outside board items so undo snapshots and pointer
 * interactions never clone binary payloads.
 * @typedef {object} AssetRecord
 * @property {string} id
 * @property {string} boardId
 * @property {string} name
 * @property {string} mimeType
 * @property {number} size
 * @property {Blob} blob
 * @property {number} createdAt
 */

/**
 * @typedef {object} BoardSnapshot
 * @property {BoardRecord} board
 * @property {BoardItemRecord[]} items
 */

export const ITEM_KINDS = /** @type {const} */ ([
  "image",
  "note",
  "document",
  "web",
  "stack",
  "folder",
]);

export const BOARD_THEMES = /** @type {const} */ (["light", "dark"]);

/** @param {unknown} value @param {string} label */
function assertFiniteNumber(value, label) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError(`${label} must be a finite number`);
  }
}

/** @param {unknown} value @param {string} label */
function assertNonEmptyString(value, label) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new TypeError(`${label} must be a non-empty string`);
  }
}

/** @param {unknown} value */
export function assertCamera(value) {
  if (!value || typeof value !== "object") {
    throw new TypeError("camera must be an object");
  }

  const camera = /** @type {Record<string, unknown>} */ (value);
  assertFiniteNumber(camera.x, "camera.x");
  assertFiniteNumber(camera.y, "camera.y");
  assertFiniteNumber(camera.zoom, "camera.zoom");

  if (/** @type {number} */ (camera.zoom) <= 0) {
    throw new RangeError("camera.zoom must be greater than zero");
  }
}

/** @param {unknown} value */
export function assertPose(value) {
  if (!value || typeof value !== "object") {
    throw new TypeError("pose must be an object");
  }

  const pose = /** @type {Record<string, unknown>} */ (value);
  assertFiniteNumber(pose.x, "pose.x");
  assertFiniteNumber(pose.y, "pose.y");
  assertFiniteNumber(pose.width, "pose.width");
  assertFiniteNumber(pose.height, "pose.height");
  assertFiniteNumber(pose.rotation, "pose.rotation");

  if (/** @type {number} */ (pose.width) <= 0 || /** @type {number} */ (pose.height) <= 0) {
    throw new RangeError("pose width and height must be greater than zero");
  }
}

/** @param {unknown} value @returns {asserts value is BoardRecord} */
export function assertBoardRecord(value) {
  if (!value || typeof value !== "object") {
    throw new TypeError("board must be an object");
  }

  const board = /** @type {Record<string, unknown>} */ (value);
  assertNonEmptyString(board.id, "board.id");
  assertNonEmptyString(board.title, "board.title");

  if (!BOARD_THEMES.includes(/** @type {BoardTheme} */ (board.theme))) {
    throw new TypeError("board.theme must be light or dark");
  }

  assertCamera(board.camera);
  assertFiniteNumber(board.revision, "board.revision");
  assertFiniteNumber(board.createdAt, "board.createdAt");
  assertFiniteNumber(board.updatedAt, "board.updatedAt");
}

/** @param {unknown} value @returns {asserts value is BoardItemRecord} */
export function assertBoardItemRecord(value) {
  if (!value || typeof value !== "object") {
    throw new TypeError("item must be an object");
  }

  const item = /** @type {Record<string, unknown>} */ (value);
  assertNonEmptyString(item.id, "item.id");
  assertNonEmptyString(item.boardId, "item.boardId");

  if (!ITEM_KINDS.includes(/** @type {ItemKind} */ (item.kind))) {
    throw new TypeError(`unsupported item kind: ${String(item.kind)}`);
  }

  if (item.stackId !== null && typeof item.stackId !== "string") {
    throw new TypeError("item.stackId must be a string or null");
  }

  if ((item.kind === "stack" || item.kind === "folder") && item.stackId !== null) {
    throw new Error("top-level groups cannot belong to another group");
  }

  assertPose(item.pose);
  assertFiniteNumber(item.z, "item.z");
  assertFiniteNumber(item.createdAt, "item.createdAt");
  assertFiniteNumber(item.updatedAt, "item.updatedAt");

  if (!item.style || typeof item.style !== "object") {
    throw new TypeError("item.style must be an object");
  }

  if (!item.content || typeof item.content !== "object") {
    throw new TypeError("item.content must be an object");
  }
}

/** @param {unknown} value @returns {asserts value is SettingRecord} */
export function assertSettingRecord(value) {
  if (!value || typeof value !== "object") {
    throw new TypeError("setting must be an object");
  }

  const setting = /** @type {Record<string, unknown>} */ (value);
  assertNonEmptyString(setting.key, "setting.key");
  assertFiniteNumber(setting.updatedAt, "setting.updatedAt");
}

/** @param {unknown} value @returns {asserts value is AssetRecord} */
export function assertAssetRecord(value) {
  if (!value || typeof value !== "object") {
    throw new TypeError("asset must be an object");
  }

  const asset = /** @type {Record<string, unknown>} */ (value);
  assertNonEmptyString(asset.id, "asset.id");
  assertNonEmptyString(asset.boardId, "asset.boardId");
  assertNonEmptyString(asset.name, "asset.name");
  assertNonEmptyString(asset.mimeType, "asset.mimeType");
  assertFiniteNumber(asset.size, "asset.size");
  assertFiniteNumber(asset.createdAt, "asset.createdAt");
  if (!(asset.blob instanceof Blob)) throw new TypeError("asset.blob must be a Blob");
  if (asset.size < 0) throw new RangeError("asset.size must be non-negative");
}
