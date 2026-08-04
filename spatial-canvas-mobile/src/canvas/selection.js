import {
  itemRect,
  rectContainsRect,
  rectsIntersect,
} from "./geometry.js";

function asIdSet(ids) {
  return ids instanceof Set ? new Set(ids) : new Set(ids ?? []);
}

/**
 * Return item ids touched by a marquee in stable canvas order.
 * `intersect` matches Spatial's live selection sweep; `contain` is useful for
 * precision selection and is exposed for keyboard-modified integrations.
 */
export function idsInMarquee(items, marquee, mode = "intersect") {
  const predicate = mode === "contain" ? rectContainsRect : rectsIntersect;
  return items
    .filter((item) => predicate(marquee, itemRect(item)))
    .map((item) => item.id);
}

/**
 * Apply the *current* marquee hits to the selection captured at pointer-down.
 * Toggle/subtract operations deliberately use `baseSelection` every frame so
 * an item does not repeatedly flip while a live marquee remains over it.
 */
export function applyMarqueeSelection(
  baseSelection,
  hitIds,
  operation = "replace",
) {
  const base = asIdSet(baseSelection);
  const hits = asIdSet(hitIds);

  if (operation === "replace") return hits;
  if (operation === "add") return new Set([...base, ...hits]);
  if (operation === "subtract") {
    for (const id of hits) base.delete(id);
    return base;
  }
  if (operation === "toggle") {
    for (const id of hits) {
      if (base.has(id)) base.delete(id);
      else base.add(id);
    }
    return base;
  }

  throw new Error(`Unknown marquee selection operation: ${operation}`);
}

export function marqueeSelection(
  items,
  marquee,
  {
    baseSelection = [],
    mode = "intersect",
    operation = "replace",
  } = {},
) {
  return applyMarqueeSelection(
    baseSelection,
    idsInMarquee(items, marquee, mode),
    operation,
  );
}

export function selectionBounds(items, selectedIds) {
  const selected = asIdSet(selectedIds);
  const rects = items.filter((item) => selected.has(item.id)).map(itemRect);
  if (!rects.length) return null;

  const left = Math.min(...rects.map((rect) => rect.x));
  const top = Math.min(...rects.map((rect) => rect.y));
  const right = Math.max(...rects.map((rect) => rect.x + rect.width));
  const bottom = Math.max(...rects.map((rect) => rect.y + rect.height));
  return { x: left, y: top, width: right - left, height: bottom - top };
}

export function orderedSelection(items, selectedIds) {
  const selected = asIdSet(selectedIds);
  return items.filter((item) => selected.has(item.id)).map((item) => item.id);
}

