# Spatial interaction and motion verification

## Audit scope

Combined UX, motion, responsive, accessibility-risk, and retained-rendering review of the five supplied Spatial demos against the current React app. Evidence was captured from the current local build at desktop (1280×720) and mobile (390×844) viewports.

## User goal and accessibility target

The board should feel like one continuous spatial surface: every object keeps its identity and content through focus, stack, folder, and fullscreen transitions; touch and trackpad navigation stay direct; controls remain reachable; and the scene remains performant as the board grows.

## Verified steps

1. **Board overview — healthy.** `20-board-final.png` shows the full-viewport canvas, real retained stack/folder depth layers, screen-space chrome, mixed-size cards, and no artificial window frame.
2. **Document open — healthy.** `02-detail-transition-mid.png` and `03-detail-open-desktop.png` show the selected card expanding from its live board bounds with the same document DOM and line wrapping. The bounds tween is deterministic and does not overshoot.
3. **Document close — healthy.** `04-detail-close-mid.png` and `05-detail-closed-desktop.png` show the exact reverse path. Content remains uniformly scaled and does not squash, reflow, or originate at the viewport corner.
4. **Mobile document — healthy.** `10-detail-transition-mobile-mid.png`, `11-detail-open-mobile.png`, `13-detail-close-mobile-mid.png`, and `14-detail-closed-mobile.png` show a fixed, reachable back control; centered action bar; wider readable editor column; and the same retained reverse transition.
5. **Real-child stack — healthy.** `15-stack-open-mid.png`, `16-stack-open.png`, and `17-stack-closed-outside-click.png` show actual child cards leaving and returning to the pile with spatial staggering. Clicking outside closes the inspection state.
6. **Selection focus — healthy.** `18-focus-transition-mid.png` and `19-focus-open.png` show one camera pan/zoom framing the selected group while nonselected context fades and desaturates.
7. **Nested folder canvas — healthy.** `21-folder-open-final.png` shows six real retained child cards in the full-size nested workspace. Only folder descendants are interactive.
8. **Nested document detail — healthy.** `22-nested-detail-mid.png` and `23-nested-detail-open.png` show a child document opening from its in-folder geometry through the same retained viewer.
9. **Folder return after panning — healthy.** Runtime geometry checks confirmed that nested panning moves content by the requested 1.75× wheel delta, remains stable after the camera commit, and closing restores the parent camera and exact folder-card bounds.
10. **Infinite-canvas pagination — healthy.** A 100,000-item benchmark built the page index in 34.5 ms and completed 120 viewport queries in 11.1 ms total (0.093 ms mean). The previous hidden all-items scan was removed; camera queries now use the memoized id lookup and retained stack/folder parents only.
11. **Spaces and persistence — healthy.** `25-spaces-switcher.png` verifies the separate-canvas switcher. Folder records are now part of the validated domain model, and a fake-IndexedDB regression test proves that both seeded spaces and their items persist together.
12. **Space switching — healthy.** `26-client-space.png` verifies that switching to the second persisted canvas replaces the full item set, preserves the shared canvas interactions and chrome, and presents six distinct client-moodboard objects without leaking items from the primary board.

## Strengths

- Detail, stack, folder, and focus transitions all preserve spatial context instead of swapping to unrelated components.
- Document previews are clipped views of the canonical editor surface, which keeps text and checkboxes visually continuous.
- Pointer-frequency camera/item updates stay outside React state and commit canonical data once at gesture end.
- Collapsed groups retain only their last four real depth layers; viewport pages keep overscan without mounting the whole board.
- Back navigation is fixed to the viewport, and detail actions are centered from a static anchor so Motion transforms cannot displace them.
- Reduced-motion preferences are honored through Motion configuration and CSS fallbacks.

## UX and accessibility risks checked

- Removed the nested interactive “Open” button inside stack/folder cards; the visible pill is decorative and the card itself remains the single activation target.
- Added Enter/Space activation for keyboard-focused cards, stacks, and folders.
- Back-control labels now distinguish `Back to folder`, `Back to board`, `Close stack`, and `Exit focus`.
- Escape follows one hierarchical level at a time rather than closing both a nested document and its folder in one key press.
- Screenshot inspection cannot prove screen-reader announcements, full keyboard order, contrast ratios, or sustained 60 fps on every physical phone. Those remain device/assistive-technology verification items rather than claimed compliance.

## Rejected evidence

- `07-folder-close-after-pan-before-fix.png` records the camera-return defect found during this audit. It is intentionally excluded from accepted evidence; the implementation now retains and restores the parent camera.
