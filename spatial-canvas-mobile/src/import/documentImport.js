// @ts-check

/** @typedef {"docx" | "pptx" | "xlsx"} OfficeDocumentFormat */
/** @typedef {"document" | "presentation" | "spreadsheet" | "drive"} GoogleWorkspaceKind */

export const OFFICE_DOCUMENT_MIME_TYPES = Object.freeze({
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
});

export const DOCUMENT_FILE_ACCEPT = [
  ".docx",
  ".pptx",
  ".xlsx",
  ...Object.values(OFFICE_DOCUMENT_MIME_TYPES),
].join(",");

const FORMAT_LABELS = Object.freeze({
  docx: "Word document",
  pptx: "PowerPoint presentation",
  xlsx: "Excel workbook",
});

const GOOGLE_KIND_CONFIG = Object.freeze({
  document: { pathKind: "document", format: "docx", label: "Google Docs", title: "Google document" },
  presentation: { pathKind: "presentation", format: "pptx", label: "Google Slides", title: "Google presentation" },
  spreadsheet: { pathKind: "spreadsheets", format: "xlsx", label: "Google Sheets", title: "Google spreadsheet" },
});

const FORMAT_BY_MIME = new Map(
  Object.entries(OFFICE_DOCUMENT_MIME_TYPES).map(([format, mimeType]) => [mimeType, format]),
);

/** @param {unknown} value */
function normalizedMimeType(value) {
  return typeof value === "string" ? value.split(";", 1)[0].trim().toLowerCase() : "";
}

/** @param {unknown} value */
function fileExtension(value) {
  if (typeof value !== "string") return "";
  const normalized = value.replaceAll("\\", "/").split("/").pop() || "";
  const match = normalized.toLowerCase().match(/\.([a-z0-9]+)$/);
  return match?.[1] || "";
}

/**
 * Browser supplied MIME types are frequently blank or `application/octet-stream`,
 * so a supported extension is authoritative unless a specific supported Office
 * MIME type contradicts it.
 *
 * @param {{name?: unknown, type?: unknown} | null | undefined} fileLike
 * @returns {OfficeDocumentFormat | null}
 */
export function detectOfficeDocumentFormat(fileLike) {
  const extension = fileExtension(fileLike?.name);
  const extensionFormat = extension === "docx" || extension === "pptx" || extension === "xlsx"
    ? extension
    : null;
  const mimeFormat = /** @type {OfficeDocumentFormat | undefined} */ (
    FORMAT_BY_MIME.get(normalizedMimeType(fileLike?.type))
  ) || null;

  if (extensionFormat && mimeFormat && extensionFormat !== mimeFormat) return null;
  return extensionFormat || mimeFormat;
}

/** @param {string} fileName */
function titleFromFileName(fileName) {
  const leaf = fileName.replaceAll("\\", "/").split("/").pop()?.trim() || "";
  return leaf.replace(/\.(docx|pptx|xlsx)$/i, "").trim() || "Untitled document";
}

/** @param {URLSearchParams} source @param {URLSearchParams} target */
function retainGoogleAccessParams(source, target) {
  for (const key of ["resourcekey", "gid"]) {
    const value = source.get(key);
    if (value) target.set(key, value);
  }
}

/** @param {URL} url */
function googleFileIdFromPath(url) {
  const segments = url.pathname.split("/").filter(Boolean);
  const dIndex = segments.lastIndexOf("d");
  if (dIndex >= 0 && segments[dIndex + 1] === "e" && segments[dIndex + 2]) {
    return segments[dIndex + 2];
  }
  if (dIndex >= 0 && segments[dIndex + 1]) return segments[dIndex + 1];
  return url.searchParams.get("id") || "";
}

/** @param {string} value */
function safeGoogleFileId(value) {
  return /^[A-Za-z0-9_-]{6,}$/.test(value) ? value : "";
}

/**
 * Parse share/preview URLs from Google Docs, Slides, Sheets, and Drive without
 * granting arbitrary hosts iframe privileges.
 *
 * @param {unknown} value
 * @returns {{
 *   provider: "google",
 *   workspaceKind: GoogleWorkspaceKind,
 *   fileId: string,
 *   format: OfficeDocumentFormat | null,
 *   sourceUrl: string,
 *   previewUrl: string,
 *   published: boolean,
 * } | null}
 */
