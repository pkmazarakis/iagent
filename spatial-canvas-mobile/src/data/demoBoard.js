import { visualAssets } from "./assets.js";

export const DEMO_VERSION = 18;
export const PRIMARY_BOARD_ID = "board-spatial-demo";
export const CLIENT_BOARD_ID = "board-client-moodboard";

const task = (text, done = false) => ({ text, done });

function record({ id, boardId, kind, x, y, width, height, z, style = {}, content = {}, stackId = null }, now) {
  return {
    id,
    boardId,
    kind,
    pose: { x, y, width, height, rotation: 0 },
    z,
    style: { cornerRadius: kind === "note" ? 14 : 18, ...style },
    content,
    stackId,
    createdAt: now,
    updatedAt: now,
  };
}

export function createDemoBoard(boardId = PRIMARY_BOARD_ID, variant = "primary", now = Date.now()) {
  const client = variant === "client";
  const title = client ? "Client moodboard" : "Spatial board";
  const board = {
    id: boardId,
    title,
    theme: "light",
    camera: client ? { x: -20, y: -10, zoom: 0.78 } : { x: -45, y: -30, zoom: 0.76 },
    revision: 1,
    createdAt: now,
    updatedAt: now,
  };

  if (client) {
    return {
      board,
      items: [
        record({
          id: "client-visual-one", boardId, kind: "image", x: 70, y: 70, width: 340, height: 300, z: 1,
          content: { title: "Material references", image: visualAssets.dailyLife.src, alt: "Spatial daily life use-case board", caption: "Warm materials / working notes", palette: ["#5e4337", "#997562", "#d5a374", "#d2c1aa", "#2f3030"] },
        }, now),
        record({
          id: "client-tasks", boardId, kind: "document", x: 455, y: 45, width: 270, height: 360, z: 2,
          content: { title: "Things I need", subtitle: "Living room", body: "A calm room with enough contrast to feel collected, not staged.", tasks: [task("Confirm timber samples", true), task("Order linen swatches"), task("Check chair dimensions"), task("Source warm task light"), task("Photograph existing joinery")] },
        }, now),
        record({
          id: "client-green", boardId, kind: "note", x: 770, y: 80, width: 170, height: 170, z: 3,
          style: { color: "#78ff43", glowColor: "#67ef35" },
          content: { title: "Next visit", text: "Bring samples\nMeasure west wall\nPhotograph the alcove" },
        }, now),
        record({
          id: "client-visual-two", boardId, kind: "image", x: 750, y: 300, width: 360, height: 300, z: 4,
          content: { title: "Visual direction", image: visualAssets.visuals.src, alt: "Spatial visual references use-case board", caption: "Forms, color and scale", palette: ["#efece4", "#4f6970", "#14bfe4", "#f0a56b", "#131719"] },
        }, now),
        record({
          id: "client-meeting", boardId, kind: "document", x: 1150, y: 110, width: 250, height: 320, z: 5,
          content: { eyebrow: "Meeting · 28 Jun", title: "Client notes", subtitle: "The room should feel quiet, useful and lived in.", body: "Keep the palette restrained. Let the objects and the natural light do the work." },
        }, now),
        record({
          id: "client-coral", boardId, kind: "note", x: 1120, y: 480, width: 175, height: 145, z: 6,
          style: { color: "#ff735f", glowColor: "#ff5e49" },
          content: { title: "Priority", text: "Finalise the floor plan before Friday." },
        }, now),
      ],
    };
  }

  const stackId = "stack-archive";
  const stackMemberIds = ["archive-doc-one", "archive-doc-two", "archive-note"];
  const folderId = "folder-research";
  const folderMemberIds = [
    "folder-reading",
    "folder-image",
    "folder-reminder",
    "folder-visual",
    "folder-web",
    "folder-tasks",
  ];
  return {
    board,
    items: [
      record({
        id: "visual-concept", boardId, kind: "image", x: 65, y: 58, width: 315, height: 285, z: 1,
        content: { title: "Visual concept", image: visualAssets.writingLight.src, alt: "Official Spatial writing use-case", caption: "Visual concept · product notes", palette: ["#f7f7f4", "#c2c6c7", "#737f82", "#202526", "#dfff31"] },
      }, now),
      record({
        id: "today", boardId, kind: "document", x: 430, y: 28, width: 285, height: 370, z: 2,
        content: { title: "Today", body: "A focused list for the work in front of me.", tasks: [task("Collect references", true), task("Map the core interactions", true), task("Tune shared-element motion"), task("Test drag and resize"), task("Polish the color picker"), task("Write the handoff notes")] },
      }, now),
      record({
        id: "cyber-blossom", boardId, kind: "image", x: 765, y: 25, width: 370, height: 290, z: 3,
        content: { title: "Cyber Ink Blossom", image: visualAssets.visuals.src, alt: "Official Spatial visuals use-case", caption: "Saved visual reference", body: "Color, texture and composition reference for the current direction.", palette: ["#13bae7", "#efb175", "#eff0ea", "#25282a", "#b4473e"] },
      }, now),
      record({
        id: "someday", boardId, kind: "note", x: 430, y: 448, width: 285, height: 175, z: 4,
        content: { title: "Some day", tasks: [task("Import X bookmarks"), task("Add local search"), task("Plan iCloud sync"), task("Build a layers view")] },
      }, now),
      record({
        id: "bauhaus-web", boardId, kind: "web", x: 780, y: 365, width: 235, height: 300, z: 5,
        content: { domain: "design-history.archive", title: "A brief history of Scandinavian design.", description: "Clean lines, natural materials and thoughtful simplicity.", excerpt: "An enduring approach to beautiful, functional objects.", image: visualAssets.secondBrain.src, url: "https://www.get-spatial.com/" },
      }, now),
      record({
        id: "spatial-web", boardId, kind: "web", x: 1045, y: 372, width: 235, height: 300, z: 6,
        content: { domain: "notes on tools", title: "Spatial organisation for notes, prose, visuals and webclips.", description: "Designing software that gets out of the way.", excerpt: "Keep words and images together in the context that made them useful.", image: visualAssets.writingDark.src, url: "https://www.get-spatial.com/" },
      }, now),
      record({
        id: "lime-note", boardId, kind: "note", x: 1170, y: 95, width: 150, height: 150, z: 7,
        style: { color: "#dfff31", glowColor: "#cafa24" },
        content: { title: "Remember", text: "Small things become useful when they stay close to their context." },
      }, now),
      record({
        id: stackId, boardId, kind: "stack", x: 90, y: 465, width: 225, height: 160, z: 11,
        style: { color: "#c8faf2", glowColor: "#8cf1df" },
        content: { title: "Archived notes", subtitle: "August 2025", memberIds: stackMemberIds, peekColors: ["#dfff31", "#ffffff"] },
      }, now),
      record({
        id: "archive-doc-one", boardId, kind: "document", x: 355, y: 455, width: 220, height: 260, z: 8, stackId,
        content: { title: "The golden era of Bauhaus", body: "A short reading note about materials, type and modern form." },
      }, now),
      record({
        id: "archive-doc-two", boardId, kind: "document", x: 610, y: 445, width: 220, height: 260, z: 9, stackId,
        content: { title: "Ideas worth keeping", body: "Loose fragments from earlier explorations and client calls." },
      }, now),
      record({
        id: "archive-note", boardId, kind: "note", x: 865, y: 485, width: 170, height: 160, z: 10, stackId,
        style: { color: "#ff7563", glowColor: "#ff6652" },
        content: { title: "Filed", text: "Three notes kept together without turning into a folder tree." },
      }, now),
      record({
        id: "far-reference", boardId, kind: "image", x: 1415, y: 120, width: 360, height: 315, z: 12,
        content: { title: "Second brain", image: visualAssets.secondBrain.src, alt: "Official Spatial second brain use-case", caption: "Keep the useful things nearby", palette: ["#111718", "#273637", "#546c70", "#7ff4d0", "#dfff31"] },
      }, now),
      record({
        id: folderId, boardId, kind: "folder", x: 90, y: 690, width: 225, height: 160, z: 15,
        style: { color: "#d7fbf2", glowColor: "#8cf1df" },
        content: { title: "Research folder", subtitle: "A full canvas inside", memberIds: folderMemberIds },
      }, now),
      record({
        id: "folder-reading", boardId, kind: "document", x: 420, y: 700, width: 260, height: 330, z: 13, stackId: folderId,
        content: { title: "Reading notes", subtitle: "Nested canvas", body: "Folders keep a full spatial workspace behind a compact card on the parent board." },
      }, now),
      record({
        id: "folder-image", boardId, kind: "image", x: 720, y: 690, width: 330, height: 280, z: 14, stackId: folderId,
        content: { title: "Folder reference", image: visualAssets.dailyLife.src, alt: "Nested folder visual", caption: "A visual kept inside the folder", palette: ["#5e4337", "#997562", "#d5a374", "#d2c1aa", "#2f3030"] },
      }, now),
      record({
        id: "folder-reminder", boardId, kind: "note", x: 1090, y: 720, width: 175, height: 150, z: 16, stackId: folderId,
        style: { color: "#dfff31", glowColor: "#cafa24" },
        content: { title: "Keep close", text: "The useful reference is the one that remains beside the work." },
      }, now),
      record({
        id: "folder-visual", boardId, kind: "image", x: 420, y: 1060, width: 300, height: 250, z: 17, stackId: folderId,
        content: { title: "Visual language", image: visualAssets.writingDark.src, alt: "Dark Spatial writing board", caption: "Tone, density and contrast", palette: ["#101415", "#2c3436", "#765de8", "#c166d7", "#f2f1ec"] },
      }, now),
      record({
        id: "folder-web", boardId, kind: "web", x: 770, y: 1010, width: 250, height: 300, z: 18, stackId: folderId,
        content: { domain: "field-notes.design", title: "Context is part of the idea.", description: "A clipped reference that remains next to the notes it informed.", excerpt: "Saved from a working research trail.", image: visualAssets.secondBrain.src, url: "https://www.get-spatial.com/" },
      }, now),
      record({
        id: "folder-tasks", boardId, kind: "document", x: 1060, y: 930, width: 240, height: 290, z: 19, stackId: folderId,
        content: { title: "Next pass", body: "A compact plan for the research board.", tasks: [task("Compare interaction timings", true), task("Keep source previews exact"), task("Test the nested return path"), task("Share the motion review")] },
      }, now),
    ],
  };
}

export function createEmptyBoard(title = "Untitled space", now = Date.now()) {
  const id = `board-${crypto.randomUUID?.() || Math.random().toString(36).slice(2)}`;
  return {
    board: { id, title, theme: "light", camera: { x: -80, y: -60, zoom: 0.84 }, revision: 0, createdAt: now, updatedAt: now },
    items: [],
  };
}
