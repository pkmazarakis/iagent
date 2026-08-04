import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { animate, motion, useMotionTemplate, useMotionValue, useTransform } from "motion/react";
import { SharedItemViewer } from "../components/SharedItemViewer.jsx";
import { officePreviewGeometry } from "../import/renderOfficeDocument.js";
import {
  compositorDetailSource,
  detailBackdropOpacity,
  DETAIL_GEOMETRY_TRANSITION,
  foldSelectionScaleIntoGeometry,
  scaledGeometryBounds,
} from "../motion/detailGeometry.js";
import { ITEM_LAYOUT_TRANSITION } from "../motion/transitions.js";
import { isContainerKind } from "./containerView.js";
import {
  SELECTION_INDICATOR_HIDE_DELAY_MS,
  shouldRevealSelectionIndicators,
} from "./selectionIndicatorIntent.js";
import { leadingEdgeCoverScale } from "./artifactGeometry.js";

const opacityTransition = { duration: 0.38, ease: [0.16, 1, 0.3, 1] };
const resizeCorners = ["nw", "ne", "se", "sw"];
const DOCUMENT_SURFACE_WIDTH = 680;
export const MARQUEE_SELECTION_SCALE = 1.075;
const MemoizedSharedItemViewer = memo(SharedItemViewer);

function useLatestCallback(callback) {
  const callbackRef = useRef(callback);
  callbackRef.current = callback;
  return useCallback((...args) => callbackRef.current?.(...args), []);
}

export function authoredDocumentScale(viewportWidth) {
  const width = Math.max(1, Number(viewportWidth) || 1);
  return Math.max(0.04, width / DOCUMENT_SURFACE_WIDTH);
}

/**
 * Scale the retained Office preview for a destination-bounds FLIP.
 *
 * The board preview already has a cover scale. When the destination shell is
 * installed before paint, its outer FLIP scale becomes the new source
 * matrix. Dividing the visible board scale by that matrix keeps the first
 * rendered frame pixel-identical, then the preview rides one uniform outer
 * transform for the rest of the flight. No nested progress-driven scale is
 * needed, which avoids both curved content paths and per-frame iframe paint.
 */
export function importedArtifactFlightScale({
  boardWidth,
  boardHeight,
  boardScale = 1,
  selectionScale = 1,
  destinationWidth,
  destinationHeight,
  baseWidth,
  baseHeight,
} = {}) {
  const width = Math.max(1, Number(boardWidth) || 1);
  const height = Math.max(1, Number(boardHeight) || 1);
  const visibleOuterScale = Math.max(0.0001, Number(boardScale) || 1)
    * Math.max(0.0001, Number(selectionScale) || 1);
  const flipScale = Math.max(
    width * visibleOuterScale / Math.max(1, Number(destinationWidth) || 1),
    height * visibleOuterScale / Math.max(1, Number(destinationHeight) || 1),
  );
  const boardCoverScale = leadingEdgeCoverScale(
    width,
    height,
    Math.max(1, Number(baseWidth) || 1),
    Math.max(1, Number(baseHeight) || 1),
  );
  return boardCoverScale * visibleOuterScale / Math.max(0.0001, flipScale);
}

export function selectionPresentationScale({
  selectionEmphasized = false,
  detailPresent = false,
  folderOpen = false,
  folderTransitioning = false,
} = {}) {
  return selectionEmphasized && !detailPresent && !folderOpen && !folderTransitioning
    ? MARQUEE_SELECTION_SCALE
    : 1;
}

function SelectionCorners({ onResizePointerDown, visible }) {
  return (
    <div
      className={`selection-corners ${visible ? "is-visible" : ""}`}
      data-selection-indicators="true"
      aria-hidden={!visible}
    >
      {resizeCorners.map((corner) => (
        <button
          key={corner}
          type="button"
          className={`resize-corner ${corner}`}
          aria-label={`Resize ${corner} corner`}
          tabIndex={visible ? 0 : -1}
          onPointerDown={(event) => onResizePointerDown?.(corner, event)}
        >
          <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
            <path pathLength="1" d="M 23 1 A 22 22 0 0 0 1 23" />
          </svg>
        </button>
      ))}
    </div>
  );
}

