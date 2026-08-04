// @ts-check

export const ARTIFACT_TONE_LIGHT = "light";
export const ARTIFACT_TONE_DARK = "dark";

const SVG_NAMESPACE = "http://www.w3.org/2000/svg";
const DEFAULT_LUMINANCE_THRESHOLD = 0.52;
const DEFAULT_SAMPLE_WIDTH = 32;
const DEFAULT_SAMPLE_HEIGHT = 12;
const DEFAULT_BOTTOM_FRACTION = 0.3;

/** @param {number} value */
function clamp01(value) {
  return Math.min(1, Math.max(0, value));
}

/** @param {number} value */
function srgbToLinear(value) {
  const channel = clamp01(value / 255);
  return channel <= 0.04045
    ? channel / 12.92
    : ((channel + 0.055) / 1.055) ** 2.4;
}

/**
 * WCAG relative luminance after compositing an RGBA pixel over a backdrop.
 * This models the color a person actually sees rather than averaging encoded
 * sRGB channel values.
 *
 * @param {number} red
 * @param {number} green
 * @param {number} blue
 * @param {number} [alpha]
 * @param {[number, number, number]} [backdrop]
 */
export function perceptualLuminance(
  red,
  green,
  blue,
  alpha = 255,
  backdrop = [255, 255, 255],
) {
  const opacity = clamp01(alpha / 255);
  const visibleRed = red * opacity + backdrop[0] * (1 - opacity);
  const visibleGreen = green * opacity + backdrop[1] * (1 - opacity);
  const visibleBlue = blue * opacity + backdrop[2] * (1 - opacity);
  return (
    0.2126 * srgbToLinear(visibleRed)
    + 0.7152 * srgbToLinear(visibleGreen)
    + 0.0722 * srgbToLinear(visibleBlue)
  );
}

/**
 * Classify RGBA pixels as the light or dark tone best suited to an overlay.
 * A lightly trimmed mean prevents a few text pixels from flipping an otherwise
 * uniform page background.
 *
 * @param {ArrayLike<number> | null | undefined} pixels
 * @param {{
 *   threshold?: number,
 *   fallback?: "light" | "dark",
 *   backdrop?: [number, number, number],
 *   trimFraction?: number,
 * }} [options]
 * @returns {"light" | "dark"}
 */
export function classifyRgbaPixels(pixels, options = {}) {
  const fallback = options.fallback === ARTIFACT_TONE_DARK
    ? ARTIFACT_TONE_DARK
    : ARTIFACT_TONE_LIGHT;
  if (!pixels || pixels.length < 4) return fallback;

  const luminances = [];
  for (let index = 0; index + 3 < pixels.length; index += 4) {
    const values = [pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3]];
    if (!values.every(Number.isFinite)) continue;
    luminances.push(perceptualLuminance(
      values[0],
      values[1],
      values[2],
      values[3],
      options.backdrop,
    ));
  }
  if (!luminances.length) return fallback;

  luminances.sort((left, right) => left - right);
  const requestedTrim = clamp01(options.trimFraction ?? 0.1);
  const trim = Math.min(
    Math.floor(luminances.length * requestedTrim),
    Math.floor((luminances.length - 1) / 2),
  );
  const visible = luminances.slice(trim, luminances.length - trim);
  const average = visible.reduce((total, value) => total + value, 0) / visible.length;
  return average >= (options.threshold ?? DEFAULT_LUMINANCE_THRESHOLD)
    ? ARTIFACT_TONE_LIGHT
    : ARTIFACT_TONE_DARK;
}

/**
 * Calculate the source rectangle visible through an object-fit: cover box.
 * Position values use CSS object-position semantics: 0 is the leading edge,
 * 0.5 is centered, and 1 is the trailing edge.
 *
 * @param {{
 *   sourceWidth: number,
 *   sourceHeight: number,
 *   containerWidth: number,
 *   containerHeight: number,
 *   positionX?: number,
 *   positionY?: number,
 * }} dimensions
 * @returns {{ x: number, y: number, width: number, height: number, scale: number } | null}
 */
