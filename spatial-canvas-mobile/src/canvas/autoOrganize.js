const DEFAULT_GRID_SIZE = 20;
const DEFAULT_GAP = 20;

function cleanZero(value) {
  return Object.is(value, -0) ? 0 : value;
}

function snapToGrid(value, gridSize) {
  return cleanZero(Math.round(value / gridSize) * gridSize);
}

function quantize(value, step) {
  return cleanZero(Math.round(value / step) * step);
}

function median(values) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
}

function average(values) {
  return values.length
    ? values.reduce((total, value) => total + value, 0) / values.length
    : 0;
}

function compareId(a, b) {
  return String(a.id).localeCompare(String(b.id));
}

function overlapsWithGap(a, b, gap) {
  return a.x < b.x + b.width + gap
    && a.x + a.width + gap > b.x
    && a.y < b.y + b.height + gap
    && a.y + a.height + gap > b.y;
}

function cellsFor(rect, cellSize, padding = 0) {
  const minX = Math.floor((rect.x - padding) / cellSize);
  const minY = Math.floor((rect.y - padding) / cellSize);
  const maxX = Math.floor((rect.x + rect.width + padding) / cellSize);
  const maxY = Math.floor((rect.y + rect.height + padding) / cellSize);
  const keys = [];
  for (let y = minY; y <= maxY; y += 1) {
    for (let x = minX; x <= maxX; x += 1) keys.push(`${x}:${y}`);
  }
  return keys;
}

function createUnionFind(length) {
  const parents = Array.from({ length }, (_, index) => index);
  const ranks = Array(length).fill(0);
  const find = (index) => {
    let root = index;
    while (parents[root] !== root) root = parents[root];
    while (parents[index] !== index) {
      const parent = parents[index];
      parents[index] = root;
      index = parent;
    }
    return root;
  };
  const union = (a, b) => {
    let rootA = find(a);
    let rootB = find(b);
    if (rootA === rootB) return;
    if (ranks[rootA] < ranks[rootB]) [rootA, rootB] = [rootB, rootA];
    parents[rootB] = rootA;
    if (ranks[rootA] === ranks[rootB]) ranks[rootA] += 1;
  };
  return { find, union };
}

function axisGap(a, b, orientation) {
  if (orientation === "row") {
    return Math.max(0, a.x - (b.x + b.width), b.x - (a.x + a.width));
  }
  return Math.max(0, a.y - (b.y + b.height), b.y - (a.y + a.height));
}

function axisAnchor(item, orientation) {
  return orientation === "row" ? item.y : item.x;
}

function laneComponents(items, orientation, tolerance, neighborhood) {
  if (items.length < 2) return items.length ? [[...items]] : [];
  const unionFind = createUnionFind(items.length);
  const cellSize = Math.max(160, neighborhood * 2);
  const cells = new Map();

  items.forEach((item, index) => {
    const nearby = new Set();
    for (const key of cellsFor(item, cellSize, neighborhood + tolerance)) {
      for (const candidate of cells.get(key) || []) nearby.add(candidate);
    }
    for (const candidate of nearby) {
      const other = items[candidate];
      if (Math.abs(axisAnchor(item, orientation) - axisAnchor(other, orientation)) <= tolerance
        && axisGap(item, other, orientation) <= neighborhood) {
        unionFind.union(index, candidate);
      }
    }
    for (const key of cellsFor(item, cellSize)) {
      const bucket = cells.get(key) || [];
      bucket.push(index);
      cells.set(key, bucket);
    }
  });

  const groups = new Map();
  items.forEach((item, index) => {
    const root = unionFind.find(index);
    const group = groups.get(root) || [];
    group.push(item);
    groups.set(root, group);
  });
  return [...groups.values()];
}

function splitByAnchor(items, orientation, tolerance) {
  const ordered = [...items].sort((a, b) => (
    axisAnchor(a, orientation) - axisAnchor(b, orientation)
    || compareId(a, b)
  ));
  const groups = [];
  for (const item of ordered) {
    const current = groups.at(-1);
    if (!current || Math.abs(axisAnchor(item, orientation) - median(
      current.map((entry) => axisAnchor(entry, orientation)),
    )) > tolerance) {
      groups.push([item]);
    } else {
      current.push(item);
    }
  }
  return groups;
}

