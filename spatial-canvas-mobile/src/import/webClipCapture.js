// @ts-check

import { buildWebClipCaptureCandidates } from "./webClip.js";

export const WEB_CLIP_CANDIDATE_TIMEOUT_MS = 10_000;
export const MAX_WEB_CLIP_PNG_BYTES = 20 * 1024 * 1024;
export const MAX_WEB_CLIP_PNG_WIDTH = 1600;
export const WEB_CLIP_PNG_ASPECT_RATIO = 16 / 9;

/**
 * @param {number} sourceWidth
 * @param {number} sourceHeight
 * @param {number} [maxWidth]
 */
export function screenshotCropGeometry(
  sourceWidth,
  sourceHeight,
  maxWidth = MAX_WEB_CLIP_PNG_WIDTH,
) {
  if (![sourceWidth, sourceHeight, maxWidth].every((value) => Number.isFinite(value) && value > 0)) {
    throw new TypeError("screenshot dimensions must be positive numbers");
  }
  const sourceRatio = sourceWidth / sourceHeight;
  let cropWidth = sourceWidth;
  let cropHeight = sourceHeight;
  let sourceX = 0;
  const sourceY = 0;
  if (sourceRatio > WEB_CLIP_PNG_ASPECT_RATIO) {
    cropWidth = sourceHeight * WEB_CLIP_PNG_ASPECT_RATIO;
    sourceX = (sourceWidth - cropWidth) / 2;
  } else if (sourceRatio < WEB_CLIP_PNG_ASPECT_RATIO) {
    cropHeight = sourceWidth / WEB_CLIP_PNG_ASPECT_RATIO;
  }
  const width = Math.max(1, Math.round(Math.min(maxWidth, cropWidth)));
  const height = Math.max(1, Math.round(width / WEB_CLIP_PNG_ASPECT_RATIO));
  return { sourceX, sourceY, sourceWidth: cropWidth, sourceHeight: cropHeight, width, height };
}

/**
 * Fetch screenshot bytes while enforcing a bounded, raster-image response.
 * The providers used by Spatial expose CORS-enabled image endpoints; if one
 * does not, the caller advances to the next provider instead of persisting an
 * opaque or non-image response.
 *
 * @param {string} url
 * @param {{
 *   timeoutMs?: number,
 *   signal?: AbortSignal,
 *   fetchImpl?: typeof fetch,
 * }} [options]
 */
