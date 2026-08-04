import { describe, expect, it } from "vitest";
import { percentile, summarizeFrameIntervals } from "./frameProbe.js";

describe("frame performance probe", () => {
  it("computes stable percentile values", () => {
    expect(percentile([20, 10, 40, 30], 0.5)).toBe(20);
    expect(percentile([], 0.95)).toBe(0);
  });

  it("reports long and dropped frames against a 60 Hz budget", () => {
    const summary = summarizeFrameIntervals([16, 17, 34, 50], 117);
    expect(summary.frames).toBe(5);
    expect(summary.longFrames).toBe(2);
    expect(summary.droppedFrames).toBe(3);
    expect(summary.maxFrameMs).toBe(50);
  });

  it("derives frame rate from observed frame intervals, not probe setup time", () => {
    const summary = summarizeFrameIntervals([8, 8, 8, 8], 120);
    expect(summary.averageFps).toBe(125);
  });
});
