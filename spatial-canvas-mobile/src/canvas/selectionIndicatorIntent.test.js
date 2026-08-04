import { describe, expect, it } from "vitest";
import {
  canRevealSelectionIndicators,
  SELECTION_INDICATOR_HIDE_DELAY_MS,
  shouldRevealSelectionIndicators,
} from "./selectionIndicatorIntent.js";

describe("selection indicator hover intent", () => {
  it("does not reveal controls before the item is active", () => {
    expect(canRevealSelectionIndicators({ active: false, pointerType: "mouse", buttons: 0 })).toBe(false);
  });

  it("reveals controls only for button-free hover on an active item", () => {
    expect(canRevealSelectionIndicators({ active: true, pointerType: "mouse", buttons: 0 })).toBe(true);
    expect(canRevealSelectionIndicators({ active: true, pointerType: "pen", buttons: 0 })).toBe(true);
    expect(canRevealSelectionIndicators({ active: true, pointerType: "mouse", buttons: 1 })).toBe(false);
    expect(canRevealSelectionIndicators({ active: true, pointerType: "touch", buttons: 0 })).toBe(false);
  });

  it("reveals immediately when selection activates under a stationary pointer", () => {
    expect(shouldRevealSelectionIndicators({
      active: true,
      pointerInside: true,
      pointerType: "mouse",
      buttons: 0,
    })).toBe(true);
  });

  it("does not synthesize hover intent outside the item or for touch", () => {
    expect(shouldRevealSelectionIndicators({
      active: true,
      pointerInside: false,
      pointerType: "mouse",
      buttons: 0,
    })).toBe(false);
    expect(shouldRevealSelectionIndicators({
      active: true,
      pointerInside: true,
      pointerType: "touch",
      buttons: 0,
    })).toBe(false);
  });

  it("uses the requested one-second leave delay", () => {
    expect(SELECTION_INDICATOR_HIDE_DELAY_MS).toBe(1000);
  });
});