function splitByPrimaryGap(items, orientation, neighborhood) {
  const primary = orientation === "row" ? "x" : "y";
  const size = orientation === "row" ? "width" : "height";
  const ordered = [...items].sort((a, b) => (
    a[primary] - b[primary] || compareId(a, b)
  ));
  const groups = [];
  let runningEnd = -Infinity;
  for (const item of ordered) {
    if (!groups.length || item[primary] - runningEnd > neighborhood) {
      groups.push([item]);
      runningEnd = item[primary] + item[size];
    } else {
      groups.at(-1).push(item);
      runningEnd = Math.max(runningEnd, item[primary] + item[size]);
    }
  }
  return groups;
}

function laneTargets(items, orientation, gridSize, gap, localityBudget) {
  if (items.length < 2) return new Map();
  const primary = orientation === "row" ? "x" : "y";
  const secondary = orientation === "row" ? "y" : "x";
  const size = orientation === "row" ? "width" : "height";
  const anchorPrimary = orientation === "row" ? "anchorX" : "anchorY";
  const ordered = [...items].sort((a, b) => (
    (a[anchorPrimary] + a[size] / 2) - (b[anchorPrimary] + b[size] / 2)
    || compareId(a, b)
  ));
  const existingGaps = ordered.slice(1).map((item, index) => (
    item[anchorPrimary] - (ordered[index][anchorPrimary] + ordered[index][size])
  ));
  const targetGap = Math.max(
    gap,
    quantize(median(existingGaps), Math.max(1, gridSize / 2)),
  );
  const relative = [0];
  for (let index = 1; index < ordered.length; index += 1) {
    relative[index] = relative[index - 1] + ordered[index - 1][size] + targetGap;
  }
  const origin = snapToGrid(average(
    ordered.map((item, index) => item[anchorPrimary] - relative[index]),
  ), gridSize);
  const lane = snapToGrid(median(ordered.map((item) => item[secondary])), gridSize);
  const targets = ordered.map((item, index) => ({
    item,
    primary: origin + relative[index],
  }));
  const maxMovement = Math.max(...targets.map(({ item, primary: target }) => (
    Math.abs(target - item[anchorPrimary])
  )));
  if (ordered.length > 2
    && existingGaps.every((value) => value >= gap)
    && maxMovement > localityBudget) {
    let splitIndex = Math.floor(ordered.length / 2);
    let largestResidual = -Infinity;
    existingGaps.forEach((value, index) => {
      const residual = Math.abs(value - targetGap);
      if (residual > largestResidual) {
        largestResidual = residual;
        splitIndex = index + 1;
      }
    });
    const splitTargets = new Map();
    for (const [id, target] of laneTargets(
      ordered.slice(0, splitIndex),
      orientation,
      gridSize,
      gap,
      localityBudget,
    )) splitTargets.set(id, target);
    for (const [id, target] of laneTargets(
      ordered.slice(splitIndex),
      orientation,
      gridSize,
      gap,
      localityBudget,
    )) splitTargets.set(id, target);
    return splitTargets;
  }
  return new Map(targets.map(({ item, primary: target }) => [item.id, {
    [primary]: target,
    [secondary]: lane,
  }]));
}

function applyLanePass(items, orientation, tolerance, neighborhood, gridSize, gap) {
  const updates = new Map();
  const localityBudget = Math.max(gridSize * 4, gap * 4);
  for (const component of laneComponents(items, orientation, tolerance, neighborhood)) {
    for (const anchorGroup of splitByAnchor(component, orientation, tolerance)) {
      for (const segment of splitByPrimaryGap(anchorGroup, orientation, neighborhood)) {
        for (const [id, target] of laneTargets(
          segment,
          orientation,
          gridSize,
          gap,
          localityBudget,
        )) {
          updates.set(id, target);
        }
      }
    }
  }
  return items.map((item) => ({ ...item, ...(updates.get(item.id) || {}) }));
}

function collisionPairs(items, gap, cellSize) {
  const cells = new Map();
  const pairs = [];
  const seen = new Set();
  items.forEach((item, index) => {
    const nearby = new Set();
    for (const key of cellsFor(item, cellSize, gap)) {
      for (const candidate of cells.get(key) || []) nearby.add(candidate);
    }
    for (const candidate of nearby) {
      const key = `${candidate}:${index}`;
      if (seen.has(key)) continue;
      seen.add(key);
      if (overlapsWithGap(items[candidate], item, gap)) pairs.push([candidate, index]);
    }
    for (const key of cellsFor(item, cellSize, gap)) {
      const bucket = cells.get(key) || [];
      bucket.push(index);
      cells.set(key, bucket);
    }
  });
  return pairs;
}

