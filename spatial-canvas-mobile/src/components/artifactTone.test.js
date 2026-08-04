import { describe, expect, it, vi } from "vitest";
import {
  ARTIFACT_TONE_DARK,
  ARTIFACT_TONE_LIGHT,
  classifyRgbaPixels,
  computeCoverCrop,
  inspectIframeBottomTone,
  perceptualLuminance,
  sampleImageBottomTone,
} from "./artifactTone.js";

describe("artifact background tone", () => {
  it("uses perceptual luminance and visible alpha", () => {
    expect(perceptualLuminance(255, 255, 255)).toBeCloseTo(1, 5);
    expect(perceptualLuminance(0, 0, 0)).toBe(0);
    expect(perceptualLuminance(255, 255, 255)).toBeGreaterThan(perceptualLuminance(0, 90, 255));
    expect(perceptualLuminance(0, 0, 0, 0)).toBeCloseTo(1, 5);
  });

  it("classifies RGBA samples without letting a few text pixels dominate", () => {
    const mostlyWhite = new Uint8ClampedArray([
      255, 255, 255, 255,
      250, 250, 250, 255,
      248, 248, 248, 255,
      0, 0, 0, 255,
    ]);
    const dark = new Uint8ClampedArray([
      12, 18, 24, 255,
      20, 24, 29, 255,
      32, 35, 38, 255,
      255, 255, 255, 255,
    ]);
    expect(classifyRgbaPixels(mostlyWhite)).toBe(ARTIFACT_TONE_LIGHT);
    expect(classifyRgbaPixels(dark)).toBe(ARTIFACT_TONE_DARK);
    expect(classifyRgbaPixels(null, { fallback: ARTIFACT_TONE_DARK })).toBe(ARTIFACT_TONE_DARK);
  });

  it("computes the visible object-fit cover crop and honors object position", () => {
    const centered = computeCoverCrop({
      sourceWidth: 1600,
      sourceHeight: 900,
      containerWidth: 320,
      containerHeight: 220,
    });
    expect(centered).toMatchObject({ y: 0, height: 900 });
    expect(centered.width).toBeCloseTo(1309.09, 2);
    expect(centered.x).toBeCloseTo(145.45, 2);

    const top = computeCoverCrop({
      sourceWidth: 800,
      sourceHeight: 1200,
      containerWidth: 400,
      containerHeight: 200,
      positionY: 0,
    });
    expect(top).toMatchObject({ x: 0, y: 0, width: 800, height: 400, scale: 0.5 });
    expect(computeCoverCrop({ sourceWidth: 0, sourceHeight: 10, containerWidth: 10, containerHeight: 10 }))
      .toBeNull();
  });

  it("samples only the bottom of the visible image crop", () => {
    const drawImage = vi.fn();
    const getImageData = vi.fn(() => ({
      data: new Uint8ClampedArray([16, 18, 22, 255, 24, 28, 32, 255]),
    }));
    const image = {
      naturalWidth: 1600,
      naturalHeight: 900,
      clientWidth: 320,
      clientHeight: 220,
    };
    const tone = sampleImageBottomTone(image, {
      sampleWidth: 2,
      sampleHeight: 1,
      canvasFactory: () => ({ getContext: () => ({ drawImage, getImageData }) }),
    });
    expect(tone).toBe(ARTIFACT_TONE_DARK);
    expect(drawImage).toHaveBeenCalledOnce();
    const args = drawImage.mock.calls[0];
    expect(args[1]).toBeCloseTo(145.45, 2);
    expect(args[2]).toBeCloseTo(630, 2);
    expect(args[3]).toBeCloseTo(1309.09, 2);
    expect(args[4]).toBeCloseTo(270, 2);
  });

  it("falls back when an image canvas is tainted", () => {
    const tone = sampleImageBottomTone(
      { naturalWidth: 100, naturalHeight: 100, clientWidth: 100, clientHeight: 100 },
      {
        fallback: ARTIFACT_TONE_DARK,
        canvasFactory: () => ({
          getContext: () => ({
            drawImage: () => {},
            getImageData: () => { throw new DOMException("Tainted", "SecurityError"); },
          }),
        }),
      },
    );
    expect(tone).toBe(ARTIFACT_TONE_DARK);
  });

  it("inspects same-origin iframe backgrounds and SVG fills near the bottom", () => {
    const darkPanel = { namespaceURI: "http://www.w3.org/1999/xhtml" };
    const svgShape = { namespaceURI: "http://www.w3.org/2000/svg" };
    const documentObject = {
      documentElement: { clientWidth: 800, clientHeight: 600 },
      elementsFromPoint: vi.fn((x) => x < 400 ? [darkPanel] : [svgShape]),
      defaultView: {
        getComputedStyle: (element) => element === svgShape
          ? { backgroundColor: "rgba(0, 0, 0, 0)", fill: "rgb(25 30 35)" }
          : { backgroundColor: "rgb(18, 22, 28)", fill: "rgb(0, 0, 0)" },
      },
    };
    expect(inspectIframeBottomTone({ contentDocument: documentObject }))
      .toBe(ARTIFACT_TONE_DARK);
    expect(documentObject.elementsFromPoint).toHaveBeenCalledTimes(15);
  });

  it("uses light document backgrounds and safely handles cross-origin iframes", () => {
    const page = {};
    const lightDocument = {
      documentElement: { clientWidth: 800, clientHeight: 600 },
      elementsFromPoint: () => [page],
      defaultView: { getComputedStyle: () => ({ backgroundColor: "#fafafa", fill: "none" }) },
    };
    expect(inspectIframeBottomTone({ contentDocument: lightDocument })).toBe(ARTIFACT_TONE_LIGHT);

    const crossOriginFrame = {};
    Object.defineProperty(crossOriginFrame, "contentDocument", {
      get() { throw new DOMException("Blocked", "SecurityError"); },
    });
    expect(inspectIframeBottomTone(crossOriginFrame, { fallback: ARTIFACT_TONE_DARK }))
      .toBe(ARTIFACT_TONE_DARK);
  });

  it("composites percentage-alpha computed colors", () => {
    const overlay = {};
    const page = {};
    const documentObject = {
      documentElement: { clientWidth: 400, clientHeight: 300 },
      elementsFromPoint: () => [overlay, page],
      defaultView: {
        getComputedStyle: (element) => element === overlay
          ? { backgroundColor: "rgb(0 0 0 / 10%)", fill: "none" }
          : { backgroundColor: "rgb(255 255 255)", fill: "none" },
      },
    };
    expect(inspectIframeBottomTone({ contentDocument: documentObject }))
      .toBe(ARTIFACT_TONE_LIGHT);
  });
});
