# Spatial motion audit

This audit is based on frame-by-frame inspection of the five supplied Spatial demos. Timing values are measured from the encoded videos and rounded to practical runtime tokens.

## Product motion language

- Spatial uses direct manipulation: a card, stack, or folder is the same visual object before, during, and after a transition.
- Object geometry follows a non-overshooting ease-out. The common settle window is roughly 600–800 ms; supporting UI enters after the main geometry is stable.
- Background context is preserved. It fades and desaturates rather than disappearing before the selected object moves.
- Canvas camera moves are a single pan/zoom transform. Individual cards do not counter-animate while the camera is focusing a group.
- Stack motion uses short spatially ordered staggers (roughly 25–45 ms per child) and a heavily damped spring. Children never teleport or swap for a synthetic preview.
- Detail previews retain exact content, clipping, and crop. Typography and media enlarge uniformly from the source before becoming interactive.
- Screen-space chrome, selection strokes, and action bars retain their apparent size while the world zoom changes.

## Demo inventory

### 2037933263612764653 — current interaction system

- Rapid canvas fit and focus transitions with inertial deceleration and no rebound.
- Document/image detail opens from the clicked card's live bounds into the viewport in about 700 ms.
- The same card content remains visible through the whole forward and reverse transition.
- Nonselected board content fades to a pale, desaturated context layer on the same timeline.
- Context actions enter only after the detail shell settles.
- A multi-item focus state preserves the selected cluster's relative geometry while the camera frames it.
- Cards remain editable in place when the camera is focused close enough.

### 1959601780649832562 — stacks

- Loose objects collapse to a shared anchor with a 25–45 ms spatial stagger.
- A stack keeps real child surfaces as depth layers; the front item stays legible.
- Opening is the exact reverse path: child cards move from their pile positions to canonical canvas positions.
- Detail can open from a child inside an expanded cluster and returns to the correct child position and z-order.
- The stack is selectable and draggable as one object while collapsed.

### 1926196508002554356 — feature overview

- Edge/center snapping with lightweight guides and a magnetic threshold.
- One-click grid organization for mixed-size objects.
- Dragging objects onto each other creates a stack.
- Spaces provide separate top-level canvases.
- Folders clean up a parent board and open into their own full-size nested canvas.
- Long-form writing opens from an exact miniature preview into a calm full-page editor.

### 1941809835671978179 — reversible pile choreography

- Several unrelated shapes converge into a pile without changing their visible content.
- Collapse order is spatial and deterministic; the final few layers remain slightly offset to communicate depth.
- Reopening is reversible and restores every card to its original location.
- Camera motion can frame a pile before opening without disturbing child geometry.

### 1939349203076936071 — nested navigation

- A document opens and closes with retained content and a context-preserving board fade.
- A folder opens as a new canvas sheet while the parent board remains behind it.
- An item can open fullscreen from inside that folder.
- Closing returns first to the exact nested item position, then from the folder canvas to the exact folder card on the parent board.
- Back navigation is hierarchical and each reverse transition follows the forward geometry in reverse.

## Current implementation gaps found

1. Detail geometry is retained, but the document uses responsive container typography during the morph. Line breaks, padding, and scale therefore change independently and make the content appear to fly in from a corner.
2. Detail timing is too short (460 ms) and background dimming is much faster (180 ms), so the transition reads as separate layers.
3. Stack children are hidden at the pile and the visible pile is synthetic. This breaks exact-content continuity.
4. Stack close completion relies on a fixed timer rather than animation completion.
5. The app supports spaces and in-context stack inspection, but not a true nested full-size folder canvas.
6. Stacks can be created from a selection, but not by dropping one object onto another as demonstrated.
7. There is no explicit camera focus-selection command.

## Implementation targets

- Use a canonical document surface that is uniformly scaled and clipped for the board preview, then expands without reflow before editing is enabled.
- Synchronize detail geometry, radius, board fade, and chrome on a shared measured timeline.
- Render real stack children at their pile positions with deterministic depth and stagger, and end transitions from animation completion.
- Add nested folder canvas state with retained parent context and hierarchical back behavior.
- Add drag-to-stack and focus-selection affordances while preserving current snapping, culling, and retained MotionValue rendering.

## Completion status

- **Canonical detail surface:** complete. Board and fullscreen use the same retained `CanvasItemNode`, `SharedItemViewer`, and document DOM. Geometry, radius, context fade, and delayed chrome are synchronized on a 680 ms non-overshooting bounds tween.
- **Live zoom continuity:** complete. The canonical surface now derives its preview scale from the live camera MotionValue, so its crop stays locked to the card during trackpad zoom rather than snapping after the React camera commit.
- **Real stack choreography:** complete. Closed groups show their last four real children, open/close order is deterministic at 36 ms per child, and cleanup waits for member animation completion.
- **Drag-to-stack:** complete for top-level board objects, with tested overlap/center targeting and topmost-target selection.
- **Focus selection:** complete. One 720 ms camera transform frames the selected bounds and reverses to the stored camera.
- **Nested folder canvas:** complete. The opening translation is captured once, folder-local poses stay canonical, nested panning no longer re-centers, and the stored parent camera is restored during the reverse transition.
- **Hierarchical navigation:** complete. Detail returns to its folder before the folder returns to the board; back labels and Escape follow the active hierarchy one level at a time.
- **Infinite-canvas culling:** complete. Page queries use the memoized item lookup and retained group parents instead of scanning all items; the 100,000-item verification averaged 0.093 ms per viewport query.
- **Responsive verification:** complete at 1280×720 and 390×844. Mobile detail keeps a fixed 44 px back target, a centered action bar, and a 342 px readable editor surface inside the 390 px viewport.
- **Spaces and persistence:** complete. Folder records are accepted by the canonical domain schema, both seeded top-level canvases persist in IndexedDB, and the spaces switcher exposes them without losing board state.

The numbered current-run evidence and limits are recorded in `research/visual-audit/audit-notes.md`.
