import { describe, expect, it, vi } from "vitest";
import { screenToWorld } from "./camera.js";
import { createCanvasInteractionController } from "./interactions.js";

function harness(initial = {}) {
  let state = {
    camera: { x: 0, y: 0, zoom: 1 },
    items: [],
    selectedIds: [],
    ...initial,
  };
  let nextFrame = 1;
  let frameTime = 0;
  const frames = new Map();
  const callbacks = {
    onCameraChange: vi.fn((camera) => {
      state = { ...state, camera };
    }),
    onItemsChange: vi.fn((changes) => {
      const byId = new Map(changes.map((change) => [change.id, change]));
      state = {
        ...state,
        items: state.items.map((item) => ({ ...item, ...(byId.get(item.id) ?? {}) })),
      };
    }),
    onSelectionChange: vi.fn((selectedIds) => {
      state = { ...state, selectedIds };
    }),
    onMarqueeChange: vi.fn(),
    onSnapChange: vi.fn(),
    onHaptic: vi.fn(),
    onInteractionChange: vi.fn(),
  };
  const controller = createCanvasInteractionController({
    getSnapshot: () => state,
    ...callbacks,
    requestFrame: (callback) => {
      const id = nextFrame++;
      frames.set(id, callback);
      return id;
    },
    cancelFrame: (id) => frames.delete(id),
  });

  return {
    controller,
    callbacks,
    getState: () => state,
    frame(step = 16) {
      frameTime += step;
      const pending = [...frames.values()];
      frames.clear();
      pending.forEach((callback) => callback(frameTime));
    },
    frameCount: () => frames.size,
  };
}

