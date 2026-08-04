// @ts-check

const PREVIEW_GEOMETRY = Object.freeze({
  docx: { width: 816, height: 1056 },
  pptx: { width: 960, height: 540 },
  xlsx: { width: 1100, height: 760 },
});

const sharedDocumentCss = `
  * { box-sizing: border-box; }
  :root { --office-leading-slot: max(76px, calc(env(safe-area-inset-left) + 68px)); color-scheme: light; background: #fff; }
  html, body { width: 100%; height: 100%; min-height: 100%; margin: 0; color: #151718; background: #fff; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  body { overflow: hidden; scrollbar-width: none; }
  body::-webkit-scrollbar { display: none; width: 0; height: 0; }
  button, input { font: inherit; }
  a { color: inherit; }

  /* The two retained layers let the host fly the exact board preview into its
     reader without replacing the iframe. The host changes only this root data
     attribute after the shared-element motion has settled. */
  .office-viewer { position: relative; isolation: isolate; width: 100%; height: 100%; min-height: 100%; overflow: hidden; background: #fff; }
  .office-layer { position: absolute; inset: 0; width: 100%; height: 100%; min-height: 0; background: #fff; transition: opacity 120ms cubic-bezier(.22,.72,.18,1), visibility 0s linear 120ms; }
  .office-preview-layer { z-index: 2; overflow: hidden; opacity: 1; visibility: visible; pointer-events: none; transition-delay: 0s; }
  .office-preview-layer > * { transform: scale(var(--office-preview-scale, 1)); transform-origin: 0 0; }
  .office-reader-layer { z-index: 1; overflow: auto; overscroll-behavior: contain; opacity: 0; visibility: hidden; pointer-events: none; scrollbar-width: none; -webkit-overflow-scrolling: touch; }
  .office-reader-layer::-webkit-scrollbar { display: none; width: 0; height: 0; }
  html[data-view-mode="reader"] .office-preview-layer { opacity: 0; visibility: hidden; transition-delay: 0s, 120ms; }
  html[data-view-mode="reader"] .office-reader-layer { z-index: 3; opacity: 1; visibility: visible; pointer-events: auto; transition-delay: 0s; }

  .office-visually-hidden { position: absolute; width: 1px; height: 1px; margin: -1px; padding: 0; overflow: hidden; clip: rect(0 0 0 0); clip-path: inset(50%); border: 0; white-space: nowrap; }

  @media (prefers-reduced-motion: reduce) {
    .office-layer { transition: none; }
  }
`;

/** @param {unknown} value */
function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

/** @param {string} name */
function fileStem(name) {
  return String(name || "Untitled").replace(/\.[^.]+$/, "") || "Untitled";
}

/** @param {{title: string, head?: string, body: string, css?: string}} options */
function htmlDocument({ title, head = "", body, css = "" }) {
  return `<!doctype html><html data-office-viewer="true" data-view-mode="preview"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title)}</title>${head}<style>${sharedDocumentCss}${css}</style></head><body>${body}</body></html>`;
}

/** @param {string} preview @param {string} reader */
function officeLayers(preview, reader) {
  return `<main class="office-viewer"><section class="office-layer office-preview-layer" aria-label="Document preview">${preview}</section><section class="office-layer office-reader-layer" aria-label="Document reader">${reader}</section></main>`;
}

/** Give duplicated preview/thumbnail fragments isolated IDs and references. */
function prefixMarkupIds(markup, prefix) {
  const ids = new Set([...String(markup).matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]));
  if (!ids.size) return String(markup);
  return String(markup)
    .replace(/\bid="([^"]+)"/g, (_, id) => `id="${prefix}${id}"`)
    .replace(/\b(href|xlink:href)="#([^"]+)"/g, (match, attribute, id) => (
      ids.has(id) ? `${attribute}="#${prefix}${id}"` : match
    ))
    .replace(/url\(#([^)]+)\)/g, (match, id) => (ids.has(id) ? `url(#${prefix}${id})` : match))
    .replace(/\b(aria-labelledby|aria-describedby)="([^"]+)"/g, (_, attribute, value) => (
      `${attribute}="${value.split(/\s+/).map((id) => (ids.has(id) ? `${prefix}${id}` : id)).join(" ")}"`
    ));
}

function afterRenderFrame() {
  return new Promise((resolve) => {
    if (typeof requestAnimationFrame === "function") requestAnimationFrame(() => resolve());
    else setTimeout(resolve, 0);
  });
}

function cssLengthPixels(value, fallback) {
  const match = String(value || "").trim().match(/^(-?[\d.]+)\s*(px|pt|in|cm|mm)?$/i);
  if (!match) return fallback;
  const amount = Number(match[1]);
  if (!Number.isFinite(amount)) return fallback;
  const unit = (match[2] || "px").toLowerCase();
  const multiplier = { px: 1, pt: 96 / 72, in: 96, cm: 96 / 2.54, mm: 96 / 25.4 }[unit] || 1;
  return amount * multiplier;
}

/** @param {"docx" | "pptx" | "xlsx" | null | undefined} format */
export function officePreviewGeometry(format) {
  return PREVIEW_GEOMETRY[format] || { width: 960, height: 720 };
}

