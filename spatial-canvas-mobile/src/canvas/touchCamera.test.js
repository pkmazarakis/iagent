import { describe, expect, it } from "vitest";
import { screenToWorld } from "./camera.js";
import { beginTouchCameraGesture, updateTouchCameraGesture } from "./touchCamera.js";

describe("two-finger camera gestures", () => {
  it("pans with a translated two-finger centroid", () => {
    const camera = { x: 100, y: 50, zoom: 2 };
    const gesture = beginTouchCameraGesture(camera, [
      { x: 100, y: 100 },
      { x: 200, y: 100 },
    ]);
    const next = updateTouchCameraGesture(gesture, [
      { x: 120, y: 130 },
      { x: 220, y: 130 },
    ]);
    expect(next).toEqual({ x: 90, y: 35, zoom: 2 });
  });

  it("pinches around the live centroid without moving its world anchor", () => {
    const camera = { x: 40, y: 20, zoom: 1 };
    const start = [
      { x: 100, y: 150 },
      { x: 200, y: 150 },
    ];
    const nextPoints = [
      { x: 50, y: 150 },
      { x: 250, y: 150 },
    ];
    const anchor = screenToWorld({ x: 150, y: 150 }, camera);
    const next = updateTouchCameraGesture(beginTouchCameraGesture(camera, start), nextPoints);
    expect(next.zoom).toBe(2);
    expect(screenToWorld({ x: 150, y: 150 }, next)).toEqual(anchor);
  });

  it("clamps extreme pinch zoom", () => {
    const camera = { x: 0, y: 0, zoom: 1 };
    const gesture = beginTouchCameraGesture(camera, [
      { x: 0, y: 0 },
      { x: 100, y: 0 },
    ]);
    const next = updateTouchCameraGesture(gesture, [
      { x: -1000, y: 0 },
      { x: 1100, y: 0 },
    ], { minZoom: 0.25, maxZoom: 3 });
    expect(next.zoom).toBe(3);
  });
});
