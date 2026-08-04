import { FileText } from "@phosphor-icons/react";
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { motion } from "motion/react";
import { renderOfficeDocument } from "../import/renderOfficeDocument.js";
import { platformBridge } from "../platform/index.js";
import { ArtifactTitleOverlay } from "./ArtifactTitleOverlay.jsx";
import { inspectIframeBottomTone } from "./artifactTone.js";

const renderedAssetCache = new Map();
const MAX_RENDERED_ASSETS = 8;

const DOCUMENT_LAYOUTS = Object.freeze({
  docx: "pages",
  xlsx: "workbook",
  pptx: "slides",
  drive: "embedded",
});

function documentFormat(item) {
  if (item.documentSource === "google") return "drive";
  return Object.hasOwn(DOCUMENT_LAYOUTS, item.documentFormat)
    ? item.documentFormat
    : "drive";
}

function cachedOfficeRender(item, loadAsset) {
  const key = `${item.assetId}:${item.documentFormat}`;
  if (renderedAssetCache.has(key)) return renderedAssetCache.get(key);
  const promise = loadAsset(item.assetId).then((asset) => renderOfficeDocument(asset, item.documentFormat));
  renderedAssetCache.set(key, promise);
  if (renderedAssetCache.size > MAX_RENDERED_ASSETS) {
    const oldestKey = renderedAssetCache.keys().next().value;
    if (oldestKey !== key) renderedAssetCache.delete(oldestKey);
  }
  promise.catch(() => renderedAssetCache.delete(key));
  return promise;
}

function DocumentLoadingState({ item, error, visible }) {
  return (
    <div
      className={`document-asset-status ${error ? "is-error" : "is-loading"} ${visible ? "is-visible" : "is-hidden"}`}
      aria-hidden={visible ? undefined : true}
      style={{
        opacity: visible ? 1 : 0,
        visibility: visible ? "visible" : "hidden",
        pointerEvents: "none",
        transition: visible
          ? "opacity 120ms ease-out"
          : "opacity 120ms ease-out, visibility 0s linear 120ms",
      }}
    >
      <FileText size={34} weight="thin" />
      <strong>{error ? "Preview unavailable" : `Opening ${item.subtitle || "document"}`}</strong>
      <span>{error || item.fileName || item.title}</span>
    </div>
  );
}

