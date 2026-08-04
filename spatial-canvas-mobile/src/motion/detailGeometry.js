/**
 * The detail shell is a measured FLIP-style bounds tween. A deterministic
 * easing curve is intentional here: springs can cross their destination and
 * make a card appear to arrive from the wrong edge before settling.
 */
export const DETAIL_GEOMETRY_TRANSITION = Object.freeze({
  type: "tween",
  duration: 0.58,
  ease: [0.22, 1, 0.36, 1],
});

export const DETAIL_BACKDROP_KEYFRAMES = Object.freeze([
  Object.freeze([0, 0]),
  Object.freeze([0.279, 0.534]),
  Object.freeze([0.883, 0.968]),
  Object.freeze([1, 1]),
]);

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

/**
 * The item keeps its board dimensions. Only its top-left translation and one
 * uniform outer scale change, so the preview and reader are literally the
 * same pixels throughout the journey.
 */
export function centeredDetailGeometry(source, camera, viewport, options = {}) {
  const zoom = Math.max(0.0001, camera?.zoom || 1);
  const viewportWidth = Math.max(1, viewport?.width || 1);
  const viewportHeight = Math.max(1, viewport?.height || 1);
  const sourceWidth = Math.max(1, source?.width || 1);
  const sourceHeight = Math.max(1, source?.height || 1);
  const compact = viewportWidth <= 640;
  const imageLike = options.kind === "image";
  const horizontalInset = Math.max(0, options.horizontalInset ?? (compact ? 24 : 64));
  const verticalInset = Math.max(0, options.verticalInset ?? (compact ? 72 : 48));
  const availableWidth = Math.max(1, viewportWidth - horizontalInset * 2);
  const availableHeight = Math.max(1, viewportHeight - verticalInset * 2);
  const maximumWidth = Math.max(1, Math.min(
    availableWidth,
    options.maximumWidth ?? (imageLike ? viewportWidth * 0.88 : 760),
  ));
  const maximumHeight = Math.max(1, Math.min(
    availableHeight,
    options.maximumHeight ?? (imageLike ? viewportHeight * 0.82 : availableHeight),
  ));
  const targetScale = Math.max(0.05, Math.min(
    maximumWidth / (sourceWidth * zoom),
    maximumHeight / (sourceHeight * zoom),
  ));
  const viewportWorldWidth = viewportWidth / zoom;
  const viewportWorldHeight = viewportHeight / zoom;

  return {
    x: (camera?.x || 0) + (viewportWorldWidth - sourceWidth * targetScale) / 2,
    y: (camera?.y || 0) + (viewportWorldHeight - sourceHeight * targetScale) / 2,
    width: sourceWidth,
    height: sourceHeight,
    opacity: 1,
    scale: targetScale,
  };
}

/**
 * Opacity sampled from the supplied reference sequence. The wash begins once
 * the card is moving, finishes with the transform, and reverses identically.
 */
export function detailBackdropOpacity(progress) {
  const value = clamp(Number(progress) || 0, 0, 1);
  for (let index = 1; index < DETAIL_BACKDROP_KEYFRAMES.length; index += 1) {
    const [nextProgress, nextOpacity] = DETAIL_BACKDROP_KEYFRAMES[index];
    if (value > nextProgress) continue;
    const [previousProgress, previousOpacity] = DETAIL_BACKDROP_KEYFRAMES[index - 1];
    const localProgress = (value - previousProgress) / Math.max(0.0001, nextProgress - previousProgress);
    return previousOpacity + (nextOpacity - previousOpacity) * localProgress;
  }
  return 1;
}

/** Fold the centered selection emphasis into the outer top-left matrix. */
export function foldSelectionScaleIntoGeometry(source, selectionScale = 1) {
  const width = Math.max(1, source?.width || 1);
  const height = Math.max(1, source?.height || 1);
  const outerScale = Math.max(0.0001, source?.scale || 1);
  const visualScale = Math.max(0.0001, selectionScale || 1);
  return {
    ...source,
    x: (source?.x || 0) - width * outerScale * (visualScale - 1) / 2,
    y: (source?.y || 0) - height * outerScale * (visualScale - 1) / 2,
    scale: outerScale * visualScale,
  };
}

/** Fold a live outer scale into the visible source bounds for FLIP setup. */
export function scaledGeometryBounds(source) {
  const scale = Math.max(0.0001, source?.scale || 1);
  return {
    x: source?.x || 0,
    y: source?.y || 0,
    width: Math.max(1, source?.width || 1) * scale,
    height: Math.max(1, source?.height || 1) * scale,
  };
}

