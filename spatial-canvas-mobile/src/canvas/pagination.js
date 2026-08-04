/**
 * Page-based world-space index for retaining a small canvas scene.
 *
 * The index is renderer- and store-agnostic. By default it accepts Spatial's
 * `{ id, pose: { x, y, width, height } }` items, while also accepting flat
 * `{ id, x, y, width, height }` items. Queries use world-space rectangles and
 * return the original item objects in stable source order.
 */

export const DEFAULT_WORLD_PAGE_SIZE = 2048;

function assertFiniteNumber(value, label) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError(`${label} must be a finite number`);
  }
  return value;
}

function assertPageSize(pageSize) {
  assertFiniteNumber(pageSize, "pageSize");
  if (pageSize <= 0) throw new RangeError("pageSize must be greater than zero");
  return pageSize;
}

/** Normalize reversed rectangles without mutating the source object. */
export function normalizeWorldRect(rect, label = "rect") {
  if (!rect || typeof rect !== "object") {
    throw new TypeError(`${label} must be a rectangle`);
  }

  const sourceX = assertFiniteNumber(rect.x, `${label}.x`);
  const sourceY = assertFiniteNumber(rect.y, `${label}.y`);
  const sourceWidth = assertFiniteNumber(rect.width, `${label}.width`);
  const sourceHeight = assertFiniteNumber(rect.height, `${label}.height`);
  const x = sourceWidth < 0 ? sourceX + sourceWidth : sourceX;
  const y = sourceHeight < 0 ? sourceY + sourceHeight : sourceY;
  const width = Math.abs(sourceWidth);
  const height = Math.abs(sourceHeight);

  if (![x, y, width, height, x + width, y + height].every(Number.isFinite)) {
    throw new RangeError(`${label} exceeds the finite world-coordinate range`);
  }

  return { x, y, width, height };
}

function nonNegativeOverscan(value, label) {
  assertFiniteNumber(value, label);
  if (value < 0) throw new RangeError(`${label} must not be negative`);
  return value;
}

function overscanInsets(overscan) {
  if (overscan == null) {
    return { top: 0, right: 0, bottom: 0, left: 0 };
  }
  if (typeof overscan === "number") {
    const value = nonNegativeOverscan(overscan, "overscan");
    return { top: value, right: value, bottom: value, left: value };
  }
  if (typeof overscan !== "object") {
    throw new TypeError("overscan must be a number or inset object");
  }

  const horizontal = overscan.x ?? overscan.horizontal ?? 0;
  const vertical = overscan.y ?? overscan.vertical ?? 0;
  return {
    top: nonNegativeOverscan(overscan.top ?? vertical, "overscan.top"),
    right: nonNegativeOverscan(overscan.right ?? horizontal, "overscan.right"),
    bottom: nonNegativeOverscan(overscan.bottom ?? vertical, "overscan.bottom"),
    left: nonNegativeOverscan(overscan.left ?? horizontal, "overscan.left"),
  };
}

/** Expand a world-space viewport by world-unit overscan. */
export function viewportWithOverscan(viewport, overscan = 0) {
  const rect = normalizeWorldRect(viewport, "viewport");
  const insets = overscanInsets(overscan);
  return {
    x: rect.x - insets.left,
    y: rect.y - insets.top,
    width: rect.width + insets.left + insets.right,
    height: rect.height + insets.top + insets.bottom,
  };
}

/**
 * Return the inclusive fixed-page range touched by a rectangle.
 * Inclusive edges match the canvas geometry layer: items touching a viewport
 * edge remain queryable.
 */
export function worldPageRange(rect, pageSize = DEFAULT_WORLD_PAGE_SIZE) {
  const normalized = normalizeWorldRect(rect);
  const size = assertPageSize(pageSize);
  return {
    minPageX: Math.floor(normalized.x / size),
    maxPageX: Math.floor((normalized.x + normalized.width) / size),
    minPageY: Math.floor(normalized.y / size),
    maxPageY: Math.floor((normalized.y + normalized.height) / size),
  };
}

