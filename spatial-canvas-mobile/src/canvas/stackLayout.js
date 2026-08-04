/**
 * Pure layout primitives for Spatial's stack, grid, unfold, and unpack motion.
 * Every function returns `{id, x, y, zIndex}` changes and never mutates items.
 */

function ordered(items, order) {
  if (order === "reverse") return [...items].reverse();
  if (typeof order === "function") return [...items].sort(order);
  return [...items];
}

export function layoutStack(
  items,
  anchor,
  {
    offsetX = 7,
    offsetY = 4,
    maxVisible = 4,
    baseZIndex = 0,
    order = "input",
  } = {},
) {
  const stack = ordered(items, order);
  const hiddenOffset = Math.max(0, stack.length - maxVisible);
  return stack.map((item, index) => {
    const visibleIndex = Math.max(0, index - hiddenOffset);
    return {
      id: item.id,
      x: anchor.x + visibleIndex * offsetX,
      y: anchor.y + visibleIndex * offsetY,
      zIndex: baseZIndex + index,
    };
  });
}

export function layoutGrid(
  items,
  anchor,
  {
    columns = Math.max(1, Math.ceil(Math.sqrt(items.length))),
    gapX = 16,
    gapY = 16,
    cellWidth,
    cellHeight,
    baseZIndex = 0,
  } = {},
) {
  const safeColumns = Math.max(1, columns);
  const defaultWidth = Math.max(0, ...items.map((item) => item.width ?? 0));
  const defaultHeight = Math.max(0, ...items.map((item) => item.height ?? 0));
  const width = cellWidth ?? defaultWidth;
  const height = cellHeight ?? defaultHeight;

  return items.map((item, index) => {
    const column = index % safeColumns;
    const row = Math.floor(index / safeColumns);
    return {
      id: item.id,
      x: anchor.x + column * (width + gapX),
      y: anchor.y + row * (height + gapY),
      zIndex: baseZIndex + index,
    };
  });
}

/**
 * Fan children horizontally as seen in folder unfold/unpack. `staggerY` and
 * `rotationStep` are optional presentation metadata that integrations may use.
 */
export function layoutFan(
  items,
  anchor,
  {
    gap = 16,
    staggerY = 0,
    rotationStep = 0,
    direction = "right",
    baseZIndex = 0,
  } = {},
) {
  const sign = direction === "left" ? -1 : 1;
  let cursor = anchor.x;

  return items.map((item, index) => {
    const width = item.width ?? 0;
    const x = sign > 0 ? cursor : cursor - width;
    cursor += sign * (width + gap);
    return {
      id: item.id,
      x,
      y: anchor.y + index * staggerY,
      zIndex: baseZIndex + index,
      rotation: index * rotationStep,
    };
  });
}

/**
 * Interpolate from a stack to a fan with a smoothstep curve. This gives the UI
 * a deterministic geometry path while leaving spring timing to the renderer.
 */
export function interpolateLayouts(from, to, progress) {
  const t = Math.min(1, Math.max(0, progress));
  const eased = t * t * (3 - 2 * t);
  const destinationById = new Map(to.map((entry) => [entry.id, entry]));
  return from.map((source) => {
    const destination = destinationById.get(source.id) ?? source;
    return {
      id: source.id,
      x: source.x + (destination.x - source.x) * eased,
      y: source.y + (destination.y - source.y) * eased,
      zIndex: destination.zIndex ?? source.zIndex,
      rotation:
        (source.rotation ?? 0) +
        ((destination.rotation ?? 0) - (source.rotation ?? 0)) * eased,
    };
  });
}

