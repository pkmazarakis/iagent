import { panCamera, screenToWorld, zoomCameraByWheel } from "./camera.js";
import { itemRect, rectFromPoints, subtractPoints } from "./geometry.js";
import { marqueeSelection } from "./selection.js";
import {
  createSnapTargetIndex,
  dragWithSnapping,
  EMPTY_SNAP_RESULT,
  resizeWithSnapping,
} from "./snap.js";
import { CANVAS_SNAP_CONFIG } from "./snapConfig.js";

const noop = () => {};

function defaultRequestFrame(callback) {
  if (typeof globalThis.requestAnimationFrame === "function") {
    return globalThis.requestAnimationFrame(callback);
  }
  return globalThis.setTimeout(() => callback(Date.now()), 16);
}

function defaultCancelFrame(id) {
  if (typeof globalThis.cancelAnimationFrame === "function") {
    globalThis.cancelAnimationFrame(id);
  } else {
    globalThis.clearTimeout(id);
  }
}

function pointFrom(value) {
  return value?.point ?? value;
}

function pointerSample(value) {
  return {
    point: pointFrom(value),
    time: Number.isFinite(value?.time) ? value.time : null,
    disableSnapping: Boolean(value?.disableSnapping),
    terminal: Boolean(value?.terminal),
  };
}

function pointerVelocity(interaction, sample, frameTime) {
  const point = sample.point;
  const now = sample.time
    ?? (Number.isFinite(frameTime) ? frameTime : null)
    ?? ((interaction.lastPointerTime ?? 0) + 16);
  const previous = interaction.lastPointerPoint ?? point;
  const elapsed = interaction.lastPointerTime == null
    ? 16
    : Math.max(1, now - interaction.lastPointerTime);
  const distance = Math.hypot(point.x - previous.x, point.y - previous.y);
  interaction.lastPointerPoint = point;
  interaction.lastPointerTime = now;
  return { velocity: distance / elapsed, time: now };
}

function dragSnappingEnabled(interaction, sample, frameTime, options) {
  const { velocity, time } = pointerVelocity(interaction, sample, frameTime);
  const engageVelocity = options.engageVelocity ?? CANVAS_SNAP_CONFIG.engageVelocity;
  const releaseVelocity = options.releaseVelocity ?? CANVAS_SNAP_CONFIG.releaseVelocity;
  const settleMs = options.settleMs ?? CANVAS_SNAP_CONFIG.settleMs;

  if (sample.disableSnapping || velocity > releaseVelocity) {
    interaction.snapActive = false;
    interaction.slowSnapSince = null;
    return false;
  }
  if (interaction.snapActive) return true;
  // Pointer-up is allowed to preserve an existing snap, but it must never be
  // the zero-velocity sample that newly captures a guide at the last moment.
  if (sample.terminal) return false;
  if (velocity <= engageVelocity) {
    if (interaction.slowSnapSince == null) interaction.slowSnapSince = time;
    if (time - interaction.slowSnapSince >= settleMs) interaction.snapActive = true;
  } else {
    interaction.slowSnapSince = null;
  }
  return interaction.snapActive;
}

function selectedIdsFrom(snapshot) {
  return new Set(snapshot.selectedIds ?? snapshot.selection ?? []);
}

function geometryPatch(item, rect) {
  return {
    id: item.id,
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
  };
}

function sameSet(a, b) {
  if (a.size !== b.size) return false;
  for (const value of a) if (!b.has(value)) return false;
  return true;
}

function snapKey(snap) {
  return snap
    ? `${snap.kind}:${snap.targetId}:${snap.targetEdge ?? "size"}:${snap.value}`
    : null;
}

/**
 * Create a DOM-agnostic, requestAnimationFrame-batched interaction controller.
 *
 * Required store adapter:
 * - `getSnapshot() -> {camera, items, selectedIds}`
 * - `onCameraChange(camera, meta)`
 * - `onItemsChange([{id, x?, y?, width?, height?}], meta)`
 * - `onSelectionChange(string[], meta)`
 *
 * Optional presentation callbacks:
 * - `onMarqueeChange({active, screenRect, worldRect})`
 * - `onSnapChange({guides, highlightedIds, snaps})`
 * - `onHaptic({type: 'snap-engage'|'snap-release', axis, snap})`
 * - `onInteractionChange({type, phase})`
 *
 * Pointer moves are coalesced to the latest point each frame. Geometry patches
 * are absolute values calculated from the pointer-down snapshot, which avoids
 * drift and makes the controller safe with asynchronous React state updates.
 */