/** @param {import("../domain/types.js").AssetRecord} asset */
async function renderDocx(asset) {
  const { renderAsync } = await import("docx-preview");
  const body = document.createElement("div");
  const styles = document.createElement("div");
  await renderAsync(asset.blob, body, styles, {
    breakPages: true,
    ignoreLastRenderedPageBreak: false,
    renderAltChunks: false,
    renderComments: false,
    renderFootnotes: true,
    renderEndnotes: true,
    useBase64URL: true,
  });
  // docx-preview finalizes legacy VML geometry on its next animation frame.
  await afterRenderFrame();

  const pages = [...body.querySelectorAll("section.docx")];
  const pageEntries = pages.length
    ? pages.map((page) => ({
        markup: page.outerHTML,
        width: Math.max(1, Math.ceil(
          page.getBoundingClientRect().width
          || page.offsetWidth
          || cssLengthPixels(page.style.width, 816),
        )),
        height: Math.max(1, Math.ceil(
          page.getBoundingClientRect().height
          || page.offsetHeight
          || cssLengthPixels(page.style.minHeight || page.style.height, 1056),
        )),
      }))
    : [{ markup: body.innerHTML, width: 816, height: 1056 }];
  const firstPage = pageEntries[0];
  const previewScale = Math.min(1, 816 / firstPage.width, 1056 / firstPage.height);
  const previewMarkup = prefixMarkupIds(firstPage.markup, "office-preview-");
  const preview = `<div class="docx-preview"><div class="docx-wrapper docx-preview-page" style="--docx-preview-scale:${previewScale}">${previewMarkup}</div></div>`;
  const reader = `
    <div class="docx-reader">
      <header class="docx-toolbar" aria-label="Document information">
        <div class="office-file-identity"><strong>${escapeHtml(fileStem(asset.name))}</strong><span>DOCX</span></div>
        <span class="docx-page-count">${pageEntries.length} ${pageEntries.length === 1 ? "page" : "pages"}</span>
      </header>
      <div class="docx-wrapper docx-pages">${pageEntries.map(({ markup }) => markup).join("")}</div>
    </div>`;
  const css = `
    .docx-preview { width: 816px; height: 1056px; overflow: hidden; background: #fff; }
    .docx-preview-page { width: 816px; min-height: 1056px; background: #fff; }
    .docx-preview-page { margin: 0 !important; padding: 0 !important; background: #fff !important; }
    .docx-preview-page > section.docx, .docx-preview-page section.docx { margin: 0 !important; border: 0 !important; border-radius: 0 !important; box-shadow: none !important; transform: scale(var(--docx-preview-scale, 1)); transform-origin: 0 0; }

    .docx-reader { width: 100%; min-height: 100vh; padding-bottom: 112px; background: #fff; }
    .docx-toolbar { position: sticky; z-index: 20; top: 0; display: flex; align-items: center; justify-content: space-between; min-height: 52px; padding: 0 20px 0 var(--office-leading-slot); border-bottom: 1px solid #e8e9e7; color: #5f6364; background: rgba(255,255,255,.97); }
    .office-file-identity { display: flex; min-width: 0; align-items: baseline; gap: 10px; }
    .office-file-identity strong { overflow: hidden; color: #202223; font-size: 14px; font-weight: 620; text-overflow: ellipsis; white-space: nowrap; }
    .office-file-identity span, .docx-page-count { color: #8a8e8f; font-size: 12px; font-weight: 500; letter-spacing: .02em; }
    .docx-pages { display: grid !important; width: 100%; gap: 26px; justify-items: center; margin: 0 !important; padding: 28px max(20px, calc((100% - 816px) / 2)) !important; background: #fff !important; counter-reset: document-page; }
    .docx-pages > section.docx { flex: none !important; margin: 0 !important; overflow: visible !important; border: 1px solid #e3e5e2 !important; border-radius: 1px !important; background: #fff !important; box-shadow: 0 1px 2px rgba(23, 27, 25, .04), 0 8px 24px rgba(23, 27, 25, .055) !important; zoom: var(--document-page-scale, 1); counter-increment: document-page; }
    .docx-pages > :not(section.docx) { width: min(816px, 100%); background: #fff; }

    @media (max-width: 760px) {
      .docx-toolbar { min-height: 46px; padding-right: 14px; padding-left: var(--office-leading-slot); }
      .docx-pages { gap: 14px; padding: 16px 8px 96px; }
      .docx-pages > section.docx { box-shadow: 0 1px 2px rgba(23, 27, 25, .05) !important; }
    }
  `;
  const srcDoc = htmlDocument({
    title: asset.name,
    head: styles.innerHTML,
    body: officeLayers(preview, reader),
    css,
  });
  return {
    previewSrcDoc: srcDoc,
    fullSrcDoc: srcDoc,
    readerPageWidth: Math.max(...pageEntries.map(({ width }) => width)),
    ...officePreviewGeometry("docx"),
  };
}

function resolveZipPath(base, target) {
  if (String(target || "").startsWith("/")) return String(target).replace(/^\/+/, "");
  return `${base}/${target}`.split("/").reduce((parts, segment) => {
    if (!segment || segment === ".") return parts;
    if (segment === "..") parts.pop();
    else parts.push(segment);
    return parts;
  }, []).join("/");
}

