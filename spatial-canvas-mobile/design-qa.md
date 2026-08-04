# Design QA — Notion-style mobile document editor

- Reference: `/tmp/codex-remote-attachments/019f1fc4-c24d-7f01-8fec-1f1c188b54a1/4A7C7A87-1B19-4D06-BC98-7F189D6F9229/1-Photo-1.jpg`
- Implementation: `/tmp/spatial-notion-mobile-unfocused.png`
- Full comparison: `/tmp/spatial-editor-comparison-full.png`
- Focused comparison: `/tmp/spatial-editor-comparison-focus.png`
- Viewport: 390 × 844 CSS pixels
- State: Today document open; title, task blocks, and trailing paragraph visible

## Comparison evidence

The full comparison normalizes both captures to a 390 px mobile width and places the complete reference and implementation side by side. The focused comparison removes the reference phone status bar and crops both captures to the editor's upper content region. The in-app browser cannot render the native iOS keyboard, so keyboard chrome is excluded from the focused comparison; title focus and Return behavior were verified interactively instead.

## Findings and fixes

- P0: none.
- P1: opening a card could focus-scroll the canvas container, shifting the fullscreen detail view horizontally. Fixed by making the transformed canvas a non-scrollable `overflow: clip` viewport.
- P1: iOS software-keyboard Return was not guaranteed to follow the desktop `keydown` path. Fixed with an `insertParagraph` `beforeinput` fallback for titles and content blocks.
- P1: the mobile document column was too wide relative to the supplied reference. Fixed to 52 px side margins at the tested viewport.
- P2: native blue input chrome was removed; title and body now use borderless contenteditable blocks with the existing Spatial typography and colors.

## Interaction verification

- Return in the page title keeps `Today` as a single-line title, inserts a paragraph block before the existing task list, and moves focus to it.
- Return in that paragraph creates and focuses a second independent paragraph block.
- The original document state was restored after verification.
- Production build passes and all 65 unit tests pass.

final result: passed

---

# Design QA — two-stage folder preview and canvas

- Source visual truth: `/var/folders/zz/97g1tdbx7b18n2fzstb99xl40000gn/T/TemporaryItems/NSIRD_screencaptureui_MZbE2m/Screenshot 2026-07-02 at 9.48.07 AM.png`
- Tested implementation: `https://spatial-motion-preview.openai.chatgpt-team.site`
- Viewports: 1280 × 720 desktop and 390 × 844 phone
- States: board → inline folder inspection → dedicated folder canvas → inline inspection → board

## Root cause and interaction contract

The two visually identical folder cards used different data kinds and activation paths: `Archived notes` was a `stack` opened inline, while `Research folder` was a `folder` opened directly as a nested canvas. Both kinds now use one deterministic two-stage contract:

1. One click, tap, Enter, or Space opens the container inline above the existing board.
2. A fixed top-right expand control promotes the same retained children into their own canvas.
3. Back or Escape from the dedicated canvas returns to the inline preview.
4. Back, Escape, or an outside click from the inline preview closes it to the board.

## Findings and fixes

- P1 fixed: folder-looking cards opened through different state paths. `stack` and `folder` are now treated as one visual container without migrating or rewriting saved board data.
- P1 fixed: direct folder activation skipped the preferred layered preview. Every pointer, keyboard, and toolbar activation now enters inline inspection first.
- P1 fixed: a dedicated canvas could previously replace the inspection state entirely. The view state now retains the container identity across inline and canvas modes, so Back traverses one level at a time.
- P1 fixed: the inline outside-dismiss capture could consume the new expand click. The safe-area control is explicitly part of the inspection scope, while unrelated board items remain visible but inert.
- P1 fixed: pagination could discard one endpoint page during translated canvas motion. Canonical inline pages and translated canvas pages remain mounted together until the handoff completes.
- P2 fixed: the former fullscreen shell path only recognized `folder`. The same compositor-only shell animation, clipping, and background behavior now supports both folder-looking data kinds.

## Verification

- `Research folder` and `Archived notes` both opened inline on the first desktop click and first phone tap.
- Inline mode preserved the existing board behind the active contents and exposed one top-right expand button.
- The phone expand control measured exactly 44 × 44 px at top 12 px and right 12 px, respecting the safe-area layout.
- Both container kinds promoted into a dedicated canvas and returned to inline preview without changing child identity or canonical poses.
- A second Back closed the preview to the original board; the browser console reported no errors or warnings across the complete loop.
- Production build passes and all 114 unit tests pass, including the two-stage state machine and dual-endpoint pagination regression.
- Owner-only Sites version 5 deployed successfully and serves bundle `index-BqVCRnRy.js` from the live URL.

