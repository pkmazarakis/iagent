export const SELECTION_INDICATOR_HIDE_DELAY_MS = 1000;

/** Resize affordances are a hover-only second step after item selection. */
export function canRevealSelectionIndicators({ active, pointerType, buttons = 0 }) {
  return Boolean(active && pointerType !== "touch" && buttons === 0);
}

/** Re-evaluate hover intent when selection activates under a stationary pointer. */
export function shouldRevealSelectionIndicators({
  active,
  pointerInside,
  pointerType,
  buttons = 0,
}) {
  return Boolean(pointerInside && canRevealSelectionIndicators({
    active,
    pointerType,
    buttons,
  }));
}
