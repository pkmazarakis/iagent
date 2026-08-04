import { describe, expect, it } from "vitest";
import { CANVAS_SNAP_CONFIG } from "./snapConfig.js";

describe("canvas snap configuration", () => {
  it("uses a restrained capture radius and a 48ms precision dwell", () => {
    expect(CANVAS_SNAP_CONFIG).toEqual({
      threshold: 6,
      proximity: 220,
      engageVelocity: 0.24,
      releaseVelocity: 0.56,
      settleMs: 48,
      minWidth: 72,
      minHeight: 64,
    });
    expect(Object.isFrozen(CANVAS_SNAP_CONFIG)).toBe(true);
  });
});