/** Follow presentation.xml ordering and retain the speaker notes per slide. */
async function presentationSlideEntries(buffer, renderedSlides) {
  try {
    const { default: JSZip } = await import("jszip");
    const zip = await JSZip.loadAsync(buffer);
    const [presentationXml, relationshipsXml] = await Promise.all([
      zip.file("ppt/presentation.xml")?.async("string"),
      zip.file("ppt/_rels/presentation.xml.rels")?.async("string"),
    ]);
    const slidePaths = Object.keys(zip.files)
      .filter((path) => /^ppt\/slides\/slide\d+\.xml$/i.test(path))
      .sort((a, b) => Number(a.match(/slide(\d+)\.xml$/i)?.[1]) - Number(b.match(/slide(\d+)\.xml$/i)?.[1]));
    const fallbackEntries = renderedSlides.map((html, index) => ({ html, path: slidePaths[index], notes: "" }));
    if (!presentationXml || !relationshipsXml || typeof DOMParser === "undefined") return fallbackEntries;
    const parser = new DOMParser();
    const relationships = parser.parseFromString(relationshipsXml, "application/xml");
    const targets = new Map(
      [...relationships.getElementsByTagNameNS("*", "Relationship")]
        .map((node) => [node.getAttribute("Id"), resolveZipPath("ppt", node.getAttribute("Target"))]),
    );
    const presentation = parser.parseFromString(presentationXml, "application/xml");
    const orderedPaths = [...presentation.getElementsByTagNameNS("*", "sldId")]
      .map((node) => node.getAttribute("r:id") || node.getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "id"))
      .map((relationshipId) => targets.get(relationshipId))
      .filter((path) => slidePaths.includes(path));
    const seen = new Set(orderedPaths);
    const finalPaths = [...orderedPaths, ...slidePaths.filter((path) => !seen.has(path))];
    const htmlByPath = new Map(slidePaths.map((path, index) => [path, renderedSlides[index]]));
    return Promise.all(finalPaths.map(async (path) => {
      const relationPath = path.replace("ppt/slides/", "ppt/slides/_rels/") + ".rels";
      const relationXml = await zip.file(relationPath)?.async("string");
      let notes = "";
      if (relationXml) {
        const relationDocument = parser.parseFromString(relationXml, "application/xml");
        const notesRelation = [...relationDocument.getElementsByTagNameNS("*", "Relationship")]
          .find((node) => String(node.getAttribute("Type") || "").endsWith("/notesSlide"));
        const notesPath = notesRelation
          ? resolveZipPath("ppt/slides", notesRelation.getAttribute("Target"))
          : "";
        const notesXml = notesPath ? await zip.file(notesPath)?.async("string") : "";
        if (notesXml) {
          const notesDocument = parser.parseFromString(notesXml, "application/xml");
          notes = [...notesDocument.getElementsByTagNameNS("*", "t")]
            .map((node) => node.textContent?.trim())
            .filter(Boolean)
            .join(" ");
        }
      }
      return { html: htmlByPath.get(path) || "", path, notes };
    }));
  } catch {
    return renderedSlides.map((html) => ({ html, path: "", notes: "" }));
  }
}

/**
 * The PowerPoint parser does not currently expose notes XML. Keep a stable
 * notes region in the UI so presentations with no parsed notes still match a
 * familiar slide viewer without inventing document content.
 * @param {import("../domain/types.js").AssetRecord} asset
 */
