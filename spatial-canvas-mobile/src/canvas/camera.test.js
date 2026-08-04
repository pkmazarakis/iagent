import { describe, expect, it } from "vitest";
import {
  cameraFromRelativeTransform,
  cameraToFrameRect,
  cameraTransform,
  panCamera,
  relativeCameraTransform,
  renderOriginForCamera,
  screenToWorld,
  worldGeometryToRender,
  worldToScreen,
  zoomCameraAt,
} from "./camera.js";

describe("world-origin camera math", () => {
  it("round-trips world and screen coordinates", () => {
    const camera = { x: -45, y: 30, zoom: 0.75 };
    const world = { x: 420, y: 180 };
    expect(screenToWorld(worldToScreen(world, camera), camera)).toEqual(world);
  });

  it("pans in screen pixels independent of zoom", () => {
    const camera = { x: 100, y: 80, zoom: 2 };
    expect(panCamera(camera, { x: 40, y: -20 })).toEqual({ x: 80, y: 90, zoom: 2 });
  });

  it("keeps the world point under the cursor fixed while zooming", () => {
    const camera = { x: 40, y: -20, zoom: 1.5 };
    const cursor = { x: 300, y: 180 };
    const before = screenToWorld(cursor, camera);
    const next = zoomCameraAt(camera, cursor, 2.25);
    expect(screenToWorld(cursor, next)).toEqual(before);
  });

  it("produces the compositor transform used by the canvas world", () => {
    expect(cameraTransform({ x: 10, y: -5, zoom: 2 })).toBe(
      "translate3d(-20px, 10px, 0) scale(2)",
    );
  });

  it("recovers a camera from an interrupted live compositor transform", () => {
    const camera = { x: 912.5, y: -443.25, zoom: 1.37 };
    const origin = { x: 8192, y: -8192 };
    expect(cameraFromRelativeTransform(relativeCameraTransform(camera, origin), origin))
      .toEqual(camera);
  });

  it("rebases enormous world coordinates without changing their screen position", () => {
    const camera = { x: 1_000_000_000_123, y: -2_000_000_000_321, zoom: 1.75 };
    const item = { x: camera.x + 460, y: camera.y + 275, width: 200, height: 100 };
    const origin = renderOriginForCamera(camera);
    const localItem = worldGeometryToRender(item, origin);
    const transform = relativeCameraTransform(camera, origin);

    expect(Math.abs(localItem.x)).toBeLessThan(9000);
    expect(Math.abs(localItem.y)).toBeLessThan(9000);
    expect(localItem.x * transform.scale + transform.x).toBeCloseTo(460 * camera.zoom, 6);
    expect(localItem.y * transform.scale + transform.y).toBeCloseTo(275 * camera.zoom, 6);
  });

  it("centers initial origins and uses hysteresis at render-tile boundaries", () => {
    expect(renderOriginForCamera({ x: -1, y: -8193, zoom: 1 }, 8192)).toEqual({
      x: 0,
      y: -8192,
    });
    const origin = { x: 0, y: 0 };
    expect(renderOriginForCamera({ x: -0.01, y: 0, zoom: 1 }, 8192, origin)).toBe(origin);
    expect(renderOriginForCamera({ x: 0.01, y: 0, zoom: 1 }, 8192, origin)).toBe(origin);
    expect(renderOriginForCamera({ x: 7000, y: 0, zoom: 1 }, 8192, origin)).toEqual({ x: 8192, y: 0 });
    expect(renderOriginForCamera(
      { x: 3000, y: 0, zoom: 1 },
      8192,
      { x: 8192, y: 0 },
    )).toEqual({ x: 8192, y: 0 });
  });

  it("frames a selection with a single bounded camera transform", () => {
    const rect = { x: 800, y: -200, width: 400, height: 200 };
    const viewport = { width: 1000, height: 600 };
    const camera = cameraToFrameRect(rect, viewport, { padding: 100, maxZoom: 1.5 });
    expect(camera).toEqual({ x: 666.6666666666667, y: -300, zoom: 1.5 });
    const topLeft = worldToScreen({ x: 800, y: -200 }, camera);
    const bottomRight = worldToScreen({ x: 1200, y: 0 }, camera);
    expect(topLeft.x).toBeCloseTo(200, 8);
    expect(topLeft.y).toBeCloseTo(150, 8);
    expect(bottomRight.x).toBeCloseTo(800, 8);
    expect(bottomRight.y).toBeCloseTo(450, 8);
  });

  it("clamps focus zoom for tiny and enormous selections", () => {
    expect(cameraToFrameRect(
      { x: 0, y: 0, width: 10, height: 10 },
      { width: 1000, height: 600 },
    ).zoom).toBe(1.55);
    expect(cameraToFrameRect(
      { x: 0, y: 0, width: 100_000, height: 100_000 },
      { width: 1000, height: 600 },
    ).zoom).toBe(0.2);
  });
});
