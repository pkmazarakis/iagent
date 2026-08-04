# Note editor design QA

## Comparison target

- source visual truth paths:
  - `/var/folders/s1/596b7xb16gbc9jmvgsjvxbhw0000gn/T/TemporaryItems/NSIRD_screencaptureui_ji0g2k/Screenshot 2026-08-02 at 11.19.55 PM.png`
  - `/var/folders/s1/596b7xb16gbc9jmvgsjvxbhw0000gn/T/TemporaryItems/NSIRD_screencaptureui_Vf7cwV/Screenshot 2026-08-02 at 11.22.34 PM.png`
- implementation screenshot path: `/Users/platonkmazarakis/Documents/iagent/artifacts/iagent-note-markdown.png`
- full-view and focused comparison evidence: `/Users/platonkmazarakis/Documents/iagent/artifacts/iagent-note-design-qa-comparison.png`
- supporting saving-state evidence: `/Users/platonkmazarakis/Documents/iagent/artifacts/iagent-note-toolbar.png`
- viewport: native macOS panel, `760 x 310` points, dark appearance
- source shell pixels: `1582 x 628`; cropped to the visible panel at `x=60, y=0, 1458 x 620`, then normalized to `1520 x 620`
- source toolbar pixels: `696 x 76`; normalized to `720 x 79` for the focused control comparison
- implementation pixels: `1520 x 620`, representing `760 x 310` points at `2x`
- implementation toolbar crop: `760 x 80`; normalized to `720 x 76` for the focused control comparison
- density normalization: the full implementation is a native `2x` capture; the source shell is a capture with surrounding-app strips removed and a small horizontal normalization for equal-size comparison
- state: populated note with an active rich-text selection and completed local save; source and implementation use different dynamic note content, so comparison is limited to shell hierarchy, control placement, formatting treatment, and footer taxonomy

## Design grounding

- Primary structural truth: the user's populated note screenshot.
- Primary control truth: the user's Slack formatting-toolbar crop.
- Product-system truth: the existing native black panel, SF system typography, faint separators, amber note identity, and semantic green completion state.
- Requested intentional deltas: remove the large amber check, move save state to the title row, replace save copy with spinner/check icons, expose direct formatting controls on the left, keep the folder at the far right, and render formatting without visible source syntax.

## Findings

- No actionable P0, P1, or P2 differences remain.
- [P3] The focused toolbar source is a light Slack surface while the implementation is a dark native panel. Icon order, grouping, and compact density are preserved; the palette and weights intentionally follow the app's established dark tokens.
- [P3] The implementation adds Checklist and More after Slack's visible code-block group. Checklist is explicitly required, and More keeps lower-frequency working tools available without increasing the main row height.

## Required fidelity surfaces

- Fonts and typography: the implementation retains native SF system faces, semibold title hierarchy, compact 12-point editor text, and the app's existing optical weights. Live heading, bold, underline, task, and strikethrough treatments are visible without source delimiters.
- Spacing and layout rhythm: the `760 x 310` shell, 42-point title row, flexible body, 40-point footer, dividers, horizontal insets, corner geometry, and top-center camera notch remain aligned with the source language. Save state occupies a fixed trailing title slot; the folder is the final footer control.
- Colors and visual tokens: black surface, white opacity ladder, amber note icon, muted toolbar icons, high-contrast white saving spinner, and green saved check use the existing semantic palette. No unrelated new surface treatment was introduced.
- Image quality and asset fidelity: the target contains no content imagery. Every visible control uses a native SF Symbol and remains sharp at `2x`; no custom SVG, emoji, placeholder image, or handcrafted icon substitute is present.
- Copy and content: fixed shell copy remains concise (`Note`, `Untitled note`, `Write a note`). Save-state text was intentionally removed per the request; descriptive help and accessibility labels remain available without adding visible copy.
- Icons: Bold, Italic, Underline, Strikethrough, Link, Numbered list, Bulleted list, Quote, Inline code, Code block, Checklist, More, and Folder are present in the requested left-to-right grouping. Two subtle separators reproduce the Slack taxonomy while the folder remains independently right-aligned.
- States and interactions: idle, saving, saved, failed, active selection, empty-caret style arming, link/image URL entry, multiline underline, checklist conversion, raw source, find/replace, voice-note completion, and folder opening are implemented. The native smoke suite verifies the core editor and save path.
- Accessibility: toolbar buttons have labels, identifiers, hover, pressed, and keyboard-focus treatments; idle save state is removed from the accessibility tree; changing save states expose an updating status label; reduced motion uses a static loading symbol.
- Viewport resilience: this is a fixed-size native panel rather than a responsive web surface. The complete direct toolbar fits without clipping or overlap at the app's `760`-point width.

## Focused-region comparison

