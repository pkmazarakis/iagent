import { describe, expect, it } from "vitest";
import {
  contentPatchFromDocument,
  createBlock,
  deleteBlockTextRange,
  documentFromItem,
  ensureTitleParagraph,
  markdownShortcut,
  moveBlock,
  parseMarkdownText,
  splitBlockAt,
} from "./blockModel.js";

describe("Notion-style block document model", () => {
  it("migrates legacy tasks and prose into ordered blocks", () => {
    const document = documentFromItem({
      title: "Today",
      tasks: [{ text: "Collect", done: true }, { text: "Write", done: false }],
      body: "A focused note.",
    });

    expect(document.title).toBe("Today");
    expect(document.blocks.map(({ type, text, checked }) => ({ type, text, checked }))).toEqual([
      { type: "todo", text: "Collect", checked: true },
      { type: "todo", text: "Write", checked: false },
      { type: "paragraph", text: "A focused note.", checked: false },
    ]);
  });

  it("turns title Enter into a paragraph before non-paragraph content", () => {
    const todo = createBlock("todo", "Existing task");
    const result = ensureTitleParagraph([todo]);

    expect(result.inserted).toBe(true);
    expect(result.blocks[0].type).toBe("paragraph");
    expect(result.blocks[1]).toEqual(todo);
    expect(result.focusId).toBe(result.blocks[0].id);
  });

  it("splits a block and continues list semantics", () => {
    const block = createBlock("todo", "Write handoff", { checked: true, indent: 2 });
    const [before, after] = splitBlockAt(block, 6);

    expect(before.text).toBe("Write ");
    expect(after).toMatchObject({
      type: "todo",
      text: "handoff",
      checked: false,
      indent: 2,
    });
  });

  it("recognizes markdown shortcuts and multiline markdown paste", () => {
    expect(markdownShortcut("## ")).toEqual({ type: "heading2" });
    expect(markdownShortcut("- [x] ")).toEqual({ type: "todo", checked: true });

    const blocks = parseMarkdownText("# Plan\n- First\n1. Second\n> Keep context\n```\nconst x = 1;\n```");
    expect(blocks.map(({ type, text }) => ({ type, text }))).toEqual([
      { type: "heading1", text: "Plan" },
      { type: "bulleted", text: "First" },
      { type: "numbered", text: "Second" },
      { type: "quote", text: "Keep context" },
      { type: "code", text: "const x = 1;" },
    ]);
  });

  it("serializes blocks while preserving legacy previews", () => {
    const patch = contentPatchFromDocument("Plan", [
      createBlock("todo", "Ship it", { checked: true }),
      createBlock("heading2", "Notes"),
      createBlock("bulleted", "Fast"),
    ]);

    expect(patch.title).toBe("Plan");
    expect(patch.tasks).toEqual([{ text: "Ship it", done: true }]);
    expect(patch.body).toBe("Notes\n\n• Fast");
    expect(patch.blocks).toHaveLength(3);
  });

  it("reorders blocks without recreating their identities", () => {
    const first = createBlock("paragraph", "First");
    const second = createBlock("paragraph", "Second");
    const third = createBlock("paragraph", "Third");
    expect(moveBlock([first, second, third], third.id, first.id)).toEqual([
      third,
      first,
      second,
    ]);
  });

  it("deletes a forward cross-block text selection as one document transaction", () => {
    const first = createBlock("todo", "Map the core interactions", { checked: true });
    const middle = createBlock("todo", "Tune shared-element motion");
    const last = createBlock("todo", "Write the handoff notes");
    const result = deleteBlockTextRange(
      [first, middle, last],
      { id: first.id, offset: 4 },
      { id: last.id, offset: 10 },
    );

    expect(result.blocks).toEqual([{
      ...first,
      text: "Map handoff notes",
      html: "",
    }]);
    expect(result.focus).toEqual({ id: first.id, position: 4 });
  });

  it("normalizes a backward cross-block selection before deleting", () => {
    const first = createBlock("paragraph", "Alpha start");
    const middle = createBlock("paragraph", "Removed");
    const last = createBlock("paragraph", "finish Omega");
    const result = deleteBlockTextRange(
      [first, middle, last],
      { id: last.id, offset: 7 },
      { id: first.id, offset: 6 },
    );

    expect(result.blocks.map((block) => block.text)).toEqual(["Alpha Omega"]);
    expect(result.focus).toEqual({ id: first.id, position: 6 });
  });

  it("removes only covered rows and preserves the first row's semantics", () => {
    const before = createBlock("heading2", "Before");
    const first = createBlock("todo", "Selected first", { checked: true, indent: 2, html: "<b>Selected</b> first" });
    const middle = createBlock("divider");
    const last = createBlock("paragraph", "last suffix");
    const after = createBlock("quote", "After");
    const result = deleteBlockTextRange(
      [before, first, middle, last, after],
      { id: first.id, offset: 0 },
      { id: last.id, offset: 5 },
    );

    expect(result.blocks.map((block) => block.id)).toEqual([before.id, first.id, after.id]);
    expect(result.blocks[1]).toMatchObject({
      type: "todo",
      text: "suffix",
      checked: true,
      indent: 2,
      html: "",
    });
    expect(result.focus).toEqual({ id: first.id, position: 0 });
  });

  it("leaves same-block selections to native inline editing", () => {
    const block = createBlock("paragraph", "Keep native formatting");
    expect(deleteBlockTextRange(
      [block],
      { id: block.id, offset: 2 },
      { id: block.id, offset: 8 },
    )).toBeNull();
  });
});