async function renderPptx(asset) {
  const { pptxToHtml } = await import("@jvmr/pptx-to-html");
  const buffer = await asset.blob.arrayBuffer();
  const renderedSlides = await pptxToHtml(buffer, {
    width: 960,
    height: 540,
    scaleToFit: true,
    letterbox: true,
  });
  const slideEntries = await presentationSlideEntries(buffer, renderedSlides);
  const slides = slideEntries.map(({ html }) => html);
  if (!slides.length) throw new Error("This presentation does not contain any slides.");

  const inputs = slides.map((_, index) => `<input class="office-visually-hidden ppt-slide-state" type="radio" name="ppt-slide" id="ppt-slide-${index}" ${index === 0 ? "checked" : ""}>`).join("");
  const thumbnails = slides.map((slide, index) => `
    <label class="ppt-thumbnail" for="ppt-slide-${index}" data-slide-index="${index}" aria-label="Show slide ${index + 1}">
      <span class="ppt-thumbnail-number">${index + 1}</span>
      <span class="ppt-thumbnail-viewport"><span class="ppt-thumbnail-slide">${prefixMarkupIds(slide, `ppt-thumb-${index}-`)}</span></span>
    </label>`).join("");
  const panels = slideEntries.map(({ html: slide, notes }, index) => `
    <section class="ppt-slide-panel" data-slide-index="${index}" aria-label="Slide ${index + 1}">
      <div class="ppt-slide-frame"><div class="ppt-slide-visual">${prefixMarkupIds(slide, `ppt-panel-${index}-`)}</div></div>
      <div class="ppt-mobile-notes" aria-label="Speaker notes for slide ${index + 1}"><span>Speaker notes</span><p>${escapeHtml(notes || "No speaker notes")}</p></div>
    </section>`).join("");
  const notesPanels = slideEntries.map(({ notes }, index) => `<section class="ppt-notes-panel" data-slide-index="${index}" aria-label="Speaker notes for slide ${index + 1}"><span>Speaker notes</span><p>${escapeHtml(notes || "No speaker notes")}</p></section>`).join("");
  const currentSlides = slides.map((_, index) => `<span class="ppt-current-slide" data-slide-index="${index}">${index + 1}</span>`).join("");
  const activeSelectors = slides.map((_, index) => `
    #ppt-slide-${index}:checked ~ .ppt-shell .ppt-slide-panel[data-slide-index="${index}"] { display: block; }
    #ppt-slide-${index}:checked ~ .ppt-shell .ppt-notes-panel[data-slide-index="${index}"] { display: block; }
    #ppt-slide-${index}:checked ~ .ppt-shell .ppt-thumbnail[data-slide-index="${index}"] { border-color: #1677e8; background: #edf5ff; box-shadow: 0 0 0 1px #1677e8; }
    #ppt-slide-${index}:checked ~ .ppt-shell .ppt-current-slide[data-slide-index="${index}"] { display: inline; }
  `).join("");

  const preview = `<div class="ppt-preview"><div class="ppt-preview-slide">${prefixMarkupIds(slides[0], "ppt-preview-")}</div></div>`;
  const reader = `
    <div class="ppt-reader">
      ${inputs}
      <div class="ppt-shell">
        <header class="ppt-toolbar">
          <div class="office-file-identity"><strong>${escapeHtml(fileStem(asset.name))}</strong><span>PPTX</span></div>
          <div class="ppt-position" aria-live="polite">Slide ${currentSlides} of ${slides.length}</div>
        </header>
        <div class="ppt-workspace">
          <nav class="ppt-thumbnails" aria-label="Presentation slides">${thumbnails}</nav>
          <main class="ppt-stage">
            <div class="ppt-slide-stack">${panels}</div>
            <div class="ppt-notes" aria-label="Speaker notes">${notesPanels}</div>
          </main>
        </div>
      </div>
    </div>`;
  const css = `
    .ppt-preview { width: 960px; height: 540px; overflow: hidden; background: #fff; }
    .ppt-preview-slide { position: relative; width: 960px; height: 540px; overflow: hidden; background: #fff; }
    .ppt-preview-slide > * { margin: 0 !important; }

    .ppt-reader, .ppt-shell { width: 100%; height: 100%; min-height: 100%; background: #fff; }
    .ppt-toolbar { position: sticky; z-index: 10; top: 0; display: flex; align-items: center; justify-content: space-between; min-height: 52px; padding: 0 20px 0 var(--office-leading-slot); border-bottom: 1px solid #e8e9e7; background: rgba(255,255,255,.98); }
    .office-file-identity { display: flex; min-width: 0; align-items: baseline; gap: 10px; }
    .office-file-identity strong { overflow: hidden; color: #202223; font-size: 14px; font-weight: 620; text-overflow: ellipsis; white-space: nowrap; }
    .office-file-identity span, .ppt-position { color: #85898a; font-size: 12px; font-weight: 500; }
    .ppt-current-slide { display: none; }
    .ppt-workspace { display: grid; grid-template-columns: 218px minmax(0, 1fr); width: 100%; min-height: calc(100vh - 52px); align-items: start; overflow: visible; background: #fff; }
    .ppt-thumbnails { position: sticky; top: 52px; display: flex; height: calc(100vh - 52px); min-height: 0; flex-direction: column; gap: 16px; overflow: auto; padding: 20px 16px 112px; border-right: 1px solid #eceeeb; background: #fff; scrollbar-width: none; }
    .ppt-thumbnails::-webkit-scrollbar { display: none; }
    .ppt-thumbnail { display: grid; grid-template-columns: 20px 160px; gap: 9px; align-items: start; padding: 7px; border: 1px solid transparent; border-radius: 7px; background: #fff; cursor: pointer; transition: border-color 100ms ease, background-color 100ms ease, box-shadow 100ms ease; }
    .ppt-thumbnail:hover { background: #f6f7f5; }
    .ppt-thumbnail-number { padding-top: 2px; color: #4d5152; font-size: 12px; font-variant-numeric: tabular-nums; text-align: right; }
    .ppt-thumbnail-viewport { display: block; width: 160px; height: 90px; overflow: hidden; border: 1px solid #e0e3df; border-radius: 3px; background: #fff; box-shadow: 0 2px 8px rgba(22, 27, 25, .05); }
    .ppt-thumbnail-slide { display: block; width: 960px; height: 540px; transform: scale(.1666667); transform-origin: 0 0; pointer-events: none; }
    .ppt-thumbnail-slide > * { margin: 0 !important; }
    .ppt-stage { display: grid; min-width: 0; min-height: calc(100vh - 52px); justify-items: center; align-content: start; gap: 16px; overflow: visible; padding: 24px 36px 32px; background: #fff; scrollbar-width: none; }
    .ppt-stage::-webkit-scrollbar { display: none; }
    .ppt-slide-stack { display: grid; place-items: center; width: 100%; min-height: max(calc(540px * var(--document-page-scale, 1)), calc(100vh - 260px)); }
    .ppt-slide-panel { display: none; grid-area: 1 / 1; justify-self: center; }
    .ppt-slide-frame { position: relative; width: 960px; height: 540px; overflow: hidden; border: 1px solid #dfe2df; border-radius: 4px; background: #fff; box-shadow: 0 10px 28px rgba(21, 26, 24, .075); zoom: var(--document-page-scale, 1); }
    .ppt-slide-visual { position: relative; width: 960px; height: 540px; overflow: hidden; background: #fff; }
    .ppt-slide-visual > * { margin: 0 !important; }
    .slide-container { background-color: #fff !important; }
    .ppt-notes { width: min(960px, 100%); min-height: 136px; padding: 20px 22px; border: 1px solid #e3e5e2; border-radius: 12px; background: #fff; }
    .ppt-notes-panel { display: none; }
    .ppt-mobile-notes { display: none; }
    .ppt-notes span { color: #696d6e; font-size: 12px; font-weight: 600; }
    .ppt-notes p { margin: 18px 0 0; color: #777b7c; font-size: 13px; line-height: 1.5; }
    ${activeSelectors}

    @media (max-width: 760px) {
      .ppt-toolbar { min-height: 46px; padding: 0 14px 0 var(--office-leading-slot); }
      .ppt-thumbnails, .ppt-notes { display: none; }
      .ppt-workspace { display: block; min-height: calc(100vh - 46px); }
      .ppt-stage { display: block; min-height: calc(100vh - 46px); padding: 18px 8px 96px; }
      .ppt-slide-stack { display: grid; min-height: 0; gap: 18px; place-items: center; }
      .ppt-slide-panel { display: grid !important; grid-area: auto; width: 100%; justify-items: center; gap: 10px; }
      .ppt-mobile-notes { display: block; width: min(960px, 100%); padding: 12px 14px; border: 1px solid #eceeeb; border-radius: 6px; background: #fff; }
      .ppt-mobile-notes span { color: #696d6e; font-size: 11px; font-weight: 600; }
      .ppt-mobile-notes p { margin: 7px 0 0; color: #777b7c; font-size: 12px; line-height: 1.45; }
    }
  `;
  const srcDoc = htmlDocument({ title: asset.name, body: officeLayers(preview, reader), css });
  return {
    previewSrcDoc: srcDoc,
    fullSrcDoc: srcDoc,
    ...officePreviewGeometry("pptx"),
  };
}