/**
 * Source state for a compositor-only detail FLIP.
 *
 * The destination shell is laid out once. A uniform scale covers the source
 * rectangle and clip insets trim the surplus axis, so content is never
 * distorted even when card and viewport aspect ratios differ.
 */
export function compositorDetailSource(source, destination) {
  const destinationWidth = Math.max(1, destination?.width || 1);
  const destinationHeight = Math.max(1, destination?.height || 1);
  const sourceWidth = Math.max(1, source?.width || 1);
  const sourceHeight = Math.max(1, source?.height || 1);
  const scale = Math.max(
    sourceWidth / destinationWidth,
    sourceHeight / destinationHeight,
  );
  return {
    x: source?.x || 0,
    y: source?.y || 0,
    width: destinationWidth,
    height: destinationHeight,
    scale,
    clipRight: Math.max(0, destinationWidth - sourceWidth / scale),
    clipBottom: Math.max(0, destinationHeight - sourceHeight / scale),
  };
}

export function itemViewportRect(item, camera, livePose = item?.pose) {
  if (!item || !camera || !livePose) return null;
  const zoom = camera.zoom;
  return {
    x: (livePose.x - camera.x) * zoom,
    y: (livePose.y - camera.y) * zoom,
    width: livePose.width * zoom,
    height: livePose.height * zoom,
    // Card radii remain in world space and scale naturally with the camera.
    // Selection indicators, not the item itself, compensate in screen space.
    radius: (item.style?.cornerRadius ?? 14) * zoom,
  };
}

export function collapsedDetailGeometry(rect, viewport) {
  const viewportWidth = Math.max(1, viewport?.width || 1);
  const viewportHeight = Math.max(1, viewport?.height || 1);
  if (!rect) {
    return {
      x: viewportWidth * 0.02,
      y: viewportHeight * 0.02,
      width: viewportWidth * 0.96,
      height: viewportHeight * 0.96,
      borderRadius: 18,
      opacity: 0,
    };
  }

  return {
    x: rect.x,
    y: rect.y,
    width: Math.max(1, rect.width),
    height: Math.max(1, rect.height),
    borderRadius: Math.max(0, rect.radius || 0),
    opacity: 1,
  };
}

export function expandedDetailGeometry(viewport) {
  return {
    x: 0,
    y: 0,
    width: Math.max(1, viewport?.width || 1),
    height: Math.max(1, viewport?.height || 1),
    borderRadius: 0,
    opacity: 1,
  };
}

/** Fullscreen bounds expressed in world coordinates for the retained item. */
export function fullscreenItemGeometry(camera, viewport) {
  const zoom = Math.max(0.0001, camera?.zoom || 1);
  return {
    x: camera?.x || 0,
    y: camera?.y || 0,
    width: Math.max(1, viewport?.width || 1) / zoom,
    height: Math.max(1, viewport?.height || 1) / zoom,
    opacity: 1,
    scale: 1,
  };
}

/**
 * Full-height, readable-width bounds for a retained authored document.
 *
 * The width is expressed in world units so the canvas camera turns it into a
 * stable screen-space reading column. It is also capped by the source aspect
 * ratio, ensuring the width ratio owns the FLIP scale; every text point then
 * follows one straight, reversible compositor path instead of an arc caused
 * by competing inner and outer scales.
 */
export function fullscreenReaderGeometry(source, camera, viewport, options = {}) {
  const zoom = Math.max(0.0001, camera?.zoom || 1);
  const viewportWidth = Math.max(1, viewport?.width || 1);
  const viewportHeight = Math.max(1, viewport?.height || 1);
  const sourceWidth = Math.max(1, source?.width || 1);
  const sourceHeight = Math.max(1, source?.height || 1);
  const gutter = Math.max(0, options.gutter ?? 24);
  const maximumWidth = Math.max(1, options.maximumWidth ?? 680);
  const aspectSafeWidth = viewportHeight * sourceWidth / sourceHeight;
  const screenWidth = Math.max(1, Math.min(
    maximumWidth,
    Math.max(1, viewportWidth - gutter * 2),
    aspectSafeWidth,
  ));
  const worldWidth = screenWidth / zoom;
  const worldHeight = viewportHeight / zoom;

  return {
    x: (camera?.x || 0) + (viewportWidth / zoom - worldWidth) / 2,
    y: camera?.y || 0,
    width: worldWidth,
    height: worldHeight,
    opacity: 1,
    scale: 1,
  };
}
