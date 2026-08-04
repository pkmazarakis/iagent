import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { officePreviewGeometry, renderOfficeDocument } from "./renderOfficeDocument.js";

const source = readFileSync(new URL("./renderOfficeDocument.js", import.meta.url), "utf8");

function sourceBetween(start, end) {
  const startIndex = source.indexOf(start);
  const endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex, `missing source marker: ${start}`).toBeGreaterThanOrEqual(0);
  expect(endIndex, `missing source marker: ${end}`).toBeGreaterThan(startIndex);
  return source.slice(startIndex, endIndex);
}

const sharedViewer = sourceBetween("const sharedDocumentCss", "/** @param {unknown} value */");
const docxRenderer = sourceBetween("async function renderDocx", "/**\n * The PowerPoint parser");
const pptxRenderer = sourceBetween("async function renderPptx", "/** @param {unknown} color */");
const xlsxRenderer = sourceBetween("async function renderXlsx", "/**\n * Convert a device-local Office asset");

describe("Office document rendering contract", () => {
  it("uses stable retained geometry for each document family", () => {
    expect(officePreviewGeometry("docx")).toEqual({ width: 816, height: 1056 });
    expect(officePreviewGeometry("pptx")).toEqual({ width: 960, height: 540 });
    expect(officePreviewGeometry("xlsx")).toEqual({ width: 1100, height: 760 });
  });

  it("fails clearly for missing assets and unsupported formats", async () => {
    await expect(renderOfficeDocument(null, "docx")).rejects.toThrow(/no longer available/);
    await expect(renderOfficeDocument({ blob: new Blob([]) }, "pdf")).rejects.toThrow(/Unsupported Office format/);
  });

  it("retains one identical srcDoc from board preview through fullscreen reader", () => {
    expect(source).toContain('data-view-mode="preview"');
    expect(source).toContain("officeLayers(preview, reader)");

    const srcDocPairs = [...source.matchAll(/previewSrcDoc:\s*([^,\n]+),\s*fullSrcDoc:\s*([^,\n]+),/g)]
      .map((match) => match.slice(1));
    expect(srcDocPairs).toHaveLength(3);
    expect(srcDocPairs).toEqual([
      ["srcDoc", "srcDoc"],
      ["srcDoc", "srcDoc"],
      ["srcDoc", "srcDoc"],
    ]);
  });

  it("keeps the retained viewer and both layers on a uniform white surface", () => {
    expect(sharedViewer).toMatch(/:root \{[^}]*color-scheme: light;[^}]*background: #fff; \}/);
    expect(sharedViewer).toMatch(/html, body \{[^}]*background: #fff/);
    expect(sharedViewer).toMatch(/\.office-viewer \{[^}]*background: #fff/);
    expect(sharedViewer).toMatch(/\.office-layer \{[^}]*background: #fff/);
    expect(docxRenderer).toContain("background: #fff");
    expect(pptxRenderer).toContain("background: #fff");
    expect(xlsxRenderer).toContain("background: #fff");
    expect(source).not.toContain("background: transparent");
  });

  it("reserves a native leading header slot for the app back control", () => {
    expect(sharedViewer).toContain("--office-leading-slot: max(76px, calc(env(safe-area-inset-left) + 68px))");
    expect(docxRenderer).toMatch(/\.docx-toolbar \{[^}]*padding: 0 20px 0 var\(--office-leading-slot\)/);
    expect(pptxRenderer).toMatch(/\.ppt-toolbar \{[^}]*padding: 0 20px 0 var\(--office-leading-slot\)/);
    expect(xlsxRenderer).toMatch(/\.workbook-header \{[^}]*padding-left: var\(--office-leading-slot\)/);
  });

  it("changes retained preview/reader mode with opacity only", () => {
    expect(sharedViewer).toMatch(/\.office-layer \{[^}]*transition: opacity 120ms/);
    expect(sharedViewer).toMatch(/\.office-preview-layer \{[^}]*opacity: 1;[^}]*visibility: visible/);
    expect(sharedViewer).toMatch(/\.office-reader-layer \{[^}]*opacity: 0;[^}]*visibility: hidden/);
    expect(sharedViewer).toMatch(/html\[data-view-mode="reader"\] \.office-preview-layer \{[^}]*opacity: 0;[^}]*visibility: hidden/);
    expect(sharedViewer).toMatch(/html\[data-view-mode="reader"\] \.office-reader-layer \{[^}]*opacity: 1;[^}]*visibility: visible/);
    expect(sharedViewer).toMatch(/\.office-preview-layer > \* \{[^}]*transform: scale\(var\(--office-preview-scale, 1\)\)/);
    expect(sharedViewer).not.toMatch(/\b(animation|keyframes)\b/);
  });

  it("renders DOCX as real paginated sections with a clean page gap", () => {
    expect(docxRenderer).toContain("breakPages: true");
    expect(docxRenderer).toContain("ignoreLastRenderedPageBreak: false");
    expect(docxRenderer).toContain('body.querySelectorAll("section.docx")');
    expect(docxRenderer).toContain("await afterRenderFrame()");
    expect(docxRenderer).toContain('prefixMarkupIds(firstPage.markup, "office-preview-")');
    expect(docxRenderer).toContain("pages.map((page) => ({");
    expect(docxRenderer).toContain('${pageEntries.map(({ markup }) => markup).join("")}');
    expect(docxRenderer).toContain("${pageEntries.length} ${pageEntries.length === 1 ? \"page\" : \"pages\"}");
    expect(docxRenderer).toContain('class="docx-wrapper docx-pages"');
    expect(docxRenderer).toContain('readerPageWidth: Math.max(...pageEntries.map(({ width }) => width))');
    expect(docxRenderer).toMatch(/\.docx-pages \{[^}]*display: grid !important;[^}]*gap: 26px;[^}]*justify-items: center/);
    expect(docxRenderer).toMatch(/\.docx-pages > section\.docx \{[^}]*border: 1px solid #e3e5e2[^}]*background: #fff[^}]*box-shadow:/);
    expect(docxRenderer).toMatch(/@media \(max-width: 760px\) \{[\s\S]*?\.docx-pages \{ gap: 14px;/);
  });

  it("renders XLSX as a full-viewport grid with functional header sheet tabs", () => {
    expect(source).toContain("async function spreadsheetStyleMaps");
    expect(source).toContain('zip.file("xl/styles.xml")');
    expect(source).toContain('getElementsByTagNameNS("*", "cellXfs")');
    expect(xlsxRenderer).toContain("styleMaps.get(name)");
    expect(xlsxRenderer).toContain('type="radio" name="workbook-sheet" id="workbook-sheet-${index}"');
    expect(xlsxRenderer).toContain('class="workbook-tab" data-sheet-index="${index}" for="workbook-sheet-${index}"');
    expect(xlsxRenderer).toContain('<nav class="workbook-tabs" aria-label="Workbook sheets">');
    expect(xlsxRenderer).toContain('#workbook-sheet-${index}:checked ~ .workbook-shell .workbook-sheet-panel[data-sheet-index="${index}"]');
    expect(xlsxRenderer).toContain('#workbook-sheet-${index}:checked ~ .workbook-shell .workbook-tab[data-sheet-index="${index}"]');
    expect(sharedViewer).toMatch(/\.office-viewer \{[^}]*height: 100%;[^}]*min-height: 100%/);
    expect(xlsxRenderer).toMatch(/\.workbook-reader, \.workbook-shell \{[^}]*width: 100%;[^}]*min-height: 100%/);
    expect(xlsxRenderer).toMatch(/\.workbook-header \{[^}]*width: 100vw;[^}]*min-width: 100vw;[^}]*min-height: 48px/);
    expect(xlsxRenderer).toMatch(/\.workbook-tabs \{[^}]*overflow-x: auto/);
    expect(xlsxRenderer).toMatch(/\.workbook-sheet-panel \{[^}]*display: none/);
    expect(xlsxRenderer).toMatch(/\.workbook-canvas \{[^}]*min-width: 100%;[^}]*min-height: calc\(100vh - 86px\)/);
    expect(xlsxRenderer).toMatch(/\.sheet-grid \{[^}]*min-width: 100%;[^}]*overflow: visible/);
    expect(xlsxRenderer).toMatch(/table \{[^}]*min-width: 100%;/);
  });

  it("renders PPTX as a centered desktop deck with a responsive all-slide stream", () => {
    expect(source).toContain("async function presentationSlideEntries");
    expect(source).toContain('endsWith("/notesSlide")');
    expect(source).toContain("finalPaths.map(async (path)");
    expect(pptxRenderer).toContain('type="radio" name="ppt-slide" id="ppt-slide-${index}"');
    expect(pptxRenderer).toContain('class="ppt-thumbnail" for="ppt-slide-${index}"');
    expect(pptxRenderer).toContain('<nav class="ppt-thumbnails" aria-label="Presentation slides">');
    expect(pptxRenderer).toContain('#ppt-slide-${index}:checked ~ .ppt-shell .ppt-slide-panel[data-slide-index="${index}"]');
    expect(pptxRenderer).toContain('#ppt-slide-${index}:checked ~ .ppt-shell .ppt-thumbnail[data-slide-index="${index}"]');
    expect(pptxRenderer).toContain('class="ppt-mobile-notes" aria-label="Speaker notes for slide ${index + 1}"');
    expect(pptxRenderer).toMatch(/\.ppt-workspace \{[^}]*grid-template-columns: 218px minmax\(0, 1fr\)/);
    expect(pptxRenderer).toMatch(/\.ppt-stage \{[^}]*justify-items: center;[^}]*align-content: start/);
    expect(pptxRenderer).toMatch(/\.ppt-slide-stack \{[^}]*place-items: center;[^}]*width: 100%/);
    expect(pptxRenderer).toMatch(/\.ppt-slide-stack \{[^}]*min-height: max\(calc\(540px \* var\(--document-page-scale, 1\)\), calc\(100vh - 260px\)\)/);
    expect(pptxRenderer).toMatch(/\.ppt-slide-panel \{[^}]*display: none;[^}]*justify-self: center/);
    expect(pptxRenderer).toContain('<div class="ppt-notes" aria-label="Speaker notes">');
    expect(pptxRenderer).toContain('class="ppt-notes-panel"');
    expect(pptxRenderer).toMatch(/\.ppt-notes \{[^}]*width: min\(960px, 100%\);[^}]*min-height: 136px/);
    expect(pptxRenderer).toMatch(/@media \(max-width: 760px\) \{[\s\S]*?\.ppt-toolbar \{ min-height: 46px; padding: 0 14px 0 var\(--office-leading-slot\); \}/);
    expect(pptxRenderer).toMatch(/@media \(max-width: 760px\) \{[\s\S]*?\.ppt-thumbnails, \.ppt-notes \{ display: none; \}/);
    expect(pptxRenderer).toMatch(/@media \(max-width: 760px\) \{[\s\S]*?\.ppt-slide-stack \{[^}]*display: grid;[^}]*gap: 18px;[^}]*place-items: center/);
    expect(pptxRenderer).toMatch(/@media \(max-width: 760px\) \{[\s\S]*?\.ppt-slide-panel \{ display: grid !important; grid-area: auto; width: 100%;/);
  });
});
