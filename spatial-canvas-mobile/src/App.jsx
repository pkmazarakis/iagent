import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { AnimatePresence, LayoutGroup, MotionConfig, animate, motion, useMotionValue, useTransform } from "motion/react";
import { Plus } from "@phosphor-icons/react";
import {
  applyGeometryPatches,
  beginTouchCameraGesture,
  autoOrganizeItemsAsync,
  CANVAS_SNAP_CONFIG,
  cameraFromRelativeTransform,
  cameraToFrameRect,
  collapsedContainerMemberTarget,
  CONTAINER_VIEW_MODE,
  createSpatialPageIndex,
  cullItemsForViewport,
  DEFAULT_WORLD_PAGE_SIZE,
  eligibleFolderMemberIds,
  findStackDropTarget,
  folderCanonicalPose,
  folderLayout as createFolderLayout,
  folderOpenOffset,
  isContainerKind,
  isStackInspectionItem,
  moveItemsToContainer,
  relativeCameraTransform,
  renderOriginForCamera,
  SELECTION_ORIGIN,
  shouldScaleSelection,
  updateTouchCameraGesture,
  useCanvasInteractions,
  visibleWorldRect,
  worldGeometryToRender,
  worldPageWindow,
  zoomCameraAt,
  selectionContainerId,
  transitionContainerView,
  visibleCollapsedMemberIds,
} from "./canvas/index.js";
import { CanvasItemNode } from "./canvas/CanvasItemNode.jsx";
import { containerTapIntent } from "./canvas/itemActivation.js";
import { wheelRoutingMode } from "./canvas/wheelRouting.js";
import { AppChrome } from "./components/Chrome.jsx";
import { ContextToolbar } from "./components/ContextToolbar.jsx";
import { DocumentImportDialog } from "./components/DocumentImportDialog.jsx";
import { ModalDialog } from "./components/ModalDialog.jsx";
import { AddMenu, FolderPicker, ScratchPad } from "./components/Overlays.jsx";
import { RadialColorPicker } from "./components/RadialColorPicker.jsx";
import { visualAssets } from "./data/assets.js";
import {
  centeredDetailGeometry,
  detailBackdropOpacity,
  fullscreenItemGeometry,
  fullscreenReaderGeometry,
} from "./motion/detailGeometry.js";
import { CAMERA_FOCUS_TRANSITION, STACK_STAGGER_SECONDS } from "./motion/transitions.js";
import {
  CLIENT_BOARD_ID,
  DEMO_VERSION,
  PRIMARY_BOARD_ID,
  createDemoBoard,
  createEmptyBoard,
} from "./data/demoBoard.js";
import { createSpatialRepository } from "./persistence/index.js";
import { platformBridge } from "./platform/index.js";
import {
  appendHistory,
  boardHistorySnapshot,
  sanitizeHistorySnapshot,
} from "./history/boardHistory.js";
import {
  buildImportedDocumentContent,
  detectOfficeDocumentFormat,
  DOCUMENT_FILE_ACCEPT,
  importedDocumentDimensions,
  OFFICE_DOCUMENT_MIME_TYPES,
} from "./import/documentImport.js";
import {
  buildWebClipContent,
  captureProviderForUrl,
  needsWebClipScreenshotCache,
} from "./import/webClip.js";
import { captureWebClipPng, downloadScreenshotPng } from "./import/webClipCapture.js";

const clone = (value) => structuredClone(value);
const uniqueId = (prefix) => `${prefix}-${crypto.randomUUID?.() || Math.random().toString(36).slice(2)}`;
const isEditableTarget = (target) => target instanceof HTMLElement && Boolean(target.closest("input, textarea, [contenteditable='true']"));
const INITIAL_VIEWPORT_SIZE = Object.freeze({ width: 1728, height: 896 });
const WORLD_PAGE_OVERSCAN = 0.5;
const WHEEL_PAN_MULTIPLIER = 1.75;
const WHEEL_ZOOM_SENSITIVITY = 0.00459;
const MAX_IMPORTED_DOCUMENT_BYTES = 40 * 1024 * 1024;

export function detailSurfaceColor(item) {
  const importedArtifact = item?.kind === "document" && Boolean(item?.content?.documentSource);
  return importedArtifact ? "#fff" : item?.style?.color || "#fcfcfc";
}

function scrollFullscreenDetail(host, deltaX, deltaY) {
  const locksHorizontalScroll = Boolean(
    host?.querySelector?.(".shared-document-stage, .shared-web-stage"),
  );
  const horizontalDelta = locksHorizontalScroll ? 0 : deltaX;
  if (locksHorizontalScroll && host.scrollLeft) host.scrollLeft = 0;

  const officeFrame = host?.querySelector?.(
    "iframe.document-asset-frame:not(.google-document-frame)",
  );
  try {
    const officeReader = officeFrame?.contentDocument?.querySelector?.(".office-reader-layer");
    if (officeReader) {
      officeReader.scrollBy({ left: deltaX, top: deltaY, behavior: "auto" });
      return;
    }
  } catch {
    // Cross-origin embeds keep their own native scrolling.
  }
  host?.scrollBy?.({ left: horizontalDelta, top: deltaY, behavior: "auto" });
}

function cameraPageWindow(camera, viewport) {
  const visible = visibleWorldRect(camera, viewport);
  const overscan = {
    x: Math.max(visible.width * WORLD_PAGE_OVERSCAN, DEFAULT_WORLD_PAGE_SIZE),
    y: Math.max(visible.height * WORLD_PAGE_OVERSCAN, DEFAULT_WORLD_PAGE_SIZE),
  };
  return worldPageWindow(visible, {
    overscan: {
      x: overscan.x,
      y: overscan.y,
    },
    pageSize: DEFAULT_WORLD_PAGE_SIZE,
  });
}

function cameraPageWindowKey(camera, viewport) {
  return cameraPageWindow(camera, viewport).signature;
}

function retainedPageBounds(camera, viewport) {
  const pageWindow = cameraPageWindow(camera, viewport);
  return {
    x: pageWindow.minPageX * pageWindow.pageSize,
    y: pageWindow.minPageY * pageWindow.pageSize,
    width: (pageWindow.maxPageX - pageWindow.minPageX + 1) * pageWindow.pageSize,
    height: (pageWindow.maxPageY - pageWindow.minPageY + 1) * pageWindow.pageSize,
  };
}

function rectContainsRect(outer, inner) {
  return inner.x >= outer.x
    && inner.y >= outer.y
    && inner.x + inner.width <= outer.x + outer.width
    && inner.y + inner.height <= outer.y + outer.height;
}

function useSpatialPageIndex(items) {
  const indexRef = useRef(null);
  const indexedItemsRef = useRef(null);

  if (!indexRef.current) {
    indexRef.current = createSpatialPageIndex().rebuild(items);
    indexedItemsRef.current = items;
  }

  if (indexedItemsRef.current !== items) {
    indexRef.current.reconcile(items);
    indexedItemsRef.current = items;
  }

  return { index: indexRef.current, revision: items };
}

function boundsFor(items) {
  const left = Math.min(...items.map((item) => item.pose.x));
  const top = Math.min(...items.map((item) => item.pose.y));
  const right = Math.max(...items.map((item) => item.pose.x + item.pose.width));
  const bottom = Math.max(...items.map((item) => item.pose.y + item.pose.height));
  return { x: left, y: top, width: right - left, height: bottom - top };
}

function pointInViewport(event, viewport, cachedRect = null) {
  const rect = cachedRect || viewport.getBoundingClientRect();
  return { x: event.clientX - rect.left, y: event.clientY - rect.top };
}

function fileAsDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

function platformFileAsBlob(picked, mimeType) {
  if (picked?.file instanceof Blob) return picked.file;
  if (picked?.bytes) {
    const bytes = picked.bytes instanceof Uint8Array
      ? picked.bytes
      : new Uint8Array(picked.bytes);
    return new Blob([bytes], { type: mimeType });
  }
  throw new Error("The selected file could not be read on this device.");
}

function itemAnimation(item, stacks, stackMemberIndexes, expandedStackId, activeFolderId, folderLayout, folderTarget) {
  if (item.stackId) {
    const stack = stacks.get(item.stackId);
    if (stack && activeFolderId === item.stackId) {
      const nestedTarget = folderLayout.get(item.id) || item.pose;
      return {
        ...nestedTarget,
        opacity: 1,
        scale: 1,
        zIndex: 1500 + (item.z || 0),
        interactive: true,
      };
    }
    if (stack && expandedStackId !== item.stackId) {
      const index = stackMemberIndexes.get(stack.id)?.get(item.id) ?? -1;
      return collapsedContainerMemberTarget(item, stack, index);
    }
  }

  if (isContainerKind(item) && activeFolderId === item.id && folderTarget) {
    return { ...folderTarget, zIndex: 1400, interactive: false };
  }

  if (isContainerKind(item) && expandedStackId === item.id) {
    return { x: item.pose.x, y: item.pose.y, width: item.pose.width, height: item.pose.height, opacity: 0.08, scale: 0.96, zIndex: Math.max(0, item.z - 5), interactive: false };
  }

  return { x: item.pose.x, y: item.pose.y, width: item.pose.width, height: item.pose.height, opacity: 1, scale: 1, zIndex: item.z, interactive: true };
}