export function parseGoogleWorkspaceUrl(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 4096) return null;

  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.protocol !== "https:") return null;

  if (url.hostname === "docs.google.com") {
    const segments = url.pathname.split("/").filter(Boolean);
    const first = segments[0];
    const entry = first === "document"
      ? GOOGLE_KIND_CONFIG.document
      : first === "presentation"
        ? GOOGLE_KIND_CONFIG.presentation
        : first === "spreadsheets"
          ? GOOGLE_KIND_CONFIG.spreadsheet
          : null;
    if (!entry) return null;

    const fileId = safeGoogleFileId(googleFileIdFromPath(url));
    if (!fileId) return null;
    const published = segments.includes("e") && segments.includes("pub");
    const preview = published
      ? new URL(`https://docs.google.com/${entry.pathKind}/d/e/${fileId}/pub`)
      : new URL(`https://docs.google.com/${entry.pathKind}/d/${fileId}/preview`);
    retainGoogleAccessParams(url.searchParams, preview.searchParams);
    retainGoogleAccessParams(new URLSearchParams(url.hash.replace(/^#/, "")), preview.searchParams);
    if (published) preview.searchParams.set("embedded", "true");

    const workspaceKind = /** @type {Exclude<GoogleWorkspaceKind, "drive">} */ (
      first === "document" ? "document" : first === "presentation" ? "presentation" : "spreadsheet"
    );
    return {
      provider: "google",
      workspaceKind,
      fileId,
      format: /** @type {OfficeDocumentFormat} */ (entry.format),
      sourceUrl: url.toString(),
      previewUrl: preview.toString(),
      published,
    };
  }

  if (url.hostname === "drive.google.com") {
    const segments = url.pathname.split("/").filter(Boolean);
    const isFilePath = segments[0] === "file" && segments.includes("d");
    const isOpenUrl = segments[0] === "open" || segments[0] === "uc";
    if (!isFilePath && !isOpenUrl) return null;
    const fileId = safeGoogleFileId(googleFileIdFromPath(url));
    if (!fileId) return null;
    const preview = new URL(`https://drive.google.com/file/d/${fileId}/preview`);
    retainGoogleAccessParams(url.searchParams, preview.searchParams);
    return {
      provider: "google",
      workspaceKind: "drive",
      fileId,
      format: null,
      sourceUrl: url.toString(),
      previewUrl: preview.toString(),
      published: false,
    };
  }

  return null;
}

/**
 * Build the flat content metadata consumed by a `kind: "document"` board item.
 * The binary itself intentionally lives in an asset store and is referenced by
 * `assetId`, keeping undo/history snapshots small.
 *
 * @param {
 *   | {kind: "upload", assetId: string, name: string, type?: string, size?: number}
 *   | {kind: "google", url: string}
 * } source
 */
export function buildImportedDocumentContent(source) {
  if (source?.kind === "upload") {
    const format = detectOfficeDocumentFormat(source);
    if (!format) throw new TypeError("unsupported or conflicting Office document type");
    if (typeof source.assetId !== "string" || source.assetId.trim().length === 0) {
      throw new TypeError("assetId must be a non-empty string");
    }
    const size = source.size ?? 0;
    if (!Number.isFinite(size) || size < 0) throw new TypeError("file size must be a non-negative number");

    return {
      title: titleFromFileName(source.name),
      subtitle: FORMAT_LABELS[format],
      documentSource: "upload",
      documentFormat: format,
      assetId: source.assetId,
      fileName: source.name,
      mimeType: OFFICE_DOCUMENT_MIME_TYPES[format],
      fileSize: size,
    };
  }

  if (source?.kind === "google") {
    const parsed = parseGoogleWorkspaceUrl(source.url);
    if (!parsed) throw new TypeError("unsupported Google Workspace URL");
    const config = parsed.workspaceKind === "document"
      ? GOOGLE_KIND_CONFIG.document
      : parsed.workspaceKind === "presentation"
        ? GOOGLE_KIND_CONFIG.presentation
        : parsed.workspaceKind === "spreadsheet"
          ? GOOGLE_KIND_CONFIG.spreadsheet
          : null;
    return {
      title: config?.title || "Google Drive file",
      subtitle: config?.label || "Google Drive",
      documentSource: "google",
      documentFormat: parsed.format,
      googleKind: parsed.workspaceKind,
      googleFileId: parsed.fileId,
      sourceUrl: parsed.sourceUrl,
      previewUrl: parsed.previewUrl,
      url: parsed.sourceUrl,
      published: parsed.published,
    };
  }

  throw new TypeError("document source must be an upload or Google URL");
}

/**
 * @param {OfficeDocumentFormat | null | undefined | {documentFormat?: OfficeDocumentFormat | null}} value
 */
export function importedDocumentDimensions(value) {
  const format = typeof value === "string" ? value : value?.documentFormat;
  if (format === "docx") return { width: 270, height: 340 };
  if (format === "pptx") return { width: 360, height: 220 };
  if (format === "xlsx") return { width: 360, height: 260 };
  return { width: 300, height: 240 };
}
