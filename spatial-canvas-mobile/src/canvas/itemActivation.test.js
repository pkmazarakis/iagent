import { describe, expect, it } from "vitest";
import { containerTapIntent } from "./itemActivation.js";

describe("container tap activation", () => {
  it("uses the first click to select a folder", () => {
    expect(containerTapIntent({ isContainer: true, wasSoleSelected: false })).toBe("select");
  });

  it("opens a folder only when it was already the sole selection", () => {
    expect(containerTapIntent({ isContainer: true, wasSoleSelected: true })).toBe("open");
  });

  it("does not intercept non-container item taps", () => {
    expect(containerTapIntent({ isContainer: false, wasSoleSelected: true })).toBeNull();
  });
});

