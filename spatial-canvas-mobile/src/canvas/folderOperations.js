function membershipLabel(item, count) {
  if (item.kind === "folder") return `${count} ${count === 1 ? "item" : "items"}`;
  return `${count} collected ${count === 1 ? "thing" : "things"}`;
}

function isContainer(item) {
  return item?.kind === "folder" || item?.kind === "stack";
}

/**
 * Move leaf items between stacks/folders as one immutable transaction.
 *
 * Membership lives in two places (`item.stackId` and the container's
 * `content.memberIds`). Updating both in one pure pass keeps undo/redo and
 * persistence snapshots internally consistent.
 */
export function moveItemsToContainer(items, itemIds, targetId, now = Date.now()) {
  const requested = new Set(itemIds || []);
  const byId = new Map(items.map((item) => [item.id, item]));
  const target = targetId ? byId.get(targetId) : null;
  if (targetId && !isContainer(target)) return items;

  const movable = items.filter((item) => requested.has(item.id) && !isContainer(item));
  if (!movable.length) return items;
  const movableIds = new Set(movable.map((item) => item.id));
  const affectedContainers = new Set(movable.map((item) => item.stackId).filter(Boolean));
  if (targetId) affectedContainers.add(targetId);

  let changed = false;
  const next = items.map((item) => {
    if (movableIds.has(item.id)) {
      const nextStackId = targetId || null;
      if ((item.stackId || null) === nextStackId) return item;
      changed = true;
      return { ...item, stackId: nextStackId, updatedAt: now };
    }

    if (!affectedContainers.has(item.id) || !isContainer(item)) return item;
    const previousMembers = item.content?.memberIds || [];
    const retained = previousMembers.filter((id) => !movableIds.has(id));
    const memberIds = item.id === targetId
      ? [...new Set([...retained, ...movableIds])]
      : retained;
    if (memberIds.length === previousMembers.length
      && memberIds.every((id, index) => id === previousMembers[index])) return item;
    changed = true;
    return {
      ...item,
      content: {
        ...item.content,
        memberIds,
        subtitle: membershipLabel(item, memberIds.length),
      },
      updatedAt: now,
    };
  });

  return changed ? next : items;
}

export function selectionContainerId(items, itemIds) {
  const requested = new Set(itemIds || []);
  const selected = items.filter((item) => requested.has(item.id) && !isContainer(item));
  if (!selected.length) return null;
  const first = selected[0].stackId || null;
  return selected.every((item) => (item.stackId || null) === first) ? first : null;
}

export function eligibleFolderMemberIds(items, itemIds) {
  const requested = new Set(itemIds || []);
  return items
    .filter((item) => requested.has(item.id) && !isContainer(item))
    .map((item) => item.id);
}