export function computeCoverCrop(dimensions) {
  const {
    sourceWidth,
    sourceHeight,
    containerWidth,
    containerHeight,
    positionX = 0.5,
    positionY = 0.5,
  } = dimensions ?? {};
  if (![sourceWidth, sourceHeight, containerWidth, containerHeight]
    .every((value) => Number.isFinite(value) && value > 0)) {
    return null;
  }

  const scale = Math.max(containerWidth / sourceWidth, containerHeight / sourceHeight);
  const width = Math.min(sourceWidth, containerWidth / scale);
  const height = Math.min(sourceHeight, containerHeight / scale);
  return {
    x: (sourceWidth - width) * clamp01(positionX),
    y: (sourceHeight - height) * clamp01(positionY),
    width,
    height,
    scale,
  };
}

/**
 * Synchronously sample the bottom of the portion of an image visible through
 * object-fit: cover. Call after the image has loaded. Cross-origin/tainted
 * canvases and incomplete images return the requested fallback tone.
 *
 * @param {HTMLImageElement | Record<string, any> | null | undefined} image
 * @param {{
 *   containerWidth?: number,
 *   containerHeight?: number,
 *   positionX?: number,
 *   positionY?: number,
 *   bottomFraction?: number,
 *   sampleWidth?: number,
 *   sampleHeight?: number,
 *   fallback?: "light" | "dark",
 *   threshold?: number,
 *   canvasFactory?: () => HTMLCanvasElement | Record<string, any>,
 * }} [options]
 * @returns {"light" | "dark"}
 */
export function sampleImageBottomTone(image, options = {}) {
  const fallback = options.fallback === ARTIFACT_TONE_DARK
    ? ARTIFACT_TONE_DARK
    : ARTIFACT_TONE_LIGHT;
  try {
    const sourceWidth = Number(image?.naturalWidth || image?.width);
    const sourceHeight = Number(image?.naturalHeight || image?.height);
    const containerWidth = Number(options.containerWidth || image?.clientWidth || image?.width);
    const containerHeight = Number(options.containerHeight || image?.clientHeight || image?.height);
    const crop = computeCoverCrop({
      sourceWidth,
      sourceHeight,
      containerWidth,
      containerHeight,
      positionX: options.positionX,
      positionY: options.positionY,
    });
    if (!crop) return fallback;

    const canvas = options.canvasFactory?.()
      ?? image?.ownerDocument?.createElement?.("canvas")
      ?? globalThis.document?.createElement?.("canvas");
    if (!canvas) return fallback;
    const sampleWidth = Math.max(1, Math.round(options.sampleWidth ?? DEFAULT_SAMPLE_WIDTH));
    const sampleHeight = Math.max(1, Math.round(options.sampleHeight ?? DEFAULT_SAMPLE_HEIGHT));
    canvas.width = sampleWidth;
    canvas.height = sampleHeight;
    const context = canvas.getContext?.("2d", { willReadFrequently: true });
    if (!context) return fallback;

    const bottomFraction = Math.min(1, Math.max(0.05, options.bottomFraction ?? DEFAULT_BOTTOM_FRACTION));
    const sampleSourceHeight = crop.height * bottomFraction;
    context.drawImage(
      image,
      crop.x,
      crop.y + crop.height - sampleSourceHeight,
      crop.width,
      sampleSourceHeight,
      0,
      0,
      sampleWidth,
      sampleHeight,
    );
    const pixels = context.getImageData(0, 0, sampleWidth, sampleHeight)?.data;
    return classifyRgbaPixels(pixels, {
      fallback,
      threshold: options.threshold,
    });
  } catch {
    return fallback;
  }
}