/**
 * A retained visual node for one canvas item.
 *
 * Canonical item data still lives in React/IndexedDB, but pointer-frequency
 * geometry is written through MotionValues. Motion updates the compositor on
 * its own render loop, so dragging and resizing never wait for a React render.
 */
export function CanvasItemNode({
  item,
  target,
  selected,
  selectionEmphasized = false,
  dimmed,
  dragging,
  resizing,
  preview,
  selectionControls,
  registerRenderer,
  onPointerDown,
  onDoubleClick,
  onOpenStack,
  onResizePointerDown,
  detailPresent = false,
  detailOpen = false,
  detailTarget = null,
  detailUsesDestinationBounds = false,
  detailProgressMotion = null,
  detailViewport = null,
  detailActionsHost = null,
  folderOpen = false,
  folderTransitioning = false,
  folderTarget = null,
  cameraZoom = 1,
  cameraZoomMotion = null,
  transitionDelay = 0,
  onLayoutTransitionComplete,
  onDetailExitComplete,
  onDetailUpdate,
  onDetailDelete,
  onDetailDuplicate,
  onDetailExport,
  onDetailMove,
  onLoadAsset,
  onOpenExternal,
  onWebPreviewResolved,
}) {
  const wrapperRef = useRef(null);
  const activeAnimationsRef = useRef([]);
  const selectionAnimationRef = useRef(null);
  const selectionHideTimerRef = useRef(null);
  const selectionPointerRef = useRef({
    pointerInside: false,
    pointerType: null,
    buttons: 0,
  });
  const transitionGenerationRef = useRef(0);
  const detailStateRef = useRef({ present: false, open: false });
  const layoutCompleteRef = useRef(onLayoutTransitionComplete);
  const detailExitCompleteRef = useRef(onDetailExitComplete);
  const [detailReady, setDetailReady] = useState(false);
  const [selectionIndicatorsVisible, setSelectionIndicatorsVisible] = useState(false);
  const x = useMotionValue(target.x);
  const y = useMotionValue(target.y);
  const width = useMotionValue(target.width);
  const height = useMotionValue(target.height);
  const opacity = useMotionValue(target.opacity);
  const scale = useMotionValue(target.scale);
  const clipRight = useMotionValue(0);
  const clipBottom = useMotionValue(0);
  const localDetailProgress = useMotionValue(detailOpen || folderOpen ? 1 : 0);
  const detailProgress = detailProgressMotion || localDetailProgress;
  const itemRadius = item.style?.cornerRadius ?? 14;
  const safeZoom = Math.max(0.0001, cameraZoom || 1);
  const fallbackZoom = useMotionValue(safeZoom);
  const liveZoom = cameraZoomMotion || fallbackZoom;
  const inverseLiveZoom = useTransform(liveZoom, (zoom) => 1 / Math.max(0.0001, zoom));
  const inverseDetailScale = useTransform(
    [liveZoom, scale],
    ([zoom, outerScale]) => 1 / Math.max(0.0001, zoom * outerScale),
  );
  const detailEdgeOpacity = useTransform(detailProgress, (progress) => 1 - detailBackdropOpacity(progress));
  const presentedSelectionScale = selectionPresentationScale({
    selectionEmphasized,
    detailPresent,
    folderOpen,
    folderTransitioning,
  });
  const selectionScale = useMotionValue(presentedSelectionScale);
  const inverseIndicatorScale = useTransform(
    [liveZoom, selectionScale],
    ([zoom, selectedScale]) => 1 / Math.max(0.0001, zoom * selectedScale),
  );
  const indicatorRadiusScale = useTransform(
    [liveZoom, selectionScale],
    ([zoom, selectedScale]) => Math.max(0.0001, zoom * selectedScale),
  );
  const documentScale = useTransform(width, (value) => authoredDocumentScale(value));
  const documentX = useMotionValue(0);
  const documentY = useMotionValue(0);
  const documentStageHeight = useTransform(
    [height, documentScale],
    ([currentHeight, currentScale]) => Math.max(
      currentHeight,
      1320 * currentScale,
    ),
  );
  const assetGeometry = officePreviewGeometry(item.content?.documentFormat);
  const assetBaseWidth = assetGeometry.width;
  const assetBaseHeight = assetGeometry.height;
  const boardSelectionScale = selectionPresentationScale({ selectionEmphasized });
  const detailAssetScale = detailTarget && detailUsesDestinationBounds
    ? importedArtifactFlightScale({
        boardWidth: target.width,
        boardHeight: target.height,
        boardScale: target.scale,
        selectionScale: boardSelectionScale,
        destinationWidth: detailTarget.width,
        destinationHeight: detailTarget.height,
        baseWidth: assetBaseWidth,
        baseHeight: assetBaseHeight,
      })
    : null;
  const assetScale = useTransform(
    [width, height],
    ([currentWidth, currentHeight]) => {
      if (detailPresent && detailAssetScale != null) return detailAssetScale;
      return leadingEdgeCoverScale(
        currentWidth,
        currentHeight,
        assetBaseWidth,
        assetBaseHeight,
      );
    },
  );
  // Cover-scaled board previews are leading-edge anchored. Keeping that
  // anchor fixed through the outer FLIP removes a second animated transform.
  const assetX = useMotionValue(0);
  const assetY = useMotionValue(0);
  const assetStageHeight = height;
  const webBaseWidth = 800;
  const webBaseHeight = 550;
  const webScale = useTransform(
    [width, height],
    ([currentWidth, currentHeight]) => leadingEdgeCoverScale(
      currentWidth,
      currentHeight,
      webBaseWidth,
      webBaseHeight,
    ),
  );
  const webX = useMotionValue(0);
  const webY = useMotionValue(0);
  const animatedRadius = useTransform(
    [detailProgress, scale],
    ([progress, outerScale]) => Math.max(
      0,
      itemRadius * (1 - progress) / Math.max(0.0001, outerScale),
    ),
  );
  const clipPath = useMotionTemplate`inset(0px ${clipRight}px ${clipBottom}px 0px round ${animatedRadius}px)`;
  const stopAnimations = () => {
    activeAnimationsRef.current.forEach((control) => control.stop());
    activeAnimationsRef.current = [];
  };

  useEffect(() => {
    fallbackZoom.jump(safeZoom);
  }, [fallbackZoom, safeZoom]);

  useLayoutEffect(() => {
    const controlsActive = selectionControls && !detailPresent;
    if (shouldRevealSelectionIndicators({
      ...selectionPointerRef.current,
      active: controlsActive,
    })) {
      clearTimeout(selectionHideTimerRef.current);
      selectionHideTimerRef.current = null;
      setSelectionIndicatorsVisible(true);
      return;
    }
    if (controlsActive && !selectionPointerRef.current.pointerInside) return;
    clearTimeout(selectionHideTimerRef.current);
    selectionHideTimerRef.current = null;
    setSelectionIndicatorsVisible(false);
  }, [detailPresent, selectionControls]);

  useEffect(() => () => {
    clearTimeout(selectionHideTimerRef.current);
  }, []);

  useEffect(() => {
    if (detailPresent) return undefined;
    selectionAnimationRef.current?.stop();
    selectionAnimationRef.current = animate(
      selectionScale,
      presentedSelectionScale,
      { type: "spring", stiffness: 520, damping: 38, mass: 0.72 },
    );
    return () => selectionAnimationRef.current?.stop();
  }, [detailPresent, presentedSelectionScale, selectionScale]);

  useLayoutEffect(() => {
    layoutCompleteRef.current = onLayoutTransitionComplete;
    detailExitCompleteRef.current = onDetailExitComplete;
  }, [onDetailExitComplete, onLayoutTransitionComplete]);

  useLayoutEffect(() => {
    const renderer = {
      setGeometry(patch) {
        stopAnimations();
        if (patch.x != null) x.jump(patch.x);
        if (patch.y != null) y.jump(patch.y);
        if (patch.width != null) width.jump(patch.width);
        if (patch.height != null) height.jump(patch.height);
      },
      rebase(delta) {
        stopAnimations();
        x.jump(x.get() - delta.x);
        y.jump(y.get() - delta.y);
      },
      setSnapTarget(active) {
        wrapperRef.current
          ?.querySelector(".spatial-item")
          ?.classList.toggle("is-snap-target", active);
      },
    };
    registerRenderer(item.id, renderer);
    return () => registerRenderer(item.id, null, renderer);
  }, [height, item.id, registerRenderer, width, x, y]);

  useLayoutEffect(() => {
    const generation = ++transitionGenerationRef.current;

    const run = () => {
      stopAnimations();
      const detailShell = Boolean(
        detailPresent
        && detailTarget
        && !isContainerKind(item),
      );
      const folderShell = Boolean(
        isContainerKind(item)
        && folderTarget
        && (folderOpen || folderTransitioning),
      );
      const previousDetailState = detailStateRef.current;
      detailStateRef.current = { present: detailPresent, open: detailOpen };

      if (detailShell) {
        const boardSelectionScale = selectionPresentationScale({ selectionEmphasized });
        const enteringDetail = detailOpen && !previousDetailState.present;
        let enteringSource = null;
        if (enteringDetail) {
          const currentSelectionScale = selectionScale.get();
          const foldedSource = foldSelectionScaleIntoGeometry({
            x: x.get(),
            y: y.get(),
            width: width.get(),
            height: height.get(),
            scale: scale.get(),
          }, currentSelectionScale);
          enteringSource = foldedSource;
          x.jump(foldedSource.x);
          y.jump(foldedSource.y);
          scale.jump(foldedSource.scale);
          selectionScale.jump(1);
          detailProgress.jump(0);
        }

        const boardDestination = foldSelectionScaleIntoGeometry(target, boardSelectionScale);
        const destination = detailOpen
          ? detailTarget
          : boardDestination;
        const fullscreenFlip = detailUsesDestinationBounds
          ? compositorDetailSource(
              scaledGeometryBounds(detailOpen && enteringSource ? enteringSource : boardDestination),
              detailTarget,
            )
          : null;

        if (detailUsesDestinationBounds) {
          if (enteringDetail) {
            x.jump(fullscreenFlip.x);
            y.jump(fullscreenFlip.y);
            scale.jump(fullscreenFlip.scale);
            clipRight.jump(fullscreenFlip.clipRight);
            clipBottom.jump(fullscreenFlip.clipBottom);
          }
          width.jump(detailTarget.width);
          height.jump(detailTarget.height);
        }

        const geometryControls = detailUsesDestinationBounds
          ? [
              animate(x, detailOpen ? detailTarget.x : fullscreenFlip.x, DETAIL_GEOMETRY_TRANSITION),
              animate(y, detailOpen ? detailTarget.y : fullscreenFlip.y, DETAIL_GEOMETRY_TRANSITION),
              animate(scale, detailOpen ? detailTarget.scale : fullscreenFlip.scale, DETAIL_GEOMETRY_TRANSITION),
              animate(clipRight, detailOpen ? 0 : fullscreenFlip.clipRight, DETAIL_GEOMETRY_TRANSITION),
              animate(clipBottom, detailOpen ? 0 : fullscreenFlip.clipBottom, DETAIL_GEOMETRY_TRANSITION),
            ]
          : [
              animate(x, destination.x, DETAIL_GEOMETRY_TRANSITION),
              animate(y, destination.y, DETAIL_GEOMETRY_TRANSITION),
              animate(scale, destination.scale, DETAIL_GEOMETRY_TRANSITION),
            ];
        const progressControl = animate(
          detailProgress,
          detailOpen ? 1 : 0,
          DETAIL_GEOMETRY_TRANSITION,
        );
        activeAnimationsRef.current = [
          ...geometryControls,
          animate(opacity, destination.opacity, opacityTransition),
          progressControl,
        ];

        Promise.all([...geometryControls, progressControl]).then(() => {
          if (transitionGenerationRef.current !== generation) return;
          if (detailOpen) {
            setDetailReady(true);
          } else {
            // Keep the exact FLIP endpoint until React clears detail presence.
            // The next layout transaction switches both the inner retained
            // preview and these outer values back to board geometry before
            // the browser can paint either state independently.
            detailExitCompleteRef.current?.();
          }
        });
        return;
      }

      if (previousDetailState.present && !detailPresent) {
        x.jump(target.x);
        y.jump(target.y);
        width.jump(target.width);
        height.jump(target.height);
        scale.jump(target.scale);
        selectionScale.jump(selectionPresentationScale({ selectionEmphasized }));
        clipRight.jump(0);
        clipBottom.jump(0);
        detailProgress.jump(0);
        setDetailReady(false);
        layoutCompleteRef.current?.(item.id);
        return;
      }

      const destination = folderShell && folderOpen ? folderTarget : target;
      const transition = folderShell || folderOpen
        ? DETAIL_GEOMETRY_TRANSITION
        : { ...ITEM_LAYOUT_TRANSITION, delay: Math.max(0, transitionDelay) };
      const liveSource = folderOpen
        ? { x: x.get(), y: y.get(), width: width.get(), height: height.get() }
        : target;
      const flip = folderShell ? compositorDetailSource(liveSource, folderTarget) : null;

      if (folderShell && folderOpen) {
        x.jump(flip.x);
        y.jump(flip.y);
        width.jump(flip.width);
        height.jump(flip.height);
        scale.jump(flip.scale);
        clipRight.jump(flip.clipRight);
        clipBottom.jump(flip.clipBottom);
        detailProgress.jump(0);
      } else if (folderShell) {
        width.jump(folderTarget.width);
        height.jump(folderTarget.height);
      }

      const geometryControls = folderShell
        ? [
            animate(x, folderOpen ? folderTarget.x : flip.x, transition),
            animate(y, folderOpen ? folderTarget.y : flip.y, transition),
            animate(scale, folderOpen ? 1 : flip.scale, transition),
            animate(clipRight, folderOpen ? 0 : flip.clipRight, transition),
            animate(clipBottom, folderOpen ? 0 : flip.clipBottom, transition),
          ]
        : [
            animate(x, destination.x, transition),
            animate(y, destination.y, transition),
            animate(width, destination.width, transition),
            animate(height, destination.height, transition),
            animate(scale, destination.scale, transition),
          ];
      activeAnimationsRef.current = [
        ...geometryControls,
        animate(opacity, destination.opacity, opacityTransition),
        animate(detailProgress, folderOpen ? 1 : 0, DETAIL_GEOMETRY_TRANSITION),
      ];

      Promise.all(geometryControls).then(() => {
        if (transitionGenerationRef.current !== generation) return;
        if (folderShell && !folderOpen) {
          x.jump(target.x);
          y.jump(target.y);
          width.jump(target.width);
          height.jump(target.height);
          scale.jump(target.scale);
          clipRight.jump(0);
          clipBottom.jump(0);
          detailProgress.jump(0);
        }
        layoutCompleteRef.current?.(item.id);
      });
    };

    // Keep the settled layout mounted throughout the reverse flight. Editing
    // is disabled from `detailOpen`, while `detailReady` remains true until
    // the exact board pixels have been reached; no intermediate preview
    // layout can appear inside the closing shell.
    run();

    return () => {
      stopAnimations();
    };
  }, [
    detailOpen,
    detailPresent,
    detailUsesDestinationBounds,
    detailTarget?.height,
    detailTarget?.opacity,
    detailTarget?.scale,
    detailTarget?.width,
    detailTarget?.x,
    detailTarget?.y,
    detailProgress,
    clipBottom,
    clipRight,
    height,
    folderOpen,
    folderTarget?.height,
    folderTarget?.opacity,
    folderTarget?.scale,
    folderTarget?.width,
    folderTarget?.x,
    folderTarget?.y,
    folderTransitioning,
    opacity,
    scale,
    selectionEmphasized,
    selectionScale,
    target.height,
    target.opacity,
    target.scale,
    target.width,
    target.x,
    target.y,
    transitionDelay,
    width,
    x,
    y,
  ]);

  const viewItem = useMemo(() => {
    const content = item.content || {};
    return {
      ...item,
      ...content,
      type: item.kind,
      x: item.pose.x,
      y: item.pose.y,
      width: "100%",
      height: "100%",
      color: preview || item.style?.color || "#fcfcfc",
      glow: preview || item.style?.glowColor || item.style?.color || "transparent",
      body: content.body || content.text || content.description || "",
      excerpt: content.excerpt || content.description || content.body || content.text || "",
      memberIds: content.memberIds || [],
      peekColors: content.peekColors,
    };
  }, [item, preview]);
  const documentMotion = useMemo(() => ({
    scale: documentScale,
    x: documentX,
    y: documentY,
    stageHeight: documentStageHeight,
  }), [documentScale, documentStageHeight, documentX, documentY]);
  const imageMotion = useMemo(() => ({
    width,
    height,
    scale: 1,
    x: 0,
    y: 0,
  }), [height, width]);
  const sharedAssetMotion = useMemo(() => ({
    baseWidth: assetBaseWidth,
    baseHeight: assetBaseHeight,
    detailPreviewScale: detailAssetScale,
    scale: assetScale,
    x: assetX,
    y: assetY,
    stageHeight: assetStageHeight,
  }), [
    assetBaseHeight,
    assetBaseWidth,
    assetScale,
    assetStageHeight,
    assetX,
    assetY,
    detailAssetScale,
  ]);
  const sharedWebMotion = useMemo(() => ({
    baseWidth: webBaseWidth,
    baseHeight: webBaseHeight,
    scale: webScale,
    x: webX,
    y: webY,
  }), [webScale, webX, webY]);
  const stableLoadAsset = useLatestCallback(onLoadAsset);
  const stablePointerDown = useLatestCallback(onPointerDown);
  const stableDoubleClick = useLatestCallback(onDoubleClick);
  const stableOpenStack = useLatestCallback(onOpenStack);
  const stableDetailUpdate = useLatestCallback(onDetailUpdate);
  const stableDetailDelete = useLatestCallback(onDetailDelete);
  const stableDetailDuplicate = useLatestCallback(onDetailDuplicate);
  const stableDetailExport = useLatestCallback(onDetailExport);
  const stableDetailMove = useLatestCallback(onDetailMove);
  const stableOpenExternal = useLatestCallback(onOpenExternal);
  const stableWebPreviewResolved = useLatestCallback(onWebPreviewResolved);

  const handleSelectionPointerEnter = (event) => {
    const pointer = {
      pointerInside: true,
      pointerType: event.pointerType,
      buttons: event.buttons,
    };
    selectionPointerRef.current = pointer;
    if (!shouldRevealSelectionIndicators({
      ...pointer,
      active: selectionControls && !detailPresent,
    })) {
      clearTimeout(selectionHideTimerRef.current);
      selectionHideTimerRef.current = null;
      if (selectionControls && !detailPresent) setSelectionIndicatorsVisible(false);
      return;
    }
    clearTimeout(selectionHideTimerRef.current);
    selectionHideTimerRef.current = null;
    setSelectionIndicatorsVisible(true);
  };

  const handleSelectionPointerLeave = () => {
    selectionPointerRef.current = {
      ...selectionPointerRef.current,
      pointerInside: false,
    };
    clearTimeout(selectionHideTimerRef.current);
    selectionHideTimerRef.current = null;
    if (!selectionControls || !selectionIndicatorsVisible) return;
    selectionHideTimerRef.current = setTimeout(() => {
      if (!shouldRevealSelectionIndicators({
        ...selectionPointerRef.current,
        active: selectionControls && !detailPresent,
      })) setSelectionIndicatorsVisible(false);
      selectionHideTimerRef.current = null;
    }, SELECTION_INDICATOR_HIDE_DELAY_MS);
  };

  return (
    <motion.div
      ref={wrapperRef}
      data-viewer-phase={detailOpen ? "open" : detailPresent ? "closing" : "board"}
      className={`world-item ${selected && !detailPresent ? "is-selected-node" : ""} ${dragging || resizing ? "is-interacting" : ""} ${detailPresent ? "is-detail-viewer" : ""} ${detailUsesDestinationBounds ? "is-fullscreen-editor" : ""} ${detailOpen ? "is-detail-open" : ""} ${detailPresent && detailReady ? "is-detail-ready" : ""} ${detailPresent && !detailOpen ? "is-detail-closing" : ""} ${folderOpen ? "is-folder-open" : ""} ${folderTransitioning ? "is-folder-transitioning" : ""}`}
      onPointerEnter={handleSelectionPointerEnter}
      onPointerLeave={handleSelectionPointerLeave}
      style={{
        x,
        y,
        width,
        height,
        opacity,
        scale,
        borderRadius: detailPresent && detailUsesDestinationBounds ? 0 : animatedRadius,
        clipPath: detailPresent && detailUsesDestinationBounds
          ? clipPath
          : isContainerKind(item) && (folderOpen || folderTransitioning)
            ? clipPath
            : "none",
        pointerEvents: detailPresent || (target.opacity !== 0 && target.interactive !== false) ? "auto" : "none",
        zIndex: detailPresent ? 2000 : (target.zIndex ?? item.z),
        "--item-radius-base": `${itemRadius}px`,
        "--item-radius": "var(--item-radius-base)",
        "--selection-corner-radius": `${itemRadius}px`,
        "--selection-inverse-scale": detailPresent ? inverseDetailScale : inverseLiveZoom,
        "--selection-indicator-inverse-scale": inverseIndicatorScale,
        "--selection-indicator-radius-scale": indicatorRadiusScale,
        "--detail-card-edge-opacity": detailEdgeOpacity,
        "--detail-viewport-width": `${detailViewport?.width || 1}px`,
        "--detail-viewport-height": `${detailViewport?.height || 1}px`,
      }}
    >
      <motion.div className="selection-visual" style={{ scale: selectionScale }}>
        <MemoizedSharedItemViewer
          item={viewItem}
          selected={selected}
          dimmed={dimmed}
          dragging={dragging}
          resizing={resizing}
          detailPresent={detailPresent}
          detailOpen={detailOpen}
          detailReady={detailReady}
          interactive={target.interactive !== false}
          documentMotion={documentMotion}
          imageMotion={imageMotion}
          assetMotion={sharedAssetMotion}
          webMotion={sharedWebMotion}
          detailActionsHost={detailActionsHost}
          loadAsset={stableLoadAsset}
          onPointerDown={stablePointerDown}
          onDoubleClick={stableDoubleClick}
          onOpenStack={stableOpenStack}
          onUpdate={stableDetailUpdate}
          onDelete={stableDetailDelete}
          onDuplicate={stableDetailDuplicate}
          onExport={stableDetailExport}
          onMove={stableDetailMove}
          onOpenExternal={stableOpenExternal}
          onWebPreviewResolved={stableWebPreviewResolved}
        />
        {selectionControls && (
          <SelectionCorners
            visible={selectionIndicatorsVisible || resizing}
            onResizePointerDown={onResizePointerDown}
          />
        )}
      </motion.div>
    </motion.div>
  );
}
