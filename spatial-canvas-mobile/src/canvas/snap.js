import {
  handleMovesX,
  handleMovesY,
  itemRect,
  normalizeRect,
  rectEdges,
  resizeRectFromHandle,
  translateRect,
  unionRects,
} from "./geometry.js";

function targetRecord(target) {
  return {
    id: target.id,
    rect: target.rect ? normalizeRect(target.rect) : itemRect(target),
  };
}

const DEFAULT_SNAP_INDEX_CELL_SIZE = 512;
const DEFAULT_MAX_CELLS_PER_TARGET = 256;
const DEFAULT_MAX_QUERY_CELLS = 4_096;

function snapCellKey(x, y) {
  return `${x}:${y}`;
}

function snapCellRange(rect, cellSize, padding = 0) {
  return {
    minX: Math.floor((rect.x - padding) / cellSize),
    maxX: Math.floor((rect.x + rect.width + padding) / cellSize),
    minY: Math.floor((rect.y - padding) / cellSize),
    maxY: Math.floor((rect.y + rect.height + padding) / cellSize),
  };
}

/**
 * Build the immutable snap-target lookup used for one drag/resize gesture.
 *
 * Snapping used to normalize and scan every canvas item on every pointer
 * frame. The gesture snapshot is already fixed at pointer-down, so indexing
 * it once makes per-frame work proportional to nearby items instead. Very
 * large targets use a small fallback list to avoid populating thousands of
 * grid cells for a single object.
 */
export function createSnapTargetIndex(
  targets,
  {
    cellSize = DEFAULT_SNAP_INDEX_CELL_SIZE,
    maxCellsPerTarget = DEFAULT_MAX_CELLS_PER_TARGET,
    maxQueryCells = DEFAULT_MAX_QUERY_CELLS,
  } = {},
) {
  const safeCellSize = Math.max(1, Number(cellSize) || DEFAULT_SNAP_INDEX_CELL_SIZE);
  const cells = new Map();
  const largeTargets = [];
  const records = targets.map(targetRecord);
  let lastQueryStats = {
    cellsVisited: 0,
    candidatesTested: 0,
    returned: 0,
  };

  for (const record of records) {
    const range = snapCellRange(record.rect, safeCellSize);
    const cellCount = (range.maxX - range.minX + 1) * (range.maxY - range.minY + 1);
    if (cellCount > maxCellsPerTarget) {
      largeTargets.push(record);
      continue;
    }
    for (let x = range.minX; x <= range.maxX; x += 1) {
      for (let y = range.minY; y <= range.maxY; y += 1) {
        const key = snapCellKey(x, y);
        const bucket = cells.get(key);
        if (bucket) bucket.push(record);
        else cells.set(key, [record]);
      }
    }
  }

  return {
    get size() {
      return records.length;
    },
    get lastQueryStats() {
      return lastQueryStats;
    },
    queryNearby(movingRect, movingIds, worldProximity) {
      const range = snapCellRange(movingRect, safeCellSize, worldProximity);
      const candidates = new Map();
      let cellsVisited = 0;
      const queryCellCount = (range.maxX - range.minX + 1) * (range.maxY - range.minY + 1);
      if (queryCellCount > maxQueryCells) {
        // A selection whose members are extremely far apart can have a huge
        // union rectangle. A bounded linear fallback is safer than walking
        // millions of empty cells in that pathological case.
        for (const record of records) candidates.set(record.id, record);
      } else {
        for (let x = range.minX; x <= range.maxX; x += 1) {
          for (let y = range.minY; y <= range.maxY; y += 1) {
            cellsVisited += 1;
            const bucket = cells.get(snapCellKey(x, y));
            if (!bucket) continue;
            for (const record of bucket) candidates.set(record.id, record);
          }
        }
      }
      for (const record of largeTargets) candidates.set(record.id, record);

      const references = [];
      let candidatesTested = 0;
      for (const record of candidates.values()) {
        if (movingIds.has(record.id)) continue;
        candidatesTested += 1;
        if (rectGapDistance(movingRect, record.rect) <= worldProximity) {
          references.push(record);
        }
      }
      lastQueryStats = {
        cellsVisited,
        candidatesTested,
        returned: references.length,
      };
      return references;
    },
  };
}

function nearestCandidate(candidates, threshold) {
  const priority = { edge: 0, width: 1, height: 1 };
  let nearest = null;
  for (const candidate of candidates) {
    if (candidate.distance > threshold) continue;
    if (!nearest
      || candidate.distance < nearest.distance
      || (candidate.distance === nearest.distance
        && (priority[candidate.kind] ?? 9) < (priority[nearest.kind] ?? 9))) {
      nearest = candidate;
    }
  }
  return nearest;
}

function rectGapDistance(a, b) {
  const aRight = a.x + a.width;
  const aBottom = a.y + a.height;
  const bRight = b.x + b.width;
  const bBottom = b.y + b.height;
  const gapX = Math.max(b.x - aRight, a.x - bRight, 0);
  const gapY = Math.max(b.y - aBottom, a.y - bBottom, 0);
  return Math.hypot(gapX, gapY);
}