function resolveOverlaps(items, gap, gridSize) {
  const result = items.map((item) => ({ ...item }));
  const typicalSize = Math.max(80, median(result.map((item) => Math.max(item.width, item.height))));
  const cellSize = typicalSize + gap * 2;
  const moveStep = Math.max(1, gridSize / 2);

  for (let iteration = 0; iteration < 12; iteration += 1) {
    const pairs = collisionPairs(result, gap, cellSize);
    if (!pairs.length) break;
    for (const [firstIndex, secondIndex] of pairs) {
      const first = result[firstIndex];
      const second = result[secondIndex];
      if (!overlapsWithGap(first, second, gap)) continue;
      const firstCenterX = first.x + first.width / 2;
      const secondCenterX = second.x + second.width / 2;
      const firstCenterY = first.y + first.height / 2;
      const secondCenterY = second.y + second.height / 2;
      const requiredX = firstCenterX <= secondCenterX
        ? first.x + first.width + gap - second.x
        : second.x + second.width + gap - first.x;
      const requiredY = firstCenterY <= secondCenterY
        ? first.y + first.height + gap - second.y
        : second.y + second.height + gap - first.y;
      if (requiredX <= requiredY) {
        const distance = Math.ceil(requiredX / moveStep) * moveStep;
        const firstMove = distance / 2;
        if (firstCenterX <= secondCenterX) {
          first.x -= firstMove;
          second.x += distance - firstMove;
        } else {
          first.x += distance - firstMove;
          second.x -= firstMove;
        }
      } else {
        const distance = Math.ceil(requiredY / moveStep) * moveStep;
        const firstMove = distance / 2;
        if (firstCenterY <= secondCenterY) {
          first.y -= firstMove;
          second.y += distance - firstMove;
        } else {
          first.y += distance - firstMove;
          second.y -= firstMove;
        }
      }
    }
  }
  return result;
}

/**
 * Tidy a spatial board without re-laying it out.
 *
 * The solver infers short, local rows from the positions the user already
 * chose, equalizes edge-to-edge gaps inside each row, then repeats the same
 * operation for local columns. Every lane is anchored by the median original
 * position, so the minimum number of pixels move and distant neighborhoods
 * never collapse together. A final spatial-hash pass separates the few
 * ambiguous overlaps using the shortest translation axis.
 */
export function autoOrganizeItems(
  items,
  {
    gridSize = DEFAULT_GRID_SIZE,
    gap = DEFAULT_GAP,
  } = {},
) {
  if (!items.length) return [];
  const safeGrid = Math.max(1, gridSize);
  const safeGap = Math.max(0, gap);
  const normalized = items.map((item) => ({
    id: item.id,
    width: Math.max(0, item.width ?? 0),
    height: Math.max(0, item.height ?? 0),
    x: snapToGrid(item.x ?? 0, safeGrid),
    y: snapToGrid(item.y ?? 0, safeGrid),
    anchorX: item.x ?? 0,
    anchorY: item.y ?? 0,
    rotation: item.rotation ?? 0,
  })).sort(compareId);
  const medianWidth = Math.max(safeGrid, median(normalized.map((item) => item.width)));
  const medianHeight = Math.max(safeGrid, median(normalized.map((item) => item.height)));
  const rowTolerance = Math.max(safeGrid * 2, Math.min(120, medianHeight * 0.4));
  // Columns should only be inferred from cards that are already visibly
  // aligned. A deliberately tight threshold prevents a vertical cleanup from
  // undoing the equal horizontal gutters established by the row pass.
  const columnTolerance = Math.max(
    safeGrid,
    Math.min(safeGrid * 1.5, medianWidth * 0.15),
  );
  const rowNeighborhood = Math.max(safeGap * 6, medianWidth * 0.85);
  const columnNeighborhood = Math.max(safeGap * 6, medianHeight * 0.85);

  const rows = applyLanePass(
    normalized,
    "row",
    rowTolerance,
    rowNeighborhood,
    safeGrid,
    safeGap,
  );
  const columns = applyLanePass(
    rows,
    "column",
    columnTolerance,
    columnNeighborhood,
    safeGrid,
    safeGap,
  );
  const resolved = resolveOverlaps(columns, safeGap, safeGrid);
  const byId = new Map(resolved.map((item) => [item.id, item]));
  return items.map((item) => {
    const next = byId.get(item.id);
    return {
      id: item.id,
      x: cleanZero(next.x),
      y: cleanZero(next.y),
      rotation: next.rotation,
    };
  });
}
