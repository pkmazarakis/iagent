# Codex desktop design system

This document translates recurring patterns in the bundled official screenshots into reusable implementation guidance. Values are approximate implementation tokens, not published OpenAI specifications. Sample the chosen reference when pixel-level matching matters.

## Contents

- [Design character](#design-character)
- [Reference hierarchy](#reference-hierarchy)
- [Layout grammar](#layout-grammar)
- [Approximate tokens](#approximate-tokens)
- [Typography](#typography)
- [Component recipes](#component-recipes)
- [State and color](#state-and-color)
- [Platform and theme behavior](#platform-and-theme-behavior)
- [Accessibility](#accessibility)

## Design character

Codex desktop is a calm command center, not a conventional analytics dashboard. It keeps navigation, conversation, code review, artifacts, browser output, and terminal state inside stable regions. The design is dense where work happens and spacious where the user chooses the next action.

The recurring character is:

- native desktop framing with quiet controls;
- neutral surfaces with thin contrast steps;
- large radii on containers, smaller radii on controls;
- one strong focal region rather than many equally weighted cards;
- compact metadata and restrained semantic color;
- progressive disclosure for detail;
- persistent composer and work context;
- broad, soft atmospheric color outside the app window, not inside every control.

## Reference hierarchy

Choose references by task:

- **Overall shell and empty states:** `01-app-light.webp`, `02-app-dark.webp`, `20-current-app-surface.png`.
- **Theme expression:** `03-themes-side-by-side.webp`.
- **Split workspaces and browser:** `04-browser-light.webp`, `05-browser-dark.webp`.
- **Settings and form controls:** `06-browser-developer-mode-light.webp`, `07-browser-developer-mode-dark.webp`.
- **Automations and scheduling:** `08-automations-light.webp`, `09-automations-dark.webp`.
- **Platform adaptation:** `10-windows-light.webp`, `11-windows-dark.webp`.
- **Review and inline comments:** `12-code-review-light.webp`, `13-code-review-dark.webp`.
- **Composer plus terminal drawer:** `14-terminal-light.webp`, `15-terminal-dark.webp`.
- **Search, marketplace, and two-column lists:** `16-plugins-directory-light.webp`, `17-plugins-directory-dark.webp`.
- **Plugin invocation chips:** `18-plugin-invocation-light.png`, `19-plugin-invocation-dark.png`.
- **Goals and long-running state:** `27-goal-controls-light.webp`, `28-goal-controls-dark.webp`.
- **Marketing atmosphere only:** `21-launch-seo.png`, `22-product-built.png` through `26-product-raise-the-bar.png`.

## Layout grammar

### Regions

Build the desktop shell from persistent regions:

1. **Window chrome or global rail** — navigation, back/forward, workspace title, top-level actions.
2. **Primary navigation** — projects, pinned work, threads, plugins, automations, settings.
3. **Work canvas** — conversation, empty state, artifact, diff, browser, or settings content.
4. **Supporting pane** — summary, file tree, browser, review, sources, or terminal.
5. **Composer/action anchor** — prompt input, permissions, model, effort, voice, send/stop.
6. **Transient layer** — menu, popover, modal, tooltip, inline comment, or toast.

Keep the first five spatially stable. Prefer inline expansion, drawers, and split panes over full navigation for temporary detail.

### Grid and dimensions

- Base grid: 4 points.
- Inline gaps: 4, 8, or 12 points.
- Control clusters: 12 or 16 points.
- Section gaps: 20, 24, or 32 points.
- Major canvas margins: 32–48 points on desktop.
- Compact thread/list row: 44–52 points.
- Toolbar: 44–52 points.
- Sidebar target width: 240–320 points; allow user resizing when the product warrants it.
- Composer: 64–112 points depending on one- or two-line mode.
- Split panes: use a hairline divider and preserve a meaningful minimum width for each side.

### Alignment

- Align titles, summaries, and timestamps to stable columns.
- Begin row dividers after the identity glyph when possible.
- Keep trailing actions in fixed slots so labels can change without shifting the row.
- Keep text baselines more consistent than icon boxes; optically align symbols.
- Protect the task title. Truncate summary copy before title copy.

## Approximate tokens

Use these only as a starting point. The application supports custom themes, so geometry and contrast relationships are more durable than any one color.

### Neutral dark baseline

| Token | Suggested value | Role |
|---|---:|---|
| `canvas` | `#0E0E0F` | primary work canvas |
| `surface-1` | `#171718` | sidebar, drawer, modal |
| `surface-2` | `#1F1F20` | composer, selected rows |
| `surface-3` | `#282829` | hover, raised control |
| `border-subtle` | `rgba(255,255,255,.08)` | dividers and outlines |
| `border-strong` | `rgba(255,255,255,.14)` | focus-adjacent outline |
| `text-primary` | `#F1F1F1` | titles and main copy |
| `text-secondary` | `#A4A4A7` | summaries and metadata |
| `text-tertiary` | `#747477` | low-priority hints |

### Neutral light baseline

| Token | Suggested value | Role |
|---|---:|---|
| `canvas` | `#FBFBFA` | primary work canvas |
| `surface-1` | `#F4F4F2` | sidebar and drawer |
| `surface-2` | `#FFFFFF` | composer and modal |
| `surface-3` | `#ECECEA` | hover and selected rows |
| `border-subtle` | `rgba(0,0,0,.08)` | dividers and outlines |
| `border-strong` | `rgba(0,0,0,.14)` | focus-adjacent outline |
| `text-primary` | `#202020` | titles and main copy |
| `text-secondary` | `#6E6E72` | summaries and metadata |
| `text-tertiary` | `#98989C` | low-priority hints |

### Semantic color

Keep saturation controlled. Use a pale tint or low-opacity fill before using a solid background.

- Link/focus blue: approximately `#5B8DEF`.
- Success/running mint: approximately `#5FCB87`.
- Warning/attention amber: approximately `#E4B85C`.
- Failure/destructive coral: approximately `#F06E61`.
- Diff addition: desaturated green background plus brighter green text/rail.
- Diff deletion: desaturated red background plus coral text/rail.

Never use semantic color as the only signal. Pair it with an icon and label.

### Radius and elevation

- App window or large floating panel: 16–22 points.
- Composer, drawer, or large card: 16–20 points.
- Modal and popover: 12–16 points.
- Row selection and compact control: 8–12 points.
- Pill/chip: fully rounded or 8–12 points depending on height.
- Internal elevation: border plus subtle tonal change; usually no shadow.
- Window over wallpaper: broad, soft shadow with low opacity and a large blur.

## Typography

Use the platform system sans unless an established product theme specifies another font.

| Role | Suggested size/line | Weight |
|---|---:|---|
| Major empty-state prompt | 24–32 / 32–40 | medium |
| Window or pane title | 16–20 / 22–26 | semibold |
| Thread/list title | 13–15 / 18–20 | medium or semibold |
| Body/conversation | 13–15 / 20–23 | regular |
| Summary/secondary | 12–14 / 17–20 | regular |
| Metadata/chip | 11–13 / 14–17 | medium |
| Terminal/code | 12–15 / 18–22 | regular mono |

Use weight before size to strengthen hierarchy. Avoid bold secondary text and oversized dashboard numerals unless the content itself is numerical analysis.

## Component recipes

### App window

- Use native traffic-light or platform window controls.
- Keep the top bar thin and visually continuous with the main canvas.
- Allow a cool translucent sidebar over the desktop wallpaper when the platform supports it.
- Put atmospheric gradient or wallpaper outside the window; keep the work canvas quiet.

### Sidebar

- Use icon-plus-label rows with 8–12 point gaps.
- Group sections using quiet labels and 20–28 point separation.
- Select with a low-contrast fill; avoid bright outlines.
- Keep counts and times trailing and secondary.

### Thread or agent row

- Grid: 28–36 point identity glyph, 8–12 point gap, flexible title/summary, optional type, runtime state, time.
- Use one or two text lines. Keep row height consistent within a list.
- Put capability/type in a neutral compact chip.
- Put execution state in one fixed slot with icon and accessible label.
- Use a 2-point leading rail only for selection or urgent attention, not every state.

### Composer

- Anchor it near the bottom of the work canvas.
- Use a large rounded container with a subtle outline and one or two control rows.
- Keep attach, permissions, model, effort, voice, and send/stop in stable slots.
- Make the primary action circular and high contrast; reuse that slot for stop and completion.
- Place goal/progress state immediately above the composer rather than as a detached toast.

### Modal and menu

- Center consequential workflows in a rounded modal over a quiet dimming layer.
- Expand menus directly below the trigger.
- Use soft row hover and a trailing check for the selected option.
- Change modal content in place for progress and success.

### Review and diff

- Preserve code alignment and use monospace type.
- Use low-opacity red/green row fills with a brighter leading rail.
- Attach review cards inline to the relevant lines.
- Keep comment cards neutral and rounded so semantic diff color remains legible.
- Reveal line actions on hover rather than showing controls everywhere.

### Terminal drawer

- Keep it inside the conversation workspace.
- Use a thin header and divider, compact close action, dense mono output, and minimal chrome.
- Preserve the composer and project context when the drawer opens.

### Marketplace or plugin directory

- Use a strong centered heading, small segmented filter, compact search field, and two-column list.
- Let app icons provide local color; keep surrounding structure neutral.
- Show installed state with a quiet check and available state with a compact plus button.

## State and color

Model these independently:

- **Selection:** which row or pane is active.
- **Type:** Goal, Voice, Review, Automation, Plugin, or project category.
- **Execution:** idle, queued, running, complete, paused, failed.
- **Urgency:** normal, unread, needs attention, blocked.

Avoid the common failure mode where a colored avatar border, overlapping badge, colored chip, and colored label all repeat the same status.

## Platform and theme behavior

- On macOS, preserve traffic lights, translucent sidebars, rounded windows, and restrained iconography.
- On Windows, preserve platform title-bar and window conventions while keeping the same pane hierarchy and component language.
- In dark mode, create separation through tonal steps and borders rather than heavy shadows.
- In light mode, use warm or neutral off-whites to avoid a sterile all-white canvas.
- Keep component placement, dimensions, and semantics consistent between themes.

## Accessibility

- Target at least WCAG AA contrast for body and control labels.
- Do not let secondary text become decorative gray-on-gray.
- Give icon-only controls accessible labels and generous hit targets.
- Maintain visible keyboard focus without introducing a permanent bright border.
- Pair state color with icon and text.
- Preserve labels, order, and status under reduced motion.
