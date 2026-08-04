import { screenToWorld } from "./camera.js";
import { clamp } from "./geometry.js";

function pairMetrics(points) {
  if (!points || points.length < 2) return null;
  const [first, second] = points;
  return {
    center: {
      x: (first.x + second.x) / 2,
      y: (first.y + second.y) / 2,
    },
    distance: Math.max(1, Math.hypot(second.x - first.x, second.y - first.y)),
  };
}

/** Capture a stable world anchor for a two-finger camera gesture. */
export function beginTouchCameraGesture(camera, points) {
  const metrics = pairMetrics(points);
  if (!metrics) return null;
  return {
    startCamera: { ...camera },
    startDistance: metrics.distance,
    anchor: screenToWorld(metrics.center, camera),
  };
}

/**
 * Resolve simultaneous two-finger pan and pinch around the gesture centroid.
 * The world point under the starting centroid stays under the live centroid.
 */
export function updateTouchCameraGesture(
  gesture,
  points,
  { minZoom = 0.2, maxZoom = 2.2 } = {},
) {
  const metrics = pairMetrics(points);
  if (!gesture || !metrics) return null;
  const zoom = clamp(
    gesture.startCamera.zoom * (metrics.distance / gesture.startDistance),
    minZoom,
    maxZoom,
  );
  return {
    x: gesture.anchor.x - metrics.center.x / zoom,
    y: gesture.anchor.y - metrics.center.y / zoom,
    zoom,
  };
}