export function App() {
  const initial = useMemo(() => createDemoBoard(), []);
  const initialRenderOrigin = useMemo(
    () => renderOriginForCamera(initial.board.camera),
    [initial],
  );
  const repository = useMemo(() => createSpatialRepository(), []);
  const appRootRef = useRef(null);
  const viewportRef = useRef(null);
  const marqueeRef = useRef(null);
  const snapLineXRef = useRef(null);
  const snapLineYRef = useRef(null);
  const zoomIndicatorRef = useRef(null);
  const renderCountRef = useRef(0);
  const performanceStatsRef = useRef({
    liveCameraFrames: 0,
    cameraCommits: 0,
    liveItemFrames: 0,
    itemCommits: 0,
  });
  const itemsRef = useRef([]);
  const itemByIdRef = useRef(new Map());
  const itemRenderersRef = useRef(new Map());
  const liveItemGeometryRef = useRef(new Map());
  const boardRef = useRef(null);
  const selectionRef = useRef([]);
  const selectionOriginRef = useRef(SELECTION_ORIGIN.ORDINARY);
  const marqueeBaseOriginRef = useRef(SELECTION_ORIGIN.ORDINARY);
  const liveCameraRef = useRef(initial.board.camera);
  const renderOriginRef = useRef(initialRenderOrigin);
  const viewportSizeRef = useRef(INITIAL_VIEWPORT_SIZE);
  const viewportRectRef = useRef(null);
  const pageWindowKeyRef = useRef(
    cameraPageWindowKey(initial.board.camera, INITIAL_VIEWPORT_SIZE),
  );
  const retainedPageBoundsRef = useRef(
    retainedPageBounds(initial.board.camera, INITIAL_VIEWPORT_SIZE),
  );
  const touchPointsRef = useRef(new Map());
  const touchCameraGestureRef = useRef(null);
  const itemPressRef = useRef(null);
  const lastTouchTapRef = useRef(null);
  const stackTransitionFramesRef = useRef([]);
  const stackTransitionTimerRef = useRef(null);
  const stackMotionRef = useRef(null);
  const inspectDismissRef = useRef(null);
  const inspectDismissTimerRef = useRef(null);
  const cameraAnimationsRef = useRef([]);
  const scheduledCameraFrameRef = useRef(null);
  const scheduledCameraUpdateRef = useRef(null);
  const focusReturnCameraRef = useRef(null);
  const folderReturnCameraRef = useRef(null);
  const activeFolderOffsetRef = useRef({ x: 0, y: 0 });
  const suppressTouchRef = useRef(false);
  const safariGestureRef = useRef(null);
  const highlightedSnapIdsRef = useRef(new Set());
  const gestureStartRef = useRef(null);
  const undoRef = useRef([]);
  const redoRef = useRef([]);
  const organizeGenerationRef = useRef(0);
  const historyTransitionGenerationRef = useRef(0);
  const historyTransitionTimerRef = useRef(null);
  const boardSwitchGenerationRef = useRef(0);
  const moveBoardWriteRef = useRef(false);
  const activeBoardWriteRef = useRef(Promise.resolve());
  const snapshotWriteRef = useRef(Promise.resolve());
  const itemRevisionRef = useRef(0);
  const savedItemRevisionRef = useRef(0);
  const saveTimerRef = useRef(null);
  const urlCaptureRequestRef = useRef(0);
  const webClipCacheJobsRef = useRef(new Map());
  const wheelCommitTimerRef = useRef(null);
  const zoomTimerRef = useRef(null);
  const initialWorldTransform = relativeCameraTransform(
    initial.board.camera,
    initialRenderOrigin,
  );
  const worldX = useMotionValue(initialWorldTransform.x);
  const worldY = useMotionValue(initialWorldTransform.y);
  const worldScale = useMotionValue(initial.board.camera.zoom);
  const detailTransitionProgress = useMotionValue(0);
  const detailBackdropOpacityMotion = useTransform(
    detailTransitionProgress,
    detailBackdropOpacity,
  );

  const [board, setBoard] = useState(initial.board);
  const [items, setItems] = useState(initial.items);
  const [boards, setBoards] = useState([initial.board]);
  const [hydrated, setHydrated] = useState(false);
  const [selectedIds, setSelectedIds] = useState([]);
  const [selectionOrigin, setSelectionOrigin] = useState(SELECTION_ORIGIN.ORDINARY);
  const [camera, setCamera] = useState(initial.board.camera);
  const [pageCamera, setPageCamera] = useState(initial.board.camera);
  const [renderOrigin, setRenderOrigin] = useState(initialRenderOrigin);
  const [viewportSize, setViewportSize] = useState(INITIAL_VIEWPORT_SIZE);
  const [interaction, setInteraction] = useState(null);
  const [interactionItemIds, setInteractionItemIds] = useState([]);
  const [containerView, setContainerView] = useState(null);
  const [stackTransitionId, setStackTransitionId] = useState(null);
  const [folderCanvasTransitionId, setFolderCanvasTransitionId] = useState(null);
  const [detailId, setDetailId] = useState(null);
  const [detailPresenceId, setDetailPresenceId] = useState(null);
  const [focusedIds, setFocusedIds] = useState([]);
  const [addMenuOpen, setAddMenuOpen] = useState(false);
  const [folderPickerOpen, setFolderPickerOpen] = useState(false);
  const [boardsOpen, setBoardsOpen] = useState(false);
  const [scratchOpen, setScratchOpen] = useState(false);
  const [colorOpen, setColorOpen] = useState(false);
  const [colorPreview, setColorPreview] = useState(null);
  const [urlCapture, setUrlCapture] = useState(null);
  const [documentImport, setDocumentImport] = useState(null);
  const [renameStackId, setRenameStackId] = useState(null);
  const [moveItemId, setMoveItemId] = useState(null);
  const [spaceDown, setSpaceDown] = useState(false);
  const [zoomVisible, setZoomVisible] = useState(false);
  const [historyRevision, setHistoryRevision] = useState(0);
  const [historyTransition, setHistoryTransition] = useState(null);
  const loadAsset = useCallback((assetId) => repository.getAsset(assetId), [repository]);
  const openExternal = useCallback((url) => {
    platformBridge.openExternal(url).catch((error) => console.error(error));
  }, []);

  const expandedStackId = containerView?.id || null;
  const activeFolderId = containerView?.mode === CONTAINER_VIEW_MODE.CANVAS
    ? containerView.id
    : null;

  renderCountRef.current += 1;

  const itemById = useMemo(() => new Map(items.map((item) => [item.id, item])), [items]);
  itemsRef.current = items;
  itemByIdRef.current = itemById;
  boardRef.current = board;
  selectionRef.current = selectedIds;
  viewportSizeRef.current = viewportSize;

  const stackMap = useMemo(() => new Map(items.filter((item) => item.kind === "stack" || item.kind === "folder").map((item) => [item.id, item])), [items]);
  const stackMemberIndexes = useMemo(() => new Map(
    [...stackMap.values()].map((stack) => [
      stack.id,
      new Map((stack.content?.memberIds || []).map((id, index) => [id, index])),
    ]),
  ), [stackMap]);
  const selectedItems = useMemo(
    () => selectedIds.map((id) => itemById.get(id)).filter(Boolean),
    [itemById, selectedIds],
  );
  const activeDetailItem = detailPresenceId ? itemById.get(detailPresenceId) : null;
  const integratedDetailHeader = Boolean(
    activeDetailItem?.kind === "document"
      && activeDetailItem?.content?.documentSource === "upload"
      && ["docx", "pptx", "xlsx"].includes(activeDetailItem?.content?.documentFormat),
  );
  const selectedKind = selectedItems.length === 1 ? selectedItems[0].kind : null;
  const selectedFolderMemberIds = useMemo(
    () => eligibleFolderMemberIds(items, selectedIds),
    [items, selectedIds],
  );
  const currentSelectionFolderId = useMemo(
    () => selectionContainerId(items, selectedIds),
    [items, selectedIds],
  );
  const availableFolders = useMemo(
    () => items
      .filter((item) => item.kind === "folder" && !selectedIds.includes(item.id))
      .map((item) => ({
        id: item.id,
        title: item.content?.title,
        count: item.content?.memberIds?.length || 0,
      })),
    [items, selectedIds],
  );
  const fullscreenDetailTarget = useMemo(() => worldGeometryToRender(
    fullscreenItemGeometry(camera, viewportSize),
    renderOrigin,
  ), [camera, renderOrigin, viewportSize]);
  const fullscreenFolderTarget = useMemo(
    () => fullscreenItemGeometry(camera, viewportSize),
    [camera, viewportSize],
  );
  const activeFolderLayout = useMemo(() => {
    const folder = activeFolderId ? stackMap.get(activeFolderId) : null;
    if (!folder) return new Map();
    const members = (folder.content?.memberIds || []).map((id) => itemById.get(id)).filter(Boolean);
    return createFolderLayout(members, activeFolderOffsetRef.current);
  }, [activeFolderId, itemById, stackMap]);
  // The index stores canonical destination poses and reconciles only changed
  // memberships. Content edits do not tear down/rebuild spatial pages.
  const {
    index: spatialPageIndex,
    revision: spatialIndexRevision,
  } = useSpatialPageIndex(items);
  const renderItems = useMemo(() => cullItemsForViewport({
    items,
    camera: pageCamera,
    viewport: viewportSize,
    pageIndex: spatialPageIndex,
    selectedIds,
    pinSelected: false,
    pinnedIds: interactionItemIds,
    detailId: detailPresenceId,
    pinDetail: true,
    stacks: stackMap,
    itemById,
    expandedStackId: expandedStackId || activeFolderId,
    transitionStackId: stackTransitionId,
    expandedGroupOffset: activeFolderId ? activeFolderOffsetRef.current : null,
    transitionGroupOffset: folderCanvasTransitionId === stackTransitionId
      ? activeFolderOffsetRef.current
      : null,
    overscan: WORLD_PAGE_OVERSCAN,
    minimumOverscan: DEFAULT_WORLD_PAGE_SIZE,
  }), [activeFolderId, detailPresenceId, expandedStackId, folderCanvasTransitionId, interactionItemIds, itemById, pageCamera, selectedIds, spatialIndexRevision, spatialPageIndex, stackMap, stackTransitionId, viewportSize]);

  const setSelection = useCallback((next, { origin = SELECTION_ORIGIN.ORDINARY } = {}) => {
    const clean = [...new Set(next)];
    selectionRef.current = clean;
    selectionOriginRef.current = origin;
    setSelectedIds(clean);
    setSelectionOrigin(origin);
  }, []);

  const cancelStackTransition = useCallback(() => {
    for (const frame of stackTransitionFramesRef.current) {
      cancelAnimationFrame(frame);
    }
    stackTransitionFramesRef.current = [];
    clearTimeout(stackTransitionTimerRef.current);
    stackTransitionTimerRef.current = null;
    stackMotionRef.current = null;
  }, []);

  const beginStackMotion = useCallback((stackId, phase) => {
    const stack = itemByIdRef.current.get(stackId);
    const pending = new Set((stack?.content?.memberIds || []).filter(
      (id) => itemRenderersRef.current.has(id),
    ));
    if (isContainerKind(stack) && itemRenderersRef.current.has(stackId)) {
      pending.add(stackId);
    }
    stackMotionRef.current = { stackId, phase, pending };
    if (!pending.size) {
      stackMotionRef.current = null;
      setStackTransitionId(null);
      setFolderCanvasTransitionId((current) => current === stackId ? null : current);
    }
  }, []);

  const finishStackMemberMotion = useCallback((stackId, memberId) => {
    const motionState = stackMotionRef.current;
    if (!motionState || motionState.stackId !== stackId) return;
    motionState.pending.delete(memberId);
    if (motionState.pending.size) return;
    stackMotionRef.current = null;
    setStackTransitionId((current) => current === stackId ? null : current);
    setFolderCanvasTransitionId((current) => current === stackId ? null : current);
  }, []);

  const openContainerInline = useCallback((stackId) => {
    cancelStackTransition();
    // First mount only destination-page members at the collapsed source pose.
    // The second animation frame then changes their targets so they spring out
    // without retaining every hidden member while the stack is closed.
    setFolderCanvasTransitionId(null);
    setContainerView(null);
    setStackTransitionId(stackId);
    setSelection([stackId]);
    const firstFrame = requestAnimationFrame(() => {
      const secondFrame = requestAnimationFrame(() => {
        stackTransitionFramesRef.current = [];
        beginStackMotion(stackId, "open");
        setContainerView(transitionContainerView(null, { type: "open-inline", id: stackId }));
      });
      stackTransitionFramesRef.current = [secondFrame];
    });
    stackTransitionFramesRef.current = [firstFrame];
  }, [beginStackMotion, cancelStackTransition, setSelection]);

  const closeContainerInline = useCallback(() => {
    cancelStackTransition();
    if (!expandedStackId || activeFolderId) {
      setStackTransitionId(null);
      return;
    }
    const closingId = expandedStackId;
    // Retain only currently paged children long enough to spring back into the
    // stack, then discard their hidden DOM nodes.
    setStackTransitionId(closingId);
    beginStackMotion(closingId, "close");
    setContainerView((current) => transitionContainerView(current, { type: "close" }));
  }, [activeFolderId, beginStackMotion, cancelStackTransition, expandedStackId]);

  const openDetail = useCallback((id) => {
    setDetailPresenceId(id);
    setDetailId(id);
  }, []);

  const closeDetail = useCallback(() => {
    if (!detailId && !detailPresenceId) return;
    setDetailId(null);
  }, [detailId, detailPresenceId]);

  const finishDetailExit = useCallback(() => {
    setDetailPresenceId(null);
  }, []);

  const syncPerformanceDiagnostics = useCallback(() => {
    if (!import.meta.env.DEV || !appRootRef.current) return;
    const stats = performanceStatsRef.current;
    appRootRef.current.dataset.liveCameraFrames = String(stats.liveCameraFrames);
    appRootRef.current.dataset.cameraCommits = String(stats.cameraCommits);
    appRootRef.current.dataset.liveItemFrames = String(stats.liveItemFrames);
    appRootRef.current.dataset.itemCommits = String(stats.itemCommits);
  }, []);

  const registerItemRenderer = useCallback((id, renderer, expected = null) => {
    if (renderer) {
      itemRenderersRef.current.set(id, renderer);
      return;
    }
    if (!expected || itemRenderersRef.current.get(id) === expected) {
      itemRenderersRef.current.delete(id);
    }
  }, []);

  const refreshPageCamera = useCallback((next, force = false, synchronous = false) => {
    const nextKey = cameraPageWindowKey(next, viewportSizeRef.current);
    if (!force && nextKey === pageWindowKeyRef.current) return;
    const update = () => {
      pageWindowKeyRef.current = nextKey;
      setPageCamera(next);
    };
    if (synchronous) flushSync(update);
    else update();
  }, []);

  const rebaseRenderOrigin = useCallback((nextCamera) => {
    const currentOrigin = renderOriginRef.current;
    const nextOrigin = renderOriginForCamera(nextCamera, undefined, currentOrigin);
    if (nextOrigin.x === currentOrigin.x && nextOrigin.y === currentOrigin.y) {
      return currentOrigin;
    }

    const delta = {
      x: nextOrigin.x - currentOrigin.x,
      y: nextOrigin.y - currentOrigin.y,
    };
    for (const renderer of itemRenderersRef.current.values()) {
      renderer.rebase?.(delta);
    }
    renderOriginRef.current = nextOrigin;
    setRenderOrigin(nextOrigin);
    return nextOrigin;
  }, []);

  const renderCameraVisual = useCallback((next, { refreshPages = true } = {}) => {
    liveCameraRef.current = next;
    const origin = rebaseRenderOrigin(next);
    const transform = relativeCameraTransform(next, origin);
    worldX.jump(transform.x);
    worldY.jump(transform.y);
    worldScale.jump(transform.scale);
    if (refreshPages) refreshPageCamera(next);
    if (zoomIndicatorRef.current) zoomIndicatorRef.current.textContent = `${Math.round(next.zoom * 100)}%`;
  }, [rebaseRenderOrigin, refreshPageCamera, worldScale, worldX, worldY]);

  const commitCameraVisual = useCallback((next = liveCameraRef.current) => {
    performanceStatsRef.current.cameraCommits += 1;
    syncPerformanceDiagnostics();
    liveCameraRef.current = next;
    // The retained set is page-window based, so a camera commit inside the
    // current window does not need to re-query or remount canvas items.
    refreshPageCamera(next);
    setCamera(next);
    setBoard((current) => ({ ...current, camera: next }));
  }, [refreshPageCamera, syncPerformanceDiagnostics]);

  const stopCameraAnimation = useCallback(() => {
    if (cameraAnimationsRef.current.length) {
      liveCameraRef.current = cameraFromRelativeTransform({
        x: worldX.get(),
        y: worldY.get(),
        scale: worldScale.get(),
      }, renderOriginRef.current);
    }
    cameraAnimationsRef.current.forEach((control) => control.stop());
    cameraAnimationsRef.current = [];
    return liveCameraRef.current;
  }, [worldScale, worldX, worldY]);

  const animateCameraTo = useCallback((next, onComplete) => {
    stopCameraAnimation();
    const current = liveCameraRef.current;
    const nextVisible = visibleWorldRect(next, viewportSizeRef.current);
    const requiresSynchronousMount = !rectContainsRect(
      retainedPageBoundsRef.current,
      nextVisible,
    );
    if (requiresSynchronousMount) refreshPageCamera(next, true, true);
    const origin = rebaseRenderOrigin(next);
    const from = relativeCameraTransform(current, origin);
    const destination = relativeCameraTransform(next, origin);
    worldX.jump(from.x);
    worldY.jump(from.y);
    worldScale.jump(from.scale);
    const controls = [
      animate(worldX, destination.x, CAMERA_FOCUS_TRANSITION),
      animate(worldY, destination.y, CAMERA_FOCUS_TRANSITION),
      animate(worldScale, destination.scale, CAMERA_FOCUS_TRANSITION),
    ];
    cameraAnimationsRef.current = controls;
    Promise.all(controls).then(() => {
      if (cameraAnimationsRef.current !== controls) return;
      cameraAnimationsRef.current = [];
      renderCameraVisual(next);
      commitCameraVisual(next);
      onComplete?.();
    });
  }, [commitCameraVisual, rebaseRenderOrigin, refreshPageCamera, renderCameraVisual, stopCameraAnimation, worldScale, worldX, worldY]);

  const openFolderCanvas = useCallback((folderId) => {
    cancelStackTransition();
    const folder = itemByIdRef.current.get(folderId);
    if (!isContainerKind(folder) || expandedStackId !== folderId || activeFolderId) return;
    const members = (folder?.content?.memberIds || [])
      .map((id) => itemByIdRef.current.get(id))
      .filter(Boolean);
    folderReturnCameraRef.current = { ...liveCameraRef.current };
    // Capture the opening translation once. The nested canvas can then pan
    // infinitely without being re-centered after each camera commit.
    activeFolderOffsetRef.current = folderOpenOffset(
      members,
      liveCameraRef.current,
      viewportSizeRef.current,
    );
    setFolderCanvasTransitionId(folderId);
    setStackTransitionId(folderId);
    setSelection([folderId]);
    beginStackMotion(folderId, "canvas-open");
    setContainerView((current) => transitionContainerView(current, {
      type: "expand-canvas",
      id: folderId,
    }));
  }, [activeFolderId, beginStackMotion, cancelStackTransition, expandedStackId, setSelection]);

  const closeFolderCanvas = useCallback(() => {
    cancelStackTransition();
    if (!activeFolderId) return;
    const closingId = activeFolderId;
    const parentCamera = folderReturnCameraRef.current;
    folderReturnCameraRef.current = null;
    setFolderCanvasTransitionId(closingId);
    setStackTransitionId(closingId);
    beginStackMotion(closingId, "canvas-close");
    setContainerView((current) => transitionContainerView(current, { type: "back" }));
    setSelection([closingId]);
    if (parentCamera) animateCameraTo(parentCamera);
  }, [activeFolderId, animateCameraTo, beginStackMotion, cancelStackTransition, setSelection]);

  const focusSelection = useCallback(() => {
    const selected = itemsRef.current.filter((item) => selectionRef.current.includes(item.id));
    if (!selected.length || detailPresenceId) return;
    const viewport = viewportSizeRef.current;
    const selectedBounds = boundsFor(selected);
    const padding = viewport.width <= 640 ? 52 : 120;
    const next = cameraToFrameRect(selectedBounds, viewport, {
      padding,
      minZoom: 0.2,
      maxZoom: 1.55,
    });
    if (!focusReturnCameraRef.current) focusReturnCameraRef.current = { ...liveCameraRef.current };
    setFocusedIds(selected.map((item) => item.id));
    animateCameraTo(next);
  }, [animateCameraTo, detailPresenceId]);

  const clearFocus = useCallback(() => {
    const previous = focusReturnCameraRef.current;
    setFocusedIds([]);
    focusReturnCameraRef.current = null;
    if (previous) animateCameraTo(previous);
  }, [animateCameraTo]);

  const showZoomFeedback = useCallback(() => {
    setZoomVisible(true);
    clearTimeout(zoomTimerRef.current);
    zoomTimerRef.current = setTimeout(() => setZoomVisible(false), 700);
  }, []);

  const applyLiveCamera = useCallback((next, meta = {}) => {
    performanceStatsRef.current.liveCameraFrames += 1;
    syncPerformanceDiagnostics();
    const nextVisible = visibleWorldRect(next, viewportSizeRef.current);
    const requiresSynchronousMount = !rectContainsRect(
      retainedPageBoundsRef.current,
      nextVisible,
    );
    if (requiresSynchronousMount) refreshPageCamera(next, true, true);
    renderCameraVisual(next, { refreshPages: !requiresSynchronousMount });
    if (meta.source === "wheel") {
      clearTimeout(wheelCommitTimerRef.current);
      wheelCommitTimerRef.current = setTimeout(() => commitCameraVisual(liveCameraRef.current), 90);
    }
    if (meta.mode === "zoom") showZoomFeedback();
  }, [commitCameraVisual, refreshPageCamera, renderCameraVisual, showZoomFeedback, syncPerformanceDiagnostics]);

  const scheduleLiveCamera = useCallback((next, meta) => {
    scheduledCameraUpdateRef.current = { next, meta };
    if (scheduledCameraFrameRef.current != null) return;
    scheduledCameraFrameRef.current = requestAnimationFrame(() => {
      scheduledCameraFrameRef.current = null;
      const pending = scheduledCameraUpdateRef.current;
      scheduledCameraUpdateRef.current = null;
      if (pending) applyLiveCamera(pending.next, pending.meta);
    });
  }, [applyLiveCamera]);

  const flushScheduledCamera = useCallback(() => {
    if (scheduledCameraFrameRef.current != null) {
      cancelAnimationFrame(scheduledCameraFrameRef.current);
      scheduledCameraFrameRef.current = null;
    }
    const pending = scheduledCameraUpdateRef.current;
    scheduledCameraUpdateRef.current = null;
    if (pending) applyLiveCamera(pending.next, pending.meta);
  }, [applyLiveCamera]);

  useEffect(() => () => {
    if (scheduledCameraFrameRef.current != null) {
      cancelAnimationFrame(scheduledCameraFrameRef.current);
    }
    scheduledCameraFrameRef.current = null;
    scheduledCameraUpdateRef.current = null;
  }, []);

  const renderItemChanges = useCallback((changes, meta = {}) => {
    if (changes.length) {
      performanceStatsRef.current.liveItemFrames += 1;
      syncPerformanceDiagnostics();
    }
    for (const change of changes) {
      const item = itemByIdRef.current.get(change.id);
      if (!item) continue;
      const current = liveItemGeometryRef.current.get(change.id) || item.pose;
      const next = {
        ...current,
        ...(change.x == null ? {} : { x: change.x }),
        ...(change.y == null ? {} : { y: change.y }),
        ...(change.width == null ? {} : { width: change.width }),
        ...(change.height == null ? {} : { height: change.height }),
      };
      liveItemGeometryRef.current.set(change.id, next);
      itemRenderersRef.current
        .get(change.id)
        ?.setGeometry(worldGeometryToRender(next, renderOriginRef.current));

      // A collapsed container is visually composed from its real retained
      // child surfaces. Move those visible layers from the shell's live pose
      // without adding per-frame canonical patches for every folder member.
      if (meta.source === "drag"
        && isContainerKind(item)
        && expandedStackId !== item.id
        && activeFolderId !== item.id) {
        const liveContainer = { ...item, pose: next };
        for (const memberId of visibleCollapsedMemberIds(item)) {
          const member = itemByIdRef.current.get(memberId);
          if (!member) continue;
          const memberIndex = stackMemberIndexes.get(item.id)?.get(memberId)
            ?? item.content?.memberIds?.indexOf(memberId)
            ?? -1;
          const memberTarget = collapsedContainerMemberTarget(
            member,
            liveContainer,
            memberIndex,
          );
          itemRenderersRef.current
            .get(memberId)
            ?.setGeometry(worldGeometryToRender(memberTarget, renderOriginRef.current));
        }
      }
    }
  }, [activeFolderId, expandedStackId, stackMemberIndexes, syncPerformanceDiagnostics]);

  const commitLiveItemGeometry = useCallback(({ translateFolderMembers = false } = {}) => {
    if (!liveItemGeometryRef.current.size) {
      gestureStartRef.current = null;
      return;
    }
    const renderedPatches = new Map(liveItemGeometryRef.current);
    const patches = new Map();
    for (const [itemId, renderedPose] of renderedPatches) {
      const item = itemByIdRef.current.get(itemId);
      const pose = renderedPose && activeFolderId && item?.stackId === activeFolderId
        ? folderCanonicalPose(renderedPose, activeFolderOffsetRef.current)
        : renderedPose;
      if (pose) patches.set(itemId, pose);
    }
    const before = gestureStartRef.current || itemsRef.current;
    const now = Date.now();
    const next = applyGeometryPatches(itemsRef.current, patches, {
      translateFolderMembers,
      now,
    });
    const changed = next.some((item, index) => item !== itemsRef.current[index]);
    if (!changed) {
      liveItemGeometryRef.current.clear();
      gestureStartRef.current = null;
      return;
    }
    if (patches.size) {
      undoRef.current = appendHistory(
        undoRef.current,
        boardHistorySnapshot(before, selectionRef.current),
      );
      redoRef.current = [];
      setHistoryRevision((revision) => revision + 1);
      performanceStatsRef.current.itemCommits += 1;
      itemRevisionRef.current += 1;
      syncPerformanceDiagnostics();
    }
    liveItemGeometryRef.current.clear();
    gestureStartRef.current = null;
    itemsRef.current = next;
    setItems(next);
  }, [activeFolderId, syncPerformanceDiagnostics]);

  const commitMutation = useCallback((mutator, options = {}) => {
    const selectionBefore = options.selectionBefore || selectionRef.current;
    const current = itemsRef.current;
    const next = mutator(current);
    if (next === current) return;

    // Mutations and history must be committed synchronously from the same
    // immutable board snapshot. Putting these side effects inside a React
    // state updater made development StrictMode replay them and could record
    // the post-action selection instead of the selected source cards.
    undoRef.current = appendHistory(
      undoRef.current,
      boardHistorySnapshot(current, selectionBefore),
    );
    redoRef.current = [];
    itemsRef.current = next;
    itemRevisionRef.current += 1;
    setHistoryRevision((revision) => revision + 1);
    setItems(next);
  }, []);

  const stackDroppedItem = useCallback((draggedId, droppedPose) => {
    if (!droppedPose || selectionRef.current.length !== 1) return;
    const dragged = itemsRef.current.find((item) => item.id === draggedId);
    if (!dragged || dragged.kind === "stack" || dragged.kind === "folder" || dragged.stackId) return;
    const target = findStackDropTarget({
      draggedId,
      droppedPose,
      items: itemsRef.current,
      minimumOverlap: 0.34,
    });
    if (!target) return;

    if (target.kind === "stack" || target.kind === "folder") {
      cancelStackTransition();
      stackMotionRef.current = { stackId: target.id, phase: "create", pending: new Set([draggedId]) };
      setStackTransitionId(target.id);
      commitMutation((current) => moveItemsToContainer(current, [draggedId], target.id, Date.now()));
      setSelection([target.id]);
      return;
    }

    const members = [target, { ...dragged, pose: droppedPose }];
    const memberBounds = boundsFor(members);
    const id = uniqueId("stack");
    const now = Date.now();
    const stack = {
      id,
      boardId: boardRef.current.id,
      kind: "stack",
      pose: {
        x: memberBounds.x + Math.max(0, (memberBounds.width - 220) / 2),
        y: memberBounds.y + Math.max(0, (memberBounds.height - 155) / 2),
        width: 220,
        height: 155,
        rotation: 0,
      },
      z: Math.max(...itemsRef.current.map((item) => item.z), 0) + 1,
      style: { color: "#c8faf2", glowColor: "#8cf1df", cornerRadius: 18 },
      content: {
        title: "Untitled stack",
        subtitle: "2 collected things",
        memberIds: members.map((item) => item.id),
      },
      stackId: null,
      createdAt: now,
      updatedAt: now,
    };
    cancelStackTransition();
    stackMotionRef.current = { stackId: id, phase: "create", pending: new Set(stack.content.memberIds) };
    setStackTransitionId(id);
    commitMutation((current) => [
      ...current.map((item) => stack.content.memberIds.includes(item.id)
        ? { ...item, stackId: id, updatedAt: now }
        : item),
      stack,
    ]);
    setSelection([id]);
  }, [cancelStackTransition, commitMutation, setSelection]);

  const applyHistorySnapshot = useCallback((snapshot, direction) => {
    const targetSnapshot = sanitizeHistorySnapshot(snapshot);
    const currentItems = itemsRef.current;
    const currentById = new Map(currentItems.map((item) => [item.id, item]));
    const targetById = new Map(targetSnapshot.items.map((item) => [item.id, item]));
    const allIds = new Set([...currentById.keys(), ...targetById.keys()]);
    const affectedIds = [...allIds].filter((id) => currentById.get(id) !== targetById.get(id));
    const groupIds = affectedIds.filter((id) => {
      const before = currentById.get(id);
      const after = targetById.get(id);
      return before?.kind === "stack"
        || before?.kind === "folder"
        || after?.kind === "stack"
        || after?.kind === "folder";
    });
    const animatedIds = new Set(affectedIds);
    for (const groupId of groupIds) {
      for (const memberId of currentById.get(groupId)?.content?.memberIds || []) animatedIds.add(memberId);
      for (const memberId of targetById.get(groupId)?.content?.memberIds || []) animatedIds.add(memberId);
    }

    const generation = ++historyTransitionGenerationRef.current;
    clearTimeout(historyTransitionTimerRef.current);
    cancelStackTransition();
    setDetailId(null);
    setDetailPresenceId(null);
    setContainerView(null);
    setFolderCanvasTransitionId(null);
    setFolderPickerOpen(false);
    setColorOpen(false);
    setColorPreview(null);

    const transition = {
      generation,
      direction,
      groupIds,
      memberIds: [...animatedIds],
    };
    // Pin affected retained nodes for one preparation frame. This lets grouped
    // children fan out from their live stack pose instead of remounting at the
    // destination when history removes a shell.
    flushSync(() => {
      setInteractionItemIds(transition.memberIds);
      setHistoryTransition(transition);
    });

    itemsRef.current = targetSnapshot.items;
    selectionRef.current = targetSnapshot.selectedIds;
    requestAnimationFrame(() => {
      if (historyTransitionGenerationRef.current !== generation) return;
      itemRevisionRef.current += 1;
      setItems(targetSnapshot.items);
      setSelection(targetSnapshot.selectedIds);
      historyTransitionTimerRef.current = setTimeout(() => {
        if (historyTransitionGenerationRef.current !== generation) return;
        setInteractionItemIds([]);
        setHistoryTransition(null);
        setSelection(targetSnapshot.selectedIds);
        historyTransitionTimerRef.current = null;
      }, 820);
    });
  }, [cancelStackTransition, setSelection]);

  const undo = useCallback(() => {
    const previous = undoRef.current.pop();
    if (!previous) return;
    redoRef.current = appendHistory(
      redoRef.current,
      boardHistorySnapshot(itemsRef.current, selectionRef.current),
    );
    setHistoryRevision((revision) => revision + 1);
    applyHistorySnapshot(previous, "undo");
  }, [applyHistorySnapshot]);

  const redo = useCallback(() => {
    const next = redoRef.current.pop();
    if (!next) return;
    undoRef.current = appendHistory(
      undoRef.current,
      boardHistorySnapshot(itemsRef.current, selectionRef.current),
    );
    setHistoryRevision((revision) => revision + 1);
    applyHistorySnapshot(next, "redo");
  }, [applyHistorySnapshot]);

  useEffect(() => () => clearTimeout(historyTransitionTimerRef.current), []);

  useEffect(() => {
    if (!import.meta.env.DEV) return undefined;
    window.__spatialPerf = performanceStatsRef.current;
    return () => {
      if (window.__spatialPerf === performanceStatsRef.current) delete window.__spatialPerf;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        await repository.initialize({ seed: false });
        const version = await repository.getSetting("demoVersion", 0);
        let availableBoards = await repository.listBoards();
        if (!availableBoards.length) {
          const primary = createDemoBoard(PRIMARY_BOARD_ID, "primary");
          const client = createDemoBoard(CLIENT_BOARD_ID, "client");
          await repository.replaceBoardSnapshot(primary);
          await repository.replaceBoardSnapshot(client);
          await repository.setSetting("activeBoardId", PRIMARY_BOARD_ID);
          availableBoards = await repository.listBoards();
        }
        if (version !== DEMO_VERSION) {
          // Demo revisions must never clear user-authored boards or binary
          // assets. Seed only an empty database, then advance the marker.
          await repository.setSetting("demoVersion", DEMO_VERSION);
        }
        // Keep the second demo space available even if an interrupted seed or
        // older preview left only the primary snapshot behind.
        if (!availableBoards.some((entry) => entry.id === CLIENT_BOARD_ID)) {
          await repository.replaceBoardSnapshot(createDemoBoard(CLIENT_BOARD_ID, "client"));
          availableBoards = await repository.listBoards();
        }
        const activeId = await repository.getSetting("activeBoardId", PRIMARY_BOARD_ID);
        const snapshot = await repository.getBoardSnapshot(activeId) || createDemoBoard();
        if (cancelled) return;
        itemsRef.current = snapshot.items;
        itemRevisionRef.current = 0;
        savedItemRevisionRef.current = 0;
        liveItemGeometryRef.current.clear();
        setBoard(snapshot.board);
        setCamera(snapshot.board.camera);
        renderCameraVisual(snapshot.board.camera);
        setItems(snapshot.items);
        setBoards(availableBoards);
        setHydrated(true);
      } catch (error) {
        console.error(error);
        setHydrated(true);
      }
    })();
    return () => {
      cancelled = true;
      // React's development StrictMode intentionally replays effects. Closing
      // the shared Dexie instance here leaves the replayed app with a stale
      // connection and silently breaks autosave. The database is scoped to
      // the page and is released by the browser/Electron process on teardown.
    };
  }, [renderCameraVisual, repository]);

  useEffect(() => {
    renderCameraVisual(camera);
  }, [camera, renderCameraVisual]);

  useLayoutEffect(() => {
    retainedPageBoundsRef.current = retainedPageBounds(pageCamera, viewportSize);
  }, [pageCamera, viewportSize]);

  useEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport) return undefined;
    const measure = () => {
      const rect = viewport.getBoundingClientRect();
      viewportRectRef.current = rect;
      const next = { width: rect.width, height: rect.height };
      viewportSizeRef.current = next;
      setViewportSize(next);
      refreshPageCamera(liveCameraRef.current, true);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(viewport);
    return () => observer.disconnect();
  }, [refreshPageCamera]);

  useEffect(() => () => {
    clearTimeout(wheelCommitTimerRef.current);
    clearTimeout(zoomTimerRef.current);
    clearTimeout(inspectDismissTimerRef.current);
    try {
      inspectDismissRef.current?.captureTarget?.releasePointerCapture?.(
        inspectDismissRef.current.pointerId,
      );
    } catch {}
    inspectDismissRef.current = null;
    cancelStackTransition();
    stopCameraAnimation();
  }, [cancelStackTransition, stopCameraAnimation]);

  const enqueueSnapshotWrite = useCallback((operation) => {
    const write = snapshotWriteRef.current
      .catch(() => undefined)
      .then(operation);
    snapshotWriteRef.current = write.catch(() => undefined);
    return write;
  }, []);

  const saveNow = useCallback(async () => {
    if (!hydrated || !boardRef.current) return;
    if (moveBoardWriteRef.current) {
      await snapshotWriteRef.current.catch(() => undefined);
      return;
    }
    const itemRevision = itemRevisionRef.current;
    const hasItemChanges = itemRevision !== savedItemRevisionRef.current;
    const persistedBoard = {
      ...boardRef.current,
      camera: liveCameraRef.current,
      updatedAt: Date.now(),
      revision: (boardRef.current.revision || 0) + 1,
    };
    const snapshot = {
      board: persistedBoard,
      items: itemsRef.current,
    };
    try {
      await enqueueSnapshotWrite(() => hasItemChanges
        ? repository.replaceBoardSnapshot(snapshot)
        : repository.putBoard(persistedBoard));
      if (hasItemChanges) savedItemRevisionRef.current = itemRevision;
    } catch (error) {
      console.error(error);
    }
  }, [enqueueSnapshotWrite, hydrated, repository]);

  useEffect(() => {
    if (!hydrated) return undefined;
    clearTimeout(saveTimerRef.current);
    saveTimerRef.current = setTimeout(saveNow, 420);
    return () => clearTimeout(saveTimerRef.current);
  }, [board, camera, hydrated, items, saveNow]);

  useEffect(() => platformBridge.onBeforeClose(async () => {
    await saveNow();
    platformBridge.confirmCloseReady();
  }), [saveNow]);

  const visibleInteractionItems = useCallback(() => renderItems
    .filter((item) => activeFolderId
      ? item.stackId === activeFolderId
      : (!item.stackId || expandedStackId === item.stackId))
    .map((item) => {
      const pose = activeFolderId && item.stackId === activeFolderId
        ? activeFolderLayout.get(item.id) || item.pose
        : item.pose;
      return { id: item.id, x: pose.x, y: pose.y, width: pose.width, height: pose.height };
    }), [activeFolderId, activeFolderLayout, expandedStackId, renderItems]);

  const renderMarqueeVisual = useCallback((next) => {
    const node = marqueeRef.current;
    if (!node) return;
    node.hidden = !next.active;
    if (!next.active) return;
    node.style.transform = `translate3d(${next.screenRect.x}px, ${next.screenRect.y}px, 0)`;
    node.style.width = `${next.screenRect.width}px`;
    node.style.height = `${next.screenRect.height}px`;
  }, []);

  const renderSnapVisual = useCallback((next) => {
    for (const id of highlightedSnapIdsRef.current) {
      itemRenderersRef.current.get(id)?.setSnapTarget(false);
    }
    const highlighted = new Set(next.highlightedIds || []);
    for (const id of highlighted) itemRenderersRef.current.get(id)?.setSnapTarget(true);
    highlightedSnapIdsRef.current = highlighted;

    const cameraValue = liveCameraRef.current;
    const xGuide = next.guides?.find((guide) => guide.axis === "x");
    const yGuide = next.guides?.find((guide) => guide.axis === "y");
    const xNode = snapLineXRef.current;
    const yNode = snapLineYRef.current;

    if (xNode) {
      xNode.hidden = !xGuide;
      if (xGuide) {
        xNode.style.transform = `translate3d(${(xGuide.position - cameraValue.x) * cameraValue.zoom}px, ${(xGuide.start - cameraValue.y) * cameraValue.zoom}px, 0)`;
        xNode.style.height = `${(xGuide.end - xGuide.start) * cameraValue.zoom}px`;
      }
    }
    if (yNode) {
      yNode.hidden = !yGuide;
      if (yGuide) {
        yNode.style.transform = `translate3d(${(yGuide.start - cameraValue.x) * cameraValue.zoom}px, ${(yGuide.position - cameraValue.y) * cameraValue.zoom}px, 0)`;
        yNode.style.width = `${(yGuide.end - yGuide.start) * cameraValue.zoom}px`;
      }
    }
  }, []);

  const controller = useCanvasInteractions({
    getSnapshot: () => ({ camera: liveCameraRef.current, items: visibleInteractionItems(), selectedIds: selectionRef.current }),
    onCameraChange: applyLiveCamera,
    onItemsChange: renderItemChanges,
    onSelectionChange: (next, meta = {}) => {
      const origin = meta.source === "marquee" && meta.phase === "update" && meta.dragged
        ? SELECTION_ORIGIN.MARQUEE
        : meta.source === "marquee" && meta.phase === "cancel"
          ? marqueeBaseOriginRef.current
          : SELECTION_ORIGIN.ORDINARY;
      setSelection(next, { origin });
    },
    onMarqueeChange: renderMarqueeVisual,
    onSnapChange: renderSnapVisual,
    onHaptic: ({ type }) => {
      if (type === "snap-engage") navigator.vibrate?.(7);
    },
    onInteractionChange: ({ type, phase, itemId }) => {
      if (phase === "start") {
        if (type === "marquee") marqueeBaseOriginRef.current = selectionOriginRef.current;
        setInteraction(type);
        if (type === "drag" || type === "resize") gestureStartRef.current = itemsRef.current;
        else setInteractionItemIds([]);
        return;
      }
      if (phase === "end") {
        const renderedDroppedPose = type === "drag" && itemId
          ? liveItemGeometryRef.current.get(itemId)
          : null;
        const draggedItem = itemId ? itemByIdRef.current.get(itemId) : null;
        const droppedPose = renderedDroppedPose && activeFolderId && draggedItem?.stackId === activeFolderId
          ? folderCanonicalPose(renderedDroppedPose, activeFolderOffsetRef.current)
          : renderedDroppedPose;
        if (type === "drag" || type === "resize") {
          commitLiveItemGeometry({ translateFolderMembers: type === "drag" });
        }
        if (type === "drag" && itemId && droppedPose) stackDroppedItem(itemId, droppedPose);
        if (type === "pan") commitCameraVisual(liveCameraRef.current);
      } else if (phase === "cancel") {
        liveItemGeometryRef.current.clear();
        gestureStartRef.current = null;
      }
      setInteractionItemIds([]);
      setInteraction(null);
    },
    snap: CANVAS_SNAP_CONFIG,
    zoom: { minZoom: 0.2, maxZoom: 2.2, sensitivity: WHEEL_ZOOM_SENSITIVITY },
  });

  const canvasPoint = useCallback((event) => pointInViewport(
    event,
    viewportRef.current,
    viewportRectRef.current,
  ), []);

  const touchPair = () => [...touchPointsRef.current.values()].slice(0, 2);

  const onTouchPointerDownCapture = (event) => {
    if (detailPresenceId) return;
    if (event.pointerType !== "touch") return;
    touchPointsRef.current.set(event.pointerId, canvasPoint(event));
    if (touchPointsRef.current.size < 2) return;

    event.preventDefault();
    event.stopPropagation();
    itemPressRef.current = null;
    stopCameraAnimation();
    if (controller.getInteraction()) controller.cancel();
    const gesture = beginTouchCameraGesture(liveCameraRef.current, touchPair());
    if (!gesture) return;
    touchCameraGestureRef.current = gesture;
    suppressTouchRef.current = true;
    setInteractionItemIds([]);
    setInteraction("pan");
    showZoomFeedback();
    for (const pointerId of touchPointsRef.current.keys()) {
      try { event.currentTarget.setPointerCapture(pointerId); } catch {}
    }
  };

  const onTouchPointerMoveCapture = (event) => {
    if (event.pointerType !== "touch") return;
    touchPointsRef.current.set(event.pointerId, canvasPoint(event));
    if (!touchCameraGestureRef.current) {
      if (suppressTouchRef.current) event.stopPropagation();
      return;
    }

    event.preventDefault();
    event.stopPropagation();
    const next = updateTouchCameraGesture(touchCameraGestureRef.current, touchPair(), {
      minZoom: 0.2,
      maxZoom: 2.2,
    });
    if (next) scheduleLiveCamera(next, { source: "touch", mode: "zoom", phase: "update" });
  };

  const onTouchPointerEndCapture = (event) => {
    if (event.pointerType !== "touch") return;
    const wasNavigating = Boolean(touchCameraGestureRef.current) || suppressTouchRef.current;
    touchPointsRef.current.delete(event.pointerId);
    if (!wasNavigating) return;

    event.preventDefault();
    event.stopPropagation();
    if (touchCameraGestureRef.current && touchPointsRef.current.size < 2) {
      touchCameraGestureRef.current = null;
      flushScheduledCamera();
      commitCameraVisual(liveCameraRef.current);
      setInteraction(null);
    }
    if (touchPointsRef.current.size === 0) suppressTouchRef.current = false;
    try { event.currentTarget.releasePointerCapture(event.pointerId); } catch {}
  };

  useEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport) return undefined;
    const wheel = (event) => {
      const unit = event.deltaMode === WheelEvent.DOM_DELTA_LINE
        ? 16
        : event.deltaMode === WheelEvent.DOM_DELTA_PAGE
          ? viewport.clientHeight
          : 1;
      let deltaX = event.deltaX * unit;
      let deltaY = event.deltaY * unit;
      if (event.shiftKey && Math.abs(deltaX) < Math.abs(deltaY)) {
        deltaX = deltaY;
        deltaY = 0;
      }
      const detailScrollHost = detailPresenceId
        ? viewport.querySelector(
            '[data-detail-scroll-region="true"] > :is(.item-document, .item-note, .item-web)',
          )
        : null;
      if (detailScrollHost && !event.ctrlKey && !event.metaKey) {
        event.preventDefault();
        scrollFullscreenDetail(detailScrollHost, deltaX, deltaY);
        return;
      }
      const wheelMode = wheelRoutingMode({
        detailOpen: Boolean(detailPresenceId),
        withinDetailScrollRegion: Boolean(event.target.closest?.("[data-detail-scroll-region]")),
      });
      if (wheelMode === "native") return;
      if (wheelMode === "blocked") {
        event.preventDefault();
        return;
      }
      event.preventDefault();
      stopCameraAnimation();
      if (event.ctrlKey || event.metaKey) {
        controller.wheelZoom({
          point: pointInViewport(event, viewport, viewportRectRef.current),
          deltaY,
        });
      } else {
        controller.wheelPan({
          deltaX: deltaX * WHEEL_PAN_MULTIPLIER,
          deltaY: deltaY * WHEEL_PAN_MULTIPLIER,
        });
      }
    };
    viewport.addEventListener("wheel", wheel, { passive: false, capture: true });
    return () => viewport.removeEventListener("wheel", wheel, { capture: true });
  }, [controller, detailPresenceId, stopCameraAnimation]);

  useEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport) return undefined;
    const gesturePoint = (event) => {
      const rect = viewportRectRef.current || viewport.getBoundingClientRect();
      const hasPoint = Number.isFinite(event.clientX) && Number.isFinite(event.clientY)
        && (event.clientX !== 0 || event.clientY !== 0);
      return hasPoint
        ? { x: event.clientX - rect.left, y: event.clientY - rect.top }
        : { x: rect.width / 2, y: rect.height / 2 };
    };
    const start = (event) => {
      if (touchPointsRef.current.size) return;
      event.preventDefault();
      if (controller.getInteraction()) controller.cancel();
      stopCameraAnimation();
      safariGestureRef.current = {
        camera: { ...liveCameraRef.current },
        point: gesturePoint(event),
      };
      setInteraction("pan");
      showZoomFeedback();
    };
    const change = (event) => {
      if (!safariGestureRef.current || touchPointsRef.current.size) return;
      event.preventDefault();
      const { camera: startCamera, point } = safariGestureRef.current;
      const next = zoomCameraAt(startCamera, point, startCamera.zoom * (event.scale || 1), {
        minZoom: 0.2,
        maxZoom: 2.2,
      });
      scheduleLiveCamera(next, { source: "gesture", mode: "zoom", phase: "update" });
    };
    const end = (event) => {
      if (!safariGestureRef.current) return;
      event.preventDefault();
      safariGestureRef.current = null;
      flushScheduledCamera();
      commitCameraVisual(liveCameraRef.current);
      setInteraction(null);
    };
    viewport.addEventListener("gesturestart", start, { passive: false });
    viewport.addEventListener("gesturechange", change, { passive: false });
    viewport.addEventListener("gestureend", end, { passive: false });
    return () => {
      viewport.removeEventListener("gesturestart", start);
      viewport.removeEventListener("gesturechange", change);
      viewport.removeEventListener("gestureend", end);
    };
  }, [commitCameraVisual, controller, flushScheduledCamera, scheduleLiveCamera, showZoomFeedback, stopCameraAnimation]);

  const onCanvasPointerDown = (event) => {
    if (detailPresenceId) return;
    if (event.button !== 0 && event.button !== 1) return;
    if (event.target.closest?.("[data-item-id], button, input, textarea, [contenteditable='true']")) return;
    stopCameraAnimation();
    const point = canvasPoint(event);
    event.currentTarget.setPointerCapture?.(event.pointerId);
    if (event.pointerType === "touch" || spaceDown || event.button === 1) controller.beginPan(point);
    else controller.beginMarquee({ point, operation: event.shiftKey ? "add" : "replace", mode: "intersect" });
  };

  const onViewportPointerDownCapture = (event) => {
    const pendingDismissal = inspectDismissRef.current;
    if (pendingDismissal?.phase === "pointer-down") {
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    if (pendingDismissal) {
      clearTimeout(inspectDismissTimerRef.current);
      inspectDismissTimerRef.current = null;
      inspectDismissRef.current = null;
    }
    if (expandedStackId && !activeFolderId && !detailPresenceId) {
      if (event.target.closest?.("[data-inspection-control='true']")) return;
      const itemNode = event.target.closest?.("[data-item-id]");
      const targetItem = itemNode
        ? itemByIdRef.current.get(itemNode.dataset.itemId)
        : null;
      if (!isStackInspectionItem(targetItem, expandedStackId)) {
        event.preventDefault();
        event.stopPropagation();
        itemPressRef.current = null;
        if (controller.getInteraction()) controller.cancel();
        setSelection([]);
        inspectDismissRef.current = {
          pointerId: event.pointerId,
          phase: "pointer-down",
          captureTarget: event.currentTarget,
        };
        try {
          event.currentTarget.setPointerCapture?.(event.pointerId);
        } catch {}
        closeContainerInline();
        return;
      }
    }
    onTouchPointerDownCapture(event);
  };

  const onViewportPointerEndCapture = (event) => {
    const dismissal = inspectDismissRef.current;
    if (dismissal?.pointerId === event.pointerId) {
      event.preventDefault();
      event.stopPropagation();
      try {
        dismissal.captureTarget?.releasePointerCapture?.(event.pointerId);
      } catch {}
      clearTimeout(inspectDismissTimerRef.current);
      if (event.type === "pointercancel") {
        inspectDismissRef.current = null;
        inspectDismissTimerRef.current = null;
      } else {
        dismissal.phase = "awaiting-click";
        // Most browsers dispatch click immediately after pointerup. The guard
        // remains longer for touch UAs that synthesize it in a later task, but
        // a new pointer-down clears it before any legitimate next interaction.
        inspectDismissTimerRef.current = setTimeout(() => {
          if (inspectDismissRef.current === dismissal) {
            inspectDismissRef.current = null;
          }
          inspectDismissTimerRef.current = null;
        }, 1000);
      }
      return;
    }
    onTouchPointerEndCapture(event);
  };

  const suppressDismissedInspectClick = (event) => {
    const dismissal = inspectDismissRef.current;
    if (!dismissal) return;
    const clickPointerId = event.nativeEvent?.pointerId;
    if (Number.isFinite(clickPointerId)
      && clickPointerId > 0
      && clickPointerId !== dismissal.pointerId) return;
    if (event.detail === 0) return;
    event.preventDefault();
    event.stopPropagation();
    clearTimeout(inspectDismissTimerRef.current);
    inspectDismissTimerRef.current = null;
    inspectDismissRef.current = null;
  };

  const onItemPointerDown = (item, event) => {
    if (detailPresenceId) return;
    if (event.button !== 0) return;
    if (event.pointerType === "touch" && suppressTouchRef.current) return;
    stopCameraAnimation();
    event.stopPropagation();
    itemPressRef.current = null;
    const current = selectionRef.current;
    if (event.shiftKey) {
      const next = current.includes(item.id) ? current.filter((id) => id !== item.id) : [...current, item.id];
      setSelection(next);
      return;
    }
    const point = canvasPoint(event);
    const wasSoleSelected = current.length === 1 && current[0] === item.id;
    if (!current.includes(item.id)) setSelection([item.id]);
    // Capture on the item itself so click/double-click keeps the item as its
    // target. Capturing on the viewport made every press look like a canvas
    // gesture and swallowed stack/detail activation.
    event.currentTarget.setPointerCapture?.(event.pointerId);
    const requestedIds = current.includes(item.id) ? current : [item.id];
    const mountedIds = requestedIds.filter((id) => itemRenderersRef.current.has(id));
    itemPressRef.current = {
      itemId: item.id,
      pointerId: event.pointerId,
      pointerType: event.pointerType,
      startPoint: point,
      moved: false,
      mountedIds,
      captureTarget: event.currentTarget,
      wasSoleSelected,
    };
  };

  const finishPointer = (event) => {
    const point = canvasPoint(event);
    const press = itemPressRef.current;
    const isItemTap = press && press.pointerId === event.pointerId && !press.moved;
    if (press?.pointerId === event.pointerId) itemPressRef.current = null;
    if (isItemTap) {
      const pressedItem = itemByIdRef.current.get(press.itemId);
      const containerIntent = containerTapIntent({
        isContainer: isContainerKind(pressedItem),
        wasSoleSelected: press.wasSoleSelected,
      });
      if (containerIntent === "open") {
        openContainerInline(press.itemId);
      } else if (containerIntent === "select") {
        setSelection([press.itemId]);
      } else if (press.pointerType === "touch") {
        const now = event.nativeEvent?.timeStamp ?? event.timeStamp;
        const previous = lastTouchTapRef.current;
        const repeated = previous
          && previous.itemId === press.itemId
          && now - previous.time <= 340
          && Math.hypot(point.x - previous.point.x, point.y - previous.point.y) <= 18;
        if (repeated) {
          lastTouchTapRef.current = null;
          openDetail(press.itemId);
        } else {
          lastTouchTapRef.current = { itemId: press.itemId, time: now, point };
        }
      }
    } else if (controller.getInteraction()) {
      controller.end({
        point,
        time: event.nativeEvent?.timeStamp ?? event.timeStamp,
        disableSnapping: event.ctrlKey,
      });
    }
    try { press?.captureTarget?.releasePointerCapture?.(event.pointerId); } catch {}
    if (viewportRef.current?.hasPointerCapture?.(event.pointerId)) viewportRef.current.releasePointerCapture(event.pointerId);
  };

  const movePointer = (event) => {
    if (event.pointerType === "touch" && suppressTouchRef.current) return;
    const nativeEvent = event.nativeEvent;
    const coalesced = nativeEvent.getCoalescedEvents?.();
    const latest = coalesced?.length ? coalesced[coalesced.length - 1] : nativeEvent;
    const point = pointInViewport(latest, viewportRef.current, viewportRectRef.current);
    const press = itemPressRef.current;
    if (press && press.pointerId === event.pointerId) {
      const deltaX = point.x - press.startPoint.x;
      const deltaY = point.y - press.startPoint.y;
      if (!press.moved && (deltaX * deltaX) + (deltaY * deltaY) > 25) {
        press.moved = true;
        setInteractionItemIds(press.mountedIds);
        controller.beginDrag({
          point: press.startPoint,
          itemId: press.itemId,
          itemIds: press.mountedIds,
        });
      }
      if (!press.moved) return;
    }
    controller.move({
      point,
      time: latest.timeStamp,
      disableSnapping: latest.ctrlKey,
    });
  };

  const selectedSingle = selectedItems.length === 1 ? selectedItems[0] : null;
  const startResize = (handle, event) => {
    event.stopPropagation();
    event.currentTarget.setPointerCapture?.(event.pointerId);
    setInteractionItemIds([selectedSingle.id]);
    controller.beginResize({ point: canvasPoint(event), itemId: selectedSingle.id, handle, options: { minWidth: 72, minHeight: 64 } });
  };

  const createStack = useCallback(() => {
    const members = itemsRef.current.filter((item) => selectionRef.current.includes(item.id)
      && !item.stackId
      && item.kind !== "stack"
      && item.kind !== "folder");
    if (members.length < 2) return;
    const bounds = boundsFor(members);
    const id = uniqueId("stack");
    const now = Date.now();
    const stack = {
      id,
      boardId: boardRef.current.id,
      kind: "stack",
      pose: { x: bounds.x + Math.max(0, (bounds.width - 220) / 2), y: bounds.y + Math.max(0, (bounds.height - 155) / 2), width: 220, height: 155, rotation: 0 },
      z: Math.max(...itemsRef.current.map((item) => item.z), 0) + 1,
      style: { color: "#c8faf2", glowColor: "#8cf1df", cornerRadius: 18 },
      content: { title: "Untitled", subtitle: `${members.length} collected things`, memberIds: members.map((item) => item.id), peekColors: ["#dfff31", "#ffffff"] },
      stackId: null,
      createdAt: now,
      updatedAt: now,
    };
    cancelStackTransition();
    stackMotionRef.current = { stackId: id, phase: "create", pending: new Set(members.map((member) => member.id)) };
    setStackTransitionId(id);
    commitMutation(
      (current) => [...current.map((item) => members.some((member) => member.id === item.id) ? { ...item, stackId: id } : item), stack],
      { selectionBefore: members.map((member) => member.id) },
    );
    setSelection([id]);
  }, [cancelStackTransition, commitMutation, setSelection]);

  const createFolder = useCallback((requestedMemberIds = []) => {
    const memberIds = eligibleFolderMemberIds(itemsRef.current, requestedMemberIds);
    const members = itemsRef.current.filter((item) => memberIds.includes(item.id));
    const memberBounds = members.length ? boundsFor(members) : null;
    const viewport = viewportSizeRef.current;
    const cameraValue = liveCameraRef.current;
    const center = {
      x: cameraValue.x + viewport.width / cameraValue.zoom / 2,
      y: cameraValue.y + viewport.height / cameraValue.zoom / 2,
    };
    const id = uniqueId("folder");
    const now = Date.now();
    const folder = {
      id,
      boardId: boardRef.current.id,
      kind: "folder",
      pose: {
        x: memberBounds
          ? memberBounds.x + Math.max(0, (memberBounds.width - 225) / 2)
          : center.x - 112.5,
        y: memberBounds
          ? memberBounds.y + Math.max(0, (memberBounds.height - 160) / 2)
          : center.y - 80,
        width: 225,
        height: 160,
        rotation: 0,
      },
      z: Math.max(...itemsRef.current.map((item) => item.z), 0) + 1,
      style: { color: "#d7fbf2", glowColor: "#8cf1df", cornerRadius: 18 },
      content: {
        title: "New folder",
        subtitle: `${memberIds.length} ${memberIds.length === 1 ? "item" : "items"}`,
        memberIds: [],
      },
      stackId: null,
      createdAt: now,
      updatedAt: now,
    };
    cancelStackTransition();
    if (memberIds.length) {
      stackMotionRef.current = { stackId: id, phase: "create", pending: new Set(memberIds) };
      setStackTransitionId(id);
    }
    commitMutation(
      (current) => moveItemsToContainer([...current, folder], memberIds, id, now),
      { selectionBefore: memberIds },
    );
    setFolderPickerOpen(false);
    setSelection([id]);
  }, [cancelStackTransition, commitMutation, setSelection]);

  const moveSelectionToFolder = useCallback((targetFolderId) => {
    const memberIds = eligibleFolderMemberIds(itemsRef.current, selectionRef.current);
    if (!memberIds.length) return;
    cancelStackTransition();
    if (targetFolderId) {
      stackMotionRef.current = {
        stackId: targetFolderId,
        phase: "create",
        pending: new Set(memberIds),
      };
      setStackTransitionId(targetFolderId);
    }
    commitMutation(
      (current) => moveItemsToContainer(
        current,
        memberIds,
        targetFolderId,
        Date.now(),
      ),
      { selectionBefore: memberIds },
    );
    setFolderPickerOpen(false);
    setSelection(targetFolderId ? [targetFolderId] : memberIds);
  }, [cancelStackTransition, commitMutation, setSelection]);

  const unpackStack = useCallback((stackId) => {
    cancelStackTransition();
    setContainerView(null);
    setFolderCanvasTransitionId(null);
    setStackTransitionId(stackId);
    // Warm the destination page while members still have their collapsed
    // stack targets, then remove the shell so they spring outward.
    const firstFrame = requestAnimationFrame(() => {
      const secondFrame = requestAnimationFrame(() => {
        stackTransitionFramesRef.current = [];
        commitMutation((current) => current
          .filter((item) => item.id !== stackId)
          .map((item) => item.stackId === stackId ? { ...item, stackId: null, updatedAt: Date.now() } : item));
        setStackTransitionId(null);
        setSelection([]);
      });
      stackTransitionFramesRef.current = [secondFrame];
    });
    stackTransitionFramesRef.current = [firstFrame];
  }, [cancelStackTransition, commitMutation, setSelection]);

  const deleteSelection = useCallback(() => {
    const ids = new Set(selectionRef.current);
    for (const item of itemsRef.current) {
      if (ids.has(item.id) && (item.kind === "stack" || item.kind === "folder")) item.content.memberIds.forEach((id) => ids.add(id));
    }
    commitMutation((current) => current.filter((item) => !ids.has(item.id)));
    setSelection([]);
    if ((expandedStackId && ids.has(expandedStackId))
      || (stackTransitionId && ids.has(stackTransitionId))
      || (activeFolderId && ids.has(activeFolderId))) {
      cancelStackTransition();
      setContainerView(null);
      setStackTransitionId(null);
      setFolderCanvasTransitionId(null);
    }
    if (detailId) closeDetail();
  }, [activeFolderId, cancelStackTransition, closeDetail, commitMutation, detailId, expandedStackId, setSelection, stackTransitionId]);

  const duplicateSelection = useCallback(() => {
    const originals = itemsRef.current.filter((item) => selectionRef.current.includes(item.id));
    const now = Date.now();
    const copies = originals.map((item, index) => ({
      ...clone(item),
      id: uniqueId(item.kind),
      pose: { ...item.pose, x: item.pose.x + 26 + index * 4, y: item.pose.y + 26 + index * 4 },
      z: Math.max(...itemsRef.current.map((candidate) => candidate.z), 0) + index + 1,
      stackId: null,
      createdAt: now,
      updatedAt: now,
    }));
    commitMutation((current) => [...current, ...copies]);
    setSelection(copies.map((item) => item.id));
  }, [commitMutation, setSelection]);

  const organizeItemIds = useCallback(async (ids) => {
    const targets = itemsRef.current.filter((item) => ids.has(item.id));
    if (!targets.length) return;
    const generation = ++organizeGenerationRef.current;
    const source = targets.map((item) => ({
      id: item.id,
      x: item.pose.x,
      y: item.pose.y,
      width: item.pose.width,
      height: item.pose.height,
      rotation: item.pose.rotation,
    }));
    let layout;
    try {
      layout = await autoOrganizeItemsAsync(source, { gridSize: 20, gap: 20 });
    } catch (error) {
      console.error(error);
      return;
    }
    if (generation !== organizeGenerationRef.current) return;
    const currentById = new Map(itemsRef.current.map((item) => [item.id, item]));
    const boardChangedWhileSolving = source.some((entry) => {
      const current = currentById.get(entry.id);
      return !current
        || current.pose.x !== entry.x
        || current.pose.y !== entry.y
        || current.pose.width !== entry.width
        || current.pose.height !== entry.height
        || current.pose.rotation !== entry.rotation;
    });
    if (boardChangedWhileSolving) return;
    const byId = new Map(layout.map((entry) => [entry.id, entry]));
    const changed = targets.some((item) => {
      const next = byId.get(item.id);
      return next && (
        next.x !== item.pose.x
        || next.y !== item.pose.y
        || next.rotation !== item.pose.rotation
      );
    });
    if (!changed) return;
    const now = Date.now();
    commitMutation((current) => current.map((item) => {
      const next = byId.get(item.id);
      return next ? {
        ...item,
        pose: { ...item.pose, x: next.x, y: next.y, rotation: next.rotation },
        updatedAt: now,
      } : item;
    }));
  }, [commitMutation]);

  const arrangeSelection = useCallback(() => {
    organizeItemIds(new Set(selectionRef.current));
  }, [organizeItemIds]);

  const autoOrganizeBoard = useCallback(() => {
    organizeItemIds(new Set(
      itemsRef.current
        .filter((item) => !item.stackId)
        .map((item) => item.id),
    ));
  }, [organizeItemIds]);

  const insertBoardItem = useCallback(({
    kind,
    content,
    dimensions,
    screenPoint = null,
    style = {},
  }) => {
    const viewport = viewportRef.current;
    if (!viewport) throw new Error("The canvas is not ready yet.");
    const center = screenPoint || { x: viewport.clientWidth / 2, y: viewport.clientHeight / 2 };
    const cameraValue = liveCameraRef.current;
    const world = {
      x: center.x / cameraValue.zoom + cameraValue.x,
      y: center.y / cameraValue.zoom + cameraValue.y,
    };
    const id = uniqueId(kind);
    const now = Date.now();
    const displayPose = {
      x: world.x - dimensions.width / 2,
      y: world.y - dimensions.height / 2,
      ...dimensions,
      rotation: 0,
    };
    const item = {
      id,
      boardId: board.id,
      kind,
      pose: activeFolderId
        ? folderCanonicalPose(displayPose, activeFolderOffsetRef.current)
        : displayPose,
      z: Math.max(...itemsRef.current.map((candidate) => candidate.z), 0) + 1,
      style,
      content,
      stackId: activeFolderId,
      createdAt: now,
      updatedAt: now,
    };
    commitMutation((current) => [
      ...current.map((candidate) => candidate.id === activeFolderId
        ? {
          ...candidate,
          content: {
            ...candidate.content,
            memberIds: [...new Set([...(candidate.content.memberIds || []), id])],
          },
          updatedAt: now,
        }
        : candidate),
      item,
    ]);
    setSelection([id]);
    return item;
  }, [activeFolderId, board.id, commitMutation, setSelection]);

  const importDocumentFile = useCallback(async (picked, screenPoint = null) => {
    const format = detectOfficeDocumentFormat(picked);
    if (!format) throw new Error("Choose a .docx, .pptx, or .xlsx file.");
    const mimeType = OFFICE_DOCUMENT_MIME_TYPES[format];
    const blob = platformFileAsBlob(picked, mimeType);
    if (blob.size > MAX_IMPORTED_DOCUMENT_BYTES) {
      throw new Error("This file is larger than the 40 MB import limit.");
    }
    const assetId = uniqueId("asset");
    const activeBoard = boardRef.current;
    if (!activeBoard) throw new Error("The canvas is not ready yet.");
    await repository.putAsset({
      id: assetId,
      boardId: activeBoard.id,
      name: picked.name,
      mimeType,
      size: blob.size,
      blob,
      createdAt: Date.now(),
    });
    const content = buildImportedDocumentContent({
      kind: "upload",
      assetId,
      name: picked.name,
      type: mimeType,
      size: blob.size,
    });
    return insertBoardItem({
      kind: "document",
      content,
      dimensions: importedDocumentDimensions(content),
      screenPoint,
      style: { color: "#f5f6f4", glowColor: "transparent", cornerRadius: 16 },
    });
  }, [insertBoardItem, repository]);

  const pickAndImportDocument = useCallback(async () => {
    setDocumentImport((current) => current ? { ...current, busy: true, error: "" } : current);
    try {
      const [picked] = await platformBridge.pickFiles({
        accept: DOCUMENT_FILE_ACCEPT,
        multiple: false,
      });
      if (!picked) {
        setDocumentImport((current) => current ? { ...current, busy: false } : current);
        return;
      }
      await importDocumentFile(picked, documentImport?.point);
      setDocumentImport(null);
    } catch (error) {
      setDocumentImport((current) => current ? {
        ...current,
        busy: false,
        error: error instanceof Error ? error.message : "The document could not be imported.",
      } : current);
    }
  }, [documentImport?.point, importDocumentFile]);

  const importGoogleDocument = useCallback(async (url) => {
    setDocumentImport((current) => current ? { ...current, busy: true, error: "" } : current);
    try {
      const content = buildImportedDocumentContent({ kind: "google", url });
      insertBoardItem({
        kind: "document",
        content,
        dimensions: importedDocumentDimensions(content),
        screenPoint: documentImport?.point,
        style: { color: "#f5f6f4", glowColor: "transparent", cornerRadius: 16 },
      });
      setDocumentImport(null);
    } catch (error) {
      setDocumentImport((current) => current ? {
        ...current,
        busy: false,
        error: error instanceof Error ? error.message : "That Google Workspace link is not supported.",
      } : current);
    }
  }, [documentImport?.point, insertBoardItem]);

  const addItemAt = useCallback(async (kind, screenPoint = null) => {
    setAddMenuOpen(false);
    if (kind === "stack") {
      createStack();
      return;
    }
    if (kind === "folder") {
      createFolder();
      return;
    }
    if (kind === "web") {
      urlCaptureRequestRef.current += 1;
      setUrlCapture({ point: screenPoint });
      return;
    }
    if (kind === "document") {
      setDocumentImport({ point: screenPoint, busy: false, error: "" });
      return;
    }

    const requestedKind = kind;
    const recordKind = kind === "label" || kind === "tasks" ? "note" : kind;
    let image = null;
    let imageName = "Imported visual";
    if (recordKind === "image") {
      const chosen = await platformBridge.pickFiles({ accept: "image/*", multiple: false });
      if (!chosen[0]) return;
      imageName = chosen[0].name;
      const imageBlob = chosen[0].file || (chosen[0].bytes
        ? platformFileAsBlob(chosen[0], chosen[0].type || "application/octet-stream")
        : null);
      image = imageBlob ? await fileAsDataUrl(imageBlob) : visualAssets.visuals.src;
    }

    const viewport = viewportRef.current;
    const center = screenPoint || { x: viewport.clientWidth / 2, y: viewport.clientHeight / 2 };
    const cameraValue = liveCameraRef.current;
    const world = { x: center.x / cameraValue.zoom + cameraValue.x, y: center.y / cameraValue.zoom + cameraValue.y };
    const id = uniqueId(recordKind);
    const now = Date.now();
    const dimensions = recordKind === "image"
        ? { width: 300, height: 260 }
        : requestedKind === "label"
          ? { width: 190, height: 105 }
          : requestedKind === "tasks"
            ? { width: 220, height: 230 }
            : { width: 180, height: 170 };
    const displayPose = {
      x: world.x - dimensions.width / 2,
      y: world.y - dimensions.height / 2,
      ...dimensions,
      rotation: 0,
    };
    const pose = activeFolderId
      ? folderCanonicalPose(displayPose, activeFolderOffsetRef.current)
      : displayPose;
    const item = {
      id,
      boardId: board.id,
      kind: recordKind,
      pose,
      z: Math.max(...itemsRef.current.map((candidate) => candidate.z), 0) + 1,
      style: { color: requestedKind === "label" ? "#dfff31" : recordKind === "note" ? "#f8fbf2" : "#fcfcfc", glowColor: "transparent", cornerRadius: 16 },
      content: requestedKind === "label"
        ? { title: "# New label", text: "A lightweight marker for this area." }
        : requestedKind === "tasks"
          ? { title: "Tasks", subtitle: "New list", tasks: [{ text: "Add the first task", done: false }, { text: "Keep it close to the work", done: false }] }
          : recordKind === "note"
            ? { title: "New note", text: "Double-click to open and write." }
            : { title: imageName, image, alt: imageName, caption: imageName, palette: ["#202728", "#657678", "#c7cecc", "#f5f5f2", "#dfff31"] },
      stackId: activeFolderId,
      createdAt: now,
      updatedAt: now,
    };
    commitMutation((current) => [
      ...current.map((candidate) => candidate.id === activeFolderId
        ? { ...candidate, content: { ...candidate.content, memberIds: [...(candidate.content.memberIds || []), id] } }
        : candidate),
      item,
    ]);
    setSelection([id]);
  }, [activeFolderId, board.id, commitMutation, createFolder, createStack, setSelection]);

  const createWebClip = useCallback(async (url) => {
    const requestId = ++urlCaptureRequestRef.current;
    const targetBoardId = boardRef.current?.id;
    let storedAssetId = null;
    setUrlCapture((current) => current ? { ...current, busy: true, error: "" } : current);
    try {
      if (!targetBoardId) throw new Error("The canvas is not ready yet.");
      const resolved = await captureWebClipPng(url, { width: 800, crop: 675 });
      if (requestId !== urlCaptureRequestRef.current || boardRef.current?.id !== targetBoardId) return;
      storedAssetId = uniqueId("asset-web");
      const content = buildWebClipContent(url, {
        width: 800,
        crop: 675,
        screenshotUrl: resolved.url,
        screenshotAssetId: storedAssetId,
        captureProvider: resolved.provider,
        candidates: resolved.candidates,
      });
      await repository.putAsset({
        id: storedAssetId,
        boardId: targetBoardId,
        name: `${content.domain || "web-clip"}.png`,
        mimeType: "image/png",
        size: resolved.blob.size,
        blob: resolved.blob,
        createdAt: Date.now(),
      });
      if (requestId !== urlCaptureRequestRef.current || boardRef.current?.id !== targetBoardId) {
        await repository.deleteAssets([storedAssetId]);
        storedAssetId = null;
        return;
      }
      insertBoardItem({
        kind: "web",
        content,
        dimensions: { width: 320, height: 220 },
        screenPoint: urlCapture?.point,
        style: { color: "#f5f6f4", glowColor: "transparent", cornerRadius: 18 },
      });
      storedAssetId = null;
      setUrlCapture(null);
    } catch (error) {
      if (storedAssetId) await repository.deleteAssets([storedAssetId]).catch(() => undefined);
      if (requestId !== urlCaptureRequestRef.current) return;
      setUrlCapture((current) => current ? {
        ...current,
        busy: false,
        error: error instanceof Error ? error.message : "That page URL could not be captured.",
      } : current);
    }
  }, [insertBoardItem, repository, urlCapture?.point]);

  const cacheWebClipSource = useCallback((id, screenshotUrl) => {
    if (!id || webClipCacheJobsRef.current.has(id)) return;
    const sourceItem = itemsRef.current.find((item) => item.id === id && item.kind === "web");
    if (!needsWebClipScreenshotCache(sourceItem, screenshotUrl)) return;
    const job = (async () => {
      let png;
      let resolvedUrl = screenshotUrl;
      try {
        png = await downloadScreenshotPng(screenshotUrl);
      } catch {
        const recovered = await captureWebClipPng(sourceItem.content.url, { width: 800, crop: 675 });
        png = recovered.blob;
        resolvedUrl = recovered.url;
      }
      const currentItem = itemsRef.current.find((item) => item.id === id && item.kind === "web");
      if (!needsWebClipScreenshotCache(currentItem, resolvedUrl)) return;
      const assetId = uniqueId("asset-web");
      await repository.putAsset({
        id: assetId,
        boardId: currentItem.boardId,
        name: `${currentItem.content.domain || "web-clip"}.png`,
        mimeType: "image/png",
        size: png.size,
        blob: png,
        createdAt: Date.now(),
      });
      const latest = itemsRef.current;
      const index = latest.findIndex((item) => item.id === id && item.kind === "web");
      if (index < 0) {
        await repository.deleteAssets([assetId]);
        return;
      }
      const item = latest[index];
      const existing = Array.isArray(item.content?.screenshotCandidates)
        ? item.content.screenshotCandidates
        : [];
      const nextItem = {
        ...item,
        content: {
          ...item.content,
          image: resolvedUrl,
          screenshotUrl: resolvedUrl,
          screenshotAssetId: assetId,
          screenshotCandidates: [
            resolvedUrl,
            ...existing.filter((candidate) => candidate !== resolvedUrl),
          ],
          captureProvider: captureProviderForUrl(resolvedUrl),
        },
        updatedAt: Date.now(),
      };
      const next = [...latest];
      next[index] = nextItem;
      itemsRef.current = next;
      itemRevisionRef.current += 1;
      setItems(next);
    })()
      .catch((error) => console.warn("Could not cache web clip screenshot", error))
      .finally(() => webClipCacheJobsRef.current.delete(id));
    webClipCacheJobsRef.current.set(id, job);
  }, [repository]);

  const toolbarAction = (action) => {
    if (action === "trash") deleteSelection();
    if (action === "copy") duplicateSelection();
    if (action === "stack") createStack();
    if (action === "focus") focusSelection();
    if (action === "unpack" && (selectedSingle?.kind === "stack" || selectedSingle?.kind === "folder")) unpackStack(selectedSingle.id);
    if (action === "unpackFolder" && selectedSingle?.kind === "folder") unpackStack(selectedSingle.id);
    if (action === "open" && isContainerKind(selectedSingle)) openContainerInline(selectedSingle.id);
    if (action === "rename" && selectedSingle?.kind === "folder") setRenameStackId(selectedSingle.id);
    if (action === "grid") {
      if (isContainerKind(selectedSingle)) openContainerInline(selectedSingle.id);
      else arrangeSelection();
    }
    if (action === "color") {
      setColorPreview(selectedSingle?.style?.color || "#f7f8f3");
      setColorOpen((current) => !current);
    }
    if (action === "folder") {
      if (selectedFolderMemberIds.length) setFolderPickerOpen(true);
    }
  };

  const commitColor = (color) => {
    commitMutation((current) => current.map((item) => selectionRef.current.includes(item.id)
      ? { ...item, style: { ...item.style, color, glowColor: color }, updatedAt: Date.now() }
      : item));
    setColorPreview(null);
    setColorOpen(false);
  };

  const updateDetail = (patch) => {
    if (!detailId) return;
    commitMutation((current) => current.map((item) => item.id === detailId
      ? { ...item, content: { ...item.content, ...patch }, updatedAt: Date.now() }
      : item));
  };

  const persistActiveBoard = async (boardId, generation) => {
    const write = activeBoardWriteRef.current
      .catch(() => undefined)
      .then(async () => {
        await repository.setSetting("activeBoardId", boardId);
        return generation === boardSwitchGenerationRef.current;
      });
    activeBoardWriteRef.current = write.catch(() => undefined);
    try {
      return await write;
    } catch (error) {
      console.error(error);
      return false;
    }
  };

  const switchBoard = async (boardId) => {
    if (moveItemId && moveBoardWriteRef.current) return;
    const generation = ++boardSwitchGenerationRef.current;
    const isCurrent = () => generation === boardSwitchGenerationRef.current;

    if (boardId === board.id) {
      setMoveItemId(null);
      setBoardsOpen(false);
      await persistActiveBoard(board.id, generation);
      return;
    }

    if (moveItemId) {
      const moving = itemsRef.current.find((item) => item.id === moveItemId);
      const target = await repository.getBoardSnapshot(boardId);
      if (!isCurrent()) return;
      if (moving && target) {
        const sourceItems = itemsRef.current.filter((item) => item.id !== moveItemId);
        const movedItem = {
          ...moving,
          boardId,
          stackId: null,
          pose: {
            ...moving.pose,
            x: target.board.camera.x + 420,
            y: target.board.camera.y + 250,
          },
          z: Math.max(...target.items.map((item) => item.z), 0) + 1,
          updatedAt: Date.now(),
        };
        moveBoardWriteRef.current = true;
        try {
          await enqueueSnapshotWrite(async () => {
            await repository.replaceBoardSnapshot({
              board: { ...boardRef.current, camera: liveCameraRef.current, updatedAt: Date.now(), revision: (boardRef.current.revision || 0) + 1 },
              items: sourceItems,
            });
            await repository.replaceBoardSnapshot({
              board: { ...target.board, updatedAt: Date.now(), revision: (target.board.revision || 0) + 1 },
              items: [...target.items, movedItem],
            });
          });
          const stayOnSourceAfterMove = () => {
            liveItemGeometryRef.current.clear();
            itemsRef.current = sourceItems;
            itemRevisionRef.current = 0;
            savedItemRevisionRef.current = 0;
            setItems(sourceItems);
            setSelection([]);
            setMoveItemId(null);
          };
          if (!isCurrent()) {
            stayOnSourceAfterMove();
            return;
          }
          if (!await persistActiveBoard(boardId, generation)) {
            stayOnSourceAfterMove();
            return;
          }
          setBoard(target.board);
          setCamera(target.board.camera);
          renderCameraVisual(target.board.camera);
          const targetItems = [...target.items, movedItem];
          liveItemGeometryRef.current.clear();
          itemsRef.current = targetItems;
          itemRevisionRef.current = 0;
          savedItemRevisionRef.current = 0;
          setItems(targetItems);
          setSelection([moveItemId]);
          setMoveItemId(null);
          cancelStackTransition();
          setContainerView(null);
          setFolderCanvasTransitionId(null);
          setStackTransitionId(null);
          setBoardsOpen(false);
          return;
        } finally {
          moveBoardWriteRef.current = false;
        }
      }
    }

    await saveNow();
    if (!isCurrent()) return;
    const snapshot = await repository.getBoardSnapshot(boardId);
    if (!isCurrent()) return;
    if (!snapshot) {
      await persistActiveBoard(board.id, generation);
      return;
    }
    if (!await persistActiveBoard(boardId, generation)) return;
    setBoard(snapshot.board);
    setCamera(snapshot.board.camera);
    renderCameraVisual(snapshot.board.camera);
    liveItemGeometryRef.current.clear();
    itemsRef.current = snapshot.items;
    itemRevisionRef.current = 0;
    savedItemRevisionRef.current = 0;
    setItems(snapshot.items);
    setSelection([]);
    cancelStackTransition();
    setContainerView(null);
    setFolderCanvasTransitionId(null);
    setStackTransitionId(null);
    setBoardsOpen(false);
  };

  const addBoard = async () => {
    if (moveBoardWriteRef.current) return;
    const generation = ++boardSwitchGenerationRef.current;
    const isCurrent = () => generation === boardSwitchGenerationRef.current;
    await saveNow();
    if (!isCurrent()) return;
    const snapshot = createEmptyBoard(`Space ${boards.length + 1}`);
    await enqueueSnapshotWrite(() => repository.replaceBoardSnapshot(snapshot));
    const discardStaleBoard = () => enqueueSnapshotWrite(
      () => repository.deleteBoard(snapshot.board.id),
    );
    if (!isCurrent()) {
      await discardStaleBoard();
      return;
    }
    if (!await persistActiveBoard(snapshot.board.id, generation)) {
      await discardStaleBoard();
      return;
    }
    setBoards((current) => [...current, snapshot.board]);
    setBoard(snapshot.board);
    setCamera(snapshot.board.camera);
    renderCameraVisual(snapshot.board.camera);
    liveItemGeometryRef.current.clear();
    itemsRef.current = [];
    itemRevisionRef.current = 0;
    savedItemRevisionRef.current = 0;
    setItems([]);
    setSelection([]);
    cancelStackTransition();
    setContainerView(null);
    setFolderCanvasTransitionId(null);
    setStackTransitionId(null);
    setBoardsOpen(false);
  };

  useEffect(() => {
    const down = (event) => {
      if (isEditableTarget(event.target)) return;
      const command = event.metaKey || event.ctrlKey;
      if (command && event.key.toLowerCase() === "z") {
        event.preventDefault();
        event.shiftKey ? redo() : undo();
        return;
      }
      if (event.ctrlKey && !event.metaKey && event.key.toLowerCase() === "y") {
        event.preventDefault();
        redo();
        return;
      }
      if (command && event.key.toLowerCase() === "a") {
        event.preventDefault();
        setSelection(itemsRef.current.filter((item) => !item.stackId || expandedStackId === item.stackId).map((item) => item.id));
        return;
      }
      if (["=", "+", "-", "0"].includes(event.key)) {
        event.preventDefault();
        stopCameraAnimation();
        const viewport = viewportRef.current;
        if (!viewport) return;
        const current = liveCameraRef.current;
        const nextZoom = event.key === "0"
          ? 1
          : current.zoom * (event.key === "-" ? 1 / 1.2 : 1.2);
        const next = zoomCameraAt(
          current,
          { x: viewport.clientWidth / 2, y: viewport.clientHeight / 2 },
          nextZoom,
          { minZoom: 0.2, maxZoom: 2.2 },
        );
        applyLiveCamera(next, { source: "keyboard", mode: "zoom", phase: "update" });
        commitCameraVisual(next);
        return;
      }
      if (event.code === "Space") {
        if (event.altKey) { event.preventDefault(); setScratchOpen(true); }
        else setSpaceDown(true);
      }
      if (event.key === "Escape") {
        controller.cancel();
        if (detailPresenceId) closeDetail();
        else if (activeFolderId) closeFolderCanvas();
        else if (expandedStackId) closeContainerInline();
        else if (focusedIds.length) clearFocus();
        else setSelection([]);
        setAddMenuOpen(false);
        setFolderPickerOpen(false);
        setBoardsOpen(false);
        setScratchOpen(false);
        urlCaptureRequestRef.current += 1;
        setUrlCapture(null);
        setDocumentImport(null);
        setRenameStackId(null);
        setColorOpen(false);
        setColorPreview(null);
      }
      if (event.key === "Backspace" || event.key === "Delete") deleteSelection();
      if (event.key.toLowerCase() === "n") addItemAt("note");
      if (event.key.toLowerCase() === "d") addItemAt("document");
      if (event.key.toLowerCase() === "w") addItemAt("web");
      if (event.key.toLowerCase() === "u" && (selectedSingle?.kind === "stack" || selectedSingle?.kind === "folder")) unpackStack(selectedSingle.id);
      if (event.key.toLowerCase() === "f" && selectionRef.current.length) focusSelection();
    };
    const up = (event) => { if (event.code === "Space") setSpaceDown(false); };
    window.addEventListener("keydown", down);
    window.addEventListener("keyup", up);
    return () => { window.removeEventListener("keydown", down); window.removeEventListener("keyup", up); };
  }, [activeFolderId, addItemAt, applyLiveCamera, clearFocus, closeContainerInline, closeDetail, closeFolderCanvas, commitCameraVisual, controller, deleteSelection, detailPresenceId, expandedStackId, focusSelection, focusedIds.length, redo, selectedSingle, setSelection, stopCameraAnimation, undo, unpackStack]);

  useEffect(() => {
    const paste = (event) => {
      if (isEditableTarget(event.target)) return;
      const text = event.clipboardData?.getData("text/plain")?.trim();
      if (text && /^https:\/\//i.test(text)) {
        event.preventDefault();
        urlCaptureRequestRef.current += 1;
        setUrlCapture({ value: text });
      }
    };
    window.addEventListener("paste", paste);
    return () => window.removeEventListener("paste", paste);
  }, []);

  const onDrop = async (event) => {
    event.preventDefault();
    const files = [...event.dataTransfer.files];
    const point = canvasPoint(event);
    const officeFile = files.find((candidate) => Boolean(detectOfficeDocumentFormat(candidate)));
    if (officeFile) {
      try {
        await importDocumentFile({
          name: officeFile.name,
          size: officeFile.size,
          type: officeFile.type,
          file: officeFile,
        }, point);
      } catch (error) {
        setDocumentImport({
          point,
          busy: false,
          error: error instanceof Error ? error.message : "The document could not be imported.",
        });
      }
      return;
    }
    const file = files.find((candidate) => candidate.type.startsWith("image/"));
    if (!file) return;
    const image = await fileAsDataUrl(file);
    const cameraValue = liveCameraRef.current;
    const world = { x: point.x / cameraValue.zoom + cameraValue.x, y: point.y / cameraValue.zoom + cameraValue.y };
    const now = Date.now();
    const id = uniqueId("image");
    const displayPose = { x: world.x - 150, y: world.y - 130, width: 300, height: 260, rotation: 0 };
    const item = {
      id,
      boardId: board.id,
      kind: "image",
      pose: activeFolderId
        ? folderCanonicalPose(displayPose, activeFolderOffsetRef.current)
        : displayPose,
      z: Math.max(...itemsRef.current.map((candidate) => candidate.z), 0) + 1,
      style: { cornerRadius: 16 },
      content: { title: file.name, image, alt: file.name, caption: file.name },
      stackId: activeFolderId,
      createdAt: now,
      updatedAt: now,
    };
    commitMutation((current) => [
      ...current.map((candidate) => candidate.id === activeFolderId
        ? {
          ...candidate,
          content: {
            ...candidate.content,
            memberIds: [...new Set([...(candidate.content.memberIds || []), id])],
          },
          updatedAt: now,
        }
        : candidate),
      item,
    ]);
    setSelection([id]);
  };

  return (
    <div
      ref={appRootRef}
      className={`spatial-app theme-${board.theme} ${hydrated ? "is-hydrated" : "is-hydrating"} ${platformBridge.isElectron ? "is-electron" : "is-browser"}`}
      data-render-count={renderCountRef.current}
      data-rendered-items={renderItems.length}
      data-total-items={items.length}
      data-board-count={boards.length}
      data-live-camera-frames={performanceStatsRef.current.liveCameraFrames}
      data-camera-commits={performanceStatsRef.current.cameraCommits}
      data-live-item-frames={performanceStatsRef.current.liveItemFrames}
      data-item-commits={performanceStatsRef.current.itemCommits}
      data-spatial-pages={spatialPageIndex.pageCount}
      data-page-candidates={spatialPageIndex.lastQueryStats.candidatesTested}
      data-index-moved={spatialPageIndex.lastSyncStats.moved}
      data-render-origin={`${renderOrigin.x},${renderOrigin.y}`}
    >
      <div
        className={`hydration-cover ${hydrated ? "is-ready" : ""}`}
        role="status"
        aria-label={hydrated ? undefined : "Loading Spatial"}
        aria-hidden={hydrated}
      >
        <span>Spatial</span>
      </div>
      <MotionConfig reducedMotion="user">
        <LayoutGroup id="spatial-shared-elements">
          <main
            ref={viewportRef}
            className={`canvas-viewport ${interaction === "pan" ? "is-panning" : ""} ${spaceDown ? "is-space-down" : ""}`}
            onPointerDownCapture={onViewportPointerDownCapture}
            onPointerMoveCapture={onTouchPointerMoveCapture}
            onPointerUpCapture={onViewportPointerEndCapture}
            onPointerCancelCapture={onViewportPointerEndCapture}
            onClickCapture={suppressDismissedInspectClick}
            onDoubleClickCapture={suppressDismissedInspectClick}
            onPointerDown={onCanvasPointerDown}
            onPointerMove={movePointer}
            onPointerUp={finishPointer}
            onPointerCancel={() => {
              itemPressRef.current = null;
              controller.cancel();
            }}
            onDragOver={(event) => event.preventDefault()}
            onDrop={onDrop}
            onDoubleClick={(event) => {
              if (!event.target.closest?.("[data-item-id], button")) addItemAt("note", canvasPoint(event));
            }}
          >
            <AnimatePresence>
              {activeFolderId && (
                <motion.div
                  className="folder-canvas-backdrop"
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  exit={{ opacity: 0 }}
                  transition={{ duration: 0.38, ease: [0.16, 1, 0.3, 1] }}
                />
              )}
            </AnimatePresence>
            <motion.div
              className="canvas-world"
              style={{ x: worldX, y: worldY, scale: worldScale }}
            >
              {activeDetailItem && (
                <motion.div
                  className="detail-color-backdrop"
                  data-detail-backdrop="true"
                  aria-hidden="true"
                  style={{
                    x: fullscreenDetailTarget.x,
                    y: fullscreenDetailTarget.y,
                    width: fullscreenDetailTarget.width,
                    height: fullscreenDetailTarget.height,
                    opacity: detailBackdropOpacityMotion,
                    backgroundColor: detailSurfaceColor(activeDetailItem),
                  }}
                />
              )}
              {renderItems.map((item) => {
                const absoluteTarget = itemAnimation(
                  item,
                  stackMap,
                  stackMemberIndexes,
                  expandedStackId,
                  activeFolderId,
                  activeFolderLayout,
                  fullscreenFolderTarget,
                );
                const target = worldGeometryToRender(absoluteTarget, renderOrigin);
                const memberOfExpanded = item.stackId === expandedStackId;
                const memberOfActiveFolder = item.stackId === activeFolderId;
                const transitionStack = item.stackId ? stackMap.get(item.stackId) : null;
                const transitionMemberIndex = stackMemberIndexes.get(item.stackId)?.get(item.id) ?? -1;
                const transitionMemberCount = transitionStack?.content?.memberIds?.length || 0;
                const isStackTransitionMember = Boolean(item.stackId && item.stackId === stackTransitionId);
                const isContainerTransitionShell = isContainerKind(item) && item.id === stackTransitionId;
                const isFolderCanvasTransitionShell = isContainerKind(item)
                  && item.id === folderCanvasTransitionId;
                const transitionGroupId = isStackTransitionMember
                  ? item.stackId
                  : isContainerTransitionShell
                    ? item.id
                    : null;
                const transitionPhase = stackMotionRef.current?.stackId === item.stackId
                  ? stackMotionRef.current.phase
                  : null;
                const transitionOrder = transitionPhase === "close"
                  ? Math.max(0, transitionMemberCount - 1 - transitionMemberIndex)
                  : Math.max(0, transitionMemberIndex);
                const historyTransitionIndex = historyTransition?.memberIds.indexOf(item.id) ?? -1;
                const historyTransitionOrder = historyTransitionIndex < 0
                  ? 0
                  : historyTransition?.direction === "undo"
                    ? Math.max(0, historyTransition.memberIds.length - 1 - historyTransitionIndex)
                    : historyTransitionIndex;
                const isDetailViewer = item.id === detailPresenceId;
                const usesAuthoredReader = isDetailViewer && (
                  item.kind === "note"
                  || (item.kind === "document" && !item.content?.documentSource)
                );
                const usesFullscreenEditor = isDetailViewer && (
                  item.kind === "note"
                  || item.kind === "document"
                );
                const itemDetailTarget = isDetailViewer
                  ? usesAuthoredReader
                    ? worldGeometryToRender(
                        fullscreenReaderGeometry(absoluteTarget, camera, viewportSize),
                        renderOrigin,
                      )
                    : usesFullscreenEditor
                      ? fullscreenDetailTarget
                    : worldGeometryToRender(
                        centeredDetailGeometry(absoluteTarget, camera, viewportSize, { kind: item.kind }),
                        renderOrigin,
                      )
                  : null;
                const dimmed = Boolean(
                  (expandedStackId && item.id !== expandedStackId && !memberOfExpanded)
                  || (activeFolderId && item.id !== activeFolderId && !memberOfActiveFolder)
                  || (focusedIds.length && !focusedIds.includes(item.id))
                );
                const isSelected = selectedIds.includes(item.id);
                const selectionEmphasized = shouldScaleSelection({
                  selected: isSelected,
                  selectedCount: selectedIds.length,
                  origin: selectionOrigin,
                });
                const preview = colorPreview && isSelected ? colorPreview : null;
                return (
                  <CanvasItemNode
                    key={item.id}
                    item={item}
                    target={target}
                    selected={isSelected}
                    selectionEmphasized={selectionEmphasized}
                    dimmed={dimmed}
                    dragging={interaction === "drag" && isSelected}
                    resizing={interaction === "resize" && isSelected}
                    preview={preview}
                    selectionControls={!dimmed && selectedIds.length === 1 && selectedIds[0] === item.id && !detailPresenceId}
                    registerRenderer={registerItemRenderer}
                    onPointerDown={(event) => onItemPointerDown(item, event)}
                    onDoubleClick={(event) => {
                      event.stopPropagation();
                      if (!isContainerKind(item)) openDetail(item.id);
                    }}
                    onOpenStack={openContainerInline}
                    onResizePointerDown={startResize}
                    detailPresent={isDetailViewer}
                    detailOpen={detailId === item.id}
                    detailTarget={itemDetailTarget}
                    detailUsesDestinationBounds={usesFullscreenEditor}
                    detailProgressMotion={isDetailViewer ? detailTransitionProgress : null}
                    detailViewport={viewportSize}
                    detailActionsHost={viewportRef.current}
                    folderOpen={item.id === activeFolderId}
                    folderTransitioning={isFolderCanvasTransitionShell}
                    folderTarget={isContainerKind(item) ? fullscreenDetailTarget : null}
                    cameraZoom={camera.zoom}
                    cameraZoomMotion={isDetailViewer || isSelected ? worldScale : null}
                    transitionDelay={isStackTransitionMember
                      ? transitionOrder * STACK_STAGGER_SECONDS
                      : historyTransitionIndex >= 0
                        ? historyTransitionOrder * STACK_STAGGER_SECONDS
                        : 0}
                    onLayoutTransitionComplete={transitionGroupId
                      ? (memberId) => finishStackMemberMotion(transitionGroupId, memberId)
                      : undefined}
                    onDetailExitComplete={finishDetailExit}
                    onDetailUpdate={updateDetail}
                    onDetailDelete={(id) => { setSelection([id]); deleteSelection(); }}
                    onDetailDuplicate={(id) => {
                      setSelection([id]);
                      duplicateSelection();
                      closeDetail();
                    }}
                    onDetailExport={(detailExportItem) => {
                      const blob = new Blob([JSON.stringify(detailExportItem, null, 2)], { type: "application/json" });
                      const url = URL.createObjectURL(blob);
                      const anchor = document.createElement("a");
                      anchor.href = url;
                      anchor.download = `${(detailExportItem.title || "spatial-item").replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "").toLowerCase() || "spatial-item"}.json`;
                      anchor.click();
                      URL.revokeObjectURL(url);
                    }}
                    onDetailMove={(id) => {
                      setSelection([id]);
                      closeDetail();
                      setMoveItemId(id);
                      setBoardsOpen(true);
                    }}
                    onLoadAsset={loadAsset}
                    onOpenExternal={openExternal}
                    onWebPreviewResolved={cacheWebClipSource}
                  />
                );
              })}
            </motion.div>

            <div ref={marqueeRef} className="marquee" hidden />

            <div ref={snapLineXRef} className="snap-line vertical" hidden />
            <div ref={snapLineYRef} className="snap-line horizontal" hidden />

            <AppChrome
              detailOpen={Boolean(detailPresenceId || activeFolderId || expandedStackId || focusedIds.length)}
              integratedDetailHeader={integratedDetailHeader}
              backLabel={detailPresenceId && activeFolderId
                ? "Back to folder"
                : detailPresenceId && expandedStackId
                  ? "Back to folder preview"
                : detailPresenceId
                  ? "Back to board"
                  : activeFolderId
                    ? "Back to folder preview"
                    : expandedStackId
                      ? "Close folder preview"
                      : "Exit focus"}
              onBack={() => detailPresenceId ? closeDetail() : activeFolderId ? closeFolderCanvas() : expandedStackId ? closeContainerInline() : clearFocus()}
              showExpandContainer={Boolean(expandedStackId && !activeFolderId && !detailPresenceId && !stackTransitionId)}
              expandContainerLabel={`Open ${stackMap.get(expandedStackId)?.content?.title || "folder"} as its own canvas`}
              onExpandContainer={() => expandedStackId && openFolderCanvas(expandedStackId)}
              onAdd={(kind) => kind === "menu" ? setAddMenuOpen(true) : addItemAt(kind)}
              onAutoOrganize={autoOrganizeBoard}
              onOpenBoards={() => setBoardsOpen((current) => !current)}
              onOpenScratch={() => setScratchOpen(true)}
              onToggleTheme={() => setBoard((current) => ({ ...current, theme: current.theme === "light" ? "dark" : "light" }))}
              onUndo={undo}
              onRedo={redo}
              canUndo={historyRevision >= 0 && undoRef.current.length > 0}
              canRedo={historyRevision >= 0 && redoRef.current.length > 0}
              showAddInDetail={Boolean(activeFolderId && !detailPresenceId)}
              theme={board.theme}
              boardTitle={board.title}
            />

            {!detailPresenceId && !expandedStackId && !focusedIds.length
              && (!activeFolderId || selectedItems.some((item) => item.stackId === activeFolderId)) && (
              <ContextToolbar
                selectedCount={selectedIds.length}
                selectedKind={selectedKind}
                canColor={selectedItems.length > 0 && selectedItems.every((item) => item.kind === "note")}
                colorOpen={colorOpen}
                onAction={toolbarAction}
              >
                <RadialColorPicker
                  open={colorOpen}
                  value={colorPreview || selectedSingle?.style?.color || "#f7f8f3"}
                  onPreview={setColorPreview}
                  onCommit={commitColor}
                  onCancel={() => { setColorPreview(null); setColorOpen(false); }}
                />
              </ContextToolbar>
            )}

            <AddMenu
              open={addMenuOpen}
              onChoose={addItemAt}
              onClose={() => setAddMenuOpen(false)}
              hiddenKinds={activeFolderId ? ["stack", "folder"] : []}
            />
            <DocumentImportDialog
              open={Boolean(documentImport)}
              busy={Boolean(documentImport?.busy)}
              error={documentImport?.error || ""}
              onClose={() => setDocumentImport(null)}
              onPickFile={pickAndImportDocument}
              onImportGoogleLink={importGoogleDocument}
            />
            <FolderPicker
              open={folderPickerOpen}
              folders={availableFolders}
              selectedCount={selectedFolderMemberIds.length}
              currentFolderId={currentSelectionFolderId}
              onChoose={moveSelectionToFolder}
              onCreate={() => createFolder(selectedFolderMemberIds)}
              onRemove={() => moveSelectionToFolder(null)}
              onClose={() => setFolderPickerOpen(false)}
            />
            <ScratchPad
              open={scratchOpen}
              onClose={() => setScratchOpen(false)}
              onSave={(text) => {
                addItemAt("note");
                setTimeout(() => commitMutation((current) => current.map((item, index) => index === current.length - 1 ? { ...item, content: { title: "Scratch pad", text } } : item)), 0);
              }}
            />

            <AnimatePresence>
              {boardsOpen && (
                <>
                  <button type="button" className="overlay-dismiss" onClick={() => { setMoveItemId(null); setBoardsOpen(false); }} aria-label="Close board switcher" />
                  <motion.div className="board-switcher" initial={{ opacity: 0, y: 12, scale: 0.92 }} animate={{ opacity: 1, y: 0, scale: 1 }} exit={{ opacity: 0, y: 10, scale: 0.94 }}>
                    <h2>{moveItemId ? "Move item to…" : "Spaces"}</h2>
                    {boards.map((entry) => (
                      <button key={entry.id} type="button" className={`board-option ${entry.id === board.id ? "is-active" : ""}`} onClick={() => switchBoard(entry.id)}>
                        <span className="board-option-preview" style={{ "--preview-color": entry.theme === "dark" ? "#171b1c" : "#dfe3e3" }} />
                        <span><strong>{entry.title}</strong><span>{entry.id === CLIENT_BOARD_ID ? "Interior project" : "Visual notes"}</span></span>
                        {entry.id === board.id && <span>Current</span>}
                      </button>
                    ))}
                    <button type="button" className="board-option" onClick={addBoard}>
                      <span className="board-option-preview" style={{ display: "grid", placeItems: "center" }}><Plus size={13} /></span>
                      <span><strong>New space</strong><span>Start with an empty canvas</span></span>
                    </button>
                  </motion.div>
                </>
              )}
            </AnimatePresence>

            <AnimatePresence>
              {urlCapture && (
                <ModalDialog
                  title="Add web clip"
                  className="web-clip-modal"
                  closeDisabled={urlCapture.busy}
                  onClose={() => {
                    urlCaptureRequestRef.current += 1;
                    setUrlCapture(null);
                  }}
                >
                  <form
                    className="web-clip-form"
                    onSubmit={(event) => {
                      event.preventDefault();
                      createWebClip(new FormData(event.currentTarget).get("url"));
                    }}
                  >
                    <label className="app-modal-field-label" htmlFor="web-clip-url">Website URL</label>
                    <div className="app-modal-input-row">
                      <input
                        id="web-clip-url"
                        name="url"
                        autoFocus
                        type="url"
                        inputMode="url"
                        autoComplete="url"
                        defaultValue={urlCapture.value || "https://"}
                        placeholder="https://example.com"
                        autoCapitalize="none"
                        autoCorrect="off"
                        spellCheck="false"
                        aria-label="Website URL"
                        aria-invalid={Boolean(urlCapture.error)}
                        disabled={urlCapture.busy}
                      />
                      <button type="submit" disabled={urlCapture.busy}>
                        {urlCapture.busy ? "Adding…" : "Add"}
                      </button>
                    </div>
                    {urlCapture.error && <p className="app-modal-error" role="alert">{urlCapture.error}</p>}
                  </form>
                </ModalDialog>
              )}
            </AnimatePresence>

            <AnimatePresence>
              {renameStackId && (
                <ModalDialog
                  title="Rename folder"
                  className="rename-modal"
                  onClose={() => setRenameStackId(null)}
                >
                  <form
                    className="rename-form"
                    onSubmit={(event) => {
                      event.preventDefault();
                      const title = new FormData(event.currentTarget).get("title")?.toString().trim();
                      if (title) commitMutation((current) => current.map((item) => item.id === renameStackId ? { ...item, content: { ...item.content, title } } : item));
                      setRenameStackId(null);
                    }}
                  >
                    <label className="app-modal-field-label" htmlFor="rename-folder-title">Folder name</label>
                    <div className="app-modal-input-row">
                      <input id="rename-folder-title" name="title" autoFocus defaultValue={items.find((item) => item.id === renameStackId)?.content.title || "Untitled"} aria-label="Folder name" />
                      <button type="submit">Save</button>
                    </div>
                  </form>
                </ModalDialog>
              )}
            </AnimatePresence>

            <span ref={zoomIndicatorRef} className={`zoom-indicator ${zoomVisible ? "is-visible" : ""}`}>{Math.round(camera.zoom * 100)}%</span>
          </main>
        </LayoutGroup>
      </MotionConfig>
    </div>
  );
}
