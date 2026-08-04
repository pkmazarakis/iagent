import { describe, expect, it, vi } from "vitest";
import {
  captureWebClipPng,
  convertScreenshotToPng,
  fetchScreenshotBlob,
  probeScreenshotImage,
  resolveWebClipScreenshot,
  screenshotCropGeometry,
} from "./webClipCapture.js";

function fakeImage(result, delay = 0) {
  return () => {
    const image = {
      naturalWidth: result === "load" ? 800 : 0,
      naturalHeight: result === "load" ? 450 : 0,
      onload: null,
      onerror: null,
      set src(_value) {
        setTimeout(() => {
          if (result === "load") image.onload?.();
          if (result === "error") image.onerror?.();
        }, delay);
      },
    };
    return image;
  };
}

describe("web clip screenshot resolution", () => {
  it("crops screenshots to a bounded top-aligned 16:9 PNG frame", () => {
    expect(screenshotCropGeometry(800, 450)).toEqual({
      sourceX: 0,
      sourceY: 0,
      sourceWidth: 800,
      sourceHeight: 450,
      width: 800,
      height: 450,
    });
    expect(screenshotCropGeometry(2560, 1600)).toEqual({
      sourceX: 0,
      sourceY: 0,
      sourceWidth: 2560,
      sourceHeight: 1440,
      width: 1600,
      height: 900,
    });
    const wide = screenshotCropGeometry(2400, 900);
    expect(wide.sourceX).toBe(400);
    expect(wide.sourceWidth).toBe(1600);
    expect(wide.width / wide.height).toBeCloseTo(16 / 9, 3);
  });

  it("downloads only bounded image responses", async () => {
    const imageBlob = new Blob([new Uint8Array(32)], { type: "image/png" });
    const fetchImpl = vi.fn(async () => new Response(imageBlob, {
      status: 200,
      headers: { "content-type": "image/png" },
    }));
    await expect(fetchScreenshotBlob("https://capture.test/ok", { fetchImpl }))
      .resolves.toEqual(imageBlob);
    expect(fetchImpl).toHaveBeenCalledWith("https://capture.test/ok", expect.objectContaining({
      credentials: "omit",
      mode: "cors",
    }));

    await expect(fetchScreenshotBlob("https://capture.test/json", {
      fetchImpl: async () => new Response("busy", {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    })).rejects.toThrow(/did not return an image/);
  });

  it("honors a signal that was already cancelled", async () => {
    const controller = new AbortController();
    controller.abort();
    const fetchImpl = vi.fn(async (_url, init) => {
      if (init.signal.aborted) throw new DOMException("cancelled", "AbortError");
      return new Response(new Blob([new Uint8Array(32)], { type: "image/png" }));
    });
    await expect(fetchScreenshotBlob("https://capture.test/cancelled", {
      fetchImpl,
      signal: controller.signal,
    })).rejects.toMatchObject({ name: "AbortError" });
    expect(fetchImpl.mock.calls[0][1].signal.aborted).toBe(true);
  });

  it("revokes its temporary decode URL after PNG conversion", async () => {
    const output = new Blob([new Uint8Array(64)], { type: "image/png" });
    const drawImage = vi.fn();
    const canvas = {
      width: 0,
      height: 0,
      getContext: vi.fn(() => ({ drawImage })),
      toBlob: vi.fn((callback) => callback(output)),
    };
    const urlApi = {
      createObjectURL: vi.fn(() => "blob:cached-source"),
      revokeObjectURL: vi.fn(),
    };
    const image = {
      naturalWidth: 800,
      naturalHeight: 450,
      decode: vi.fn(async () => undefined),
      onload: null,
      onerror: null,
      set src(value) { this.currentSrc = value; },
    };
    await expect(convertScreenshotToPng(
      new Blob([new Uint8Array(32)], { type: "image/webp" }),
      {
        imageFactory: () => image,
        documentObject: { createElement: vi.fn(() => canvas) },
        urlApi,
      },
    )).resolves.toBe(output);
    expect(image.currentSrc).toBe("blob:cached-source");
    expect(canvas.width).toBe(800);
    expect(canvas.height).toBe(450);
    expect(drawImage).toHaveBeenCalledOnce();
    expect(urlApi.revokeObjectURL).toHaveBeenCalledWith("blob:cached-source");
  });

  it("falls back until a provider returns savable PNG bytes", async () => {
    const candidates = [
      { provider: "thum", url: "https://capture.test/one" },
      { provider: "microlink", url: "https://capture.test/two" },
    ];
    const png = new Blob([new Uint8Array(64)], { type: "image/png" });
    const download = vi.fn(async (url) => {
      if (url.endsWith("one")) throw new Error("CORS blocked");
      return png;
    });
    const result = await captureWebClipPng("https://example.com", { candidates, download });
    expect(result).toMatchObject({ provider: "microlink", url: candidates[1].url, blob: png });
    expect(download).toHaveBeenCalledTimes(2);
  });

  it("accepts only a decoded image response", async () => {
    await expect(probeScreenshotImage("https://capture.test/ok", {
      imageFactory: fakeImage("load"),
      timeoutMs: 25,
    })).resolves.toBe("https://capture.test/ok");
    await expect(probeScreenshotImage("https://capture.test/broken", {
      imageFactory: fakeImage("error"),
      timeoutMs: 25,
    })).rejects.toThrow(/invalid image/);
  });

  it("times out a provider that never settles", async () => {
    vi.useFakeTimers();
    const pending = probeScreenshotImage("https://capture.test/hangs", {
      imageFactory: fakeImage("hang"),
      timeoutMs: 50,
    });
    const assertion = expect(pending).rejects.toThrow(/timed out/);
    await vi.advanceTimersByTimeAsync(51);
    await assertion;
    vi.useRealTimers();
  });

  it("falls through failures and returns the first working provider", async () => {
    const candidates = [
      { provider: "thum", url: "https://capture.test/one" },
      { provider: "microlink", url: "https://capture.test/two" },
      { provider: "pageshot", url: "https://capture.test/three" },
    ];
    const probe = vi.fn(async (url) => {
      if (!url.endsWith("two")) throw new Error("provider failed");
      return url;
    });
    const result = await resolveWebClipScreenshot("https://example.com", { candidates, probe });

    expect(result.provider).toBe("microlink");
    expect(result.url).toBe(candidates[1].url);
    expect(probe.mock.calls.map(([url]) => url)).toEqual([
      candidates[0].url,
      candidates[1].url,
    ]);
  });

  it("does not return a broken record when every provider fails", async () => {
    const candidates = [
      { provider: "thum", url: "https://capture.test/one" },
      { provider: "microlink", url: "https://capture.test/two" },
    ];
    await expect(resolveWebClipScreenshot("https://example.com", {
      candidates,
      probe: async () => { throw new Error("provider failed"); },
    })).rejects.toThrow(/could not be captured/);
  });

  it("stops immediately when capture is cancelled", async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(probeScreenshotImage("https://capture.test/ok", {
      imageFactory: fakeImage("load"),
      signal: controller.signal,
    })).rejects.toMatchObject({ name: "AbortError" });
  });
});
