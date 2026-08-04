import { describe, expect, it } from "vitest";
import { wheelRoutingMode } from "./wheelRouting.js";

describe("wheel routing", () => {
  it("preserves native scrolling inside the retained detail viewer", () => {
    expect(wheelRoutingMode({ detailOpen: true, withinDetailScrollRegion: true })).toBe("native");
  });

  it("blocks canvas movement behind a detail while leaving board wheels to the canvas", () => {
    expect(wheelRoutingMode({ detailOpen: true, withinDetailScrollRegion: false })).toBe("blocked");
    expect(wheelRoutingMode({ detailOpen: false, withinDetailScrollRegion: false })).toBe("canvas");
  });
});
