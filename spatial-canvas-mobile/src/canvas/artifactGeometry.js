// @ts-check

/**
 * Scale retained artifact pixels until they cover the card viewport. The
 * caller anchors the transformed surface at x=0/y=0, so any crop is confined
 * to the far/right and bottom edges rather than hiding the readable leading
 * edge.
 */
export function leadingEdgeCoverScale(viewportWidth, viewportHeight, baseWidth, baseHeight) {
  if (![viewportWidth, viewportHeight, baseWidth, baseHeight]
    .every((value) => Number.isFinite(value) && value > 0)) return 0.04;
  return Math.max(0.04, viewportWidth / baseWidth, viewportHeight / baseHeight);
}

export function leadingEdgeCoverFrame(viewportWidth, viewportHeight, baseWidth, baseHeight) {
  const scale = leadingEdgeCoverScale(viewportWidth, viewportHeight, baseWidth, baseHeight);
  return {
    x: 0,
    y: 0,
    scale,
    renderedWidth: baseWidth * scale,
    renderedHeight: baseHeight * scale,
  };
}
