import { describe, expect, it } from "vitest";
import { edgeScrollVelocity, revealDelta } from "./textSelection.js";

describe("editor text-selection scrolling", () => {
  it("does not auto-scroll while the pointer is away from the edge", () => {
    const bounds = { top: 100, bottom: 700 };
    expect(edgeScrollVelocity(400, bounds)).toBe(0);
    expect(edgeScrollVelocity(120, bounds)).toBeLessThan(0);
    expect(edgeScrollVelocity(680, bounds)).toBeGreaterThan(0);
  });

  it("reveals a row only after it crosses the visible editor boundary", () => {
    const viewport = { top: 100, bottom: 700 };
    expect(revealDelta({ top: 220, bottom: 260 }, viewport)).toBe(0);
    expect(revealDelta({ top: 80, bottom: 120 }, viewport)).toBe(-20);
    expect(revealDelta({ top: 680, bottom: 725 }, viewport)).toBe(25);
  });
});