/**
 * Describe the fixed-page window covered by a viewport and its overscan.
 * Compare `signature` values to cheaply detect page-boundary crossings.
 */
export function worldPageWindow(
  viewport,
  { overscan = 0, pageSize = DEFAULT_WORLD_PAGE_SIZE } = {},
) {
  const fixedPageSize = assertPageSize(pageSize);
  const bounds = viewportWithOverscan(viewport, overscan);
  const range = worldPageRange(bounds, fixedPageSize);
  return {
    ...range,
    pageSize: fixedPageSize,
    bounds,
    signature: [
      fixedPageSize,
      range.minPageX,
      range.minPageY,
      range.maxPageX,
      range.maxPageY,
    ].join(":"),
  };
}

function pageKey(pageX, pageY) {
  return `${pageX}:${pageY}`;
}

function pageKeysForRect(rect, pageSize) {
  const range = worldPageRange(rect, pageSize);
  const keys = [];
  for (let pageY = range.minPageY; pageY <= range.maxPageY; pageY += 1) {
    for (let pageX = range.minPageX; pageX <= range.maxPageX; pageX += 1) {
      keys.push(pageKey(pageX, pageY));
    }
  }
  return keys;
}

function rectsIntersectInclusive(first, second) {
  return !(
    first.x + first.width < second.x ||
    first.x > second.x + second.width ||
    first.y + first.height < second.y ||
    first.y > second.y + second.height
  );
}

function sameRect(first, second) {
  return first.x === second.x
    && first.y === second.y
    && first.width === second.width
    && first.height === second.height;
}

function defaultGetId(item) {
  return item?.id;
}

function defaultGetBounds(item) {
  return item?.pose ?? item;
}

function addExplicitIds(target, ids) {
  if (ids == null) return;
  if (typeof ids === "string" || typeof ids === "number") {
    target.add(ids);
    return;
  }
  if (typeof ids[Symbol.iterator] !== "function") {
    throw new TypeError("includeIds and pinnedIds must be IDs or iterables of IDs");
  }
  for (const id of ids) target.add(id);
}

/**
 * Create a mutable spatial index with deterministic, pure query results.
 *
 * Existing IDs retain their original source order when upserted. `rebuild()`
 * resets order to its input sequence; removing then re-adding an ID appends it.
 */
