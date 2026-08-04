// @ts-check

export const INITIAL_BOARD_ID = "board-welcome";

/**
 * Create deterministic starter records while allowing tests/importers to choose timestamps.
 * @param {number} [now]
 */
export function createInitialSeed(now = Date.now()) {
  /** @type {import("./types.js").BoardRecord} */
  const board = {
    id: INITIAL_BOARD_ID,
    title: "Spatial board",
    theme: "light",
    camera: { x: 0, y: 0, zoom: 1 },
    revision: 0,
    createdAt: now,
    updatedAt: now,
  };

  /** @type {import("./types.js").BoardItemRecord[]} */
  const items = [
    {
      id: "item-welcome-document",
      boardId: board.id,
      kind: "document",
      pose: { x: 140, y: 110, width: 280, height: 360, rotation: 0 },
      z: 1,
      style: { cornerRadius: 20 },
      content: {
        title: "Spatial organisation for thoughts",
        body: "Capture ideas, references, notes, and images without losing their context.",
      },
      stackId: null,
      createdAt: now,
      updatedAt: now,
    },
    {
      id: "item-green-note",
      boardId: board.id,
      kind: "note",
      pose: { x: 468, y: 132, width: 164, height: 164, rotation: 0 },
      z: 2,
      style: { color: "#9bff48", glowColor: "#79ff2d", cornerRadius: 16 },
      content: { text: "Things I want to remember" },
      stackId: null,
      createdAt: now,
      updatedAt: now,
    },
    {
      id: "item-reference-card",
      boardId: board.id,
      kind: "web",
      pose: { x: 462, y: 334, width: 250, height: 220, rotation: 0 },
      z: 3,
      style: { cornerRadius: 18 },
      content: {
        title: "A digital shoebox",
        description: "For what you see, think, and want to remember.",
        url: "https://get-spatial.com/",
      },
      stackId: null,
      createdAt: now,
      updatedAt: now,
    },
  ];

  /** @type {import("./types.js").SettingRecord[]} */
  const settings = [
    { key: "activeBoardId", value: board.id, updatedAt: now },
    { key: "hasSeededInitialBoard", value: true, updatedAt: now },
  ];

  return { boards: [board], items, settings };
}

