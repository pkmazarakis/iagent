import type { SpatialDesktopAPI } from "./electronPlatformBridge.js";

declare global {
  interface Window {
    spatialDesktop?: SpatialDesktopAPI;
  }
}

export {};