final result: passed

---

# Design QA — centered scale + item-color wash transition

- Source sequence: `/Users/platon/Desktop/Screenshot 2026-07-02 at 9.35.59 AM.png` through `/Users/platon/Desktop/Screenshot 2026-07-02 at 9.36.35 AM.png`
- Implementation endpoint: `research/performance-audit/30-crown-jewel-final.png`
- Combined source/implementation comparison: `research/performance-audit/crown-comparison.html`
- Desktop verification: 1280 × 720 and 1280 × 1024 CSS pixels
- Phone verification: 390 × 844 CSS pixels
- States: selected note, portrait web article, and image reference opened and returned to their canvas bounds

## Comparison evidence

The side-by-side comparison uses the supplied final frame and the implemented retained reader at the same tall viewport ratio. Both keep a portrait page centered on a solid item-colored surface with the back control fixed at the top-left. The implementation intentionally retains the app's existing article copy while matching the reference's page scale, two-line heading geometry, and centered reader placement.

## Findings and fixes

- P1 fixed: the retained node previously jumped to viewport width/height and simulated its source with clip insets. Width and height now remain source-sized; only top-left translation and one uniform outer scale animate.
- P1 fixed: document content previously counter-scaled and moved internally while the shell expanded. The canonical 680 px document surface now keeps one local scale and zero internal travel, so line breaks, typography, and relative geometry remain identical throughout.
- P1 fixed: images previously ran a second nested fit transform. The same image element, source URL, object-fit value, and local bounds are now retained while only the card's outer transform changes.
- P1 fixed: the selected 1.1× emphasis could shrink on the first detail frame. Its centered visual bounds are folded into the outer source matrix before motion begins, then restored atomically after close.
- P1 fixed: every board item previously dimmed immediately. A dedicated world-space layer now fades from the active item's exact surface color using the measured reference opacity curve, while the selected card stays above it.
- P2 fixed: image metadata and the bottom action bar are deferred until the card reaches its endpoint, keeping the hero journey to compositor transform and opacity work.

## Geometry and performance verification

- Note local box remained exactly 285 × 175 CSS px while its visual rect moved from 132.05 × 81.08 to 760 × 466.67 at 46% canvas zoom.
- Portrait article local box remained exactly 235 × 300 CSS px and finished centered at x 276.53, y 48, width 726.93, height 928 in the 1280 × 1024 viewport.
- Image local box remained exactly 360 × 315 CSS px; its `currentSrc` and `object-fit: cover` were unchanged before and after expansion.
- Desktop note open: 120.1 fps average, 10.0 ms p95, 0 dropped frames, 0 long frames, 0 long tasks.
- Desktop note close: 120.0 fps average, 9.9 ms p95, 0 dropped frames, 0 long frames, 0 long tasks.
- Desktop image open: 119.8 fps average, 8.8 ms p95, 0 dropped frames, 0 long frames, 0 long tasks.
- Phone note open: 120.2 fps average, 9.4 ms p95, 0 dropped frames, 0 long frames, 0 long tasks; the 44 × 44 back target remained visible at x 12, y 12.
- Phone note close: 117.8 fps average, 10.0 ms p95, 1 dropped frame, 0 long frames, 0 long tasks.
- Close returned to the exact pre-open board rectangle and retained the same 285 × 175 local box.
- Production build succeeds and all 110 unit tests pass.
- Owner-only Sites version 4 reached `succeeded` at deployment `appgdep_6a46aff767b881919e23b9c6555169fd`.

final result: passed

---

# Design QA — selection, image detail, folders, and history

- Source references: `research/performance-audit/reference-multiselect.png`, `reference-command-bar.png`, and `reference-image-detail.png`
- Combined source/implementation evidence: `research/performance-audit/29-qa-comparison.png`
- Live multi-selection: `research/performance-audit/25-live-multiselect-final.png`
- Phone selection: `research/performance-audit/26-phone-selection-final.png`
- Phone image detail: `research/performance-audit/27-phone-image-detail-final.png`
- Phone folder picker: `research/performance-audit/28-phone-folder-picker-final.png`
- Viewports: 1728 × 896 desktop and 390 × 844 phone
- State: single selection, additive multi-selection, retained image detail, folder destination picker, and atomic create-folder undo/redo

## Comparison evidence

The combined comparison puts the supplied selection, command-bar, and image references beside the tested implementation states. It confirms the requested white selected-item outline, raised selected cards, compact black action surface, and retained image content. Interaction and alignment metrics were read from the rendered DOM at the same states.

## Findings and fixes

