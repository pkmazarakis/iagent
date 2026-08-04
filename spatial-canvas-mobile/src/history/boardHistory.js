export const HISTORY_LIMIT = 80;

export function boardHistorySnapshot(items, selectedIds = []) {
  return {
    // Items are immutable throughout the app, so retaining the array reference
    // is both safe and dramatically cheaper than serialising the board.
    items,
    selectedIds: [...selectedIds],
  };
}

export function appendHistory(stack, snapshot, limit = HISTORY_LIMIT) {
  const next = [...stack, snapshot];
  return next.length > limit ? next.slice(next.length - limit) : next;
}

export function sanitizeHistorySnapshot(snapshot) {
  const ids = new Set(snapshot.items.map((item) => item.id));
  return {
    items: snapshot.items,
    selectedIds: snapshot.selectedIds.filter((id) => ids.has(id)),
  };
}
