import { clamp } from "./geometry.js";

/** @typedef {{x: number, y: number, zoom: number}} Camera */

export const DEFAULT_CAMERA_LIMITS = Object.freeze({ minZoom: 0.15, maxZoom: 4 });
export const DEFAULT_RENDER_ORIGIN_SIZE = 8192;

/**
 * Camera x/y are the world-space coordinates at the viewport origin.
 * Keeping the camera in world units makes pan sensitivity independent of zoom
 * and matches the model persisted by Spatial boards.
 */
export function worldToScreen(point, camera) {
  return {
    x: (point.x - camera.x) * camera.zoom,
    y: (point.y - camera.y) * camera.zoom,
  };
}

export function screenToWorld(point, camera) {
  return {
    x: point.x / camera.zoom + camera.x,
    y: point.y / camera.zoom + camera.y,
  };
}

export function panCamera(camera, screenDelta) {
  return {
    ...camera,
    x: camera.x - screenDelta.x / camera.zoom,
    y: camera.y - screenDelta.y / camera.zoom,
  };
}

/**
 * Zoom while keeping the world point currently under `screenPoint` stationary.
 * This is the cursor-centered behavior used by Spatial's canvas.
 */
export function zoomCameraAt(
  camera,
  screenPoint,
  nextZoom,
  limits = DEFAULT_CAMERA_LIMITS,
) {
  const zoom = clamp(nextZoom, limits.minZoom, limits.maxZoom);
  const anchor = screenToWorld(screenPoint, camera);
  return {
    x: anchor.x - screenPoint.x / zoom,
    y: anchor.y - screenPoint.y / zoom,
    zoom,
  };
}

/** Exponential wheel scaling feels consistent across mouse wheels and trackpads. */
export function zoomCameraByWheel(
  camera,
  screenPoint,
  deltaY,
  { sensitivity = 0.0015, ...limits } = {},
) {
  const nextZoom = camera.zoom * Math.exp(-deltaY * sensitivity);
  return zoomCameraAt(camera, screenPoint, nextZoom, {
    ...DEFAULT_CAMERA_LIMITS,
    ...limits,
  });
}

export function cameraTransform(camera) {
  return `translate3d(${-camera.x * camera.zoom}px, ${-camera.y * camera.zoom}px, 0) scale(${camera.zoom})`;
}

/**
 * Pick a nearby world-space origin for compositor rendering.
 *
 * Canonical coordinates remain absolute. Only the CSS transforms are rebased,
 * keeping their values small enough for stable GPU precision even when the
 * camera has travelled trillions of world units from the board's origin.
 */
export function renderOriginForCamera(
  camera,
  originSize = DEFAULT_RENDER_ORIGIN_SIZE,
  currentOrigin = null,
) {
  if (!Number.isFinite(originSize) || originSize <= 0) {
    throw new RangeError("originSize must be a positive finite number");
  }
  if (!Number.isFinite(camera?.x) || !Number.isFinite(camera?.y)) {
    throw new TypeError("camera coordinates must be finite numbers");
  }
  const rebaseDistance = originSize * 0.75;
  const nextAxis = (value, current) => {
    if (Number.isFinite(current) && Math.abs(value - current) <= rebaseDistance) {
      return current;
    }
    const rounded = Math.round(value / originSize) * originSize;
    return Object.is(rounded, -0) ? 0 : rounded;
  };
  const nextOrigin = {
    x: nextAxis(camera.x, currentOrigin?.x),
    y: nextAxis(camera.y, currentOrigin?.y),
  };
  return currentOrigin
    && nextOrigin.x === currentOrigin.x
    && nextOrigin.y === currentOrigin.y
    ? currentOrigin
    : nextOrigin;
}

/** Motion transform for a world whose child coordinates are relative to origin. */
export function relativeCameraTransform(camera, origin) {
  return {
    x: (origin.x - camera.x) * camera.zoom,
    y: (origin.y - camera.y) * camera.zoom,
    scale: camera.zoom,
  };
}

/** Recover the canonical camera from the live compositor transform. */
export function cameraFromRelativeTransform(transform, origin) {
  const zoom = Math.max(0.0001, transform?.scale || 1);
  return {
    x: origin.x - (transform?.x || 0) / zoom,
    y: origin.y - (transform?.y || 0) / zoom,
    zoom,
  };
}

/** Convert absolute world geometry to the current small render-coordinate space. */
export function worldGeometryToRender(geometry, origin) {
  return {
    ...geometry,
    x: geometry.x - origin.x,
    y: geometry.y - origin.y,
  };
}

export function visibleWorldRect(camera, viewport) {
  const topLeft = screenToWorld({ x: 0, y: 0 }, camera);
  const bottomRight = screenToWorld(
    { x: viewport.width, y: viewport.height },
    camera,
  );
  return {
    x: topLeft.x,
    y: topLeft.y,
    width: bottomRight.x - topLeft.x,
    height: bottomRight.y - topLeft.y,
  };
}

/** Frame a world-space rectangle with one camera pan/zoom transform. */
export function cameraToFrameRect(
  rect,
  viewport,
  { padding = 120, minZoom = 0.2, maxZoom = 1.55 } = {},
) {
  if (!rect || !viewport) return null;
  const availableWidth = Math.max(1, viewport.width - padding * 2);
  const availableHeight = Math.max(1, viewport.height - padding * 2);
  const zoom = clamp(Math.min(
    availableWidth / Math.max(1, rect.width),
    availableHeight / Math.max(1, rect.height),
  ), minZoom, maxZoom);
  return {
    x: rect.x + rect.width / 2 - viewport.width / (2 * zoom),
    y: rect.y + rect.height / 2 - viewport.height / (2 * zoom),
    zoom,
  };
}

/** Convert a client pointer coordinate to coordinates inside a DOM element. */
export function eventPoint(event, element) {
  const bounds = element.getBoundingClientRect();
  return { x: event.clientX - bounds.left, y: event.clientY - bounds.top };
}