- P1 fixed: selected-item resize arcs were clipped by paint containment. Selected retained nodes now drop paint containment, and all four screen-space corner handles remain visible.
- P1 fixed: multi-selected cards lacked a shared visual contract. Every selected card now animates to exactly 1.1× and receives a zoom-compensated white outline.
- P1 fixed: image cards were excluded from detail expansion. Image cards now reuse the same retained image surface from canvas to fullscreen and back.
- P1 fixed: click intent started a zero-distance drag before opening detail, adding work and perceived lag. Drag begins only after the pointer crosses a 5 px movement threshold.
- P1 fixed: the phone command bar used a shrink-to-fit transformed anchor and drifted off center. Its static full-width anchor now centers the animated inner surface; measured center was exactly 195 px in the 390 px viewport.
- P1 fixed during live-device QA: the folder picker was anchored from the viewport midpoint and extended off the right edge. A transform-independent `translate: -50% 0` now centers its 330 px surface at x 30 in the 390 px viewport.
- P2 fixed: folder creation and destination choices were mixed into indirect actions. A dedicated folder picker now lists destinations, item counts, creation, and removal explicitly.
- P2 fixed: undo/redo side effects were recorded inside a React state updater. Board snapshots and selection are now committed synchronously, so grouped actions restore exact membership and selection under StrictMode and rapid reversal.

## Verification

- Desktop multi-selection rendered two retained nodes at `matrix(1.1, 0, 0, 1.1, 0, 0)` with zoom-compensated white outlines.
- Single selection rendered four 34 px corner hit targets; the command toolbar center equaled the 1728 px viewport center at 864 px.
- Phone command bar measured x 124, width 142, center 195, with a 22 px clear gap above the bottom controls.
- Phone image detail measured exactly 390 × 844; the retained image fit inside with 22 px side margins and the back control remained reachable.
- Phone create-folder → undo restored `Cyber Ink Blossom` selected with four corners; redo restored `New folder` selected with four corners.
- Detail open and close each required four React renders for state transitions only, with zero camera commits, zero item commits, and zero pointer-frequency React updates.
- The deployed owner-only Sites build reached `succeeded` at version 3.
- Production build passes and all 106 unit tests pass.

final result: passed

---

# Design QA — retained board-to-fullscreen article morph

- Source sequence: `/Users/platon/Desktop/Screenshot 2026-07-01 at 11.16.19 PM.png` through `/Users/platon/Desktop/Screenshot 2026-07-01 at 11.17.15 PM.png`
- Implementation board endpoint: `/tmp/spatial-article-board-settled.png`
- Implementation fullscreen endpoint: `/tmp/spatial-article-open.png`
- Implementation return endpoint: `/tmp/spatial-article-closed.png`
- Same-state source/implementation comparison: `/tmp/spatial-transition-final-comparison.png`
- Implementation viewport: 1280 × 720 CSS pixels
- State: `A brief history of Scandinavian design.` web article selected, opened, then returned to its board bounds

## Comparison evidence

The combined comparison places the supplied final article frame and the implementation fullscreen frame side by side after removing the reference browser chrome and normalizing both app surfaces to 1280 × 720. Both show the same two-line title, `Untitled` breadcrumb, supporting sentence, back control, white canvas, and centered bottom action bar.

## Findings and fixes

- P1 fixed: the board card used an image/web-preview renderer and fullscreen used a different document editor. Web clips now use one persistent article/document renderer in both states, including identical title and body data.
- P1 fixed: the old spring could cross its target and visually arrive from the wrong edge. X, Y, width, height, and scale now use one deterministic 460 ms cubic-bezier bounds tween with no overshoot.
- P1 fixed: preview and editor opacity timelines exposed the board and made content appear to travel from the lower-right into a new top-left layout. The crossfade layers were removed; the same content DOM remains mounted throughout open and close.
- P1 fixed: content typography and padding could finish settling after the shell returned to its card. Content dimensions now derive from the retained shell's live container size, so layout and geometry share the same frame clock.
- P2 fixed: editing and the action bar activate only after fullscreen geometry completes, preventing focus or control movement during the hero transition.

## Endpoint and regression verification

- Fullscreen retained shell: x 0, y 0, width 1279.99, height 719.99 — exactly the viewport.
- Returned article card: x 627, y 300.20, width 178.60, height 228.00 — identical to its board bounds.
- Returned article uses the same mounted title/body editor surface; no image-card-to-document component replacement occurs.
- Today document still opens into the editable block editor with its title, six task blocks, and trailing paragraph intact.
- All 78 unit tests pass and the production build succeeds.

final result: passed

---

# Design QA — active empty-block placeholder and row backgrounds

