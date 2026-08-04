import { ArrowSquareOut, CopySimple, DownloadSimple, Folder, Trash } from "@phosphor-icons/react";
import { motion } from "motion/react";
import { useState } from "react";
import { createPortal } from "react-dom";
import { webClipDisplayUrl } from "../import/webClip.js";
import { ImagePreview, ItemCard, WebPreview } from "./ItemCard.jsx";
import { NotionBlockEditor } from "./NotionBlockEditor.jsx";
import { DocumentAssetSurface } from "./DocumentAssetSurface.jsx";
import { ArtifactTitleOverlay } from "./ArtifactTitleOverlay.jsx";

function SharedDocumentSurface({ item, interactive, documentMotion, onUpdate }) {
  return (
    <motion.div
      className="shared-document-stage"
      style={{ height: documentMotion?.stageHeight }}
    >
      <motion.div
        className="shared-document-surface"
        inert={interactive ? undefined : true}
        aria-hidden={interactive ? undefined : true}
        style={{
          x: documentMotion?.x,
          y: documentMotion?.y,
          scale: documentMotion?.scale,
          transformOrigin: "0 0",
        }}
      >
        <span className="document-breadcrumb">Untitled</span>
        <NotionBlockEditor item={item} onChange={onUpdate} interactive={interactive} />
      </motion.div>
    </motion.div>
  );
}

function SharedImageSurface({ item, imageMotion }) {
  return (
    <div className="shared-image-stage">
      <motion.div
        className="shared-image-surface"
        style={{
          width: imageMotion?.width,
          height: imageMotion?.height,
          x: imageMotion?.x,
          y: imageMotion?.y,
          scale: imageMotion?.scale,
          transformOrigin: "0 0",
        }}
      >
        <ImagePreview item={item} />
      </motion.div>
    </div>
  );
}

function SharedWebSurface({ item, detailPresent, interactive, webMotion, loadAsset, onScreenshotResolved }) {
  const [overlayTone, setOverlayTone] = useState(item.artifactTone === "dark" ? "dark" : "light");
  const domain = webClipDisplayUrl(item);

  return (
    <div className="shared-web-stage">
      <motion.div
        className="shared-web-surface"
        style={{
          width: webMotion?.baseWidth,
          height: webMotion?.baseHeight,
          x: webMotion?.x,
          y: webMotion?.y,
          scale: webMotion?.scale,
          transformOrigin: "0 0",
        }}
      >
        <WebPreview
          item={item}
          interactive={interactive}
          loadAsset={loadAsset}
          onScreenshotResolved={onScreenshotResolved}
          onToneChange={setOverlayTone}
        />
      </motion.div>
      <ArtifactTitleOverlay title={domain} tone={overlayTone} visible={!detailPresent} />
    </div>
  );
}

/**
 * The item preview and fullscreen editor intentionally share this permanent
 * viewer. Opening only changes the retained canvas node's bounds; the card is
 * never replaced by a second transition clone.
 */