export function createSpatialPageIndex({
  pageSize = DEFAULT_WORLD_PAGE_SIZE,
  getId = defaultGetId,
  getBounds = defaultGetBounds,
} = {}) {
  const fixedPageSize = assertPageSize(pageSize);
  if (typeof getId !== "function") throw new TypeError("getId must be a function");
  if (typeof getBounds !== "function") {
    throw new TypeError("getBounds must be a function");
  }

  const pages = new Map();
  const entries = new Map();
  let nextOrder = 0;
  let lastQueryStats = Object.freeze({
    pagesVisited: 0,
    candidatesTested: 0,
    returned: 0,
  });
  let lastSyncStats = Object.freeze({
    added: 0,
    moved: 0,
    updated: 0,
    unchanged: 0,
    removed: 0,
  });

  function unlink(entry) {
    for (const key of entry.pageKeys) {
      const page = pages.get(key);
      if (!page) continue;
      page.delete(entry.id);
      if (page.size === 0) pages.delete(key);
    }
  }

  function upsert(item) {
    const id = getId(item);
    if (id == null) throw new TypeError("indexed items must have an ID");
    const rect = normalizeWorldRect(getBounds(item), `item(${String(id)}) bounds`);
    const existing = entries.get(id);
    if (existing) unlink(existing);

    const entry = {
      id,
      item,
      rect,
      order: existing?.order ?? nextOrder++,
      pageKeys: pageKeysForRect(rect, fixedPageSize),
    };
    entries.set(id, entry);

    for (const key of entry.pageKeys) {
      let page = pages.get(key);
      if (!page) {
        page = new Set();
        pages.set(key, page);
      }
      page.add(id);
    }
    return api;
  }

  function remove(id) {
    const entry = entries.get(id);
    if (!entry) return false;
    unlink(entry);
    entries.delete(id);
    return true;
  }

  function clear() {
    pages.clear();
    entries.clear();
    nextOrder = 0;
    lastSyncStats = Object.freeze({
      added: 0,
      moved: 0,
      updated: 0,
      unchanged: 0,
      removed: 0,
    });
    return api;
  }

  function rebuild(items) {
    if (!items || typeof items[Symbol.iterator] !== "function") {
      throw new TypeError("rebuild items must be iterable");
    }
    clear();
    for (const item of items) upsert(item);
    return api;
  }

  /**
   * Reconcile a new source collection without rebuilding unchanged pages.
   * Content-only updates replace the retained item reference; only geometry
   * changes relink page membership.
   */
  function reconcile(items) {
    if (!items || typeof items[Symbol.iterator] !== "function") {
      throw new TypeError("reconcile items must be iterable");
    }

    const seen = new Set();
    let order = 0;
    let added = 0;
    let moved = 0;
    let updated = 0;
    let unchanged = 0;

    for (const item of items) {
      const id = getId(item);
      if (id == null) throw new TypeError("indexed items must have an ID");
      if (seen.has(id)) throw new Error(`duplicate indexed item ID: ${String(id)}`);
      seen.add(id);

      const rect = normalizeWorldRect(getBounds(item), `item(${String(id)}) bounds`);
      const existing = entries.get(id);
      if (!existing) {
        upsert(item);
        added += 1;
      } else if (!sameRect(existing.rect, rect)) {
        upsert(item);
        moved += 1;
      } else {
        if (existing.item === item) unchanged += 1;
        else updated += 1;
        existing.item = item;
      }
      entries.get(id).order = order;
      order += 1;
    }

    let removed = 0;
    for (const id of [...entries.keys()]) {
      if (seen.has(id)) continue;
      remove(id);
      removed += 1;
    }
    nextOrder = order;
    lastSyncStats = Object.freeze({
      added,
      moved,
      updated,
      unchanged,
      removed,
    });
    return api;
  }

  function query({
    viewport,
    overscan = 0,
    includeIds = [],
    pinnedIds = [],
    exact = true,
  }) {
    const bounds = viewportWithOverscan(viewport, overscan);
    const candidateIds = new Set();
    const explicitlyIncluded = new Set();
    addExplicitIds(explicitlyIncluded, includeIds);
    addExplicitIds(explicitlyIncluded, pinnedIds);

    const visitedPageKeys = pageKeysForRect(bounds, fixedPageSize);
    for (const key of visitedPageKeys) {
      const page = pages.get(key);
      if (!page) continue;
      for (const id of page) candidateIds.add(id);
    }
    for (const id of explicitlyIncluded) candidateIds.add(id);

    const candidateEntries = [...candidateIds]
      .map((id) => entries.get(id))
      .filter(Boolean);
    const result = candidateEntries
      .filter(
        (entry) =>
          !exact ||
          explicitlyIncluded.has(entry.id) ||
          rectsIntersectInclusive(entry.rect, bounds),
      )
      .sort((first, second) => first.order - second.order)
      .map((entry) => entry.item);

    lastQueryStats = Object.freeze({
      pagesVisited: visitedPageKeys.length,
      candidatesTested: candidateEntries.length,
      returned: result.length,
    });
    return result;
  }

  const api = Object.freeze({
    pageSize: fixedPageSize,
    get size() {
      return entries.size;
    },
    get pageCount() {
      return pages.size;
    },
    get lastQueryStats() {
      return lastQueryStats;
    },
    get lastSyncStats() {
      return lastSyncStats;
    },
    has(id) {
      return entries.has(id);
    },
    get(id) {
      return entries.get(id)?.item;
    },
    upsert,
    remove,
    rebuild,
    reconcile,
    clear,
    query,
  });

  return api;
}
