/** Return true when an item belongs to the active folder inspection scope. */
export function isStackInspectionItem(item, expandedStackId) {
  if (!item || !expandedStackId) return false;
  return item.id === expandedStackId || item.stackId === expandedStackId;
}