export function SharedItemViewer({
  item,
  selected,
  dimmed,
  dragging,
  resizing,
  detailPresent,
  detailOpen,
  detailReady,
  interactive = true,
  documentMotion,
  imageMotion,
  assetMotion,
  webMotion,
  detailActionsHost,
  loadAsset,
  onPointerDown,
  onDoubleClick,
  onOpenStack,
  onUpdate,
  onDelete,
  onDuplicate,
  onExport,
  onMove,
  onOpenExternal,
  onWebPreviewResolved,
}) {
  const kind = item.kind || item.type;
  const importedDocument = kind === "document" && Boolean(item.documentSource);
  const authoredDocument = kind === "note" || (kind === "document" && !importedDocument);
  const externalUrl = kind === "web" ? item.url : item.sourceUrl;
  const artifactFormat = importedDocument
    ? item.documentSource === "google"
      ? "drive"
      : item.documentFormat || "document"
    : kind;
  const artifactLayout = ({
    docx: "pages",
    xlsx: "workbook",
    pptx: "slides",
    drive: "embedded",
    web: "capture",
    image: "image",
    note: "editor",
    document: "editor",
  })[artifactFormat] || "card";
  const viewerPhase = !detailPresent
    ? "board"
    : !detailOpen
      ? "closing"
      : detailReady
        ? "ready"
        : "opening";
  // Authored editor attributes stay stable through the reverse flight. The
  // closing shell blocks pointer input immediately while its DOM stays mounted
  // until the exact board endpoint.
  const detailInteractive = Boolean(detailReady && detailOpen);
  const detailChromeVisible = detailInteractive;

  return (
    <div
      className={`shared-item-viewer artifact-${kind} artifact-format-${artifactFormat} artifact-layout-${artifactLayout} ${detailReady ? "is-detail-ready" : ""}`}
      data-artifact-kind={kind}
      data-artifact-format={artifactFormat}
      data-artifact-layout={artifactLayout}
      data-viewer-phase={viewerPhase}
      data-detail-interactive={detailInteractive ? "true" : "false"}
      data-retained-surface="true"
      data-detail-scroll-region={detailPresent ? "true" : undefined}
    >
      <ItemCard
        item={item}
        selected={selected && !detailPresent}
        dimmed={dimmed}
        dragging={dragging}
        resizing={resizing}
        snapTarget={false}
        interactive={interactive && !detailPresent}
        onPointerDown={onPointerDown}
        onDoubleClick={onDoubleClick}
        onOpenStack={onOpenStack}
      >
        {authoredDocument
          ? <SharedDocumentSurface item={item} interactive={detailInteractive} documentMotion={documentMotion} onUpdate={onUpdate} />
          : importedDocument
            ? (
              <DocumentAssetSurface
                item={item}
                detailPresent={detailPresent}
                detailOpen={detailOpen}
                detailReady={detailReady}
                assetMotion={assetMotion}
                loadAsset={loadAsset}
              />
            )
            : kind === "web"
              ? (
                 <SharedWebSurface
                   item={item}
                   detailPresent={detailPresent}
                  interactive={detailInteractive}
                  webMotion={webMotion}
                  loadAsset={loadAsset}
                  onScreenshotResolved={onWebPreviewResolved}
                />
              )
          : kind === "image"
            ? <SharedImageSurface item={item} imageMotion={imageMotion} />
            : undefined}
      </ItemCard>

      {detailPresent && kind === "image" && (
        <motion.aside
          className="image-detail-chrome"
          initial={false}
          animate={{ opacity: detailChromeVisible ? 1 : 0 }}
          transition={{ duration: detailChromeVisible ? 0.22 : 0.1, ease: "easeOut" }}
          aria-hidden={detailChromeVisible ? undefined : true}
          style={{ pointerEvents: detailChromeVisible ? "auto" : "none" }}
        >
          <div className="image-detail-palette" aria-label="Image palette">
            {(item.palette || ["#f7f7f4", "#c2c6c7", "#737f82", "#202526"]).slice(0, 5).map((color) => (
              <span key={color} style={{ background: color }} />
            ))}
          </div>
          <dl className="image-detail-metadata">
            <div><dt>Title</dt><dd>{item.title || "Untitled visual"}</dd></div>
            <div><dt>Type</dt><dd>Image reference</dd></div>
          </dl>
        </motion.aside>
      )}

      {detailPresent && (
        <div
          className="shared-viewer-dialog-semantics"
          role="dialog"
          aria-modal="true"
          aria-label={`${item.title || kind} detail`}
          onPointerDown={(event) => event.stopPropagation()}
          onDoubleClick={(event) => event.stopPropagation()}
        />
      )}

      {detailPresent && detailActionsHost && createPortal(
        <div
          className="detail-actions-anchor is-viewport-fixed"
          inert={detailChromeVisible ? undefined : true}
          aria-hidden={detailChromeVisible ? undefined : true}
          onPointerDown={(event) => event.stopPropagation()}
          onDoubleClick={(event) => event.stopPropagation()}
        >
          <motion.div
            className="detail-actions"
            initial={false}
            animate={{ opacity: detailChromeVisible ? 1 : 0, y: detailChromeVisible ? 0 : 8 }}
            transition={detailChromeVisible ? { duration: 0.16, ease: "easeOut" } : { duration: 0.08 }}
            style={{ pointerEvents: detailChromeVisible ? "auto" : "none" }}
          >
            {externalUrl && (
              <button
                type="button"
                aria-label="Open original"
                title="Open original"
                onClick={() => onOpenExternal?.(externalUrl)}
              >
                <ArrowSquareOut size={15} />
              </button>
            )}
            <button type="button" aria-label="Duplicate" onClick={() => onDuplicate?.(item.id)}><CopySimple size={15} /></button>
            <button type="button" aria-label="Export" onClick={() => onExport?.(item)}><DownloadSimple size={15} /></button>
            <button type="button" aria-label="Move" onClick={() => onMove?.(item.id)}><Folder size={15} /></button>
            <button type="button" aria-label="Delete" onClick={() => onDelete?.(item.id)}><Trash size={15} /></button>
          </motion.div>
        </div>,
        detailActionsHost,
      )}
    </div>
  );
}
