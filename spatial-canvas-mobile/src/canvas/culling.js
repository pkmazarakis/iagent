import { visibleWorldRect } from "./camera.js";
import { rectsIntersect } from "./geometry.js";

/**
 * Return the small retained scene that should be mounted for this viewport.
 * `overscan` is expressed in viewport widths/heights on each side.
 */
export function cullItemsForViewport({
  items,
  camera,
  viewport,
  pageIndex = null,
  selectedIds = [],
  pinSelected = true,
  pinnedIds = [],
  detailId = null,
  pinDetail = true,
  stacks = new Map(),
  itemById = null,
  expandedStackId = null,
  transitionStackId = null,
  expandedGroupOffset = null,
  transitionGroupOffset = null,
  overscan = 0.5,
  minimumOverscan = 0,
}) {
  const visible = visibleWorldRect(camera, viewport);
  const overscanX = Math.max(visible.width * overscan, minimumOverscan);
  const overscanY = Math.max(visible.height * overscan, minimumOverscan);
  const bounds = {
    x: visible.x - overscanX,
    y: visible.y - overscanY,
    width: visible.width + overscanX * 2,
    height: visible.height + overscanY * 2,
  };
  const selected = new Set(pinSelected ? selectedIds : []);
  for (const id of pinnedIds) selected.add(id);

  if (pageIndex) {
    const retainedItems = pageIndex.query({
      viewport: visible,
      overscan: {
        x: overscanX,
        y: overscanY,
      },
      pinnedIds: [
        ...selected,
        ...(!pinDetail || detailId == null ? [] : [detailId]),
      ],
      // Keep every item in the retained page window mounted. If the live
      // camera moves inside the same page range, those nodes are already
      // available at the leading edge and no React render is needed.
      exact: false,
    });
    const filtered = retainedItems.filter((item) => !item.stackId
      || item.stackId === expandedStackId
      || item.stackId === transitionStackId
      || selected.has(item.id)
      || (pinDetail && item.id === detailId));
    const retainedIds = new Set(filtered.map((item) => item.id));
    const retainedParents = new Map();
    for (const candidate of filtered) {
      if (candidate.kind === "stack" || candidate.kind === "folder") {
        retainedParents.set(candidate.id, candidate);
      }
    }
    for (const id of [expandedStackId, transitionStackId]) {
      const parent = id ? stacks.get(id) : null;
      if (parent) retainedParents.set(parent.id, parent);
    }
    if (!retainedParents.size) return filtered;

    // App passes its memoized id map, keeping camera-page queries O(visible)
    // instead of rebuilding a map across the entire infinite board.
    const lookup = itemById || new Map(items.map((item) => [item.id, item]));
    const appendMember = (id) => {
      if (retainedIds.has(id)) return;
      const member = lookup.get(id);
      if (!member) return;
      retainedIds.add(id);
      filtered.push(member);
    };

    const appendVisibleTranslatedMembers = (parent, offset) => {
      if (!offset || (!offset.x && !offset.y)) return;
      const translated = pageIndex.query({
        viewport: {
          x: visible.x - offset.x,
          y: visible.y - offset.y,
          width: visible.width,
          height: visible.height,
        },
        overscan: { x: overscanX, y: overscanY },
        exact: false,
      });
      for (const candidate of translated) {
        if (candidate.stackId === parent.id) appendMember(candidate.id);
      }
    };

    // A collapsed stack is made from its real child surfaces, not synthetic
    // colored layers. Active groups keep only their destination pages plus the
    // four real source layers, so large folders never defeat pagination.
    for (const parent of retainedParents.values()) {
      const memberIds = parent.content?.memberIds || [];
      if (parent.id === expandedStackId || parent.id === transitionStackId) {
        // During inline <-> dedicated-canvas motion both endpoint page ranges
        // stay mounted. This prevents a translated child from disappearing
        // before it reaches its canonical inline position (or vice versa).
        if (parent.id === expandedStackId) {
          appendVisibleTranslatedMembers(parent, expandedGroupOffset);
        }
        if (parent.id === transitionStackId) {
          appendVisibleTranslatedMembers(parent, transitionGroupOffset);
        }
        memberIds.slice(-4).forEach(appendMember);
      } else if (retainedIds.has(parent.id)) {
        memberIds.slice(-4).forEach(appendMember);
      }
    }
    return filtered;
  }

  return items.filter((item) => {
    if (selected.has(item.id) || (pinDetail && item.id === detailId)) return true;
    const stack = item.stackId ? stacks.get(item.stackId) : null;
    const pose = stack && expandedStackId !== item.stackId ? stack.pose : item.pose;
    return rectsIntersect(pose, bounds);
  });
}
