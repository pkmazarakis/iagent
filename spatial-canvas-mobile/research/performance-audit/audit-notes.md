# Spatial transition and interaction performance audit

Run July 2, 2026 against the production Vite build in the in-app Chromium browser. Desktop traces used the normal 1280×720 viewport; responsive traces used 390×844. The test display/browser scheduled at 120Hz, so healthy frame intervals are roughly 8.3ms. Screenshots in this directory are numbered in run order.

## End-to-end transition results

| Flow | Average FPS | p95 / max frame | Dropped / long frames | CLS |
| --- | ---: | ---: | ---: | ---: |
| Document fullscreen open | 120.0 | 9.3 / 10.3ms | 0 / 0 | 0 |
| Document fullscreen close | 120.0 | 9.9 / 10.4ms | 0 / 0 | 0 |
| Stack expand | 120.0 | 10.0 / 10.3ms | 0 / 0 | 0 |
| Stack collapse | 120.0 | 10.1 / 10.4ms | 0 / 0 | 0 |
| Folder expand | 120.1 | 10.0 / 10.4ms | 0 / 0 | 0.0021 |
| Folder collapse | 120.0 | 10.1 / 10.4ms | 0 / 0 | 0 |
| Focus selection / exit | 118.9–119.0 | 9.5 / 10.5ms | 0 / 0 | 0.0001 |
| Wheel pan | 119.6 | 9.4 / 10.4ms | 0 / 0 | 0 |
| 260-step item drag | 122.0 | 10.3 / 10.3ms | 0 / 0 | 0 |
| Scratch pad open / close | 120.0 | 8.4 / 10.3ms | 0 / 0 | 0 |
| Spaces panel open / close | 120.1 | 10.0 / 10.4ms | 0 / 0 | 0 |
| Add menu open / close | 120.0 | 10.3 / 10.4ms | 0 / 0 | 0 |
| Anchored local auto-organize | 120.0 | 9.2 / 9.4ms | 0 / 0 | 0 |
| Theme transition | 120.2 | 10.0 / 10.4ms | 0 / 0 | 0 |
| Mobile document open / close | 120.0 | 9.8 / 10.4ms | 0 / 0 | 0 |
| Mobile folder open / close | 120.0 | 9.4 / 10.4ms | 0 / 0 | 0.0093 / 0 |

The small folder-open CLS comes from the old folder-card title/subtitle leaving the accessibility/layout-shift viewport as the retained shell becomes the folder canvas. The copy now fades and stays hidden throughout the morph, so there is no visible content pop or squashed text. Folder close is zero-shift because the preview is revealed only after canonical card geometry is restored. See `15-folder-open-compositor.png`, `17-folder-close-mid-compositor.png`, and `20-final-mobile-folder.png`.

## Interaction and scale checks

1. A real wheel event injected 180ms into focus animation canceled the camera controls. The world transform was byte-for-byte identical 120ms and 900ms after the interruption, proving there was no delayed snap-back.
2. At 100,000 items, a camera-page cull query measured 0.102ms median / 0.155ms p95. Reconciling one edited item in the page index measured 13.24ms median / 13.75ms p95.
3. Immutable single-item mutation plus undo reference capture at 100,000 items measured 0.61ms median / 0.93ms p95 (2.0ms max), replacing a whole-board clone/serialization path measured at roughly 388ms median.
4. Drag snapping measured 0.108ms p95 with 5,000 nearby targets; resize snapping measured 0.094ms p95. A full begin/drag/end controller pass with 5,000 visible items measured 0.154ms p95.
5. A synthetic 10,000-member stack retained five collapsed nodes and only destination-page candidates during expansion; it did not mount all members.
6. The phone pass verified the back control remains reachable, the action bar stays centered, document content remains exact through the morph, and folders open with one tap. See `19-final-mobile-detail.png` and `20-final-mobile-folder.png`.
7. The new auto-organize solver moved the demo board by at most ~70 world pixels, retained every row/column neighborhood and reading order, and produced no long or dropped animation frames. A 10,000-item solve measured ~205ms median in the pure benchmark and is routed through a module worker above 750 targets, keeping that work off the interaction thread.

## Fixes made during this audit

1. Replaced per-frame width/height detail and folder animation with a retained compositor FLIP using uniform scale and clip insets.
2. Rebased closing shells before clearing transition presence, removing the final scaled-content/card-layout swap.
3. Converted undo bookkeeping to immutable structural sharing and removed whole-board clone/JSON equality work.
4. Limited large stack/folder transitions to current pages plus four visible depth layers.
5. Coalesced Safari gesture and touch camera updates and made every camera animation interruptible from its live transform.
6. Scoped camera-zoom MotionValues to active nodes, kept inactive editors inert, and removed duplicate selection listeners.
7. Removed animated blur/filter work from dimming and the scratch pad, constrained promotion hints to active transforms, and stabilized toolbar slots.
8. Added responsive 640/1280 image variants so small cards do not decode the original 2268px assets.
9. Added the `?perf=1` frame/long-task/layout-shift probe and tests for its frame statistics.
10. Replaced square-root/global grid packing with an anchored local-tidy solver: cardinal lanes, median/mean anchored equal gutters, an 80px voluntary movement budget, deterministic overlap separation, rotation preservation, and a large-board worker path.

## Evidence limits

The mobile run is a real production-rendered responsive viewport in Chromium, not physical iOS Safari hardware. It validates layout, browser input, animation frames, and endpoint continuity; physical multi-touch/pinch latency still requires a phone check on the deployed URL.
