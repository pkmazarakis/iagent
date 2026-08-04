# Spatial canvas performance architecture

## Decision

Keep the accessible DOM card renderer and split live presentation from canonical application state. Pointer-frequency pan, drag, resize, marquee, and snap updates go directly through MotionValues or imperative DOM styles on a requestAnimationFrame loop. React and IndexedDB receive one canonical commit when a gesture ends.

This is the best fit for Spatial's current mix of rich text, editable controls, images, links, and keyboard-accessible cards. Moving the whole canvas to WebGL/WebGPU would require rebuilding text layout, selection, accessibility, hit testing, and every card control inside a custom rendering engine.

## What the research showed

- Figma's editor is not a React canvas with GSAP. Its core is a custom C++ scene and rendering engine compiled to WebAssembly/native, historically rendered with WebGL and now progressively moving to WebGPU. Figma batches scene work and draw calls because its objects are vector primitives, not independent DOM applications. Sources: [WebGPU rendering](https://www.figma.com/blog/figma-rendering-powered-by-webgpu/), [professional design tool architecture](https://www.figma.com/blog/building-a-professional-design-tool-on-the-web/), [WebAssembly load-time work](https://www.figma.com/blog/webassembly-cut-figmas-load-time-by-3x/), and [Figma performance work](https://www.figma.com/blog/figma-faster/).
- GSAP's `quickSetter` is a fast property-write utility, not a retained renderer or scene architecture. Its own documentation positions it as an optimization for repeated property writes inside hot loops. Introducing it here would duplicate Motion's scheduling and animation layer without removing DOM layout or React renders. Source: [GSAP quickSetter](https://gsap.com/docs/v3/GSAP/gsap.quickSetter%28%29/).
- MotionValues can update DOM properties outside React's render cycle and batch those writes to the next animation frame. Spatial already depends on Motion, so this gives the required hot-path behavior without a second animation runtime. Sources: [MotionValues](https://motion.dev/docs/react-motion-value) and [Motion performance](https://motion.dev/docs/performance).
- PixiJS is excellent for batched sprites and graphics, with documented benefits from culling and texture batching, but it would trade away native text editing and accessible DOM controls for Spatial's current card content. Source: [PixiJS performance tips](https://pixijs.com/8.x/guides/concepts/performance-tips).
- Browser pointer/wheel input should be coalesced to `requestAnimationFrame`; wheel handlers need `passive: false` when the application intentionally prevents browser scrolling. Sources: [requestAnimationFrame](https://developer.mozilla.org/en-US/docs/Web/API/Window/requestAnimationFrame), [wheel events](https://developer.mozilla.org/en-US/docs/Web/API/Element/wheel_event), and [coalesced pointer events](https://developer.mozilla.org/en-US/docs/Web/API/PointerEvent/getCoalescedEvents).

## Implemented scene split

1. The interaction controller snapshots canonical geometry at pointer-down and calculates absolute geometry from that snapshot, avoiding drift.
2. Pointer and wheel events are reduced to the newest input once per animation frame.
3. Camera transform and item geometry are written through retained MotionValues; marquee, selection bounds, and snap guides use direct DOM styles.
4. React state, undo history, autosave, and IndexedDB are updated once per completed gesture.
5. Cards outside a three-viewport overscan rectangle are not mounted and are excluded from snapping/marquee candidates.
6. Production QA builds loaded with `?perf=1` expose `window.__spatialPerformance` reports so browser QA can verify frame pacing, long tasks, and layout-shift sources.
7. Shared item and folder viewers use a compositor-only FLIP: destination layout is established once, and x/y, uniform scale, clip insets, opacity, and radius are the only animated properties.
8. Undo history stores immutable array references; it never clones or serializes the full board during an interaction.
9. Stack/folder transitions retain visible pages and at most four collapsed depth layers instead of mounting every member.
10. Camera animations are reconstructible from the live MotionValues and are canceled as soon as wheel, touch, or pointer navigation begins.
11. Only the active fullscreen editor attaches selection tracking and editable content, while responsive image variants cap decode and upload cost for board previews.
12. Auto-organize uses spatially indexed local lane constraints instead of global grid packing. It preserves neighborhoods and rotations, caps voluntary movement, resolves only true collisions, and moves 750+ item solves to a module worker.

## Performance acceptance gate

The production build includes an opt-in frame probe behind `?perf=1`. A transition passes when it has no frames over 33.3ms, no estimated dropped 60Hz frames, no long tasks, and no visible endpoint discontinuity. Layout-shift sources are included in diagnostic reports so hidden preview reflows can be distinguished from actual board motion.

## When to reconsider a GPU renderer

Profile again before migrating. A WebGPU/Pixi scene becomes compelling if Spatial needs thousands of simultaneously visible simple vector/sprite nodes and paint/layout remains the dominant bottleneck after culling. At that point, use a hybrid: GPU-render passive board content and promote the active/edited card to a DOM overlay. A full Figma-style engine is a separate product-scale renderer project, not an animation-library swap.