/** @param {unknown} color */
function spreadsheetColor(color) {
  const value = String(color || "").replace(/^#/, "");
  if (!/^[0-9a-f]{6}([0-9a-f]{2})?$/i.test(value)) return "";
  return `#${value.slice(-6)}`;
}

function appendInlineStyle(tag, declarations) {
  if (!declarations) return tag;
  if (/\bstyle="/i.test(tag)) {
    return tag.replace(/\bstyle="([^"]*)"/i, (_, current) => `style="${current};${declarations}"`);
  }
  return tag.replace("<td", `<td style="${declarations}"`);
}

function spreadsheetBorder(edge) {
  if (!edge?.style) return "";
  const width = /medium|thick/i.test(edge.style) ? 2 : 1;
  const style = /dash/i.test(edge.style) ? "dashed" : /dot/i.test(edge.style) ? "dotted" : /double/i.test(edge.style) ? "double" : "solid";
  return `${width}px ${style} ${spreadsheetColor(edge.color?.rgb) || "#cfd3cf"}`;
}

function spreadsheetCellStyle(cell) {
  const style = cell?.s;
  if (!style || typeof style !== "object") return "";
  const declarations = [];
  const fillDefinition = style.fill || style;
  const fill = !fillDefinition.patternType || fillDefinition.patternType === "solid"
    ? spreadsheetColor(fillDefinition.fgColor?.rgb || fillDefinition.bgColor?.rgb)
    : "";
  if (fill) declarations.push(`background-color:${fill}`);
  const font = style.font || {};
  const fontColor = spreadsheetColor(font.color?.rgb);
  if (fontColor) declarations.push(`color:${fontColor}`);
  if (font.bold) declarations.push("font-weight:700");
  if (font.italic) declarations.push("font-style:italic");
  if (font.underline) declarations.push("text-decoration:underline");
  if (Number(font.sz)) declarations.push(`font-size:${Math.max(8, Number(font.sz))}pt`);
  if (font.name) declarations.push(`font-family:${String(font.name).replace(/["'<>]/g, "")},sans-serif`);
  const alignment = style.alignment || {};
  if (alignment.horizontal) declarations.push(`text-align:${alignment.horizontal === "centerContinuous" ? "center" : alignment.horizontal}`);
  if (alignment.vertical) declarations.push(`vertical-align:${alignment.vertical}`);
  if (alignment.wrapText) declarations.push("white-space:pre-wrap");
  const border = style.border || {};
  for (const [edge, property] of [["top", "border-top"], ["right", "border-right"], ["bottom", "border-bottom"], ["left", "border-left"]]) {
    const value = spreadsheetBorder(border[edge]);
    if (value) declarations.push(`${property}:${value}`);
  }
  return declarations.join(";");
}

/** @param {Record<string, any>} sheet @param {number} index */
function applySpreadsheetStyles(table, sheet, index, styleMap) {
  return table.replace(/<td\b[^>]*\bid="([^"]+)"[^>]*>/g, (tag, id) => {
    const prefix = `sheet-${index}-`;
    if (!String(id).startsWith(prefix)) return tag;
    const reference = String(id).slice(prefix.length);
    const cell = sheet[reference];
    const resolvedStyle = styleMap?.get(reference) || cell?.s;
    return appendInlineStyle(tag, spreadsheetCellStyle({ s: resolvedStyle }));
  });
}

