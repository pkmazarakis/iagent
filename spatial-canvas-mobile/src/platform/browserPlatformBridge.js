// @ts-check

import { assertPlatformBridge, normalizeExternalUrl } from "./PlatformBridge.js";

/**
 * @typedef {object} BrowserRuntime
 * @property {Window=} window
 * @property {Document=} document
 */

/**
 * @param {BrowserRuntime} [runtime]
 * @returns {import("./PlatformBridge.js").PlatformBridge}
 */
export function createBrowserPlatformBridge(runtime = {}) {
  const browserWindow = runtime.window ?? globalThis.window;
  const browserDocument = runtime.document ?? globalThis.document;

  /** @type {import("./PlatformBridge.js").PlatformBridge} */
  const bridge = {
    kind: "browser",
    isElectron: false,

    async getAppInfo() {
      return { name: "Spatial", version: "web", platform: "browser" };
    },

    async pickFiles(options = {}) {
      if (!browserDocument?.createElement) {
        throw new Error("file picking is unavailable in this browser context");
      }

      return new Promise((resolve) => {
        const input = browserDocument.createElement("input");
        input.type = "file";
        input.multiple = Boolean(options.multiple);
        input.accept = options.accept ?? "";
        input.style.display = "none";

        const cleanup = () => input.remove();
        input.addEventListener(
          "change",
          () => {
            const files = Array.from(input.files ?? []).map((file) => ({
              name: file.name,
              size: file.size,
              type: file.type,
              file,
            }));
            cleanup();
            resolve(files);
          },
          { once: true },
        );
        input.addEventListener(
          "cancel",
          () => {
            cleanup();
            resolve([]);
          },
          { once: true },
        );

        browserDocument.body?.append(input);
        input.click();
      });
    },

    async openExternal(value) {
      const url = normalizeExternalUrl(value);
      if (!browserWindow?.open) {
        throw new Error("opening external URLs is unavailable in this browser context");
      }

      const opened = browserWindow.open(url, "_blank", "noopener,noreferrer");
      if (opened) opened.opener = null;
    },

    onBeforeClose(callback) {
      if (!browserWindow?.addEventListener || !browserWindow?.removeEventListener) {
        return () => {};
      }

      const handler = () => void callback();
      browserWindow.addEventListener("beforeunload", handler);
      return () => browserWindow.removeEventListener("beforeunload", handler);
    },

    confirmCloseReady() {},
  };

  assertPlatformBridge(bridge);
  return bridge;
}