describe("canvas interaction controller", () => {
  it("coalesces background pan moves to one update per frame", () => {
    const test = harness({ camera: { x: 10, y: 20, zoom: 2 } });
    test.controller.beginPan({ point: { x: 100, y: 100 } });
    test.controller.move({ x: 110, y: 120 });
    test.controller.move({ x: 135, y: 150 });

    expect(test.frameCount()).toBe(1);
    expect(test.callbacks.onCameraChange).not.toHaveBeenCalled();
    test.frame();
    expect(test.getState().camera).toEqual({ x: -7.5, y: -5, zoom: 2 });
  });

  it("maps two-finger wheel deltas to native-feeling world-space pan", () => {
    const test = harness({ camera: { x: 10, y: 20, zoom: 2 } });
    test.controller.wheelPan({ deltaX: 40, deltaY: 60 });
    test.frame();
    expect(test.getState().camera).toEqual({ x: 30, y: 50, zoom: 2 });
  });

  it("batches cursor-centered wheel zoom", () => {
    const test = harness({ camera: { x: 40, y: -20, zoom: 1.5 } });
    const cursor = { x: 300, y: 180 };
    const before = screenToWorld(cursor, test.getState().camera);
    test.controller.wheelZoom({ point: cursor, deltaY: -100 });
    test.frame();
    expect(screenToWorld(cursor, test.getState().camera)).toEqual(before);
  });

  it("drags the live selection in world units", () => {
    const test = harness({
      camera: { x: 0, y: 0, zoom: 2 },
      selectedIds: ["a", "b"],
      items: [
        { id: "a", x: 10, y: 10, width: 50, height: 50 },
        { id: "b", x: 100, y: 30, width: 50, height: 50 },
      ],
    });
    test.controller.beginDrag({ point: { x: 100, y: 100 }, itemId: "a" });
    test.controller.move({ x: 120, y: 140 });
    test.frame();
    expect(test.getState().items).toMatchObject([
      { id: "a", x: 20, y: 30 },
      { id: "b", x: 110, y: 50 },
    ]);
  });

  it("publishes live drag geometry before the gesture-end commit signal", () => {
    const test = harness({
      selectedIds: ["a"],
      items: [{ id: "a", x: 0, y: 0, width: 50, height: 50 }],
    });
    test.controller.beginDrag({ point: { x: 10, y: 10 }, itemId: "a" });
    test.controller.move({ x: 40, y: 55 });
    test.frame();

    expect(test.callbacks.onItemsChange).toHaveBeenCalledWith(
      [{ id: "a", x: 30, y: 45 }],
      { source: "drag", phase: "update" },
    );
    expect(test.callbacks.onInteractionChange).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: "drag", phase: "end" }),
    );

    test.controller.end();
    expect(test.callbacks.onInteractionChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ type: "drag", phase: "end" }),
    );
  });

  it("does not emit a zero-distance drag update for a click", () => {
    const test = harness({
      selectedIds: ["a"],
      items: [{ id: "a", x: 0, y: 0, width: 50, height: 50 }],
    });
    test.controller.beginDrag({ point: { x: 10, y: 10 }, itemId: "a" });
    test.controller.end();
    expect(test.callbacks.onItemsChange).not.toHaveBeenCalled();
  });

  it("keeps fast dragging direct, then snaps after a 48ms low-speed dwell", () => {
    const test = harness({
      items: [
        { id: "a", x: 0, y: 20, width: 100, height: 80 },
        { id: "b", x: 150, y: 0, width: 80, height: 140 },
      ],
    });
    test.controller.beginDrag({ point: { x: 0, y: 0 }, itemId: "a" });
    test.controller.move({ x: 47, y: 0, time: 0 });
    test.frame();

    expect(test.getState().items[0]).toMatchObject({ x: 47, y: 20 });
    expect(test.callbacks.onSnapChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ guides: [] }),
    );

    test.controller.move({ x: 48, y: 0, time: 16 });
    test.frame();
    expect(test.getState().items[0]).toMatchObject({ x: 48, y: 20 });

    test.controller.move({ x: 49, y: 0, time: 63 });
    test.frame();

    expect(test.getState().items[0]).toMatchObject({ x: 49, y: 20 });
    expect(test.callbacks.onSnapChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ guides: [] }),
    );

    test.controller.move({ x: 49, y: 0, time: 64 });
    test.frame();

    expect(test.getState().items[0]).toMatchObject({ x: 50, y: 20 });
    expect(test.callbacks.onSnapChange).toHaveBeenLastCalledWith(
      expect.objectContaining({
        highlightedIds: ["b"],
        guides: [expect.objectContaining({ axis: "x", position: 150 })],
      }),
    );
    expect(test.callbacks.onHaptic).toHaveBeenCalledWith(
      expect.objectContaining({ type: "snap-engage", axis: "x" }),
    );

    test.controller.move({
      point: { x: 49.25, y: 0 },
      disableSnapping: true,
    });
    test.frame();
    expect(test.getState().items[0]).toMatchObject({ x: 49.25, y: 20 });
    expect(test.callbacks.onSnapChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ guides: [] }),
    );

    test.controller.end();
    expect(test.callbacks.onSnapChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ guides: [] }),
    );
  });

  it("does not newly engage a snap from the terminal pointer-up sample", () => {
    const test = harness({
      items: [
        { id: "a", x: 0, y: 20, width: 100, height: 80 },
        { id: "b", x: 150, y: 0, width: 80, height: 140 },
      ],
    });
    test.controller.beginDrag({ point: { x: 0, y: 0 }, itemId: "a" });
    test.controller.move({ x: 47, y: 0, time: 0 });
    test.frame();
    test.controller.move({ x: 48, y: 0, time: 16 });
    test.frame();
    test.controller.move({ x: 49, y: 0, time: 63 });
    test.frame();

    test.controller.end({ point: { x: 49, y: 0 }, time: 64 });

    expect(test.getState().items[0]).toMatchObject({ x: 49, y: 20 });
    expect(test.callbacks.onHaptic).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: "snap-engage" }),
    );
    expect(test.callbacks.onInteractionChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ type: "drag", phase: "end" }),
    );
  });

  it("does not publish a zero-distance marquee as a drag", () => {
    const test = harness({
      items: [{ id: "a", x: 0, y: 0, width: 50, height: 50 }],
    });
    const point = { x: 10, y: 10 };
    test.controller.beginMarquee({ point });

    test.controller.end({ point });

    expect(test.callbacks.onSelectionChange).not.toHaveBeenCalled();
    expect(test.callbacks.onInteractionChange).toHaveBeenLastCalledWith({
      type: "marquee",
      phase: "end",
      itemId: null,
      dragged: false,
    });
  });

  it("publishes dragged marquee metadata only after moving more than 5px", () => {
    const test = harness({
      items: [{ id: "a", x: 0, y: 0, width: 50, height: 50 }],
    });
    test.controller.beginMarquee({ point: { x: -2, y: -2 } });
    test.controller.move({ x: 1, y: 2 });
    test.frame();

    expect(test.callbacks.onSelectionChange).not.toHaveBeenCalled();

    test.controller.move({ x: 4, y: 2 });
    test.frame();

    expect(test.callbacks.onSelectionChange).toHaveBeenLastCalledWith(
      ["a"],
      { source: "marquee", phase: "update", dragged: true },
    );
    test.controller.end();
    expect(test.callbacks.onInteractionChange).toHaveBeenLastCalledWith({
      type: "marquee",
      phase: "end",
      itemId: null,
      dragged: true,
    });
  });

  it("updates marquee selection live during a drag", () => {
    const test = harness({
      items: [
        { id: "a", x: 0, y: 0, width: 50, height: 50 },
        { id: "b", x: 70, y: 0, width: 50, height: 50 },
      ],
    });
    test.controller.beginMarquee({ point: { x: -10, y: -10 } });
    test.controller.move({ x: 55, y: 55 });
    test.frame();
    expect(test.getState().selectedIds).toEqual(["a"]);

    test.controller.move({ x: 130, y: 55 });
    test.frame();
    expect(test.getState().selectedIds).toEqual(["a", "b"]);
    expect(test.callbacks.onMarqueeChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ active: true }),
    );
  });

  it("resizes with snapping and emits one haptic per snap engagement", () => {
    const test = harness({
      items: [
        { id: "a", x: 0, y: 0, width: 100, height: 100 },
        { id: "b", x: 150, y: 10, width: 80, height: 80 },
      ],
    });
    test.controller.beginResize({
      point: { x: 100, y: 50 },
      itemId: "a",
      handle: "e",
    });
    test.controller.move({ x: 149, y: 50 });
    test.frame();
    expect(test.getState().items[0].width).toBe(150);
    expect(test.callbacks.onHaptic).toHaveBeenCalledTimes(1);
    expect(test.callbacks.onHaptic).toHaveBeenCalledWith(
      expect.objectContaining({ type: "snap-engage", axis: "x" }),
    );

    test.controller.move({ x: 149.5, y: 50 });
    test.frame();
    expect(test.callbacks.onHaptic).toHaveBeenCalledTimes(1);

    test.controller.move({ x: 125, y: 50 });
    test.frame();
    expect(test.callbacks.onHaptic).toHaveBeenCalledWith(
      expect.objectContaining({ type: "snap-release", axis: "x" }),
    );
  });
});
