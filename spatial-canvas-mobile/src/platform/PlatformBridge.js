// @ts-check

/** @typedef {"browser" | "electron"} PlatformKind */

/**
 * @typedef {object} AppInfo
 * @property {string} name
 * @property {string} version
 * @property {PlatformKind} platform
 */

/**
 * @typedef {object} FilePickerOptions
 * @property {boolean=} multiple
 * @property {string=} accept
 */

/**
 * @typedef {object} PlatformFile
 * @property {string} name
 * @property {string=} path
 * @property {number=} size
 * @property {string=} type
 * @property {File=} file
 * @property {Uint8Array=} bytes
 */

/**
 * @typedef {object} PlatformBridge
 * @property {PlatformKind} kind
 * @property {boolean} isElectron
 * @property {() => Promise<AppInfo>} getAppInfo
 * @property {(options?: FilePickerOptions) => Promise<PlatformFile[]>} pickFiles
 * @property {(url: string) => Promise<void>} openExternal
 * @property {(callback: () => void | Promise<void>) => () => void} onBeforeClose
 * @property {() => void} confirmCloseReady
 */

/**
 * Accept only HTTPS external links. File, javascript, data, and custom schemes never cross
 * the platform bridge.
 * @param {string} value
 */
export function normalizeExternalUrl(value) {
  if (typeof value !== "string" || value.length > 4096) {
    throw new TypeError("external URL must be a reasonably sized string");
  }

  const url = new URL(value);
  if (url.protocol !== "https:") {
    throw new TypeError("only HTTPS external URLs are allowed");
  }

  return url.toString();
}

/** @param {unknown} value @returns {asserts value is PlatformBridge} */
export function assertPlatformBridge(value) {
  if (!value || typeof value !== "object") {
    throw new TypeError("platform bridge must be an object");
  }

  const bridge = /** @type {Record<string, unknown>} */ (value);
  if (bridge.kind !== "browser" && bridge.kind !== "electron") {
    throw new TypeError("platform bridge kind must be browser or electron");
  }

  for (const method of [
    "getAppInfo",
    "pickFiles",
    "openExternal",
    "onBeforeClose",
    "confirmCloseReady",
  ]) {
    if (typeof bridge[method] !== "function") {
      throw new TypeError(`platform bridge is missing ${method}()`);
    }
  }
}
