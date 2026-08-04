import { describe, expect, it } from "vitest";
import {
  buildMicrolinkScreenshotUrl,
  buildPageShotPreviewUrl,
  buildThumScreenshotUrl,
  buildWebClipCaptureCandidates,
  buildWebClipContent,
  DEFAULT_WEB_CLIP_CAPTURE_HEIGHT,
  DEFAULT_WEB_CLIP_PREVIEW_WIDTH,
  isPublicWebClipHostname,
  MAX_WEB_CLIP_URL_LENGTH,
  MICROLINK_SCREENSHOT_ENDPOINT,
  needsWebClipScreenshotCache,
  normalizeWebClipUrl,
  PAGESHOT_PREVIEW_ENDPOINT,
  screenshotCandidatesForItem,
  THUM_SCREENSHOT_ENDPOINT,
  webClipDisplayUrl,
} from "./webClip.js";

describe("web clip import contract", () => {
  it("normalizes public HTTPS page URLs and removes fragments", () => {
    expect(normalizeWebClipUrl(" example.com/article ")).toBe("https://example.com/article");
    expect(normalizeWebClipUrl("//example.com/path")).toBe("https://example.com/path");
    expect(normalizeWebClipUrl("https://example.com/search?q=canvas#results"))
      .toBe("https://example.com/search?q=canvas");
    expect(normalizeWebClipUrl("https://example.com")).toBe("https://example.com/");
  });

  it("derives one compact, untruncated display URL", () => {
    expect(webClipDisplayUrl({ url: "https://www.google.com/search?q=spatial" })).toBe("google.com");
    expect(webClipDisplayUrl({ domain: "www.openai.com", url: "https://ignored.example" })).toBe("openai.com");
    expect(webClipDisplayUrl({ url: "https://a-very-long-subdomain-for-a-spatial-board.example.com/path" }))
      .toBe("a-very-long-subdomain-for-a-spatial-board.example.com");
    expect(webClipDisplayUrl({ url: "not a valid URL" })).toBe("Saved page");
  });

  it("caches a remote screenshot only once for a legacy web clip", () => {
    const legacy = {
      kind: "web",
      content: { url: "https://example.com/" },
    };
    expect(needsWebClipScreenshotCache(legacy, "https://capture.example/shot.png")).toBe(true);
    expect(needsWebClipScreenshotCache({
      ...legacy,
      content: { ...legacy.content, screenshotAssetId: "asset-web-1" },
    }, "https://capture.example/shot.png")).toBe(false);
    expect(needsWebClipScreenshotCache(legacy, "blob:cached-shot")).toBe(false);
    expect(needsWebClipScreenshotCache({ kind: "note", content: legacy.content }, "https://capture.example/shot.png"))
      .toBe(false);
  });

  it("rejects malformed, unsafe, private, and credential-bearing URLs", () => {
    const rejected = [
      " ",
      "https://",
      "http://example.com/legacy",
      "javascript:alert(1)",
      "data:text/plain,hello",
      "file:///tmp/private",
      "https://user:secret@example.com/private",
      "https://localhost:4000",
      "https://127.0.0.1",
      "https://10.0.0.8",
      "https://192.168.1.4",
      "https://169.254.169.254/latest/meta-data",
      "https://[::1]",
      "https://printer.local",
    ];
    rejected.forEach((value) => expect(() => normalizeWebClipUrl(value)).toThrow());
  });

  it("recognizes public and non-public hostnames", () => {
    expect(isPublicWebClipHostname("example.com")).toBe(true);
    expect(isPublicWebClipHostname("8.8.8.8")).toBe(true);
    expect(isPublicWebClipHostname("172.16.2.2")).toBe(false);
    expect(isPublicWebClipHostname("device.internal")).toBe(false);
  });

  it("enforces a bounded target URL", () => {
    expect(MAX_WEB_CLIP_URL_LENGTH).toBe(4096);
    expect(() => normalizeWebClipUrl(`https://example.com/${"a".repeat(MAX_WEB_CLIP_URL_LENGTH)}`))
      .toThrow(/reasonably sized/);
    expect(() => normalizeWebClipUrl(null)).toThrow(/string/);
  });

  it("builds encoded Thum, Microlink, and PageShot candidates", () => {
    const value = "https://example.com/search?q=spatial canvas";
    const thum = new URL(buildThumScreenshotUrl(value, { width: 640, crop: 540 }));
    const microlink = new URL(buildMicrolinkScreenshotUrl(value));
    const pageshot = new URL(buildPageShotPreviewUrl(value, { width: 640 }));

    expect(thum.toString().startsWith(`${THUM_SCREENSHOT_ENDPOINT}/noanimate/png/width/640/crop/540/`)).toBe(true);
    expect(thum.searchParams.get("url")).toBe("https://example.com/search?q=spatial%20canvas");
    expect(`${microlink.origin}${microlink.pathname}`).toBe(MICROLINK_SCREENSHOT_ENDPOINT);
    expect(microlink.searchParams.get("screenshot")).toBe("true");
    expect(microlink.searchParams.get("meta")).toBe("false");
    expect(microlink.searchParams.get("embed")).toBe("screenshot.url");
    expect(microlink.searchParams.get("url")).toBe("https://example.com/search?q=spatial%20canvas");
    expect(`${pageshot.origin}${pageshot.pathname}`).toBe(PAGESHOT_PREVIEW_ENDPOINT);
    expect(pageshot.searchParams.get("width")).toBe("640");
  });

  it("uses bounded card-sized capture defaults", () => {
    expect(DEFAULT_WEB_CLIP_PREVIEW_WIDTH).toBe(800);
    expect(DEFAULT_WEB_CLIP_CAPTURE_HEIGHT).toBe(675);
    expect(() => buildThumScreenshotUrl("example.com", { width: 99 })).toThrow(/100 through 800/);
    expect(() => buildThumScreenshotUrl("example.com", { crop: 99 })).toThrow(/100 through 2400/);
    expect(() => buildPageShotPreviewUrl("example.com", { width: 801 })).toThrow(/100 through 800/);
  });

  it("builds an ordered three-provider fallback chain", () => {
    const candidates = buildWebClipCaptureCandidates("https://example.com");
    expect(candidates.map((candidate) => candidate.provider))
      .toEqual(["thum", "microlink", "pageshot"]);
    expect(new Set(candidates.map((candidate) => candidate.url)).size).toBe(3);
  });

  it("persists the validated source and all fallbacks compactly", () => {
    const candidates = buildWebClipCaptureCandidates("https://www.example.com/articles/one");
    const selected = candidates[1];
    const content = buildWebClipContent("https://www.example.com/articles/one", {
      candidates,
      screenshotUrl: selected.url,
      screenshotAssetId: "asset-web-1",
      captureProvider: selected.provider,
    });

    expect(content).toMatchObject({
      domain: "example.com",
      title: "example.com",
      description: "Saved from the web",
      excerpt: "https://www.example.com/articles/one",
      image: selected.url,
      screenshotUrl: selected.url,
      captureProvider: "microlink",
      screenshotAssetId: "asset-web-1",
      url: "https://www.example.com/articles/one",
    });
    expect(content.screenshotCandidates).toEqual([
      selected.url,
      candidates[0].url,
      candidates[2].url,
    ]);
    expect(content.image.startsWith("data:")).toBe(false);
  });

  it("self-heals a legacy PageShot-only record by trying new providers first", () => {
    const legacy = {
      url: "https://example.com/",
      screenshotUrl: buildPageShotPreviewUrl("https://example.com/"),
    };
    const candidates = screenshotCandidatesForItem(legacy);
    expect(candidates[0].startsWith(THUM_SCREENSHOT_ENDPOINT)).toBe(true);
    expect(candidates[1].startsWith(MICROLINK_SCREENSHOT_ENDPOINT)).toBe(true);
    expect(candidates.at(-1).startsWith(PAGESHOT_PREVIEW_ENDPOINT)).toBe(true);
  });
});
