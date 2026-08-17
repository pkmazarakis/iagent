# Design QA — native iPhone media rollout

Date: 2026-08-14

Scope: private, owner-only phone-testing deployment using the exact iPhone captures supplied by the user.

## Outcome

- No actionable P0, P1, or P2 visual, responsive, interaction, accessibility, image-loading, or video-loading findings remain for the private test site.
- The six supplied recordings and nine supplied screenshots are represented across the hero, Meetings, Ask, Knowledge, Today, capture, and onboarding stories.
- Every mobile product visual remains inside the reusable front-facing iPhone frame and the existing silver-light stage. No raw screen floats directly on the page.
- The Mac demonstrations, dark app-derived theme, section order, typography, and conversion path remain intact.

## Source visual truth

Primary source captures:

- Finished meeting summary: `/Users/platonmazarakis/Downloads/IMG_0514.PNG` — 1206×2622 px.
- Full iPhone hardware direction: `/var/folders/zj/rwl9xbp92csc19g6d4yklw440000gn/T/codex-clipboard-3541c6c1-8bb5-4791-a618-5fc168f85ca5.png` — 1080×1350 px.
- Remaining supplied mobile truth: `IMG_0483.PNG`, `IMG_0508.PNG` through `IMG_0515.PNG`, plus the six `ScreenRecording_08-14-2026 *.MP4` files in `/Users/platonmazarakis/Downloads/`.

The source recording content is real user-authorized app data, not a sanitized public fixture. That distinction is intentional for this owner-only test and is a hard public-release gate noted below.

## Browser-rendered evidence

Implementation captures:

- Mobile viewport: `qa-captures/native-mobile-v1/mobile-meeting-summary-390x844.jpg` — 390×844 px at a 390×844 CSS viewport and 1:1 screenshot density.
- Focused rendered phone screen: `qa-captures/native-mobile-v1/implementation-meeting-summary-screen.jpg` — 175×382 px.
- Desktop device-stage view: `qa-captures/native-mobile-v1/desktop-meeting-summary-1440x900.jpg` — browser capture from a 1440×900 CSS viewport.
- Browser assertion record: `qa-captures/native-mobile-v1/browser-qa.json`.

Combined comparisons opened and reviewed:

- Full-view art direction: `qa-captures/native-mobile-v1/reference-vs-rendered-device-stage.png`.
- Focused product pixels: `qa-captures/native-mobile-v1/reference-vs-rendered-meeting-summary.png`.

Normalization for the focused comparison:

- Source: 1206×2622 original, first web-optimized to 604×1312, then normalized to 175×382 for comparison.
- Implementation: the visible `.iphone-device-screen` measured 174.86×382.34 CSS px and was captured/cropped to 175×382 px.
- State: dark theme, Meetings → Finished summary, same timestamp and same product content.

The focused comparison confirms that the app typography, spacing, colors, icons, and content remain the supplied native pixels. The only expected visible difference is the iPhone aperture mask at the outer corners. The full-view comparison is an art-direction check rather than a pixel clone: it confirms the requested complete hardware silhouette, front-facing product readability, and neutral gray illumination.

## Required fidelity surfaces

- Fonts and typography: native UI text is preserved as source pixels, with no redraw or font substitution. Landing display/body type keeps the established system stack, weights, wrapping, and dark-theme hierarchy.
- Spacing and layout rhythm: all seven rendered iPhones stay inside their stage/panel bounds at 1440, 768, 390, and 320 px. Device-to-caption overlap is zero; horizontal page overflow is zero.
- Colors and tokens: the native black/sheet hierarchy, coral/green/blue/violet/amber states, titanium edge, and silver-light stage remain balanced against the landing page's black canvas.
- Image quality and asset fidelity: screenshots are served at 604×1312 and remain above their rendered density. The phone frame is a transparent 565×1175 raster overlay; no CSS phone shell, fake SVG, or image-model redraw replaces the product.
- Copy and content: landing copy now accurately describes each visible mobile flow. The native captures remain verbatim because this is the user's requested private test data.

## Comparison history

### Pass 1

- [P1] Play/pause controls sat inside `.iphone-device-screen` and covered real native controls.
- [P2] The 28–30 px playback targets were too small for a comfortable mobile tap.
- [P2] End-state posters flashed backward into videos that begin on Today.
- [P2] The mobile hero phone had only one pixel of bottom clearance.
- [P2] Six unreferenced legacy mobile assets added roughly 5.5 MB to the deployable tree.

Fixes:

- Moved iPhone playback controls into an external stage lane with zero product-pixel overlap.
- Increased every iPhone playback target to 44×44 px and simplified it to an action label without contradictory `aria-pressed` state.
- Extracted real first-frame posters for all six recordings while retaining useful end-state posters for reduced motion.
- Raised the hero phone 14 px.
- Removed the superseded synthetic/legacy mobile images and video.

### Pass 2

- [P2] The Ask control exceeded the silver stage by 8 px at desktop/tablet and by 12 px at 320 px.
- [P2] The Mac meeting video and iPhone meeting video could briefly play together at the section handoff.

Fixes:

- Centered the phone-plus-control group with explicit desktop/tablet/narrow offsets; final control clipping and screen overlap are both zero at every tested width.
- Added exclusive demo playback. A new demo claims playback, pauses the previous visible demo, and leaves the previous control correctly labeled Play.

### Final pass

- No remaining P0, P1, or P2 findings.
- Seven iPhones × four viewports: frame clipping 0.
- Four showcase captions × four viewports: device overlap 0.
- Four active mobile video surfaces × four viewports: 44×44 targets, control clipping 0, product-screen overlap 0, and one visible video playing.

## Interaction and accessibility verification

- All 12 mobile showcase tabs were clicked in the in-app browser; every tab became selected, every `aria-controls` target existed, and every active image/video decoded successfully.
- Meeting, Ask, Knowledge, and Today videos expose external Play/Pause actions. User pause persists after scrolling away and returning.
- When two demonstrations share a viewport edge, only one plays; the automatically paused control reports Play.
- Initial page DOM contains zero iPhone MP4 elements. Mobile recordings mount only when their phone approaches the viewport.
- Reduced-motion logic swaps videos for static `reducedPoster` images and disables rotating image sequences.
- Features opens and closes with Escape. The first FAQ opens with a resolving controlled panel.
- Duplicate IDs: 0. Broken tab references: 0. Broken images: 0.
- Recent browser console errors/warnings at `http://localhost:4173/`: 0.

## Media pipeline

All six source HEVC recordings were converted to web-safe 604×1312 H.264/AVC, 30 fps, fast-start MP4 with audio removed:

| Flow | Duration | Deployed size |
| --- | ---: | ---: |
| Today | 10.5 s | 1.09 MB |
| Codex | 10.1 s | 1.19 MB |
| Notes | 12.6 s | 0.90 MB |
| Todos | 10.6 s | 0.78 MB |
| Ask | 41.3 s | 2.80 MB |
| Meeting | 31.9 s | 2.31 MB |

The optimized mobile screenshots plus first-frame posters total approximately 2.1 MB. The original 67.8 MB source set remains outside `public/`.

## Runtime verification

- `npm run build`: passed.
- `npm run test:sites`: passed, 4/4.
- `git diff --check`: passed.
- Local preview: `http://localhost:4173/`.

## Private-test gate

The supplied captures contain real names, project titles, and task/campaign text. The user explicitly supplied and requested these assets for the current owner-only test deployment. Do not change the Site to public or shared access until those pixels are sanitized or the user explicitly approves that exact public disclosure.

final result: passed