export function createCanvasInteractionController({
  getSnapshot,
  onCameraChange = noop,
  onItemsChange = noop,
  onSelectionChange = noop,
  onMarqueeChange = noop,
  onSnapChange = noop,
  onHaptic = noop,
  onInteractionChange = noop,
  requestFrame = defaultRequestFrame,
  cancelFrame = defaultCancelFrame,
  zoom = {},
  snap = {},
} = {}) {
  if (typeof getSnapshot !== "function") {
    throw new TypeError("createCanvasInteractionController requires getSnapshot");
  }

  let interaction = null;
  let pendingPointer = null;
  let pendingWheel = [];
  let frameId = null;
  let destroyed = false;

  function emitInteraction(type, phase, details = {}) {
    onInteractionChange({ type, phase, ...details });
  }

  function schedule() {
    if (destroyed || frameId !== null) return;
    frameId = requestFrame(processFrame);
  }

  function processWheelQueue() {
    if (!pendingWheel.length) return;
    let camera = getSnapshot().camera;
    const events = pendingWheel;
    pendingWheel = [];
    let mode = "pan";

    for (const event of events) {
      if (event.type === "zoom") {
        mode = "zoom";
        camera = zoomCameraByWheel(camera, event.point, event.deltaY, {
          ...zoom,
          ...event.options,
        });
      } else {
        camera = panCamera(camera, {
          x: -event.deltaX,
          y: -event.deltaY,
        });
      }
    }
    onCameraChange(camera, { source: "wheel", mode, phase: "update" });
  }

  function emitSnapHaptics(nextSnaps) {
    if (!interaction || (interaction.type !== "drag" && interaction.type !== "resize")) return;
    for (const axis of ["x", "y"]) {
      const previousKey = interaction.snapKeys[axis];
      const nextKey = snapKey(nextSnaps[axis]);
      if (nextKey && nextKey !== previousKey) {
        onHaptic({ type: "snap-engage", axis, snap: nextSnaps[axis] });
      } else if (!nextKey && previousKey) {
        onHaptic({ type: "snap-release", axis, snap: null });
      }
      interaction.snapKeys[axis] = nextKey;
    }
  }

  function processPointer(frameTime) {
    if (!interaction || !pendingPointer) return;
    const sample = pendingPointer;
    const point = sample.point;
    pendingPointer = null;

    if (interaction.type === "pan") {
      const delta = subtractPoints(point, interaction.startPoint);
      onCameraChange(panCamera(interaction.startCamera, delta), {
        source: "pan",
        phase: "update",
      });
      return;
    }

    if (interaction.type === "drag") {
      const startWorld = screenToWorld(interaction.startPoint, interaction.camera);
      const currentWorld = screenToWorld(point, interaction.camera);
      const delta = subtractPoints(currentWorld, startWorld);
      const result = dragWithSnapping(
        interaction.items,
        delta,
        interaction.targets,
        {
          ...snap,
          enabled: dragSnappingEnabled(interaction, sample, frameTime, snap),
          zoom: interaction.camera.zoom,
          excludeIds: interaction.itemIds,
        },
      );
      emitSnapHaptics(result.snaps);
      onItemsChange(result.changes, { source: "drag", phase: "update" });
      onSnapChange(result);
      return;
    }

    if (interaction.type === "marquee") {
      const screenRect = rectFromPoints(interaction.startPoint, point);
      const worldRect = rectFromPoints(
        screenToWorld(interaction.startPoint, interaction.camera),
        screenToWorld(point, interaction.camera),
      );
      const next = marqueeSelection(interaction.items, worldRect, {
        baseSelection: interaction.baseSelection,
        mode: interaction.mode,
        operation: interaction.operation,
      });
      const crossedDragThreshold = !interaction.dragged
        && Math.hypot(screenRect.width, screenRect.height) > 5;
      if (crossedDragThreshold) interaction.dragged = true;
      if (interaction.dragged
        && (!sameSet(next, interaction.lastSelection) || crossedDragThreshold)) {
        interaction.lastSelection = next;
        onSelectionChange([...next], {
          source: "marquee",
          phase: "update",
          dragged: true,
        });
      }
      interaction.lastScreenRect = screenRect;
      interaction.lastWorldRect = worldRect;
      onMarqueeChange({ active: true, screenRect, worldRect });
      return;
    }

    if (interaction.type === "resize") {
      const startWorld = screenToWorld(interaction.startPoint, interaction.camera);
      const currentWorld = screenToWorld(point, interaction.camera);
      const delta = subtractPoints(currentWorld, startWorld);
      const result = resizeWithSnapping(
        interaction.startRect,
        interaction.handle,
        delta,
        interaction.targets,
        {
          ...snap,
          ...interaction.options,
          zoom: interaction.camera.zoom,
          excludeId: interaction.item.id,
        },
      );
      emitSnapHaptics(result.snaps);
      onItemsChange([geometryPatch(interaction.item, result.rect)], {
        source: "resize",
        phase: "update",
      });
      onSnapChange(result);
    }
  }

  function processFrame(frameTime) {
    frameId = null;
    processWheelQueue();
    processPointer(frameTime);
  }

  function flush() {
    if (frameId !== null) {
      cancelFrame(frameId);
      frameId = null;
    }
    processFrame();
  }

  function replaceInteraction(next) {
    if (interaction) end();
    interaction = next;
    interaction.lastPointerPoint = next.startPoint;
    interaction.lastPointerTime = null;
    interaction.slowSnapSince = null;
    interaction.snapActive = false;
    pendingPointer = null;
    emitInteraction(next.type, "start", { itemId: next.item?.id ?? null });
  }

  function beginPan(input) {
    const point = pointFrom(input);
    const snapshot = getSnapshot();
    replaceInteraction({
      type: "pan",
      startPoint: point,
      startCamera: { ...snapshot.camera },
    });
    return api;
  }

  function beginMarquee({
    point,
    operation = "replace",
    mode = "intersect",
  }) {
    const snapshot = getSnapshot();
    const baseSelection = selectedIdsFrom(snapshot);
    replaceInteraction({
      type: "marquee",
      startPoint: point,
      camera: { ...snapshot.camera },
      items: snapshot.items.map((item) => ({ ...item })),
      baseSelection,
      lastSelection: new Set(baseSelection),
      lastScreenRect: rectFromPoints(point, point),
      lastWorldRect: rectFromPoints(
        screenToWorld(point, snapshot.camera),
        screenToWorld(point, snapshot.camera),
      ),
      operation,
      mode,
      dragged: false,
    });
    onMarqueeChange({
      active: true,
      screenRect: interaction.lastScreenRect,
      worldRect: interaction.lastWorldRect,
    });
    return api;
  }

  function beginDrag({ point, itemId, itemIds = null, preserveSelection = true }) {
    const snapshot = getSnapshot();
    const selected = selectedIdsFrom(snapshot);
    let dragIds = itemIds ? new Set(itemIds) : selected;

    if (!dragIds.has(itemId)) {
      dragIds = new Set([itemId]);
      if (preserveSelection) {
        onSelectionChange([itemId], { source: "drag", phase: "start" });
      }
    }
    const items = snapshot.items
      .filter((item) => dragIds.has(item.id))
      .map((item) => ({ ...item }));
    if (!items.length) throw new Error(`Cannot drag missing item: ${itemId}`);

    replaceInteraction({
      type: "drag",
      startPoint: point,
      camera: { ...snapshot.camera },
      items,
      itemIds: new Set(items.map((item) => item.id)),
      targets: createSnapTargetIndex(snapshot.items),
      item: items.find((item) => item.id === itemId) ?? items[0],
      snapKeys: { x: null, y: null },
    });
    return api;
  }

  function beginResize({ point, itemId, handle, options = {} }) {
    const snapshot = getSnapshot();
    const item = snapshot.items.find((candidate) => candidate.id === itemId);
    if (!item) throw new Error(`Cannot resize missing item: ${itemId}`);
    const selected = selectedIdsFrom(snapshot);
    if (!selected.has(itemId)) {
      onSelectionChange([itemId], { source: "resize", phase: "start" });
    }
    replaceInteraction({
      type: "resize",
      startPoint: point,
      camera: { ...snapshot.camera },
      item: { ...item },
      startRect: itemRect(item),
      targets: createSnapTargetIndex(snapshot.items),
      handle,
      options,
      snapKeys: { x: null, y: null },
    });
    return api;
  }

  function move(input) {
    if (!interaction) return api;
    pendingPointer = pointerSample(input);
    schedule();
    return api;
  }

  function end(input = null) {
    if (!interaction) return api;
    if (input) pendingPointer = { ...pointerSample(input), terminal: true };
    flush();
    const finished = interaction;

    if (finished.type === "marquee") {
      onMarqueeChange({
        active: false,
        screenRect: finished.lastScreenRect,
        worldRect: finished.lastWorldRect,
      });
    }
    if (finished.type === "drag" || finished.type === "resize") {
      onSnapChange(EMPTY_SNAP_RESULT);
    }
    interaction = null;
    pendingPointer = null;
    emitInteraction(finished.type, "end", {
      itemId: finished.item?.id ?? null,
      ...(finished.type === "marquee" ? { dragged: finished.dragged } : {}),
    });
    return api;
  }

  function cancel() {
    if (!interaction) return api;
    const cancelled = interaction;
    pendingPointer = null;
    if (cancelled.type === "pan") {
      onCameraChange(cancelled.startCamera, { source: "pan", phase: "cancel" });
    } else if (cancelled.type === "drag") {
      onItemsChange(
        cancelled.items.map((item) => ({ id: item.id, x: item.x, y: item.y })),
        { source: "drag", phase: "cancel" },
      );
      onSnapChange(EMPTY_SNAP_RESULT);
    } else if (cancelled.type === "resize") {
      onItemsChange([geometryPatch(cancelled.item, cancelled.startRect)], {
        source: "resize",
        phase: "cancel",
      });
      onSnapChange(EMPTY_SNAP_RESULT);
    } else if (cancelled.type === "marquee") {
      onSelectionChange([...cancelled.baseSelection], {
        source: "marquee",
        phase: "cancel",
        dragged: cancelled.dragged,
      });
      onMarqueeChange({
        active: false,
        screenRect: cancelled.lastScreenRect,
        worldRect: cancelled.lastWorldRect,
      });
    }
    interaction = null;
    emitInteraction(cancelled.type, "cancel", {
      itemId: cancelled.item?.id ?? null,
    });
    return api;
  }

  function wheelZoom({ point, deltaY, options = {} }) {
    const previous = pendingWheel[pendingWheel.length - 1];
    const canCoalesce = previous?.type === "zoom"
      && previous.point.x === point.x
      && previous.point.y === point.y
      && Object.keys(previous.options).length === 0
      && Object.keys(options).length === 0;
    if (canCoalesce) previous.deltaY += deltaY;
    else pendingWheel.push({ type: "zoom", point, deltaY, options });
    schedule();
    return api;
  }

  function wheelPan({ deltaX = 0, deltaY = 0 }) {
    const previous = pendingWheel[pendingWheel.length - 1];
    if (previous?.type === "pan") {
      previous.deltaX += deltaX;
      previous.deltaY += deltaY;
    } else {
      pendingWheel.push({ type: "pan", deltaX, deltaY });
    }
    schedule();
    return api;
  }

  function destroy() {
    destroyed = true;
    if (frameId !== null) cancelFrame(frameId);
    frameId = null;
    interaction = null;
    pendingPointer = null;
    pendingWheel = [];
  }

  const api = {
    beginPan,
    beginMarquee,
    beginDrag,
    beginResize,
    move,
    end,
    cancel,
    wheelZoom,
    wheelPan,
    flush,
    destroy,
    getInteraction: () => interaction?.type ?? null,
  };

  return api;
}
