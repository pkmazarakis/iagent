function overlapRatio(a, b) {
  const left = Math.max(a.x, b.x);
  const top = Math.max(a.y, b.y);
  const right = Math.min(a.x + a.width, b.x + b.width);
  const bottom = Math.min(a.y + a.height, b.y + b.height);
  if (right <= left || bottom <= top) return 0;
  const intersection = (right - left) * (bottom - top);
  return intersection / Math.max(1, Math.min(
    a.width * a.height,
    b.width * b.height,
  ));
}

/**
 * Pick the topmost card under a dropped card inside one canvas scope.
 * Scope is null for the board and a folder id for its nested canvas.
 */
export function findStackDropTarget({
  draggedId,
  droppedPose,
  items,
  scopeId = null,
  minimumOverlap = 0.34,
}) {
  if (!droppedPose) return null;
  const center = {
    x: droppedPose.x + droppedPose.width / 2,
    y: droppedPose.y + droppedPose.height / 2,
  };

  return items
    .filter((candidate) => candidate.id !== draggedId)
    .filter((candidate) => (candidate.stackId || null) === scopeId)
    .filter((candidate) => center.x >= candidate.pose.x
      && center.x <= candidate.pose.x + candidate.pose.width
      && center.y >= candidate.pose.y
      && center.y <= candidate.pose.y + candidate.pose.height)
    .map((candidate) => ({ candidate, overlap: overlapRatio(droppedPose, candidate.pose) }))
    .filter(({ overlap }) => overlap >= minimumOverlap)
    .sort((a, b) => (b.candidate.z || 0) - (a.candidate.z || 0))[0]?.candidate || null;
}