/** @param {any} XLSX @param {Record<string, any>} sheet @param {number} index @param {string} name */
function renderSpreadsheetTable(XLSX, sheet, index, name, styleMap) {
  if (!sheet?.["!ref"]) {
    return `<table id="sheet-${index}" aria-label="${escapeHtml(name)}"><thead><tr><th class="sheet-corner"></th><th class="column-heading">A</th></tr></thead><tbody><tr><th class="row-heading">1</th><td></td></tr></tbody></table>`;
  }
  const range = XLSX.utils.decode_range(sheet["!ref"]);
  const exported = XLSX.utils.sheet_to_html(sheet, {
    id: `sheet-${index}`,
    editable: false,
    header: "",
    footer: "",
  });
  const rawRows = exported.match(/<tr>[\s\S]*?<\/tr>/g) || [];
  const rows = rawRows.map((row, rowIndex) => {
    const rowMeta = sheet["!rows"]?.[range.s.r + rowIndex];
    const rowStyles = [
      rowMeta?.hidden ? "display:none" : "",
      Number(rowMeta?.hpx) ? `height:${Math.max(18, Number(rowMeta.hpx))}px` : "",
      Number(rowMeta?.hpt) ? `height:${Math.max(18, Number(rowMeta.hpt) * 1.333)}px` : "",
    ].filter(Boolean).join(";");
    const opening = rowStyles ? `<tr style="${rowStyles}">` : "<tr>";
    return row.replace("<tr>", `${opening}<th class="row-heading" scope="row">${range.s.r + rowIndex + 1}</th>`);
  }).join("");
  const headings = Array.from(
    { length: range.e.c - range.s.c + 1 },
    (_, offset) => `<th class="column-heading" scope="col">${escapeHtml(XLSX.utils.encode_col(range.s.c + offset))}</th>`,
  ).join("");
  const columns = Array.from(
    { length: range.e.c - range.s.c + 1 },
    (_, offset) => {
      const column = sheet["!cols"]?.[range.s.c + offset];
      const width = Math.max(72, Math.min(360, Number(column?.wpx) || (Number(column?.wch) || 13) * 7.2));
      return `<col style="width:${width}px;${column?.hidden ? "display:none" : ""}">`;
    },
  ).join("");
  const table = `<table id="sheet-${index}" aria-label="${escapeHtml(name)}"><colgroup><col class="row-number-column">${columns}</colgroup><thead><tr><th class="sheet-corner"></th>${headings}</tr></thead><tbody>${rows}</tbody></table>`;
  return applySpreadsheetStyles(table, sheet, index, styleMap);
}

function directXmlChildren(node, localName) {
  return [...(node?.children || [])].filter((child) => !localName || child.localName === localName);
}

function directXmlChild(node, localName) {
  return directXmlChildren(node, localName)[0] || null;
}

const SPREADSHEET_INDEXED_COLORS = [
  "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
  "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
];

function spreadsheetXmlColor(node, themeColors) {
  if (!node) return "";
  const rgb = node.getAttribute("rgb");
  if (rgb) return spreadsheetColor(rgb);
  const theme = Number(node.getAttribute("theme"));
  if (Number.isInteger(theme) && themeColors[theme]) return themeColors[theme];
  const indexed = Number(node.getAttribute("indexed"));
  if (Number.isInteger(indexed) && SPREADSHEET_INDEXED_COLORS[indexed]) {
    return `#${SPREADSHEET_INDEXED_COLORS[indexed]}`;
  }
  return "";
}

function spreadsheetThemeColors(themeDocument) {
  const scheme = themeDocument?.getElementsByTagNameNS("*", "clrScheme")?.[0];
  if (!scheme) return [];
  const byName = new Map(directXmlChildren(scheme).map((entry) => {
    const color = directXmlChildren(entry)[0];
    return [entry.localName, spreadsheetColor(color?.getAttribute("val") || color?.getAttribute("lastClr"))];
  }));
  return [
    byName.get("dk1"), byName.get("lt1"), byName.get("dk2"), byName.get("lt2"),
    byName.get("accent1"), byName.get("accent2"), byName.get("accent3"),
    byName.get("accent4"), byName.get("accent5"), byName.get("accent6"),
    byName.get("hlink"), byName.get("folHlink"),
  ];
}

function spreadsheetStyleDefinitions(stylesDocument, themeColors) {
  const fontsRoot = stylesDocument?.getElementsByTagNameNS("*", "fonts")?.[0];
  const fillsRoot = stylesDocument?.getElementsByTagNameNS("*", "fills")?.[0];
  const bordersRoot = stylesDocument?.getElementsByTagNameNS("*", "borders")?.[0];
  const xfsRoot = stylesDocument?.getElementsByTagNameNS("*", "cellXfs")?.[0];
  const fonts = directXmlChildren(fontsRoot, "font").map((font) => ({
    name: directXmlChild(font, "name")?.getAttribute("val") || "",
    sz: Number(directXmlChild(font, "sz")?.getAttribute("val")) || 0,
    bold: Boolean(directXmlChild(font, "b")),
    italic: Boolean(directXmlChild(font, "i")),
    underline: Boolean(directXmlChild(font, "u")),
    color: { rgb: spreadsheetXmlColor(directXmlChild(font, "color"), themeColors) },
  }));
  const fills = directXmlChildren(fillsRoot, "fill").map((fill) => {
    const pattern = directXmlChild(fill, "patternFill");
    return {
      patternType: pattern?.getAttribute("patternType") || "",
      fgColor: { rgb: spreadsheetXmlColor(directXmlChild(pattern, "fgColor"), themeColors) },
      bgColor: { rgb: spreadsheetXmlColor(directXmlChild(pattern, "bgColor"), themeColors) },
    };
  });
  const borders = directXmlChildren(bordersRoot, "border").map((border) => Object.fromEntries(
    ["top", "right", "bottom", "left"].map((edgeName) => {
      const edge = directXmlChild(border, edgeName);
      return [edgeName, {
        style: edge?.getAttribute("style") || "",
        color: { rgb: spreadsheetXmlColor(directXmlChild(edge, "color"), themeColors) },
      }];
    }),
  ));
  return directXmlChildren(xfsRoot, "xf").map((xf) => {
    const alignment = directXmlChild(xf, "alignment");
    return {
      font: fonts[Number(xf.getAttribute("fontId"))] || {},
      fill: fills[Number(xf.getAttribute("fillId"))] || {},
      border: borders[Number(xf.getAttribute("borderId"))] || {},
      alignment: alignment ? {
        horizontal: alignment.getAttribute("horizontal") || "",
        vertical: alignment.getAttribute("vertical") || "",
        wrapText: alignment.getAttribute("wrapText") === "1",
      } : {},
    };
  });
}

