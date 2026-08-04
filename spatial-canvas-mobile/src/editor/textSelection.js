export function edgeScrollVelocity(pointerY, bounds, options = {}) {
  const edge = Math.min(
    options.edge ?? 48,
    Math.max(0, (bounds.bottom - bounds.top) / 4),
  );
  if (!edge) return 0;
  const maximum = options.maximum ?? 14;
  const minimum = options.minimum ?? 2;
  if (pointerY < bounds.top + edge) {
    const amount = Math.min(1, (bounds.top + edge - pointerY) / edge);
    return -Math.max(minimum, maximum * amount * amount);
  }
  if (pointerY > bounds.bottom - edge) {
    const amount = Math.min(1, (pointerY - (bounds.bottom - edge)) / edge);
    return Math.max(minimum, maximum * amount * amount);
  }
  return 0;
}

export function revealDelta(elementBounds, visibleBounds) {
  if (elementBounds.top < visibleBounds.top) return elementBounds.top - visibleBounds.top;
  if (elementBounds.bottom > visibleBounds.bottom) return elementBounds.bottom - visibleBounds.bottom;
  return 0;
}
