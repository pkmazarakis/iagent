# Codex desktop motion language

Use motion to preserve continuity while long-running work changes state. This guide separates directly observed behavior from implementation recommendations.

## Contents

- [Directly observed patterns](#directly-observed-patterns)
- [Recommended timing contract](#recommended-timing-contract)
- [Component storyboards](#component-storyboards)
- [Reduced motion](#reduced-motion)
- [Official motion sources](#official-motion-sources)

## Directly observed patterns

The official recordings repeatedly show:

- Stable sidebars, composers, toolbars, and modal frames while content changes inside them.
- Soft selection washes instead of outlined or scaled rows.
- Menus opening directly beneath their trigger with no layout jump.
- Prompt text appearing inside an anchored composer while the trailing action stays fixed.
- Send controls becoming stop controls in the same slot during execution.
- Dictation replacing the microphone area with a timer, waveform, and stop control, then returning to the normal composer.
- Compact activity lines appearing incrementally, with chevrons for optional detail.
- Branch, commit, and automation workflows using centered rounded modals over a dimmed but spatially stable surface.
- Modal state changing in place from configuration to progress to success.
- Small inline skill or app chips supplying local color while the rest of the interface stays neutral.
- Tiny task-state marks and muted metadata in thread lists.
- Editorial product videos using camera zooms and large title cards; these belong to marketing storytelling, not in-product microinteraction.

The strongest principle is **spatial continuity**: update status inside a persistent region so long-running work feels supervised rather than disruptive.

## Recommended timing contract

These timings are implementation inferences, not published OpenAI specifications.

| Interaction | Duration | Recommended treatment |
|---|---:|---|
| Hover | 90–120 ms | background and icon opacity only |
| Selection | 140–170 ms | fill, border, and optional leading rail |
| Tooltip | 120–160 ms | fade; no scale |
| Menu/popover | 150–190 ms | fade plus 4-point rise |
| Inline disclosure | 160–200 ms | height and opacity; retain scroll position |
| Composer state swap | 140–180 ms | crossfade in the same control slot |
| Modal entry | 180–220 ms | backdrop fade plus 0.98→1 scale or 6-point rise |
| Modal content state | 150–200 ms | crossfade inside a stable card |
| Drawer/side pane | 190–240 ms | ease-out reveal; preserve primary anchors |
| Row insert/reorder | 180–230 ms | position, height, and opacity |
| Completion/error settle | 160–200 ms | crossfade spinner to final icon; no flash |

Use a restrained ease-out curve. A practical starting point is `cubic-bezier(.2,.8,.2,1)` for entrances and `cubic-bezier(.2,0,0,1)` for state changes. Treat these curves as implementation suggestions.

## Component storyboards

### Thread and agent list

1. **Open:** fade content in and move it upward 4 points over 160 ms.
2. **Hover:** change only the surface and icon contrast over 100 ms.
3. **Select:** transition fill, subtle border, and leading rail over 150 ms.
4. **Running:** rotate one thin arc at roughly one cycle per 1.0–1.2 seconds.
5. **Progress update:** crossfade summary copy over 120–160 ms without changing row height.
6. **Complete:** crossfade the arc into a check over 180 ms.
7. **Needs attention:** settle to amber icon and label; do not pulse indefinitely.
8. **Insert/reorder:** animate position and opacity over 200 ms.

### Composer

1. Keep attach, permissions, model, effort, voice, and action slots fixed.
2. Crossfade send to stop in the same circular slot when work begins.
3. Dim unavailable options rather than removing them.
4. Insert activity or goal state immediately above the composer with a short height/opacity reveal.
5. Return to the normal composer in place after completion.

### Goal and long-running work

1. Reveal the goal row directly above the composer.
2. Keep goal label, truncated title, time, edit, pause/resume, clear, and disclosure actions on one stable baseline.
3. Update elapsed time without animation.
4. Crossfade pause/resume icons in place.
5. Use a quiet running indicator; reserve repeated motion for live execution only.

### Voice

1. Replace the microphone slot with recording status.
2. Use a low-amplitude waveform and visible timer.
3. Keep the waveform confined to the active region; do not pulse unrelated rows.
4. Crossfade back to the normal composer after stopping.

### Modal workflow

1. Fade in a neutral dimming layer.
2. Bring in one centered card with a subtle rise or scale.
3. Expand dropdowns inside the card.
4. Replace configuration, progress, and success content inside the same frame.
5. Close with a short fade; return focus to the original trigger.

### Drawer or split pane

1. Keep the conversation and composer visible.
2. Reveal terminal, browser, review, or summary in a bottom or trailing pane.
3. Animate the divider and pane together.
4. Preserve scroll, selection, and collapsed state when toggling.

### Diff review

1. Reveal line actions on hover.
2. Expand a file or hunk with height and opacity while retaining scroll position.
3. Insert review findings beside their source lines.
4. Animate diff-stat alignment and count changes subtly; do not bounce numbers.

## Continuous motion budget

Allow at most one dominant continuous motion per active region:

- spinner or arc for running;
- waveform for recording;
- low-contrast shimmer for loading;
- indeterminate progress only when progress cannot be quantified.

Stop continuous motion immediately when the state resolves. Avoid ambient glows, breathing cards, scrolling gradients, and simultaneous row spinners.

## Reduced motion

- Replace zoom, scale, and pane translation with 100–160 ms crossfades.
- Replace a rotating running arc with a static mint dot plus `Running` label.
- Replace waveform amplitude animation with a static recording indicator and timer.
- Keep row insertion ordered; switch it to an immediate layout update plus fade.
- Preserve every state label, status icon, focus position, and control.

## Official motion sources

### Current unified desktop shell

The local originals are archived at `../../../../artifacts/codex-desktop-design-sources/motion/` in the source repository.

- [Proactive teammate](https://cdn.openai.com/codex/docs/developers-website/use-cases/proactive-teammate-v2.mp4) — 29.5 s, 3840×2160.
- [Fraud-spike analysis](https://cdn.openai.com/codex/docs/developers-website/use-cases/data-analysis-fraud-spike.mp4) — 15.3 s, 3840×2160.
- [Draft PRDs](https://cdn.openai.com/codex/docs/developers-website/use-cases/draft-prds-from-slack-linear-docs.mp4) — 20.8 s, 3840×2160.
- [CSV cleaning](https://cdn.openai.com/codex/docs/developers-website/use-cases/data-analysis-cleaning-csv.mp4) — 16.8 s, 3840×2160.
- [Feedback synthesis](https://cdn.openai.com/codex/docs/developers-website/use-cases/feedback-synthesis-into-gsheets.mp4) — 26.4 s, 3840×2160.

### Codex-specific product motion

- [Launch walkthrough](https://player.vimeo.com/video/1161130375?h=2470243d0c) — navigation, composer, worktrees, review, skills, and automations.
- [Computer use](https://player.vimeo.com/video/1183780832?h=f579830b18).
- [In-app browser](https://player.vimeo.com/video/1183780962?h=deca50f4ea).
- [Plugins](https://player.vimeo.com/video/1183781009?h=5a011a7afc).
- [Automation](https://player.vimeo.com/video/1183782137?h=d0f18d769a).
- [Artifact annotations](https://player.vimeo.com/video/1197553037?h=33eb53e37c).
- [Cross-device continuity](https://player.vimeo.com/video/1192355275?h=21a61dbf54).

Use current stills for present-day geometry and these videos for motion language. Launch-era geometry may differ from the current unified shell.