The combined comparison includes both full panels and a focused footer pair in the same image. The focused region is required because the toolbar symbols are too small to judge reliably in the full view. It confirms source-equivalent order through Code block, the requested Checklist addition, dark-token adaptation, consistent icon weight, and left-group/right-folder separation.

## Comparison history

1. Baseline source review found the requested P1 mismatches in the old note footer: a large save button, visible `Saved locally` copy, disk icon, word count, and only an `Aa` formatting entry point. The implementation removed those elements, moved the save state into the title row, and added the direct formatting group. Post-fix evidence: `/Users/platonkmazarakis/Documents/iagent/artifacts/iagent-note-markdown.png`.
2. The first saving-state capture exposed a P1 contrast issue: AppKit's mini `ProgressView` rendered too dark against black. It was replaced with an explicitly colored rotating SF Symbol with a reduced-motion fallback. Post-fix evidence: `/Users/platonkmazarakis/Documents/iagent/artifacts/iagent-note-toolbar.png`.
3. The final combined source/implementation comparison found no remaining actionable P0/P1/P2 visual differences. Post-fix full and focused evidence: `/Users/platonkmazarakis/Documents/iagent/artifacts/iagent-note-design-qa-comparison.png`.

## Implementation checklist

- [x] Remove the large bottom save button and visible save copy.
- [x] Place loading/saved state at the trailing edge of the title row.
- [x] Add the Slack-grounded direct formatting toolbar, including Checklist.
- [x] Keep Folder pinned to the far right.
- [x] Hide source syntax during caret and selection editing while preserving Markdown on disk.
- [x] Verify empty-caret styling, underline, checklist selection mapping, autosave, source round-trip, keyboard routing, and Option-N in the native smoke suite.
- [x] Build, ad-hoc sign, capture, compare, and visually inspect the native app.

final result: passed

# Mobile drawer design QA

## Comparison target

- source motion reference: `/Users/platonkmazarakis/Downloads/JoiHomeDemo.mp4`
- extracted 16-frame motion summary: `/Users/platonkmazarakis/Documents/iagent/artifacts/mobile-drawer-reference.png`
- iPhone 15 Pro resting state: `/Users/platonkmazarakis/Documents/iagent/artifacts/mobile-drawer-resting.png`
- iPhone 15 Pro expanded state: `/Users/platonkmazarakis/Documents/iagent/artifacts/mobile-drawer-expanded.png`
- iPhone SE resting state: `/Users/platonkmazarakis/Documents/iagent/artifacts/mobile-drawer-se-resting.png`
- iPhone SE expanded state: `/Users/platonkmazarakis/Documents/iagent/artifacts/mobile-drawer-se-expanded.png`
- source duration: `8.008s`, `720 x 720`, `29.97fps`
- implementation viewports: iPhone 15 Pro and iPhone SE (3rd generation), iOS 17.5, dark appearance

## Reference behavior

- The masthead and briefing are stationary in the page background.
- The list is a separate bottom drawer with a rounded upper edge.
- At the resting detent, the drawer exposes the briefing and occupies the lower portion of the viewport.
- An upward drag directly tracks the finger, then snaps the drawer below the masthead.
- At the upper detent, the drawer covers the briefing and its list becomes independently scrollable.
- A downward drag at the list's top edge returns the drawer to the resting detent.

## Findings

- No actionable P0, P1, or P2 visual differences remain.
- The implementation intentionally keeps the app's existing dark sheet tokens instead of copying the reference's white drawer.
- The top corners preserve the existing `42pt` continuous radius through both detents and during interpolation.
- The fixed bottom dock remains outside the drawer, matching the reference's persistent create control.
- The compact viewport preserves the same hierarchy without text overlap or drawer/dock collision.

## Motion and interaction

- The drawer uses direct vertical translation while dragging and the app's established `cubic-bezier(0.165, 0.84, 0.44, 1)` equivalent for its `0.3s` snap.
- Predicted gesture travel allows a short, decisive flick to change detents while a partial drag returns to its origin.
- Horizontal intent is ignored by the drawer so the root tab pager remains available.
- The inner list is disabled at rest and enabled only at the upper detent.
- At the upper detent, downward movement transfers to the drawer only when the list is at its top boundary; otherwise the list retains scrolling.
- Native pull-to-refresh was removed from these surfaces because it competes with the required downward-collapse gesture. Background sync and the existing explicit Sync action remain available.

## Verification

- [x] Today, Codex, Notes, and Todos no longer wrap hero and list in one page-level scroll view.
- [x] Shared drawer compiles under Swift 6 concurrency checks.
- [x] Debug iOS Simulator build succeeds for iOS 17.5.
- [x] Resting and expanded states were captured on iPhone 15 Pro.
- [x] Resting and expanded states were captured on iPhone SE (3rd generation).
- [x] Shared Swift sync test passes (`1` test, `0` failures).

final result: passed
