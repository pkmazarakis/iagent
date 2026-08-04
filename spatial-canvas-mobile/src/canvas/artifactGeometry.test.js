import { describe, expect, it } from "vitest";
import { leadingEdgeCoverFrame, leadingEdgeCoverScale } from "./artifactGeometry.js";

describe("artifact cover geometry", () => {
  it.each([
    [270, 340, 816, 1056],
    [360, 220, 960, 540],
    [360, 260, 1100, 760],
    [320, 220, 800, 550],
    [1440, 900, 960, 540],
    [390, 780, 800, 550],
  ])("covers %sx%s from a leading-edge anchored %sx%s surface", (width, height, baseWidth, baseHeight) => {
    const frame = leadingEdgeCoverFrame(width, height, baseWidth, baseHeight);
    expect(frame.x).toBe(0);
    expect(frame.y).toBe(0);
    expect(frame.renderedWidth).toBeGreaterThanOrEqual(width);
    expect(frame.renderedHeight).toBeGreaterThanOrEqual(height);
  });

  it("returns a safe minimum for invalid geometry", () => {
    expect(leadingEdgeCoverScale(0, 100, 800, 550)).toBe(0.04);
  });
});