async function spreadsheetStyleMaps(buffer) {
  try {
    const { default: JSZip } = await import("jszip");
    const zip = await JSZip.loadAsync(buffer);
    if (typeof DOMParser === "undefined") return new Map();
    const parser = new DOMParser();
    const [stylesXml, themeXml, workbookXml, relationshipsXml] = await Promise.all([
      zip.file("xl/styles.xml")?.async("string"),
      zip.file("xl/theme/theme1.xml")?.async("string"),
      zip.file("xl/workbook.xml")?.async("string"),
      zip.file("xl/_rels/workbook.xml.rels")?.async("string"),
    ]);
    if (!stylesXml || !workbookXml || !relationshipsXml) return new Map();
    const themeColors = themeXml
      ? spreadsheetThemeColors(parser.parseFromString(themeXml, "application/xml"))
      : [];
    const definitions = spreadsheetStyleDefinitions(
      parser.parseFromString(stylesXml, "application/xml"),
      themeColors,
    );
    const relationshipDocument = parser.parseFromString(relationshipsXml, "application/xml");
    const relationshipTargets = new Map(
      [...relationshipDocument.getElementsByTagNameNS("*", "Relationship")]
        .map((node) => [node.getAttribute("Id"), resolveZipPath("xl", node.getAttribute("Target"))]),
    );
    const workbookDocument = parser.parseFromString(workbookXml, "application/xml");
    const sheets = [...workbookDocument.getElementsByTagNameNS("*", "sheet")];
    const maps = new Map();
    await Promise.all(sheets.map(async (sheet) => {
      const name = sheet.getAttribute("name") || "";
      const relationshipId = sheet.getAttribute("r:id")
        || sheet.getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "id");
      const path = relationshipTargets.get(relationshipId);
      const xml = path ? await zip.file(path)?.async("string") : "";
      if (!xml) return;
      const sheetDocument = parser.parseFromString(xml, "application/xml");
      const styleMap = new Map();
      for (const cell of sheetDocument.getElementsByTagNameNS("*", "c")) {
        const reference = cell.getAttribute("r");
        const style = definitions[Number(cell.getAttribute("s"))];
        if (reference && style) styleMap.set(reference, style);
      }
      maps.set(name, styleMap);
    }));
    return maps;
  } catch {
    return new Map();
  }
}