- Source visual truth: `/tmp/codex-remote-attachments/019f1fc4-c24d-7f01-8fec-1f1c188b54a1/DF5375B5-B47B-4D79-AFE1-E7CB45C8BDC2/1-Photo-1.jpg`
- Implementation screenshot: `/tmp/spatial-editor-repeated-enter-fixed.png`
- Full-view comparison: `/tmp/spatial-editor-placeholder-comparison-full.png`
- Focused comparison: `/tmp/spatial-editor-placeholder-comparison.png`
- Viewport: 390 × 844 CSS pixels
- State: `Some day` open with three text paragraphs, four consecutive empty paragraphs, and the final empty paragraph focused

## Evidence

The full comparison normalizes both captures to 390 px width. The supplied reference includes native iOS keyboard and browser chrome, which the in-app browser cannot reproduce; the focused comparison removes those surfaces and aligns the editor content region. The focused evidence shows the reported duplicate hints and gray ordinary row beside the corrected single focused hint and transparent rows.

## Required fidelity surfaces

- Typography: existing Inter sizes, weights, line heights, and placeholder color are unchanged.
- Spacing/layout: block height and vertical rhythm are unchanged; inactive empty blocks still occupy document space without rendering duplicate hint text.
- Colors/tokens: ordinary rows resolve to `rgba(0, 0, 0, 0)` in light mode; code blocks retain the existing `#f1f2f2` fill and dark-mode code fill.
- Image quality/assets: no image or icon assets are involved in this editor-state fix.
- Copy/content: the existing `Type '/' for commands` hint is unchanged and now appears only on the focused empty block.

## Findings and patches

- P1 fixed: every empty block rendered the command hint. The pseudo-element now requires `:focus`, so inactive empty blocks are blank.
- P1 fixed: the row hover/menu fill became sticky on touch and looked like an unintended selected row. Ordinary rows are now explicitly transparent and have no hover/menu background rule.
- P2 fixed: native tap highlighting is explicitly disabled on editor rows; the global rule already did this, and the local declaration keeps the editor contract durable.
- Regression coverage verifies focused-only placeholder rendering, transparent ordinary rows, and a retained code-block background.

## Verification

- Six empty blocks were created in the same document; computed pseudo-content was `none` for every inactive block and `"Type '/' for commands"` only for the focused block.
- Every ordinary row measured a transparent computed background.
- Production build passes and all 74 unit tests pass.

final result: passed

---

# Design QA — fullscreen item close transition

- Reported frame: `/tmp/codex-remote-attachments/019f1fc4-c24d-7f01-8fec-1f1c188b54a1/DFFE0691-CE29-4216-B981-A3951A1C5315/1-Photo-1.jpg`
- Desired resting frame: `/tmp/codex-remote-attachments/019f1fc4-c24d-7f01-8fec-1f1c188b54a1/DFFE0691-CE29-4216-B981-A3951A1C5315/2-Photo-2.jpg`
- Fixed implementation: `/tmp/spatial-close-fixed-mobile.png`
- Combined comparison: `/tmp/spatial-close-transition-comparison.png`
- Viewports: 390 × 844 for transition measurement; 390 × 692 for the browser-chrome-free visual comparison
- State: `Some day` task card selected after closing fullscreen detail

## Comparison evidence

The combined comparison places the reported squished close frame, the supplied desired resting frame, and the fixed implementation in one image. Native Safari status and browser bars are removed from the references so all three columns compare only the app surface.

## Findings and fixes

- P0: none.
- P1: the fullscreen sheet was collapsed with non-uniform X/Y scaling, which compressed the editor and made its text temporarily microscopic. The sheet now animates its actual x/y/width/height geometry.
- P1: fullscreen editor layout was being recalculated as the sheet shrank. The expensive detail content now keeps fixed viewport dimensions and is clipped by the contained sheet instead of reflowing every frame.
- P1: the transition preview previously rendered in screen-space CSS pixels, then popped to the canvas-scaled card after unmount. It now renders at the card's natural world size with the current camera scale applied once.
- P2: the preview crossfade is delayed until the sheet is near its destination, avoiding a visible card traveling out of the fullscreen view's top-left corner.

## Endpoint and performance verification

- Last transition-preview bounds at 58% zoom: x 235.36, y 284.14, width 164.93, height 101.27.
- Resting canvas-card bounds after unmount: x 235.36, y 284.14, width 164.93, height 101.27.
- Last transition title bounds and resting title bounds are also identical: x 244.04, y 292.82, width 147.57, height 8.12.
- Transition preview and editor layers are fixed-size; only the contained sheet geometry and two opacity values animate.
- Production build passes and all 72 unit tests pass.

final result: passed
