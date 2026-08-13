# Design QA — iAgent native-device demo redesign

Date: 2026-08-13

## Outcome

- No actionable P0, P1, or P2 visual, interaction, responsive, accessibility, image-loading, or video-loading findings remain.
- Every product demonstration now appears inside a photorealistic front-facing Mac display or iPhone frame. Raw floating panels and CSS-only phone shells are removed from the rendered site.
- The original page hierarchy, dark app-derived palette, typography, navigation, copy, section order, and conversion path remain intact.
- The hero now presents one coherent 16-second Mac meeting flow plus a fully visible iPhone companion. The Mac video starts with the closed panel, clicks Record, shows live capture, finishes, processes the local transcript, opens Summary and Transcript, and returns to the closed panel.
- Ask iAgent now uses a 1206×2622, 14.98-second mobile golden flow instead of the legacy 220×480 video.

## Visual target and evidence

Primary references supplied by the user:

- Straight-on complete Mac display: `qa-captures/device-reference/mac-monitor-reference.png`
- Full front-facing iPhone: `qa-captures/device-reference/iphone-reference.png`
- Linear-style gray illumination behind black product UI: `qa-captures/device-reference/linear-light-reference.png`

Final implementation captures:

- Desktop full page: `qa-captures/desktop-full.png`
- Desktop hero: `qa-captures/desktop/sections/01-hero.png`
- Desktop meetings: `qa-captures/desktop/sections/04-meeting-notes.png`
- Desktop Ask: `qa-captures/desktop/sections/06-ai-chat.png`
- Mobile full page: `qa-captures/mobile-full.png`
- Mobile hero: `qa-captures/mobile/sections/01-hero.png`
- Mobile meetings: `qa-captures/mobile/sections/04-meeting-notes.png`
- Mobile Ask: `qa-captures/mobile/sections/06-ai-chat.png`

Combined reference/implementation comparisons opened and reviewed:

- `qa-captures/device-comparisons/desktop-hero.jpg`
- `qa-captures/device-comparisons/desktop-linear.jpg`
- `qa-captures/device-comparisons/mobile-hero.jpg`

The comparisons confirm the requested complete front-facing hardware, large legible screens, visible Mac stand, fully visible iPhone silhouette, and restrained silver illumination. Product UI remains the dominant subject; hardware is support, not decoration.

## Media quality

| Asset | Resolution | Duration | Verification |
| --- | ---: | ---: | --- |
| `macos-meeting-golden-flow.mp4` | 1920×1200 | 16.0 s | H.264, 30 fps, muted, fast-start, 6.5 MB, media `readyState: 4` |
| `iphone-ask-golden-flow.mp4` | 1206×2622 | 15.0 s | H.264, muted, fast-start, 4.0 MB, media `readyState: 4` |
| `mac-studio-display-frame-v2.png` | 1210×930 | — | RGBA with transparent screen/background |
| `iphone-titanium-frame-v2.png` | 565×1175 | — | RGBA with transparent screen/background |
| `device-stage-silver-light-v1.jpg` | 1536×1024 | — | Original generated background, decoded successfully |

The 16:10 Mac recording is top-anchored and cover-cropped only at the bottom to fit the display's approximately 16:9 opening; the panel, cursor, and top-edge actions remain intact. All published fixture content is sanitized. No local Codex/task/project titles appear.

## Responsive and interaction checks

- Desktop rail remains 976 px; mobile rail remains 342 px with 24 px gutters.
- Horizontal overflow is zero at 1440, 1024, 768, 390, 360, and 320 px.
- No main section crosses the viewport at 1024, 768, 360, or 320 px.
- Every rendered Mac/iPhone frame remains inside its clipped demo stage at 1024, 768, 360, and 320 px; no frame intersects the hero note or showcase captions.
- Hero phone is fully contained at desktop and mobile and does not obscure the Mac screen.
- Mobile showcase tab strips are now reachable with horizontal scrolling; Ask and local-knowledge states are no longer locked to the first tab.
- Desktop tab keyboard behavior still supports Arrow keys and End.
- Mac demos expose an accessible pause/play control; reduced-motion mode swaps all videos for closed/static posters.
- The hero companion phone is a crisp static Notes state so it does not compete with the Mac golden flow or trigger a second above-the-fold sequence download.
- Features uses disclosure navigation semantics, opens, closes on Escape, closes on outside click, and exposes five ordinary links.
- Product tabs use one stable rendered tabpanel, and every `aria-controls` reference resolves.
- FAQ accordion semantics, anchors, and primary CTA scrolling continue to work.
- Browser console errors: 0. Page errors: 0. Image decode failures: 0. Video media errors: 0.

