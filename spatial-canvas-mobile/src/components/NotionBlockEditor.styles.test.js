import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const css = readFileSync(new URL("../styles.css", import.meta.url), "utf8");
const editorSource = readFileSync(new URL("./NotionBlockEditor.jsx", import.meta.url), "utf8");

function declarationsFor(selector) {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return css.match(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`))?.[1] || "";
}

describe("Notion block editor visual states", () => {
  it("shows the empty-block command hint only on the focused block", () => {
    expect(declarationsFor('.notion-block-content[data-empty="true"]:focus::before'))
      .toContain("content: attr(data-placeholder)");
    expect(css).not.toMatch(/\.notion-block-content\[data-empty="true"\]::before\s*\{/);
  });

  it("keeps ordinary rows transparent and reserves a fill for code blocks", () => {
    expect(declarationsFor(".notion-block-row")).toContain("background: transparent");
    expect(css).not.toMatch(/\.notion-block-row:hover,\s*\.notion-block-row\.has-menu\s*\{/);
    expect(declarationsFor(".notion-block-code")).toContain("background: #f1f2f2");
  });

  it("uses text-range selection across blocks without a box-selection marquee", () => {
    expect(editorSource).toContain("setBaseAndExtent");
    expect(editorSource).toContain("edgeScrollVelocity");
    expect(editorSource).toContain("selectedTextClientRects(range, root)");
    expect(editorSource).toContain("for (const rect of selectedTextClientRects(range, root))");
    expect(editorSource).not.toContain("notion-block-marquee");
    expect(editorSource).not.toContain("is-block-selected");
  });

  it("paints only selected glyphs and handles cross-block deletion in the model", () => {
    expect(declarationsFor(".notion-editor.has-custom-selection *::selection"))
      .toContain("background: transparent");
    expect(editorSource).toContain("handleCrossBlockDeletion");
    expect(editorSource).toContain("deleteBlockTextRange");
  });

  it("never forces caret navigation through scrollIntoView", () => {
    expect(editorSource).not.toContain("scrollIntoView");
    expect(editorSource).toContain("revealEditorElement");
  });
});