export function DocumentAssetSurface({
  item,
  detailPresent,
  detailOpen,
  detailReady,
  assetMotion,
  loadAsset,
}) {
  const isGoogle = item.documentSource === "google";
  const format = documentFormat(item);
  const layout = DOCUMENT_LAYOUTS[format];
  const renderKey = isGoogle ? `google:${item.previewUrl || item.sourceUrl || item.id}` : `${item.assetId}:${format}`;
  const [renderedState, setRenderedState] = useState({ key: "", value: null });
  const [errorState, setErrorState] = useState({ key: "", message: "" });
  const [readyFrameKey, setReadyFrameKey] = useState("");
  const [overlayTone, setOverlayTone] = useState(item.artifactTone === "dark" ? "dark" : "light");
  const documentFrameRef = useRef(null);

  const rendered = renderedState.key === renderKey ? renderedState.value : null;
  const error = errorState.key === renderKey ? errorState.message : "";
  const srcDoc = rendered?.fullSrcDoc;
  const surfaceReady = readyFrameKey === renderKey;
  const interactive = Boolean(detailReady && detailOpen && surfaceReady);
  // Install the fullscreen iframe bounds on the preparation frame and keep
  // them until the reverse FLIP reaches the board. The preview itself carries
  // a compensating scale inside the retained iframe, so both endpoints remain
  // pixel-identical without a settle-frame wrapper resize.
  const detailShellActive = Boolean(
    (!isGoogle && detailPresent)
    || (isGoogle && detailReady && detailOpen),
  );
  const desiredViewMode = detailReady && detailOpen ? "reader" : "preview";
  const viewerPhase = !detailPresent
    ? "board"
    : !detailOpen
      ? "closing"
      : detailReady
        ? "ready"
        : "opening";
  const semanticClass = useMemo(() => ({
    docx: "is-paginated-document",
    xlsx: "is-spreadsheet-workbook",
    pptx: "is-slide-deck",
    drive: "is-google-document",
  })[format], [format]);

  useEffect(() => {
    if (isGoogle || !item.assetId || typeof loadAsset !== "function") return undefined;
    let active = true;
    cachedOfficeRender(item, loadAsset)
      .then((value) => {
        if (!active) return;
        setErrorState({ key: renderKey, message: "" });
        setRenderedState({ key: renderKey, value });
      })
      .catch((reason) => {
        if (!active) return;
        setErrorState({
          key: renderKey,
          message: reason instanceof Error ? reason.message : "The file could not be rendered.",
        });
      });
    return () => {
      active = false;
    };
  }, [format, isGoogle, item.assetId, loadAsset, renderKey]);

  const setFrameViewMode = useCallback((frame = documentFrameRef.current) => {
    if (isGoogle || !frame?.contentDocument) return;
    const root = frame.contentDocument.documentElement;
    const retainedPreviewScale = detailShellActive
      ? Number(assetMotion?.detailPreviewScale ?? assetMotion?.scale?.get?.() ?? assetMotion?.scale) || 1
      : 1;
    root.dataset.viewMode = desiredViewMode;
    root.dataset.documentFormat = format;
    root.dataset.documentLayout = layout;
    root.dataset.interactive = interactive ? "true" : "false";
    root.dataset.detailShell = detailShellActive ? "true" : "false";
    root.style.setProperty(
      "--office-leading-slot",
      platformBridge.isElectron
        ? "164px"
        : "max(76px, calc(env(safe-area-inset-left) + 68px))",
    );
    root.style.setProperty("--office-preview-scale", String(retainedPreviewScale));
  }, [assetMotion?.detailPreviewScale, assetMotion?.scale, desiredViewMode, detailShellActive, format, interactive, isGoogle, layout]);

  const syncDocumentPageScale = useCallback((frame = documentFrameRef.current) => {
    if (isGoogle || !frame?.contentDocument) return;
    const baseWidth = Number(
      format === "docx" ? rendered?.readerPageWidth : assetMotion?.baseWidth,
    ) || 1;
    const baseHeight = Number(assetMotion?.baseHeight) || 1;
    const compact = frame.clientWidth <= 760;
    const availableWidth = format === "pptx"
      ? frame.clientWidth - (compact ? 16 : 290)
      : frame.clientWidth - (compact ? 16 : 56);
    const availableHeight = format === "pptx"
      ? frame.clientHeight - (compact ? 190 : 260)
      : frame.clientHeight;
    const maximumScale = format === "pptx" ? 1.4 : 1;
    const pageScale = detailShellActive
      ? Math.min(
          maximumScale,
          Math.max(0.1, availableWidth) / Math.max(1, baseWidth),
          format === "pptx"
            ? compact
              ? maximumScale
              : Math.max(0.1, availableHeight) / Math.max(1, baseHeight)
            : maximumScale,
        )
      : 1;
    frame.contentDocument.documentElement.style.setProperty(
      "--document-page-scale",
      String(Math.max(0.1, pageScale)),
    );
  }, [assetMotion?.baseHeight, assetMotion?.baseWidth, detailShellActive, format, isGoogle, rendered?.readerPageWidth]);

  // The iframe document is permanent. Only a root data attribute changes
  // between its preview and reader presentation, and that happens before the
  // browser paints the corresponding React phase.
  useLayoutEffect(() => {
    const frame = documentFrameRef.current;
    if (!frame || isGoogle || !surfaceReady) return;
    setFrameViewMode(frame);
    syncDocumentPageScale(frame);
  }, [isGoogle, setFrameViewMode, surfaceReady, syncDocumentPageScale]);

  useEffect(() => {
    const frame = documentFrameRef.current;
    if (!frame || isGoogle) return undefined;
    // Board cards always use the authored preview scale. Observing every
    // visible Office iframe added a resize callback per card during canvas
    // pan/zoom even though their page scale could not change. The fullscreen
    // shell is the only layout whose available reader bounds are responsive.
    if (!detailShellActive || !surfaceReady || typeof ResizeObserver === "undefined") {
      return undefined;
    }
    const observer = new ResizeObserver(() => syncDocumentPageScale(frame));
    observer.observe(frame);
    return () => observer.disconnect();
  }, [detailShellActive, isGoogle, srcDoc, surfaceReady, syncDocumentPageScale]);

  const frameTitle = item.title || item.fileName || (isGoogle ? "Google document" : "Imported document");

  return (
    <motion.div
      className={`document-asset-stage format-${format} layout-${layout} ${semanticClass} ${detailReady ? "is-detail-ready" : ""} ${surfaceReady ? "is-surface-ready" : "is-surface-loading"}`}
      data-document-format={format}
      data-document-layout={layout}
      data-viewer-phase={viewerPhase}
      data-view-mode={desiredViewMode}
      data-frame-state={error ? "error" : surfaceReady ? "ready" : "loading"}
      aria-busy={!surfaceReady && !error}
      style={{
        width: "100%",
        height: assetMotion?.stageHeight,
        backgroundColor: "#fff",
      }}
    >
      <motion.div
        className={`document-asset-surface ${desiredViewMode === "reader" ? "is-reader" : "is-preview"} ${detailShellActive ? "is-detail-shell" : "is-board-shell"} ${surfaceReady ? "is-surface-ready" : "is-surface-loading"}`}
        data-document-format={format}
        data-document-layout={layout}
        data-view-mode={desiredViewMode}
        inert={interactive ? undefined : true}
        style={{
          width: detailShellActive ? "100%" : assetMotion?.baseWidth,
          height: detailShellActive ? "100%" : assetMotion?.baseHeight,
          x: detailShellActive ? 0 : assetMotion?.x,
          y: detailShellActive ? 0 : assetMotion?.y,
          scale: detailShellActive ? 1 : assetMotion?.scale,
          transformOrigin: "0 0",
          backgroundColor: "#fff",
        }}
      >
        {isGoogle ? (
          <iframe
            className="document-asset-frame google-document-frame"
            src={item.previewUrl}
            title={frameTitle}
            loading="eager"
            sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox allow-downloads allow-storage-access-by-user-activation"
            referrerPolicy="strict-origin-when-cross-origin"
            tabIndex={interactive ? 0 : -1}
            aria-hidden={interactive ? undefined : true}
            data-document-format={format}
            data-document-layout={layout}
            style={{
              opacity: surfaceReady ? 1 : 0,
              pointerEvents: interactive ? "auto" : "none",
              transition: "opacity 120ms ease-out",
            }}
            onLoad={(event) => {
              setReadyFrameKey(renderKey);
              setOverlayTone(inspectIframeBottomTone(event.currentTarget, {
                fallback: item.artifactTone === "dark" ? "dark" : "light",
              }));
            }}
          />
        ) : (
          <iframe
            ref={documentFrameRef}
            className="document-asset-frame"
            srcDoc={srcDoc}
            title={frameTitle}
            sandbox="allow-same-origin"
            tabIndex={interactive ? 0 : -1}
            aria-hidden={interactive ? undefined : true}
            data-document-format={format}
            data-document-layout={layout}
            data-view-mode={desiredViewMode}
            style={{
              width: "100%",
              height: "100%",
              opacity: surfaceReady ? 1 : 0,
              pointerEvents: interactive ? "auto" : "none",
              transition: "opacity 120ms ease-out",
            }}
            onLoad={(event) => {
              if (!srcDoc) return;
              setFrameViewMode(event.currentTarget);
              syncDocumentPageScale(event.currentTarget);
              setReadyFrameKey(renderKey);
              setOverlayTone(inspectIframeBottomTone(event.currentTarget, {
                fallback: item.artifactTone === "dark" ? "dark" : "light",
              }));
            }}
          />
        )}
        <DocumentLoadingState item={item} error={error} visible={!surfaceReady || Boolean(error)} />
      </motion.div>
      {isGoogle && !detailReady && !item.published && (
        <div className="google-document-gate" aria-hidden="true">
          <FileText size={30} weight="thin" />
          <span>Open to preview</span>
        </div>
      )}
      <ArtifactTitleOverlay
        eyebrow={item.subtitle || item.fileName || "Document"}
        title={item.title || item.fileName || "Untitled document"}
        tone={overlayTone}
        visible={!detailPresent}
      />
    </motion.div>
  );
}
