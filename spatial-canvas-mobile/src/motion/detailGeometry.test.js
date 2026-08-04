import { describe, expect, it } from "vitest";
import {
  centeredDetailGeometry,
  compositorDetailSource,
  detailBackdropOpacity,
  DETAIL_BACKDROP_KEYFRAMES,
  DETAIL_GEOMETRY_TRANSITION,
  foldSelectionScaleIntoGeometry,
  collapsedDetailGeometry,
  expandedDetailGeometry,
  fullscreenItemGeometry,
  fullscreenReaderGeometry,
  itemViewportRect,
  scaledGeometryBounds,
} from "./detailGeometry.js";

describe("detail transition geometry", () => {
  it("uses a deterministic non-overshooting bounds tween", () => {
    expect(DETAIL_GEOMETRY_TRANSITION).toEqual({
      type: "tween",
      duration: 0.58,
      ease: [0.22, 1, 0.36, 1],
    });
  });

  it("centers one source-sized surface with a uniform scale", () => {
    const source = { x: 140, y: 90, width: 240, height: 320 };
    const camera = { x: -320, y: 180, zoom: 0.5 };
    const viewport = { width: 1280, height: 720 };
    const target = centeredDetailGeometry(source, camera, viewport, {
      horizontalInset: 64,
      verticalInset: 48,
      maximumWidth: 760,
    });

    expect(target.width).toBe(source.width);
    expect(target.height).toBe(source.height);
    expect(target.scale).toBeCloseTo(3.9, 8);
    expect((target.x - camera.x) * camera.zoom + source.width * target.scale * camera.zoom / 2)
      .toBeCloseTo(viewport.width / 2, 8);
    expect((target.y - camera.y) * camera.zoom + source.height * target.scale * camera.zoom / 2)
      .toBeCloseTo(viewport.height / 2, 8);
  });

  it("fits portrait and image surfaces without changing their aspect ratio", () => {
    const cases = [
      [{ width: 260, height: 420 }, { width: 390, height: 844 }, "document"],
      [{ width: 480, height: 300 }, { width: 1440, height: 900 }, "image"],
    ];

    for (const [source, viewport, kind] of cases) {
      const target = centeredDetailGeometry(source, { x: 0, y: 0, zoom: 1 }, viewport, { kind });
      expect(target.width / target.height).toBeCloseTo(source.width / source.height, 10);
      expect(target.width * target.scale).toBeLessThanOrEqual(viewport.width + 0.001);
      expect(target.height * target.scale).toBeLessThanOrEqual(viewport.height + 0.001);
    }
  });

  it("maps the backdrop from the measured reference and reverses exactly", () => {
    expect(DETAIL_BACKDROP_KEYFRAMES).toEqual([
      [0, 0],
      [0.279, 0.534],
      [0.883, 0.968],
      [1, 1],
    ]);
    expect(detailBackdropOpacity(0)).toBe(0);
    expect(detailBackdropOpacity(0.279)).toBeCloseTo(0.534, 8);
    expect(detailBackdropOpacity(0.883)).toBeCloseTo(0.968, 8);
    expect(detailBackdropOpacity(1)).toBe(1);
    expect(detailBackdropOpacity(0.42)).toBeGreaterThan(detailBackdropOpacity(0.279));
    expect(detailBackdropOpacity(0.42)).toBeLessThan(detailBackdropOpacity(0.883));
  });

  it("folds centered selection emphasis into an identical outer visual rect", () => {
    const source = { x: 420, y: 440, width: 285, height: 175, scale: 1 };
    const folded = foldSelectionScaleIntoGeometry(source, 1.1);
    expect(folded).toEqual({
      x: 405.75,
      y: 431.25,
      width: 285,
      height: 175,
      scale: 1.1,
    });
    expect(folded.x).toBe(source.x - source.width * 0.05);
    expect(folded.y).toBe(source.y - source.height * 0.05);
  });

  it("folds the live outer scale into fullscreen compositor source bounds", () => {
    expect(scaledGeometryBounds({ x: 40, y: 55, width: 180, height: 240, scale: 1.075 }))
      .toEqual({ x: 40, y: 55, width: 193.5, height: 258 });
  });

  it("projects the latest item pose through the live camera", () => {
    const item = { pose: { x: 100, y: 80, width: 300, height: 200 }, style: { cornerRadius: 16 } };
    expect(itemViewportRect(item, { x: 20, y: 30, zoom: 0.75 }, { x: 140, y: 90, width: 320, height: 220 })).toEqual({
      x: 90,
      y: 45,
      width: 240,
      height: 165,
      radius: 12,
    });
  });

  it("maps the closing sheet directly onto the item rectangle", () => {
    const viewport = { width: 1280, height: 720 };
    const rect = { x: 84, y: 67, width: 240, height: 216, radius: 12 };
    expect(collapsedDetailGeometry(rect, viewport)).toEqual({
      x: 84,
      y: 67,
      width: 240,
      height: 216,
      borderRadius: 12,
      opacity: 1,
    });
  });

  it("covers the source with uniform scale and clips only the surplus axis", () => {
    const source = { x: 120, y: 80, width: 240, height: 320 };
    const destination = { x: 0, y: 0, width: 1280, height: 720 };
    const flip = compositorDetailSource(source, destination);
    expect(flip.scale).toBeCloseTo(320 / 720, 8);
    expect((flip.width - flip.clipRight) * flip.scale).toBeCloseTo(240, 8);
    expect((flip.height - flip.clipBottom) * flip.scale).toBeCloseTo(320, 8);
  });

  it("expands with real viewport geometry and no content scaling", () => {
    expect(expandedDetailGeometry({ width: 390, height: 844 })).toEqual({
      x: 0,
      y: 0,
      width: 390,
      height: 844,
      borderRadius: 0,
      opacity: 1,
    });
  });

  it("expresses fullscreen bounds in the retained item's world coordinate system", () => {
    expect(fullscreenItemGeometry(
      { x: -320, y: 180, zoom: 0.5 },
      { width: 390, height: 844 },
    )).toEqual({
      x: -320,
      y: 180,
      width: 780,
      height: 1688,
      opacity: 1,
      scale: 1,
    });
  });

  it("centers an authored reader at a stable screen width and width-led FLIP ratio", () => {
    const source = { x: 100, y: 80, width: 240, height: 320 };
    const camera = { x: -320, y: 180, zoom: 0.5 };
    const viewport = { width: 1280, height: 720 };
    const target = fullscreenReaderGeometry(source, camera, viewport);

    expect(target.width).toBe(1080);
    expect(target.height).toBe(1440);
    expect((target.x - camera.x) * camera.zoom + target.width * camera.zoom / 2)
      .toBe(viewport.width / 2);
    expect(source.width / target.width).toBeGreaterThanOrEqual(source.height / target.height);
  });

  it("preserves the exact authored document scale at both FLIP endpoints", () => {
    for (const zoom of [0.2, 0.5, 1, 2.2]) {
      const source = { x: 220, y: 140, width: 260, height: 340, scale: 1 };
      const target = fullscreenReaderGeometry(
        source,
        { x: 0, y: 0, zoom },
        { width: 1440, height: 900 },
      );
      const flip = compositorDetailSource(scaledGeometryBounds(source), target);
      const destinationDocumentScale = target.width / 680;
      const boardDocumentScale = source.width / 680;

      expect(flip.scale * destinationDocumentScale).toBeCloseTo(boardDocumentScale, 10);
    }
  });

  it("moves authored glyph anchors on one straight reversible path", () => {
    const source = { x: 190, y: 110, width: 250, height: 330, scale: 1 };
    const target = fullscreenReaderGeometry(
      source,
      { x: 0, y: 0, zoom: 0.65 },
      { width: 1375, height: 931 },
    );
    const flip = compositorDetailSource(scaledGeometryBounds(source), target);
    const innerScale = target.width / 680;

    for (const point of [{ x: 24, y: 72 }, { x: 170, y: 280 }, { x: 620, y: 760 }]) {
      const start = {
        x: flip.x + flip.scale * innerScale * point.x,
        y: flip.y + flip.scale * innerScale * point.y,
      };
      const end = {
        x: target.x + innerScale * point.x,
        y: target.y + innerScale * point.y,
      };
      for (const progress of [0, 0.25, 0.5, 0.75, 1]) {
        const outerX = flip.x + (target.x - flip.x) * progress;
        const outerY = flip.y + (target.y - flip.y) * progress;
        const outerScale = flip.scale + (1 - flip.scale) * progress;
        const sample = {
          x: outerX + outerScale * innerScale * point.x,
          y: outerY + outerScale * innerScale * point.y,
        };
        expect(sample.x).toBeCloseTo(start.x + (end.x - start.x) * progress, 10);
        expect(sample.y).toBeCloseTo(start.y + (end.y - start.y) * progress, 10);
      }
    }
  });
});
