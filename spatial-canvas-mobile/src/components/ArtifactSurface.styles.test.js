import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const css = readFileSync(new URL("../styles.css", import.meta.url), "utf8");
const app = readFileSync(new URL("../App.jsx", import.meta.url), "utf8");
const documentSurface = readFileSync(new URL("./DocumentAssetSurface.jsx", import.meta.url), "utf8");
const itemCard = readFileSync(new URL("./ItemCard.jsx", import.meta.url), "utf8");
const sharedViewer = readFileSync(new URL("./SharedItemViewer.jsx", import.meta.url), "utf8");
const chrome = readFileSync(new URL("./Chrome.jsx", import.meta.url), "utf8");
const overlay = readFileSync(new URL("./ArtifactTitleOverlay.jsx", import.meta.url), "utf8");

function rulesFor(selector) {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const matches = [...css.matchAll(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`, "g"))];
  return matches.map((match) => match[1]).join("\n");
}

describe("full-bleed artifact surfaces", () => {
  it("keeps the document metadata on the board but removes it from fullscreen", () => {
    expect(documentSurface).toContain("<ArtifactTitleOverlay");
    expect(documentSurface).toContain("visible={!detailPresent}");
    expect(sharedViewer).toContain("<ArtifactTitleOverlay");
    expect(itemCard).not.toContain("<ArtifactTitleOverlay");
    expect(overlay).toContain('aria-hidden="true"');
    expect(overlay).toContain("tone-${tone");

    const declarations = rulesFor(".artifact-title-overlay");
    expect(declarations).toContain("position: absolute");
    expect(declarations).toContain("bottom: 0");
    expect(declarations).toContain("linear-gradient");
    expect(declarations).toContain("pointer-events: none");
  });

  it("keeps the web screenshot full bleed and moves its action to viewport chrome", () => {
    expect(rulesFor(".shared-web-surface .web-preview")).toContain("display: block");
    const shot = rulesFor(".shared-web-surface .web-preview-shot");
    expect(shot).toContain("position: absolute");
    expect(shot).toContain("inset: 0");
    expect(itemCard).not.toContain('className="web-copy"');
    expect(sharedViewer).toContain("<ArtifactTitleOverlay title={domain}");
    expect(sharedViewer).toContain("visible={!detailPresent}");
    expect(sharedViewer).not.toContain('className="web-open-source"');
    expect(sharedViewer).toContain('aria-label="Open original"');
    expect(sharedViewer).toContain("createPortal(");
    expect(sharedViewer).not.toContain("eyebrow={domain}");

    const webTitle = rulesFor(".shared-web-stage .artifact-title-overlay strong");
    expect(webTitle).toContain("max-width: none");
    expect(webTitle).toContain("overflow-wrap: anywhere");
    expect(webTitle).toContain("white-space: normal");
  });

  it("preserves the retained cached web capture path", () => {
    for (const contract of [
      "screenshotAssetId",
      "loadAsset",
      "URL.createObjectURL",
      "screenshotCandidatesForItem",
      "tryNextCandidate",
      "onScreenshotResolved",
      "loadedScreenshot",
      "candidates.indexOf(loadedScreenshot)",
    ]) {
      expect(itemCard).toContain(contract);
    }
    expect(itemCard).not.toContain("if (assetPending) return []");
    expect(itemCard).toContain("readyAssetIndex");
    expect(itemCard).toContain("!item.screenshotAssetId");
    expect(app).toContain("needsWebClipScreenshotCache(sourceItem, screenshotUrl)");
    expect(app).toContain("needsWebClipScreenshotCache(currentItem, resolvedUrl)");
  });

  it("keeps Google consent interactive only in detail with a board fallback", () => {
    expect(documentSurface).toContain("allow-storage-access-by-user-activation");
    expect(documentSurface).toContain("isGoogle && !detailReady && !item.published");
    expect(documentSurface).toContain('className="google-document-gate"');
    expect(documentSurface).not.toContain("document-open-source");
    expect(sharedViewer).toContain("item.sourceUrl");
  });

  it("retains one permanent Office document while its presentation mode changes", () => {
    expect(documentSurface).toContain("const srcDoc = rendered?.fullSrcDoc");
    expect(documentSurface).toContain("srcDoc={srcDoc}");
    expect(documentSurface).not.toContain("previewSrcDoc");
    expect(documentSurface).not.toContain("showFullDocument");
    expect(documentSurface).not.toContain("fullDocumentReady");
    expect(documentSurface.match(/srcDoc=\{srcDoc\}/g)).toHaveLength(1);
  });

  it("synchronously sets the retained frame's semantic view mode", () => {
    expect(documentSurface).toContain("useLayoutEffect");
    expect(documentSurface).toContain("root.dataset.viewMode = desiredViewMode");
    expect(documentSurface).toContain("root.dataset.documentFormat = format");
    expect(documentSurface).toContain("root.dataset.documentLayout = layout");
    expect(documentSurface).toContain('root.dataset.interactive = interactive ? "true" : "false"');
    expect(documentSurface).toContain("setFrameViewMode(frame)");
    expect(documentSurface).toContain("setFrameViewMode(event.currentTarget)");
  });

  it("installs retained fullscreen bounds for the whole FLIP and reveals the reader only after settle", () => {
    expect(documentSurface).toContain(
      "(!isGoogle && detailPresent)",
    );
    expect(documentSurface).toContain("(isGoogle && detailReady && detailOpen)");
    expect(documentSurface).toContain(
      'const desiredViewMode = detailReady && detailOpen ? "reader" : "preview"',
    );
    expect(documentSurface).toContain(
      '${desiredViewMode === "reader" ? "is-reader" : "is-preview"}',
    );
    expect(documentSurface).toContain('${detailShellActive ? "is-detail-shell" : "is-board-shell"}');
    expect(documentSurface).toContain('width: detailShellActive ? "100%" : assetMotion?.baseWidth');
    expect(documentSurface).toContain('scale: detailShellActive ? 1 : assetMotion?.scale');
    expect(documentSurface).toContain('root.style.setProperty("--office-preview-scale"');
    expect(documentSurface).toContain('data-view-mode={desiredViewMode}');
    expect(documentSurface).not.toContain('readerLayoutActive');
  });

  it("exposes stable format and layout semantics for every Office surface", () => {
    for (const contract of [
      'docx: "pages"',
      'xlsx: "workbook"',
      'pptx: "slides"',
      'drive: "embedded"',
      'docx: "is-paginated-document"',
      'xlsx: "is-spreadsheet-workbook"',
      'pptx: "is-slide-deck"',
      'drive: "is-google-document"',
      "format-${format}",
      "layout-${layout}",
      "data-document-format={format}",
      "data-document-layout={layout}",
    ]) {
      expect(documentSurface).toContain(contract);
    }
    expect(documentSurface).toContain("${semanticClass}");
  });

  it("keeps the stage and retained surface solid white in every phase", () => {
    expect(documentSurface.match(/backgroundColor: "#fff"/g)).toHaveLength(2);
    expect(rulesFor(".document-asset-frame")).toContain("background: #fff");
  });

  it("integrates the app back action into the pinned Office header", () => {
    expect(app).toContain("integratedDetailHeader={integratedDetailHeader}");
    expect(chrome).toContain("integratedDetailHeader = false");
    expect(chrome).toContain("is-integrated-detail-header");
    expect(documentSurface).toContain('"--office-leading-slot"');
    expect(documentSurface).toContain("platformBridge.isElectron");

    const header = rulesFor(".chrome-top-left.is-integrated-detail-header");
    expect(header).toContain("top: 0");
    expect(header).toContain("height: 52px");
    const back = rulesFor(".chrome-top-left.is-integrated-detail-header .back-button");
    expect(back).toContain("border-radius: 0");
    expect(back).toContain("box-shadow: none");
  });

  it("fits mobile slide streams by width instead of viewport height", () => {
    expect(documentSurface).toContain("const compact = frame.clientWidth <= 760");
    expect(documentSurface).toContain('format === "pptx"');
    expect(documentSurface).toContain("compact\n              ? maximumScale");
  });

  it("reveals the frame only when ready and gates pointer input consistently", () => {
    expect(documentSurface).toContain(
      "const interactive = Boolean(detailReady && detailOpen && surfaceReady)",
    );
    expect(documentSurface.match(/opacity: surfaceReady \? 1 : 0/g)).toHaveLength(2);
    expect(documentSurface.match(/pointerEvents: interactive \? "auto" : "none"/g)).toHaveLength(2);
    expect(documentSurface.match(/tabIndex=\{interactive \? 0 : -1\}/g)).toHaveLength(2);
    expect(documentSurface.match(/aria-hidden=\{interactive \? undefined : true\}/g)).toHaveLength(2);
    expect(documentSurface).toContain("inert={interactive ? undefined : true}");
  });

  it("selects title contrast from rendered artifact content", () => {
    expect(itemCard).toContain("sampleImageBottomTone");
    expect(documentSurface).toContain("inspectIframeBottomTone");
    expect(sharedViewer).toContain("onToneChange={setOverlayTone}");
    expect(rulesFor(".artifact-title-overlay.tone-dark")).toContain("rgba(10, 12, 13, 0.66)");
  });
});
