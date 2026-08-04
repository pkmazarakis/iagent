// @ts-check

import { createBrowserPlatformBridge } from "./browserPlatformBridge.js";
import { createElectronPlatformBridge } from "./electronPlatformBridge.js";

/**
 * @param {{window?: Window & {spatialDesktop?: import("./electronPlatformBridge.js").SpatialDesktopAPI}, document?: Document}} [runtime]
 */
export function createPlatformBridge(runtime = {}) {
  const hostWindow = runtime.window ?? globalThis.window;
  if (hostWindow?.spatialDesktop) {
    return createElectronPlatformBridge(hostWindow.spatialDesktop);
  }

  return createBrowserPlatformBridge({
    window: hostWindow,
    document: runtime.document ?? globalThis.document,
  });
}

export const platformBridge = createPlatformBridge();

