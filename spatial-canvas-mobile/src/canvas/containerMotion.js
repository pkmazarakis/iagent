const COLLAPSED_LAYER_LIMIT = 4;

export function visibleCollapsedMemberIds(container, limit = COLLAPSED_LAYER_LIMIT) {
  return (container?.content?.memberIds || []).slice(-Math.max(0, limit));
}

export function collapsedContainerMemberTarget(member, container, memberIndex) {
  const memberIds = container?.content?.memberIds || [];
  const memberCount = memberIds.length;
  const firstVisible = Math.max(0, memberCount - COLLAPSED_LAYER_LIMIT);
  const visibleIndex = Math.max(0, memberIndex - firstVisible);
  const visible = memberIndex >= firstVisible;
  const availableWidth = Math.max(1, container.pose.width - 24);
  const availableHeight = Math.max(1, container.pose.height - 22);
  const memberScale = Math.min(
    0.82,
    availableWidth / Math.max(1, member.pose.width),
    availableHeight / Math.max(1, member.pose.height),
  );
  const renderedWidth = member.pose.width * memberScale;
  const renderedHeight = member.pose.height * memberScale;

  return {
    x: container.pose.x + (container.pose.width - renderedWidth) / 2 + visibleIndex * 4,
    y: container.pose.y - 13 - visibleIndex * 3,
    width: member.pose.width,
    height: member.pose.height,
    opacity: visible ? 1 : 0,
    scale: memberScale,
    zIndex: Math.max(0, container.z - COLLAPSED_LAYER_LIMIT + visibleIndex),
    interactive: false,
  };
}

function poseChanged(before, after) {
  return before.x !== after.x
    || before.y !== after.y
    || before.width !== after.width
    || before.height !== after.height
    || before.rotation !== after.rotation;
}

/**
 * Commit retained geometry once per completed gesture.
 *
 * During a folder drag only the shell participates in snapping. At drop, its
 * exact snapped translation is applied to every canonical member in the same
 * immutable transaction. Explicit member patches win, preventing double
 * translation during mixed multi-selection gestures.
 */
export function applyGeometryPatches(
  items,
  patches,
  { translateFolderMembers = false, now = Date.now() } = {},
) {
  const patchMap = patches instanceof Map ? patches : new Map(patches || []);
  const folderDeltas = new Map();

  if (translateFolderMembers) {
    for (const item of items) {
      if (item.kind !== "folder" && item.kind !== "stack") continue;
      const patch = patchMap.get(item.id);
      if (!patch) continue;
      const nextX = patch.x ?? item.pose.x;
      const nextY = patch.y ?? item.pose.y;
      const delta = { x: nextX - item.pose.x, y: nextY - item.pose.y };
      if (delta.x || delta.y) folderDeltas.set(item.id, delta);
    }
  }

  let changed = false;
  const next = items.map((item) => {
    const explicitPatch = patchMap.get(item.id);
    const folderDelta = !explicitPatch && item.stackId
      ? folderDeltas.get(item.stackId)
      : null;
    if (!explicitPatch && !folderDelta) return item;

    const nextPose = explicitPatch
      ? { ...item.pose, ...explicitPatch }
      : {
          ...item.pose,
          x: item.pose.x + folderDelta.x,
          y: item.pose.y + folderDelta.y,
        };
    if (!poseChanged(item.pose, nextPose)) return item;
    changed = true;
    return { ...item, pose: nextPose, updatedAt: now };
  });

  return changed ? next : items;
}
