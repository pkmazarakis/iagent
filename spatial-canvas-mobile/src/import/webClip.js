// @ts-check

export const MAX_WEB_CLIP_URL_LENGTH = 4096;
export const THUM_SCREENSHOT_ENDPOINT = "https://image.thum.io/get";
export const MICROLINK_SCREENSHOT_ENDPOINT = "https://api.microlink.io/";
export const PAGESHOT_PREVIEW_ENDPOINT = "https://pageshot.site/v1/preview";
export const DEFAULT_WEB_CLIP_PREVIEW_WIDTH = 800;
export const DEFAULT_WEB_CLIP_CAPTURE_HEIGHT = 675;

const NON_PUBLIC_HOST_SUFFIXES = [
  ".localhost",
  ".local",
  ".internal",
  ".lan",
  ".home",
  ".test",
];

/** @param {string} hostname */
function normalizedHostname(hostname) {
  return hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.$/, "");
}

/** @param {string} hostname */
function isPublicIpv4(hostname) {
  if (!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(hostname)) return true;
  const octets = hostname.split(".").map(Number);
  if (octets.some((octet) => octet < 0 || octet > 255)) return false;
  const [a, b] = octets;
  return !(
    a === 0
    || a === 10
    || a === 127
    || (a === 100 && b >= 64 && b <= 127)
    || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && (b === 0 || b === 168))
    || (a === 198 && (b === 18 || b === 19))
    || a >= 224
  );
}

/** @param {string} hostname */
function isPublicIpv6(hostname) {
  if (!hostname.includes(":")) return true;
  const compact = hostname.toLowerCase();
  if (compact === "::" || compact === "::1") return false;
  if (/^(?:fc|fd)/.test(compact) || /^fe[89ab]/.test(compact)) return false;
  if (compact.startsWith("::ffff:")) {
    return isPublicIpv4(compact.slice("::ffff:".length));
  }
  return true;
}

/**
 * Keep anonymous screenshot providers away from obvious loopback and private
 * network targets. DNS rebinding still belongs at a server boundary; this
 * client-side guard covers the literal/private URLs a static app can reject.
 *
 * @param {string} hostname
 */
export function isPublicWebClipHostname(hostname) {
  const normalized = normalizedHostname(hostname);
  if (!normalized || normalized === "localhost") return false;
  if (NON_PUBLIC_HOST_SUFFIXES.some((suffix) => normalized.endsWith(suffix))) return false;
  return isPublicIpv4(normalized) && isPublicIpv6(normalized);
}

/**
 * Normalize a public page URL before it is persisted or sent to a screenshot
 * provider. Bare hostnames default to HTTPS. Credentials and obvious private
 * network targets are rejected, and fragments are removed because they do not
 * identify a different capturable document.
 *
 * @param {unknown} value
 * @returns {string}
 */
export function normalizeWebClipUrl(value) {
  if (typeof value !== "string") {
    throw new TypeError("web clip URL must be a string");
  }

  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > MAX_WEB_CLIP_URL_LENGTH) {
    throw new TypeError("web clip URL must be a reasonably sized string");
  }

  const hasExplicitScheme = /^[a-z][a-z0-9+.-]*:/i.test(trimmed);
  const candidate = trimmed.startsWith("//")
    ? `https:${trimmed}`
    : hasExplicitScheme
      ? trimmed
      : `https://${trimmed}`;

  let url;
  try {
    url = new URL(candidate);
  } catch {
    throw new TypeError("web clip URL is invalid");
  }

  if (url.protocol !== "https:") {
    throw new TypeError("web clip URL must use HTTPS");
  }
  if (!url.hostname) {
    throw new TypeError("web clip URL must include a hostname");
  }
  if (url.username || url.password) {
    throw new TypeError("web clip URL must not include credentials");
  }
  if (!isPublicWebClipHostname(url.hostname)) {
    throw new TypeError("web clip URL must use a public hostname");
  }

  url.hash = "";
  const normalized = url.toString();
  if (normalized.length > MAX_WEB_CLIP_URL_LENGTH) {
    throw new TypeError("web clip URL must be a reasonably sized string");
  }
  return normalized;
}

/**
 * Return the single, compact URL label shown on a retained web clip. Web clips
 * intentionally present the hostname rather than repeating title/description
 * metadata over the captured page.
 *
 * @param {Record<string, any>} item
 * @returns {string}
 */
export function webClipDisplayUrl(item) {
  const storedDomain = typeof item?.domain === "string" ? item.domain.trim() : "";
  const candidate = storedDomain || item?.url;
  if (typeof candidate !== "string" || !candidate.trim()) return "Saved page";

  try {
    const withScheme = /^[a-z][a-z0-9+.-]*:/i.test(candidate)
      ? candidate
      : `https://${candidate}`;
    return new URL(withScheme).hostname.replace(/^www\./i, "") || "Saved page";
  } catch {
    return storedDomain.replace(/^www\./i, "") || "Saved page";
  }
}

/**
 * A remote screenshot only needs to be persisted for legacy clips that do not
 * already own a cached PNG. Re-caching an asset-backed clip changes its asset
 * id and forces the retained card through another loading cycle.
 *
 * @param {Record<string, any> | null | undefined} item
 * @param {unknown} screenshotUrl
 * @returns {boolean}
 */
export function needsWebClipScreenshotCache(item, screenshotUrl) {
  return Boolean(
    item?.kind === "web"
    && item?.content?.url
    && !item?.content?.screenshotAssetId
    && typeof screenshotUrl === "string"
    && screenshotUrl.startsWith("https:"),
  );
}

