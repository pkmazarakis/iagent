/** Return the container action for a completed, movement-free item press. */
export function containerTapIntent({ isContainer, wasSoleSelected }) {
  if (!isContainer) return null;
  return wasSoleSelected ? "open" : "select";
}