function nearbyTargetRecords(targets, movingRect, movingIds, worldProximity) {
  if (typeof targets?.queryNearby === "function") {
    return targets.queryNearby(movingRect, movingIds, worldProximity);
  }
  const references = [];
  for (const target of targets) {
    if (movingIds.has(target.id)) continue;
    const record = targetRecord(target);
    if (rectGapDistance(movingRect, record.rect) <= worldProximity) {
      references.push(record);
    }
  }
  return references;
}

function xCandidates(rect, handle, targets, minimumWidth) {
  if (!handleMovesX(handle)) return [];
  const edge = rectEdges(rect);
  const movingEast = handle.includes("e");
  const sourceEdge = movingEast ? "right" : "left";
  const movingValue = edge[sourceEdge];
  const candidates = [];

  for (const target of targets) {
    const targetEdge = rectEdges(target.rect);
    for (const targetEdgeName of ["left", "right"]) {
      const value = targetEdge[targetEdgeName];
      const width = movingEast ? value - edge.left : edge.right - value;
      if (width < minimumWidth) continue;
      candidates.push({
        axis: "x",
        kind: "edge",
        distance: Math.abs(movingValue - value),
        value,
        sourceEdge,
        targetEdge: targetEdgeName,
        targetId: target.id,
        targetRect: target.rect,
        label: targetEdgeName.toUpperCase(),
      });
    }

    const value = movingEast
      ? edge.left + target.rect.width
      : edge.right - target.rect.width;
    candidates.push({
      axis: "x",
      kind: "width",
      distance: Math.abs(movingValue - value),
      value,
      sourceEdge,
      targetEdge: null,
      targetId: target.id,
      targetRect: target.rect,
      label: "WIDTH",
    });
  }
  return candidates;
}

function yCandidates(rect, handle, targets, minimumHeight) {
  if (!handleMovesY(handle)) return [];
  const edge = rectEdges(rect);
  const movingSouth = handle.includes("s");
  const sourceEdge = movingSouth ? "bottom" : "top";
  const movingValue = edge[sourceEdge];
  const candidates = [];

  for (const target of targets) {
    const targetEdge = rectEdges(target.rect);
    for (const targetEdgeName of ["top", "bottom"]) {
      const value = targetEdge[targetEdgeName];
      const height = movingSouth ? value - edge.top : edge.bottom - value;
      if (height < minimumHeight) continue;
      candidates.push({
        axis: "y",
        kind: "edge",
        distance: Math.abs(movingValue - value),
        value,
        sourceEdge,
        targetEdge: targetEdgeName,
        targetId: target.id,
        targetRect: target.rect,
        label: targetEdgeName.toUpperCase(),
      });
    }

    const value = movingSouth
      ? edge.top + target.rect.height
      : edge.bottom - target.rect.height;
    candidates.push({
      axis: "y",
      kind: "height",
      distance: Math.abs(movingValue - value),
      value,
      sourceEdge,
      targetEdge: null,
      targetId: target.id,
      targetRect: target.rect,
      label: "HEIGHT",
    });
  }
  return candidates;
}

function dragCandidates(rect, targets, axis) {
  const sourceEdges = axis === "x" ? ["left", "right"] : ["top", "bottom"];
  const targetEdges = sourceEdges;
  const moving = rectEdges(rect);
  const candidates = [];

  for (const target of targets) {
    const targetEdge = rectEdges(target.rect);
    for (const sourceEdge of sourceEdges) {
      for (const targetEdgeName of targetEdges) {
        const value = targetEdge[targetEdgeName];
        const adjustment = value - moving[sourceEdge];
        candidates.push({
          axis,
          kind: "edge",
          distance: Math.abs(adjustment),
          adjustment,
          value,
          sourceEdge,
          targetEdge: targetEdgeName,
          targetId: target.id,
          targetRect: target.rect,
          label: targetEdgeName.toUpperCase(),
        });
      }
    }
  }
  return candidates;
}

function applyXAxis(rect, handle, snap) {
  if (!snap) return rect;
  const edge = rectEdges(rect);
  if (handle.includes("e")) {
    return { ...rect, width: snap.value - edge.left };
  }
  return {
    ...rect,
    x: snap.value,
    width: edge.right - snap.value,
  };
}

function applyYAxis(rect, handle, snap) {
  if (!snap) return rect;
  const edge = rectEdges(rect);
  if (handle.includes("s")) {
    return { ...rect, height: snap.value - edge.top };
  }
  return {
    ...rect,
    y: snap.value,
    height: edge.bottom - snap.value,
  };
}