## Reference comparison fixes

### Pass 1

- [P1] Separate closed/open Mac panels read as overlapping screenshots rather than a real native flow.
- [P1] Hero iPhone was 43–45% clipped and covered Mac product pixels.
- [P1] The Ask video was only 220×480 and enlarged beyond its source dimensions.
- [P2] Raw panel corners were clipped in Today and Ask demonstrations.
- [P2] Dark product surfaces disappeared into near-black showcase backgrounds.
- [P2] Mobile showcase tabs were hidden, making later product states unreachable.

Fixes:

- Replaced the fragmented Mac states with one sanitized high-resolution golden-flow video inside a generated display frame.
- Added a high-resolution native iPhone Ask loop inside a generated titanium frame.
- Wrapped every secondary Mac and iPhone demo in the same reusable hardware system.
- Replaced colored/raw showcase fills with an original Linear-inspired silver-light stage asset.
- Removed all oversizing/cut-corner media rules and made every device fully visible.
- Restored mobile tab access with a horizontally scrollable tablist.
- Removed public files containing personal/local fixture names and kept those originals outside the deployable `public/` tree.

### Pass 2

- [P2] The Mac summary poster skipped the requested closed-panel opening state.

Fix:

- Regenerated the Mac poster at the loop's closed-panel timestamp. Reduced-motion and pre-video states now tell the same story as the animation.

### Pass 3

- [P1] Mobile hardware intersected the hero note and sat over showcase captions.
- [P1] The iPhone video and rotating image sequences lacked durable pause controls.
- [P1] Legacy public assets exposed personal/local fixture labels even though they were not needed by the final page.
- [P2] High video bitrates made the two golden flows heavier than needed for their rendered sizes.
- [P1] Fixed-width Mac frames clipped at 768 px and 320 px edge cases.
- [P2] Product tabs and Features used incomplete ARIA patterns.

Fixes:

- Repositioned and slightly reduced the mobile hero phone, reserved a dedicated caption lane, and raised showcase captions onto legible dark glass.
- Added independent user-pause state to image sequences and accessible pause/play controls to the iPhone and Mac motion demos.
- Quarantined every identified personal/local capture outside `public/`, updated the favicon, and rebuilt the deployable output.
- Re-encoded Mac and iPhone flows at visually lossless-for-slot bitrates, cutting their combined weight from roughly 17.6 MB to 10.5 MB.
- Added tablet and narrow-phone device sizing without changing the established 360/390/desktop composition.
- Replaced the Features menu role with disclosure navigation semantics and stabilized tabpanel IDs.

## Runtime verification

- `npm run build`: passed.
- `npm run test:sites`: passed, 4/4.
- `node ../research/scripts/interaction-qa.mjs`: passed, 47/47 assertions, including deferred below-fold media loading, ARIA reference integrity, tablet/narrow-phone hardware containment, and copy-obstruction checks.
- `git diff --check -- iagent-landing`: passed.
- Local preview remains available at `http://127.0.0.1:4173/`.

## Production note

- The generated device frames are polished front-on 2.5D product renders. This keeps the real UI pixel-perfect and readable, unlike a perspective-heavy scene or an image-model redraw of the app.
- Screen Studio is installed but has no supported CLI, URL scheme, or headless renderer. Its bundled hardware images were not copied. A future manual Screen Studio export can add editorial zooms, but the deterministic in-site compositing is the production source of truth.

final result: passed
