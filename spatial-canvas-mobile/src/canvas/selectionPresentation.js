export const SELECTION_ORIGIN = Object.freeze({
  ORDINARY: "ordinary",
  MARQUEE: "marquee",
});

export function shouldScaleSelection({ selected, selectedCount, origin }) {
  return Boolean(
    selected
    && selectedCount > 1
    && origin === SELECTION_ORIGIN.MARQUEE,
  );
}
