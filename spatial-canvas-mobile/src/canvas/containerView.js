export const CONTAINER_VIEW_MODE = Object.freeze({
  INLINE: "inline",
  CANVAS: "canvas",
});

export function isContainerKind(value) {
  const kind = typeof value === "string" ? value : value?.kind;
  return kind === "stack" || kind === "folder";
}

/**
 * Small, deterministic state machine for the two-stage folder interaction.
 * Keeping this contract pure makes rapid taps/back presses idempotent and
 * prevents the dedicated canvas from existing without its inline preview.
 */
export function transitionContainerView(state, event) {
  switch (event?.type) {
    case "open-inline":
      return event.id ? { id: event.id, mode: CONTAINER_VIEW_MODE.INLINE } : state;
    case "expand-canvas":
      if (!state?.id || (event.id && event.id !== state.id)) return state;
      return { id: state.id, mode: CONTAINER_VIEW_MODE.CANVAS };
    case "back":
      if (!state) return null;
      return state.mode === CONTAINER_VIEW_MODE.CANVAS
        ? { id: state.id, mode: CONTAINER_VIEW_MODE.INLINE }
        : null;
    case "close":
      return null;
    case "remove":
      return state?.id === event.id ? null : state;
    default:
      return state;
  }
}
