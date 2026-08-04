import { describe, expect, it } from "vitest";
import {
  buildImportedDocumentContent,
  detectOfficeDocumentFormat,
  DOCUMENT_FILE_ACCEPT,
  importedDocumentDimensions,
  OFFICE_DOCUMENT_MIME_TYPES,
  parseGoogleWorkspaceUrl,
} from "./documentImport.js";

describe("document import contract", () => {
  it("publishes a file picker accept list for the three supported Office formats", () => {
    expect(DOCUMENT_FILE_ACCEPT).toContain(".docx");
    expect(DOCUMENT_FILE_ACCEPT).toContain(".pptx");
    expect(DOCUMENT_FILE_ACCEPT).toContain(".xlsx");
    expect(DOCUMENT_FILE_ACCEPT).toContain(OFFICE_DOCUMENT_MIME_TYPES.docx);
  });

  it("detects Office formats from extensions or exact MIME types", () => {
    expect(detectOfficeDocumentFormat({ name: "Plan.DOCX", type: "" })).toBe("docx");
    expect(detectOfficeDocumentFormat({ name: "", type: OFFICE_DOCUMENT_MIME_TYPES.pptx })).toBe("pptx");
    expect(detectOfficeDocumentFormat({ name: "book.xlsx", type: "application/octet-stream" })).toBe("xlsx");
  });

  it("rejects unsupported legacy files and contradictory metadata", () => {
    expect(detectOfficeDocumentFormat({ name: "old.doc", type: "application/msword" })).toBeNull();
    expect(detectOfficeDocumentFormat({ name: "deck.pptx", type: OFFICE_DOCUMENT_MIME_TYPES.docx })).toBeNull();
    expect(detectOfficeDocumentFormat({ name: "archive.zip", type: "application/zip" })).toBeNull();
  });

  it("normalizes Google Docs links into constrained preview URLs", () => {
    const parsed = parseGoogleWorkspaceUrl(
      "https://docs.google.com/document/u/0/d/1AbCdEfGhIjKlMnOp/edit?usp=sharing&resourcekey=abc123",
    );
    expect(parsed).toMatchObject({
      workspaceKind: "document",
      format: "docx",
      fileId: "1AbCdEfGhIjKlMnOp",
      published: false,
    });
    expect(parsed.previewUrl).toBe(
      "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/preview?resourcekey=abc123",
    );
  });

  it("normalizes Slides, Sheets, published, and Drive file links", () => {
    expect(parseGoogleWorkspaceUrl(
      "https://docs.google.com/presentation/d/slide_123456/edit",
    )).toMatchObject({ workspaceKind: "presentation", format: "pptx" });

    const sheet = parseGoogleWorkspaceUrl(
      "https://docs.google.com/spreadsheets/d/sheet_123456/edit#gid=42",
    );
    expect(sheet).toMatchObject({ workspaceKind: "spreadsheet", format: "xlsx" });

    const published = parseGoogleWorkspaceUrl(
      "https://docs.google.com/document/d/e/2PACX-123456789/pub",
    );
    expect(published.published).toBe(true);
    expect(published.previewUrl).toBe(
      "https://docs.google.com/document/d/e/2PACX-123456789/pub?embedded=true",
    );

    const drive = parseGoogleWorkspaceUrl(
      "https://drive.google.com/file/d/drive_123456/view?usp=sharing&resourcekey=key123",
    );
    expect(drive).toMatchObject({ workspaceKind: "drive", format: null, fileId: "drive_123456" });
    expect(drive.previewUrl).toBe(
      "https://drive.google.com/file/d/drive_123456/preview?resourcekey=key123",
    );
  });

  it("rejects unsafe, lookalike, folder, and unrelated URLs", () => {
    expect(parseGoogleWorkspaceUrl("http://docs.google.com/document/d/abcdef123/edit")).toBeNull();
    expect(parseGoogleWorkspaceUrl("https://docs.google.com.evil.test/document/d/abcdef123/edit")).toBeNull();
    expect(parseGoogleWorkspaceUrl("https://drive.google.com/drive/folders/abcdef123")).toBeNull();
    expect(parseGoogleWorkspaceUrl("https://example.com/document/d/abcdef123/edit")).toBeNull();
  });

  it("builds compact upload metadata that references an external asset", () => {
    expect(buildImportedDocumentContent({
      kind: "upload",
      assetId: "asset-1",
      name: "Quarterly plan.docx",
      type: OFFICE_DOCUMENT_MIME_TYPES.docx,
      size: 42,
    })).toEqual({
      title: "Quarterly plan",
      subtitle: "Word document",
      documentSource: "upload",
      documentFormat: "docx",
      assetId: "asset-1",
      fileName: "Quarterly plan.docx",
      mimeType: OFFICE_DOCUMENT_MIME_TYPES.docx,
      fileSize: 42,
    });
  });

  it("builds Google preview metadata and rejects incomplete sources", () => {
    expect(buildImportedDocumentContent({
      kind: "google",
      url: "https://docs.google.com/presentation/d/slide_123456/edit",
    })).toMatchObject({
      title: "Google presentation",
      subtitle: "Google Slides",
      documentSource: "google",
      documentFormat: "pptx",
      googleKind: "presentation",
      googleFileId: "slide_123456",
    });
    expect(() => buildImportedDocumentContent({ kind: "upload", assetId: "", name: "a.docx" })).toThrow(/assetId/);
    expect(() => buildImportedDocumentContent({ kind: "google", url: "https://example.com" })).toThrow(/Google/);
  });

  it("uses format-aware card dimensions", () => {
    expect(importedDocumentDimensions("docx")).toEqual({ width: 270, height: 340 });
    expect(importedDocumentDimensions({ documentFormat: "pptx" })).toEqual({ width: 360, height: 220 });
    expect(importedDocumentDimensions("xlsx")).toEqual({ width: 360, height: 260 });
    expect(importedDocumentDimensions(null)).toEqual({ width: 300, height: 240 });
  });
});