/** @param {import("../domain/types.js").AssetRecord} asset */
async function renderXlsx(asset) {
  const module = await import("xlsx");
  const XLSX = module.default || module;
  const buffer = await asset.blob.arrayBuffer();
  const workbook = XLSX.read(buffer, {
    type: "array",
    cellDates: true,
    cellStyles: true,
  });
  if (!workbook.SheetNames.length) throw new Error("This workbook does not contain any sheets.");

  const styleMaps = await spreadsheetStyleMaps(buffer);
  const sheetTables = workbook.SheetNames.map((name, index) => renderSpreadsheetTable(
    XLSX,
    workbook.Sheets[name],
    index,
    name,
    styleMaps.get(name),
  ));
  const inputs = workbook.SheetNames.map((_, index) => `<input class="office-visually-hidden workbook-sheet-state" type="radio" name="workbook-sheet" id="workbook-sheet-${index}" ${index === 0 ? "checked" : ""}>`).join("");
  const tabs = workbook.SheetNames.map((name, index) => `<label class="workbook-tab" data-sheet-index="${index}" for="workbook-sheet-${index}" title="${escapeHtml(name)}">${escapeHtml(name)}</label>`).join("");
  const formulaNames = workbook.SheetNames.map((name, index) => `<span class="formula-sheet-name" data-sheet-index="${index}">${escapeHtml(name)}</span>`).join("");
  const panels = sheetTables.map((table, index) => `<section class="workbook-sheet-panel" data-sheet-index="${index}" aria-label="${escapeHtml(workbook.SheetNames[index])}"><div class="sheet-grid">${table}</div></section>`).join("");
  const activeSelectors = workbook.SheetNames.map((_, index) => `
    #workbook-sheet-${index}:checked ~ .workbook-shell .workbook-sheet-panel[data-sheet-index="${index}"] { display: block; }
    #workbook-sheet-${index}:checked ~ .workbook-shell .workbook-tab[data-sheet-index="${index}"] { color: #232627; background: #eff0ee; }
    #workbook-sheet-${index}:checked ~ .workbook-shell .formula-sheet-name[data-sheet-index="${index}"] { display: inline; }
  `).join("");

  const preview = `<div class="workbook-preview"><div class="sheet-grid">${prefixMarkupIds(sheetTables[0], "workbook-preview-")}</div></div>`;
  const reader = `
    <div class="workbook-reader">
      ${inputs}
      <div class="workbook-shell">
        <header class="workbook-header">
          <div class="office-file-identity"><strong>${escapeHtml(fileStem(asset.name))}</strong><span>XLSX</span></div>
          <nav class="workbook-tabs" aria-label="Workbook sheets">${tabs}</nav>
          <span class="workbook-zoom">100%</span>
        </header>
        <div class="formula-bar" aria-label="Formula bar"><span class="cell-reference">A1</span><span class="formula-symbol" aria-hidden="true">fx</span><strong>${formulaNames}</strong></div>
        <main class="workbook-canvas">${panels}</main>
      </div>
    </div>`;
  const css = `
    .workbook-preview { width: 1100px; height: 760px; overflow: hidden; background: #fff; }
    .workbook-reader, .workbook-shell { width: 100%; min-width: 100%; min-height: 100%; background: #fff; }
    .workbook-header { position: sticky; z-index: 20; top: 0; left: 0; display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; width: 100vw; min-width: 100vw; min-height: 48px; padding-left: var(--office-leading-slot); border-bottom: 1px solid #e5e7e4; background: rgba(255,255,255,.98); }
    .office-file-identity { display: flex; min-width: 220px; align-items: baseline; gap: 10px; padding: 0 18px; border-right: 1px solid #eceeeb; }
    .office-file-identity strong { overflow: hidden; max-width: 220px; color: #202223; font-size: 14px; font-weight: 620; text-overflow: ellipsis; white-space: nowrap; }
    .office-file-identity span, .workbook-zoom { color: #898d8e; font-size: 12px; font-weight: 500; }
    .workbook-tabs { display: flex; min-width: 0; height: 48px; align-items: center; gap: 4px; overflow-x: auto; overflow-y: hidden; padding: 0 14px; scrollbar-width: none; }
    .workbook-tabs::-webkit-scrollbar { display: none; }
    .workbook-tab { overflow: hidden; max-width: 180px; padding: 8px 12px; border-radius: 9px; color: #6c7071; font-size: 13px; font-weight: 530; text-overflow: ellipsis; white-space: nowrap; cursor: pointer; transition: color 100ms ease, background-color 100ms ease; }
    .workbook-tab:hover { color: #303334; background: #f5f6f4; }
    .workbook-zoom { padding: 0 18px; }
    .formula-bar { position: sticky; z-index: 19; top: 48px; left: 0; display: grid; grid-template-columns: 58px 44px minmax(0, 1fr); width: 100vw; min-width: 100vw; min-height: 38px; align-items: center; border-bottom: 1px solid #e5e7e4; background: rgba(255,255,255,.98); }
    .formula-bar > * { min-height: 38px; display: flex; align-items: center; padding: 0 14px; }
    .cell-reference, .formula-symbol { border-right: 1px solid #eceeeb; color: #777b7c; font-size: 12px; }
    .formula-symbol { justify-content: center; color: #a3a6a6; font-family: Georgia, serif; font-size: 15px; font-style: italic; }
    .formula-bar strong { color: #343738; font-size: 13px; font-weight: 520; }
    .formula-sheet-name { display: none; }
    .workbook-canvas { display: grid; min-width: 100%; min-height: calc(100vh - 86px); align-content: start; background: #fff; padding-bottom: 108px; }
    .workbook-sheet-panel { display: none; grid-area: 1 / 1; width: max-content; min-width: 100%; }
    .sheet-grid { width: max-content; min-width: 100%; overflow: visible; background: #fff; }
    table { width: max-content; min-width: 100%; border-spacing: 0; border-collapse: separate; table-layout: fixed; color: #222526; background: #fff; font-size: 13px; }
    .row-number-column { width: 48px; }
    th, td { height: 30px; padding: 5px 8px; overflow: hidden; border-right: 1px solid #e1e4e0; border-bottom: 1px solid #e1e4e0; text-overflow: ellipsis; white-space: pre-wrap; vertical-align: middle; }
    thead th { height: 30px; color: #515657; background: #f3f5f2; font-weight: 540; text-align: center; }
    .sheet-corner, .row-heading { width: 48px; min-width: 48px; color: #737879; background: #f6f7f5; font-weight: 500; text-align: center; font-variant-numeric: tabular-nums; }
    tbody td { min-width: 72px; }
    tbody td[data-t="n"], tbody td[data-t="d"] { text-align: right; font-variant-numeric: tabular-nums; }
    tbody tr:first-child td { font-weight: 620; }
    ${activeSelectors}

    @media (max-width: 700px) {
      .workbook-header { grid-template-columns: auto minmax(0, 1fr); }
      .office-file-identity { min-width: 0; padding-inline: 12px; }
      .office-file-identity strong { max-width: 132px; }
      .workbook-tabs { padding-inline: 8px; }
      .workbook-tab { max-width: 116px; padding-inline: 9px; }
      .workbook-zoom { display: none; }
    }
  `;
  const srcDoc = htmlDocument({ title: asset.name, body: officeLayers(preview, reader), css });
  return {
    previewSrcDoc: srcDoc,
    fullSrcDoc: srcDoc,
    ...officePreviewGeometry("xlsx"),
  };
}

/**
 * Convert a device-local Office asset into an isolated retained iframe. The
 * source is stable from board preview through fullscreen; the host changes
 * `documentElement.dataset.viewMode` between `preview` and `reader`.
 *
 * @param {import("../domain/types.js").AssetRecord} asset
 * @param {"docx" | "pptx" | "xlsx"} format
 */
export async function renderOfficeDocument(asset, format) {
  if (!asset?.blob) throw new Error("The imported file is no longer available on this device.");
  if (format === "docx") return renderDocx(asset);
  if (format === "pptx") return renderPptx(asset);
  if (format === "xlsx") return renderXlsx(asset);
  throw new TypeError(`Unsupported Office format: ${String(format)}`);
}
