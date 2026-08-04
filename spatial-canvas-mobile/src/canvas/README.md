# Canvas interaction API

This directory is store- and renderer-agnostic. Items are plain objects with:

```js
{ id, x, y, width, height, zIndex? }
```

Item geometry is world-space. A camera is `{ x, y, zoom }`, where `x` and `y`
are screen-pixel translations. Render the world layer with `cameraTransform()`.

## Pure modules

- `geometry.js`: rectangles, hit tests, resize handles, resize math.
- `camera.js`: world/screen conversion, cursor-centered zoom, pan, viewport.
- `selection.js`: stable live marquee selection with replace/add/toggle/subtract.
- `snap.js`: proximity-prioritized edge/equal-width/equal-height resize snapping.
  `resizeWithSnapping()` returns geometry plus guides and highlighted item ids.
- `stackLayout.js`: deterministic stack, grid, fan/unpack, and interpolation paths.

## Interaction controller

```js
const canvas = createCanvasInteractionController({
  getSnapshot: () => store.getState(), // {camera, items, selectedIds}
  onCameraChange: (camera) => store.setCamera(camera),
  onItemsChange: (patches) => store.patchItems(patches),
  onSelectionChange: (ids) => store.setSelection(ids),
  onMarqueeChange: (marquee) => setMarqueeOverlay(marquee),
  onSnapChange: ({ guides, highlightedIds }) => setSnapOverlay({ guides, highlightedIds }),
  onHaptic: ({ type }) => type === "snap-engage" && performAlignmentHaptic(),
});
```

Map pointer intent explicitly after hit-testing:

```js
canvas.beginPan({ point });
canvas.beginMarquee({ point, operation: "replace" });
canvas.beginDrag({ point, itemId });
canvas.beginResize({ point, itemId, handle: "se" });
canvas.move(point);       // coalesced to the next animation frame
canvas.end(point);        // flushes the final point
canvas.cancel();          // restores pointer-down geometry
canvas.wheelZoom({ point, deltaY });
canvas.wheelPan({ deltaX, deltaY });
```

`useCanvasInteractions(options)` provides the same stable controller in React
and destroys it on unmount. All callbacks are read from the latest render while
an active gesture retains its pointer-down geometry.

Snap thresholds are screen pixels and are divided by camera zoom internally.
Render x-axis guides as vertical lines (`position` is x, `start/end` are y) and
y-axis guides as horizontal lines. Labels are `WIDTH`, `HEIGHT`, or the target
edge (`LEFT`, `RIGHT`, `TOP`, `BOTTOM`).