export async function fetchScreenshotBlob(url, options = {}) {
  const timeoutMs = options.timeoutMs ?? WEB_CLIP_CANDIDATE_TIMEOUT_MS;
  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") throw new Error("Screenshot download is unavailable");
  const controller = new AbortController();
  const abort = () => controller.abort(options.signal?.reason);
  if (options.signal?.aborted) abort();
  else options.signal?.addEventListener("abort", abort, { once: true });
  const timeout = setTimeout(() => controller.abort("Screenshot provider timed out"), timeoutMs);
  try {
    const response = await fetchImpl(url, {
      method: "GET",
      mode: "cors",
      credentials: "omit",
      cache: "force-cache",
      referrerPolicy: "no-referrer",
      headers: { Accept: "image/png,image/*;q=0.9" },
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`Screenshot provider returned ${response.status}`);
    const contentType = response.headers.get("content-type")?.split(";")[0].trim().toLowerCase() || "";
    if (!contentType.startsWith("image/")) {
      throw new Error("Screenshot provider did not return an image");
    }
    const blob = await response.blob();
    if (blob.size < 16) throw new Error("Screenshot provider returned an empty image");
    if (blob.size > MAX_WEB_CLIP_PNG_BYTES) throw new Error("Screenshot image is too large to save");
    return blob;
  } finally {
    clearTimeout(timeout);
    options.signal?.removeEventListener("abort", abort);
  }
}

/**
 * Convert any supported raster response into a bounded 16:9 PNG. Captures are
 * top-aligned because the beginning of a web page carries the useful context.
 *
 * @param {Blob} blob
 * @param {{
 *   maxWidth?: number,
 *   imageFactory?: () => HTMLImageElement,
 *   documentObject?: Document,
 *   urlApi?: typeof URL,
 * }} [options]
 */
export async function convertScreenshotToPng(blob, options = {}) {
  if (!(blob instanceof Blob) || !blob.type.startsWith("image/")) {
    throw new TypeError("screenshot source must be an image Blob");
  }
  const imageFactory = options.imageFactory ?? (() => new Image());
  const documentObject = options.documentObject ?? document;
  const urlApi = options.urlApi ?? URL;
  const objectUrl = urlApi.createObjectURL(blob);
  try {
    const image = imageFactory();
    image.decoding = "async";
    const loaded = new Promise((resolve, reject) => {
      image.onload = () => resolve(undefined);
      image.onerror = () => reject(new Error("Screenshot image could not be decoded"));
    });
    image.src = objectUrl;
    if (typeof image.decode === "function") {
      try { await image.decode(); } catch { await loaded; }
    } else {
      await loaded;
    }
    const geometry = screenshotCropGeometry(
      image.naturalWidth,
      image.naturalHeight,
      options.maxWidth,
    );
    const canvas = documentObject.createElement("canvas");
    canvas.width = geometry.width;
    canvas.height = geometry.height;
    const context = canvas.getContext("2d", { alpha: false });
    if (!context) throw new Error("PNG conversion is unavailable");
    context.drawImage(
      image,
      geometry.sourceX,
      geometry.sourceY,
      geometry.sourceWidth,
      geometry.sourceHeight,
      0,
      0,
      geometry.width,
      geometry.height,
    );
    const png = await new Promise((resolve, reject) => {
      canvas.toBlob(
        (result) => result ? resolve(result) : reject(new Error("PNG conversion failed")),
        "image/png",
      );
    });
    if (!(png instanceof Blob) || png.type !== "image/png" || png.size < 16) {
      throw new Error("PNG conversion returned an invalid image");
    }
    return png;
  } finally {
    urlApi.revokeObjectURL(objectUrl);
  }
}

/**
 * Download one already-resolved provider source and save it as a local PNG.
 *
 * @param {string} url
 * @param {{
 *   timeoutMs?: number,
 *   signal?: AbortSignal,
 *   fetchImpl?: typeof fetch,
 *   convert?: typeof convertScreenshotToPng,
 * }} [options]
 */
export async function downloadScreenshotPng(url, options = {}) {
  const source = await fetchScreenshotBlob(url, options);
  const convert = options.convert ?? convertScreenshotToPng;
  return convert(source);
}

/**
 * Resolve a provider and return durable PNG bytes in one pass.
 *
 * @param {unknown} value
 * @param {{
 *   width?: number,
 *   crop?: number,
 *   timeoutMs?: number,
 *   signal?: AbortSignal,
 *   candidates?: import("./webClip.js").WebClipCaptureCandidate[],
 *   download?: typeof downloadScreenshotPng,
 * }} [options]
 */
export async function captureWebClipPng(value, options = {}) {
  const candidates = options.candidates ?? buildWebClipCaptureCandidates(value, options);
  const download = options.download ?? downloadScreenshotPng;
  const failures = [];
  for (const candidate of candidates) {
    try {
      const blob = await download(candidate.url, {
        timeoutMs: options.timeoutMs,
        signal: options.signal,
      });
      return { ...candidate, candidates, blob };
    } catch (error) {
      if (options.signal?.aborted || (error instanceof DOMException && error.name === "AbortError")) {
        throw error;
      }
      failures.push({ provider: candidate.provider, error });
    }
  }
  const error = new Error("This page could not be captured and saved right now. Check the URL and try again.");
  error.cause = failures;
  throw error;
}

/**
 * Validate that a provider response actually decodes as an image. This works
 * on a static host without requiring the remote provider to grant fetch/CORS.
 *
 * @param {string} url
 * @param {{
 *   timeoutMs?: number,
 *   signal?: AbortSignal,
 *   imageFactory?: () => HTMLImageElement,
 * }} [options]
 */
export function probeScreenshotImage(url, options = {}) {
  const timeoutMs = options.timeoutMs ?? WEB_CLIP_CANDIDATE_TIMEOUT_MS;
  const imageFactory = options.imageFactory ?? (() => new Image());

  return new Promise((resolve, reject) => {
    if (options.signal?.aborted) {
      reject(new DOMException("Capture cancelled", "AbortError"));
      return;
    }

    const image = imageFactory();
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      options.signal?.removeEventListener("abort", onAbort);
      image.onload = null;
      image.onerror = null;
      callback(value);
    };
    const onAbort = () => finish(reject, new DOMException("Capture cancelled", "AbortError"));
    const timer = setTimeout(() => {
      finish(reject, new Error("Screenshot provider timed out"));
    }, timeoutMs);

    image.decoding = "async";
    image.referrerPolicy = "no-referrer";
    image.onload = () => {
      const invalidWidth = typeof image.naturalWidth === "number" && image.naturalWidth < 2;
      const invalidHeight = typeof image.naturalHeight === "number" && image.naturalHeight < 2;
      if (invalidWidth || invalidHeight) {
        finish(reject, new Error("Screenshot provider returned an empty image"));
      } else {
        finish(resolve, url);
      }
    };
    image.onerror = () => finish(reject, new Error("Screenshot provider returned an invalid image"));
    options.signal?.addEventListener("abort", onAbort, { once: true });
    image.src = url;
  });
}

/**
 * Try capture services one at a time so a single clip does not burn quota on
 * every provider. A candidate must decode before the board item is created.
 *
 * @param {unknown} value
 * @param {{
 *   width?: number,
 *   crop?: number,
 *   timeoutMs?: number,
 *   signal?: AbortSignal,
 *   candidates?: import("./webClip.js").WebClipCaptureCandidate[],
 *   probe?: typeof probeScreenshotImage,
 * }} [options]
 */
export async function resolveWebClipScreenshot(value, options = {}) {
  const candidates = options.candidates ?? buildWebClipCaptureCandidates(value, options);
  const probe = options.probe ?? probeScreenshotImage;
  const failures = [];

  for (const candidate of candidates) {
    try {
      await probe(candidate.url, {
        timeoutMs: options.timeoutMs,
        signal: options.signal,
      });
      return { ...candidate, candidates };
    } catch (error) {
      if (options.signal?.aborted || (error instanceof DOMException && error.name === "AbortError")) {
        throw error;
      }
      failures.push({ provider: candidate.provider, error });
    }
  }

  const error = new Error("This page could not be captured right now. Check the URL and try again.");
  error.cause = failures;
  throw error;
}
