import { visibleWorldRect } from "./camera.js";

function boundsForPoses(items) {
  if (!items.length) return null;
  const left = Math.min(...items.map((item) => item.pose.x));
  const top = Math.min(...items.map((item) => item.pose.y));
  const right = Math.max(...items.map((item) => item.pose.x + item.pose.width));
  const bottom = Math.max(...items.map((item) => item.pose.y + item.pose.height));
  return { x: left, y: top, width: right - left, height: bottom - top };
}

/**
 * Compute the one-time world-space translation used when a folder opens.
 *
 * The offset is intentionally captured at open time. Recomputing it after
 * every camera commit would re-center the children and make an infinite
 * nested canvas feel as though it snaps back after each pan.
 */
export function folderOpenOffset(members, camera, viewport) {
  const memberBounds = boundsForPoses(members);
  if (!memberBounds) return { x: 0, y: 0 };
  const visible = visibleWorldRect(camera, viewport);
  return {
    x: visible.x + (visible.width - memberBounds.width) / 2 - memberBounds.x,
    y: visible.y + (visible.height - memberBounds.height) / 2 - memberBounds.y,
  };
}

export function folderDisplayPose(pose, offset) {
  return {
    ...pose,
    x: pose.x + (offset?.x || 0),
    y: pose.y + (offset?.y || 0),
  };
}

export function folderCanonicalPose(pose, offset) {
  return {
    ...pose,
    x: pose.x - (offset?.x || 0),
    y: pose.y - (offset?.y || 0),
  };
}

export function folderLayout(members, offset) {
  return new Map(members.map((member) => [
    member.id,
    folderDisplayPose(member.pose, offset),
  ]));
}