/** @param {number} width */
function assertPreviewWidth(width) {
  if (!Number.isInteger(width) || width < 100 || width > 800) {
    throw new RangeError("web clip preview width must be an integer from 100 through 800");
  }
}

/**
 * @param {unknown} value
 * @param {{width?: number, crop?: number}} [options]
 */
export function buildThumScreenshotUrl(value, options = {}) {
  const width = options.width ?? DEFAULT_WEB_CLIP_PREVIEW_WIDTH;
  const crop = options.crop ?? DEFAULT_WEB_CLIP_CAPTURE_HEIGHT;
  assertPreviewWidth(width);
  if (!Number.isInteger(crop) || crop < 100 || crop > 2400) {
    throw new RangeError("web clip capture height must be an integer from 100 through 2400");
  }
  const capture = new URL(`${THUM_SCREENSHOT_ENDPOINT}/noanimate/png/width/${width}/crop/${crop}/`);
  capture.searchParams.set("url", normalizeWebClipUrl(value));
  return capture.toString();
}

/**
 * @param {unknown} value
 * @returns {string}
 */
export function buildMicrolinkScreenshotUrl(value) {
  const capture = new URL(MICROLINK_SCREENSHOT_ENDPOINT);
  capture.searchParams.set("url", normalizeWebClipUrl(value));
  capture.searchParams.set("screenshot", "true");
  capture.searchParams.set("meta", "false");
  capture.searchParams.set("embed", "screenshot.url");
  return capture.toString();
}

/**
 * Retained as a tertiary fallback for existing records and temporary outages.
 *
 * @param {unknown} value
 * @param {{width?: number}} [options]
 * @returns {string}
 */
export function buildPageShotPreviewUrl(value, options = {}) {
  const width = options.width ?? DEFAULT_WEB_CLIP_PREVIEW_WIDTH;
  assertPreviewWidth(width);
  const preview = new URL(PAGESHOT_PREVIEW_ENDPOINT);
  preview.searchParams.set("url", normalizeWebClipUrl(value));
  preview.searchParams.set("width", String(width));
  return preview.toString();
}

/**
 * @typedef {{provider: "thum" | "microlink" | "pageshot", url: string}} WebClipCaptureCandidate
 */

/**
 * @param {unknown} value
 * @param {{width?: number, crop?: number}} [options]
 * @returns {WebClipCaptureCandidate[]}
 */
export function buildWebClipCaptureCandidates(value, options = {}) {
  return [
    { provider: "thum", url: buildThumScreenshotUrl(value, options) },
    { provider: "microlink", url: buildMicrolinkScreenshotUrl(value) },
    { provider: "pageshot", url: buildPageShotPreviewUrl(value, options) },
  ];
}

/** @param {string} url */
export function captureProviderForUrl(url) {
  if (url.startsWith(THUM_SCREENSHOT_ENDPOINT)) return "thum";
  if (url.startsWith(MICROLINK_SCREENSHOT_ENDPOINT)) return "microlink";
  if (url.startsWith(PAGESHOT_PREVIEW_ENDPOINT)) return "pageshot";
  return "custom";
}

/**
 * Derive a self-healing source list for both new and legacy records. An old
 * PageShot-only item intentionally tries the new providers first.
 *
 * @param {Record<string, any>} item
 * @returns {string[]}
 */
export function screenshotCandidatesForItem(item) {
  const persisted = Array.isArray(item?.screenshotCandidates)
    ? item.screenshotCandidates.filter((value) => typeof value === "string" && value)
    : [];
  const direct = [item?.screenshotUrl, item?.image]
    .filter((value) => typeof value === "string" && value);
  let generated = [];
  try {
    if (item?.url) generated = buildWebClipCaptureCandidates(item.url).map((candidate) => candidate.url);
  } catch {
    // Legacy/private records still retain any explicit source they already had.
  }

  const preferred = [...direct, ...persisted].filter(
    (url) => captureProviderForUrl(url) !== "pageshot",
  );
  const pageShot = [...direct, ...persisted].filter(
    (url) => captureProviderForUrl(url) === "pageshot",
  );
  return [...new Set([...preferred, ...generated, ...pageShot])];
}

/**
 * Build the flat metadata consumed by a `kind: "web"` board item.
 *
 * @param {unknown} value
 * @param {{
 *   width?: number,
 *   crop?: number,
 *   screenshotUrl?: string,
 *   screenshotAssetId?: string,
 *   captureProvider?: string,
 *   candidates?: WebClipCaptureCandidate[],
 * }} [options]
 */
export function buildWebClipContent(value, options = {}) {
  const url = normalizeWebClipUrl(value);
  const parsed = new URL(url);
  const domain = parsed.hostname.replace(/^www\./i, "") || "Saved website";
  const candidates = options.candidates ?? buildWebClipCaptureCandidates(url, options);
  const screenshotUrl = options.screenshotUrl || candidates[0]?.url || "";
  const orderedCandidates = [
    screenshotUrl,
    ...candidates.map((candidate) => candidate.url),
  ].filter(Boolean);

  return {
    domain,
    title: domain,
    description: "Saved from the web",
    excerpt: url,
    image: screenshotUrl,
    screenshotUrl,
    screenshotCandidates: [...new Set(orderedCandidates)],
    captureProvider: options.captureProvider || captureProviderForUrl(screenshotUrl),
    ...(options.screenshotAssetId ? { screenshotAssetId: options.screenshotAssetId } : {}),
    url,
  };
}
