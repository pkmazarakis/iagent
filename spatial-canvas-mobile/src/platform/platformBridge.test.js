import { describe, expect, it, vi } from "vitest";
import { createBrowserPlatformBridge } from "./browserPlatformBridge.js";
import { createElectronPlatformBridge } from "./electronPlatformBridge.js";
import { createPlatformBridge } from "./index.js";
import { normalizeExternalUrl } from "./PlatformBridge.js";

describe("PlatformBridge", () => {
  it("rejects privileged and non-HTTPS external URLs", () => {
    expect(() => normalizeExternalUrl("javascript:alert(1)")).toThrow(/HTTPS/);
    expect(() => normalizeExternalUrl("file:///tmp/secret")).toThrow(/HTTPS/);
    expect(normalizeExternalUrl("https://example.com/path")).toBe("https://example.com/path");
  });

  it("provides a browser-safe adapter", async () => {
    const open = vi.fn(() => ({ opener: {} }));
    const listeners = new Map();
    const browserWindow = {
      open,
      addEventListener: vi.fn((name, callback) => listeners.set(name, callback)),
      removeEventListener: vi.fn((name) => listeners.delete(name)),
    };
    const bridge = createBrowserPlatformBridge({ window: browserWindow });

    expect(bridge.kind).toBe("browser");
    expect((await bridge.getAppInfo()).platform).toBe("browser");
    await bridge.openExternal("https://example.com/");
    expect(open).toHaveBeenCalledWith("https://example.com/", "_blank", "noopener,noreferrer");

    const onClose = vi.fn();
    const unsubscribe = bridge.onBeforeClose(onClose);
    listeners.get("beforeunload")();
    expect(onClose).toHaveBeenCalledOnce();
    unsubscribe();
    expect(listeners.has("beforeunload")).toBe(false);
  });

  it("wraps only the narrow preload API for Electron", async () => {
    const api = {
      getAppInfo: vi.fn(async () => ({ name: "Spatial", version: "1.2.3" })),
      pickFiles: vi.fn(async () => [{ name: "image.png", path: "/chosen/image.png" }]),
      openExternal: vi.fn(async () => {}),
      onBeforeClose: vi.fn(() => () => {}),
      confirmCloseReady: vi.fn(),
    };
    const bridge = createElectronPlatformBridge(api);

    expect(bridge.kind).toBe("electron");
    expect(await bridge.getAppInfo()).toEqual({
      name: "Spatial",
      version: "1.2.3",
      platform: "electron",
    });
    await expect(bridge.pickFiles({ multiple: true, accept: "image/*" })).resolves.toHaveLength(1);
    expect(api.pickFiles).toHaveBeenCalledWith({ multiple: true, accept: "image/*" });
    await bridge.openExternal("https://get-spatial.com/");
    expect(api.openExternal).toHaveBeenCalledWith("https://get-spatial.com/");
  });

  it("auto-selects Electron only when the preload API exists", () => {
    const api = {
      getAppInfo: vi.fn(),
      pickFiles: vi.fn(),
      openExternal: vi.fn(),
      onBeforeClose: vi.fn(() => () => {}),
      confirmCloseReady: vi.fn(),
    };

    expect(createPlatformBridge({ window: { spatialDesktop: api } }).kind).toBe("electron");
    expect(createPlatformBridge({ window: {} }).kind).toBe("browser");
  });
});