/** @param {string | null | undefined} value */
function parseCssColor(value) {
  const input = value?.trim().toLowerCase();
  if (!input || input === "none" || input === "transparent") return null;

  const hex = input.match(/^#([0-9a-f]{3,8})$/i)?.[1];
  if (hex) {
    const expanded = hex.length === 3 || hex.length === 4
      ? [...hex].map((character) => `${character}${character}`).join("")
      : hex;
    if (expanded.length === 6 || expanded.length === 8) {
      return [
        Number.parseInt(expanded.slice(0, 2), 16),
        Number.parseInt(expanded.slice(2, 4), 16),
        Number.parseInt(expanded.slice(4, 6), 16),
        expanded.length === 8 ? Number.parseInt(expanded.slice(6, 8), 16) : 255,
      ];
    }
  }

  const rgb = input.match(/^rgba?\(\s*([\d.]+)(?:\s+|\s*,\s*)([\d.]+)(?:\s+|\s*,\s*)([\d.]+)(?:\s*(?:\/|,)\s*([\d.]+)(%)?)?\s*\)$/i);
  if (!rgb) return null;
  const rawAlpha = rgb[4] == null ? 1 : Number(rgb[4]);
  const alpha = rgb[5] ? rawAlpha / 100 : rawAlpha;
  return [
    Math.min(255, Number(rgb[1])),
    Math.min(255, Number(rgb[2])),
    Math.min(255, Number(rgb[3])),
    Math.round(clamp01(alpha) * 255),
  ];
}

/** @param {Array<[number, number, number, number]>} foregroundToBackground */
function compositeColors(foregroundToBackground) {
  let output = [255, 255, 255];
  for (let index = foregroundToBackground.length - 1; index >= 0; index -= 1) {
    const [red, green, blue, alpha] = foregroundToBackground[index];
    const opacity = clamp01(alpha / 255);
    output = [
      red * opacity + output[0] * (1 - opacity),
      green * opacity + output[1] * (1 - opacity),
      blue * opacity + output[2] * (1 - opacity),
    ];
  }
  return [...output, 255];
}

/**
 * Synchronously inspect computed background/fill colors near the bottom of a
 * same-origin iframe viewport. Cross-origin access, detached frames, and
 * unsupported DOM APIs safely return the requested fallback.
 *
 * @param {HTMLIFrameElement | Record<string, any> | null | undefined} iframe
 * @param {{
 *   fallback?: "light" | "dark",
 *   threshold?: number,
 *   sampleColumns?: number,
 *   sampleRows?: number,
 * }} [options]
 * @returns {"light" | "dark"}
 */
export function inspectIframeBottomTone(iframe, options = {}) {
  const fallback = options.fallback === ARTIFACT_TONE_DARK
    ? ARTIFACT_TONE_DARK
    : ARTIFACT_TONE_LIGHT;
  try {
    const documentObject = iframe?.contentDocument;
    const view = documentObject?.defaultView;
    if (!documentObject || !view || typeof view.getComputedStyle !== "function") return fallback;
    const root = documentObject.documentElement;
    const width = Number(root?.clientWidth || iframe?.clientWidth);
    const height = Number(root?.clientHeight || iframe?.clientHeight);
    if (!(width > 0 && height > 0)) return fallback;

    const columns = Math.max(1, Math.round(options.sampleColumns ?? 5));
    const rows = Math.max(1, Math.round(options.sampleRows ?? 3));
    const colors = [];
    for (let row = 0; row < rows; row += 1) {
      const y = height * (0.7 + ((row + 0.5) / rows) * 0.29);
      for (let column = 0; column < columns; column += 1) {
        const x = width * ((column + 0.5) / columns);
        const elements = typeof documentObject.elementsFromPoint === "function"
          ? documentObject.elementsFromPoint(x, y)
          : [documentObject.elementFromPoint?.(x, y)].filter(Boolean);
        const stackColors = [];
        for (const element of elements) {
          const style = view.getComputedStyle(element);
          const isSvg = element?.namespaceURI === SVG_NAMESPACE || Boolean(element?.ownerSVGElement);
          const fill = isSvg ? parseCssColor(style?.fill) : null;
          if (fill && fill[3] > 0) stackColors.push(fill);
          const background = parseCssColor(style?.backgroundColor);
          if (background && background[3] > 0) stackColors.push(background);
          if (stackColors.some((color) => color[3] === 255)) break;
        }
        if (stackColors.length) colors.push(compositeColors(stackColors));
      }
    }

    if (!colors.length) {
      for (const element of [documentObject.body, root]) {
        if (!element) continue;
        const color = parseCssColor(view.getComputedStyle(element)?.backgroundColor);
        if (color && color[3] > 0) colors.push(compositeColors([color]));
      }
    }
    return classifyRgbaPixels(colors.flat(), {
      fallback,
      threshold: options.threshold,
      trimFraction: 0,
    });
  } catch {
    return fallback;
  }
}
