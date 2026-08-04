// @ts-check

import { assertPlatformBridge, normalizeExternalUrl } from "./PlatformBridge.js";

/**
 * The only Electron surface the renderer is allowed to see. The preload implementation
 * supplies this object through contextBridge; raw ipcRenderer is never exposed.
 *
 * @typedef {object} SpatialDesktopAPI
 * @property {() => Promise<{name: string, version: string}>} getAppInfo
 * @property {(options?: import("./PlatformBridge.js").FilePickerOptions) => Promise<import("./PlatformBridge.js").PlatformFile[]>} pickFiles
 * @property {(url: string) => Promise<void>} openExternal
 * @property {(callback: () => void) => () => void} onBeforeClose
 * @property {() => void} confirmCloseReady
 */

/**
 * @param {SpatialDesktopAPI} api
 * @returns {import("./PlatformBridge.js").PlatformBridge}
 */
export function createElectronPlatformBridge(api) {
  if (!api || typeof api !== "object") {
    throw new TypeError("Electron preload API is unavailable");
  }

  for (const method of [
    "getAppInfo",
    "pickFiles",
    "openExternal",
    "onBeforeClose",
    "confirmCloseReady",
  ]) {
    if (typeof api[method] !== "function") {
      throw new TypeError(`Electron preload API is missing ${method}()`);
    }
  }

  /** @type {import("./PlatformBridge.js").PlatformBridge} */
  const bridge = {
    kind: "electron",
    isElectron: true,

    async getAppInfo() {
      const info = await api.getAppInfo();
      return { ...info, platform: "electron" };
    },

    pickFiles(options = {}) {
      return api.pickFiles({
        multiple: Boolean(options.multiple),
        accept: options.accept ?? "",
      });
    },

    openExternal(value) {
      return api.openExternal(normalizeExternalUrl(value));
    },

    onBeforeClose(callback) {
      return api.onBeforeClose(() => void callback());
    },

    confirmCloseReady() {
      api.confirmCloseReady();
    },
  };

  assertPlatformBridge(bridge);
  return bridge;
}

