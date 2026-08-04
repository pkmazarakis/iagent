/**
 * Axis-aligned geometry helpers used by the canvas interaction layer.
 *
 * Canvas items are intentionally structural: any object with numeric
 * `x`, `y`, `width`, and `height` fields can be passed to these functions.
 * Coordinates are in world space unless a function explicitly says screen.
 * Rotation is visual-only and is not included in hit-testing or snapping.
 */

/** @typedef {{x: number, y: number}} Point */
/** @typedef {{x: number, y: number, width: number, height: number}} Rect */
/** @typedef {'n'|'ne'|'e'|'se'|'s'|'sw'|'w'|'nw'} ResizeHandle */

export const EPSILON = 1e-6;

export function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

export function addPoints(a, b) {
  return { x: a.x + b.x, y: a.y + b.y };
}

export function subtractPoints(a, b) {
  return { x: a.x - b.x, y: a.y - b.y };
}

export function scalePoint(point, scale) {
  return { x: point.x * scale, y: point.y * scale };
}

export function distance(a, b) {
  return Math.hypot(b.x - a.x, b.y - a.y);
}

export function normalizeRect(rect) {
  const x = rect.width < 0 ? rect.x + rect.width : rect.x;
  const y = rect.height < 0 ? rect.y + rect.height : rect.y;
  return {
    x,
    y,
    width: Math.abs(rect.width),
    height: Math.abs(rect.height),
  };
}

export function rectFromPoints(a, b) {
  return normalizeRect({
    x: a.x,
    y: a.y,
    width: b.x - a.x,
    height: b.y - a.y,
  });
}

export function itemRect(item) {
  return normalizeRect({
    x: item.x,
    y: item.y,
    width: item.width,
    height: item.height,
  });
}

export function rectEdges(rect) {
  const normalized = normalizeRect(rect);
  return {
    left: normalized.x,
    top: normalized.y,
    right: normalized.x + normalized.width,
    bottom: normalized.y + normalized.height,
    centerX: normalized.x + normalized.width / 2,
    centerY: normalized.y + normalized.height / 2,
  };
}

export function pointInRect(point, rect, inclusive = true) {
  const edges = rectEdges(rect);
  if (inclusive) {
    return (
      point.x >= edges.left &&
      point.x <= edges.right &&
      point.y >= edges.top &&
      point.y <= edges.bottom
    );
  }
  return (
    point.x > edges.left &&
    point.x < edges.right &&
    point.y > edges.top &&
    point.y < edges.bottom
  );
}

export function rectsIntersect(a, b, inclusive = true) {
  const first = rectEdges(a);
  const second = rectEdges(b);
  if (inclusive) {
    return !(
      first.right < second.left ||
      first.left > second.right ||
      first.bottom < second.top ||
      first.top > second.bottom
    );
  }
  return !(
    first.right <= second.left ||
    first.left >= second.right ||
    first.bottom <= second.top ||
    first.top >= second.bottom
  );
}

export function rectContainsRect(outer, inner, inclusive = true) {
  const a = rectEdges(outer);
  const b = rectEdges(inner);
  if (inclusive) {
    return (
      b.left >= a.left &&
      b.right <= a.right &&
      b.top >= a.top &&
      b.bottom <= a.bottom
    );
  }
  return (
    b.left > a.left &&
    b.right < a.right &&
    b.top > a.top &&
    b.bottom < a.bottom
  );
}

export function translateRect(rect, delta) {
  const normalized = normalizeRect(rect);
  return {
    ...normalized,
    x: normalized.x + delta.x,
    y: normalized.y + delta.y,
  };
}

export function insetRect(rect, amountX, amountY = amountX) {
  const normalized = normalizeRect(rect);
  return {
    x: normalized.x + amountX,
    y: normalized.y + amountY,
    width: Math.max(0, normalized.width - amountX * 2),
    height: Math.max(0, normalized.height - amountY * 2),
  };
}

export function unionRects(rects) {
  if (!rects.length) return null;
  const edges = rects.map(rectEdges);
  const left = Math.min(...edges.map((edge) => edge.left));
  const top = Math.min(...edges.map((edge) => edge.top));
  const right = Math.max(...edges.map((edge) => edge.right));
  const bottom = Math.max(...edges.map((edge) => edge.bottom));
  return { x: left, y: top, width: right - left, height: bottom - top };
}

export function rectCenter(rect) {
  const edges = rectEdges(rect);
  return { x: edges.centerX, y: edges.centerY };
}

export function handleMovesX(handle) {
  return handle.includes("e") || handle.includes("w");
}

export function handleMovesY(handle) {
  return handle.includes("n") || handle.includes("s");
}

/**
 * Resize `rect` from one of its eight handles. Minimum sizes are enforced by
 * holding the opposite edge fixed, matching native direct-manipulation UI.
 */
export function resizeRectFromHandle(
  rect,
  handle,
  delta,
  { minWidth = 40, minHeight = 40 } = {},
) {
  const start = rectEdges(rect);
  let { left, top, right, bottom } = start;

  if (handle.includes("w")) left += delta.x;
  if (handle.includes("e")) right += delta.x;
  if (handle.includes("n")) top += delta.y;
  if (handle.includes("s")) bottom += delta.y;

  if (right - left < minWidth) {
    if (handle.includes("w")) left = right - minWidth;
    else right = left + minWidth;
  }
  if (bottom - top < minHeight) {
    if (handle.includes("n")) top = bottom - minHeight;
    else bottom = top + minHeight;
  }

  return { x: left, y: top, width: right - left, height: bottom - top };
}

/** Return the nearest resize handle at `point`, or null. */
export function hitTestResizeHandle(
  point,
  rect,
  { radius = 10, includeEdges = true } = {},
) {
  const edge = rectEdges(rect);
  const handles = [
    ["nw", edge.left, edge.top],
    ["ne", edge.right, edge.top],
    ["se", edge.right, edge.bottom],
    ["sw", edge.left, edge.bottom],
  ];
  if (includeEdges) {
    handles.push(
      ["n", edge.centerX, edge.top],
      ["e", edge.right, edge.centerY],
      ["s", edge.centerX, edge.bottom],
      ["w", edge.left, edge.centerY],
    );
  }

  let best = null;
  for (const [handle, x, y] of handles) {
    const candidateDistance = distance(point, { x, y });
    if (candidateDistance <= radius && (!best || candidateDistance < best.distance)) {
      best = { handle, distance: candidateDistance, point: { x, y } };
    }
  }
  return best;
}

/** Return items from topmost to bottommost at a world-space point. */
export function hitTestItems(items, point) {
  return items
    .filter((item) => pointInRect(point, itemRect(item)))
    .sort((a, b) => (b.zIndex ?? 0) - (a.zIndex ?? 0));
}