function guideForSnap(snap, resultRect) {
  const result = rectEdges(resultRect);
  const target = rectEdges(snap.targetRect);
  if (snap.axis === "x") {
    return {
      axis: "x",
      position: snap.value,
      start: Math.min(result.top, target.top),
      end: Math.max(result.bottom, target.bottom),
      kind: snap.kind,
      label: snap.label,
      sourceEdge: snap.sourceEdge,
      targetEdge: snap.targetEdge,
      targetId: snap.targetId,
    };
  }
  return {
    axis: "y",
    position: snap.value,
    start: Math.min(result.left, target.left),
    end: Math.max(result.right, target.right),
    kind: snap.kind,
    label: snap.label,
    sourceEdge: snap.sourceEdge,
    targetEdge: snap.targetEdge,
    targetId: snap.targetId,
  };
}

/**
 * Resize and snap in one pure operation.
 *
 * `threshold` is expressed in screen pixels and converted to world units by
 * `zoom`, so snapping feels equally sticky at every camera scale. The nearest
 * eligible edge/width/height wins independently per axis (proximity priority).
 * The result includes render-ready guides and reference ids for highlights.
 */
export function resizeWithSnapping(
  startRect,
  handle,
  worldDelta,
  targets,
  {
    threshold = 8,
    zoom = 1,
    proximity = 360,
    enabled = true,
    minWidth = 40,
    minHeight = 40,
    excludeId = null,
  } = {},
) {
  const unsnapped = resizeRectFromHandle(startRect, handle, worldDelta, {
    minWidth,
    minHeight,
  });
  if (!enabled) {
    return {
      rect: unsnapped,
      unsnappedRect: unsnapped,
      ...EMPTY_SNAP_RESULT,
    };
  }
  const worldThreshold = threshold / Math.max(zoom, 0.0001);
  const worldProximity = proximity / Math.max(zoom, 0.0001);
  const references = nearbyTargetRecords(
    targets,
    unsnapped,
    new Set(excludeId ? [excludeId] : []),
    worldProximity,
  );
  const x = nearestCandidate(
    xCandidates(unsnapped, handle, references, minWidth),
    worldThreshold,
  );
  const y = nearestCandidate(
    yCandidates(unsnapped, handle, references, minHeight),
    worldThreshold,
  );

  let rect = applyXAxis(unsnapped, handle, x);
  rect = applyYAxis(rect, handle, y);
  const snaps = { x, y };
  const guides = [x, y].filter(Boolean).map((snap) => guideForSnap(snap, rect));
  const highlightedIds = [...new Set(guides.map((guide) => guide.targetId))];

  return { rect, unsnappedRect: unsnapped, snaps, guides, highlightedIds };
}

/**
 * Translate one item or a multi-selection and snap its outer edges to nearby
 * item edges. The returned changes preserve every selected item's relative
 * position while guides are calculated from the complete moving bounds.
 */
export function dragWithSnapping(
  movingItems,
  worldDelta,
  targets,
  {
    threshold = 8,
    zoom = 1,
    proximity = 360,
    enabled = true,
    excludeIds = movingItems.map((item) => item.id),
  } = {},
) {
  const moving = movingItems.map(targetRecord);
  const movingIds = excludeIds instanceof Set ? excludeIds : new Set(excludeIds);
  const startRect = unionRects(moving.map((item) => item.rect));
  if (!startRect) {
    return { changes: [], rect: null, unsnappedRect: null, ...EMPTY_SNAP_RESULT };
  }
  const unsnappedRect = translateRect(startRect, worldDelta);
  if (!enabled) {
    return {
      changes: moving.map((item) => ({
        id: item.id,
        x: item.rect.x + worldDelta.x,
        y: item.rect.y + worldDelta.y,
      })),
      rect: unsnappedRect,
      unsnappedRect,
      ...EMPTY_SNAP_RESULT,
    };
  }
  const worldThreshold = threshold / Math.max(zoom, 0.0001);
  const worldProximity = proximity / Math.max(zoom, 0.0001);
  const references = nearbyTargetRecords(
    targets,
    unsnappedRect,
    movingIds,
    worldProximity,
  );
  const x = nearestCandidate(dragCandidates(unsnappedRect, references, "x"), worldThreshold);
  const y = nearestCandidate(dragCandidates(unsnappedRect, references, "y"), worldThreshold);
  const snappedDelta = {
    x: worldDelta.x + (x?.adjustment ?? 0),
    y: worldDelta.y + (y?.adjustment ?? 0),
  };
  const rect = translateRect(startRect, snappedDelta);
  const snaps = { x, y };
  const guides = [x, y].filter(Boolean).map((snap) => guideForSnap(snap, rect));
  const highlightedIds = [...new Set(guides.map((guide) => guide.targetId))];
  const changes = moving.map((item) => ({
    id: item.id,
    x: item.rect.x + snappedDelta.x,
    y: item.rect.y + snappedDelta.y,
  }));

  return { changes, rect, unsnappedRect, snaps, guides, highlightedIds };
}

export const EMPTY_SNAP_RESULT = Object.freeze({
  guides: [],
  highlightedIds: [],
  snaps: { x: null, y: null },
});
