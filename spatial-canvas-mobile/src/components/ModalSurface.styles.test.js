import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const app = readFileSync(new URL("../App.jsx", import.meta.url), "utf8");
const css = readFileSync(new URL("../styles.css", import.meta.url), "utf8");
const documentDialog = readFileSync(new URL("./DocumentImportDialog.jsx", import.meta.url), "utf8");
const modalDialog = readFileSync(new URL("./ModalDialog.jsx", import.meta.url), "utf8");

function rulesFor(selector) {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const matches = [...css.matchAll(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`, "g"))];
  return matches.map((match) => match[1]).join("\n");
}

describe("compact modal surfaces", () => {
  it("routes web clips through the shared application modal", () => {
    expect(app).toContain('title="Add web clip"');
    expect(app).toContain('className="web-clip-form"');
    expect(app).toContain('className="app-modal-input-row"');
    expect(app).not.toContain('className="url-capture spatial-modal"');
    expect(app).not.toContain("A screenshot of this public URL");
    expect(app).not.toContain("third-party screenshot services");

    const layer = rulesFor(".app-modal-layer");
    expect(layer).toContain("position: fixed");
    expect(layer).toContain("place-items: center");

    const panel = rulesFor(".app-modal-panel");
    expect(panel).toContain("width: min(420px, calc(100vw - 40px))");
    expect(panel).toContain("max-height: calc(100dvh - 40px)");
    expect(panel).not.toContain("translateX(-50%)");
  });

  it("keeps the mobile URL field compact and inside the visual viewport", () => {
    const field = rulesFor(".app-modal-input-row");
    expect(field).toContain("grid-template-columns: minmax(0, 1fr) auto");
    expect(field).toContain("min-width: 0");

    const input = rulesFor(".app-modal-input-row input");
    expect(input).toContain("min-width: 0");
    expect(input).toContain("width: 100%");

    const layer = rulesFor(".app-modal-layer");
    expect(layer).toContain("position: fixed");
    expect(layer).not.toContain("transform:");
  });

  it("uses the same component and minimal surface for document import", () => {
    expect(app).toContain('import { ModalDialog } from "./components/ModalDialog.jsx"');
    expect(documentDialog).toContain('import { ModalDialog } from "./ModalDialog.jsx"');
    expect(documentDialog).toContain('title="Add document"');
    expect(documentDialog).toContain('className="app-modal-input-row document-import-link-row"');
    expect(documentDialog).not.toContain("document-import-overlay");
    expect(modalDialog).toContain('className="app-modal-layer"');
    expect(modalDialog).toContain('className="app-modal-backdrop"');

    const foundation = rulesFor(".app-modal-panel");
    expect(foundation).toContain("border: 1px solid #e1e3e1");
    expect(foundation).toContain("border-radius: 14px");
    expect(foundation).toContain("backdrop-filter: none");
  });
});
