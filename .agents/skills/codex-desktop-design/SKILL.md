---
name: codex-desktop-design
description: Design, redesign, review, or generate desktop application UI that should match the OpenAI Codex and ChatGPT desktop aesthetic. Use for Codex-like thread lists, agent dashboards, composers, review and diff panes, terminals, browser panels, plugin directories, settings, automations, status surfaces, and motion specifications, or when evaluating a UI against the bundled official reference images. Do not use to copy OpenAI logos, product names, or protected brand marks into unrelated products.
---

# Codex Desktop Design

Reproduce the product's design language—calm hierarchy, persistent work regions, restrained surfaces, and spatial continuity—without copying OpenAI branding.

## Establish visual truth

Use this priority when references disagree:

1. Treat current unified desktop-shell references as structural truth.
2. Use Codex-specific 2026 surfaces for specialist components such as review, terminal, browser, goals, plugins, and automations.
3. Use launch-era and marketing references for atmosphere and composition, not current component geometry.

Read [references/source-catalog.md](references/source-catalog.md) before choosing images. Label the visual vintage in design notes. Inspect three to five relevant files under `assets/references/official/`; do not average every reference into one style.

## Follow this workflow

1. Classify the surface: shell, thread list, composer, review, terminal, browser, settings, marketplace, automation, or modal.
2. Choose light or dark mode and the platform context. Preserve platform conventions while keeping the Codex hierarchy.
3. Identify the input image role: edit target, structural reference, style reference, or content reference.
4. Read [references/design-system.md](references/design-system.md). For interactive work, also read [references/motion.md](references/motion.md).
5. Map content into persistent regions before styling: navigation, task context, work canvas, supporting pane, composer, and status.
6. Separate selection, task type, execution state, and urgency. Never encode all four in one badge.
7. Produce the requested implementation, mockup, critique, or prompt.
8. Validate against the checklist below and the chosen references.

For image generation or image editing, read [references/imagegen-prompt.md](references/imagegen-prompt.md) and use the image-generation skill when available.

## Apply the core visual rules

- Build with layered neutral surfaces, hairline separators, large quiet regions, and precise alignment.
- Use a 4-point base grid; favor 8, 12, 16, 24, 32, and 48-point intervals.
- Keep internal surfaces nearly flat. Reserve a broad soft shadow for a floating app window or panel over a desktop backdrop.
- Use one primary focal region. Avoid card grids when a list, drawer, split pane, or inline disclosure is more natural.
- Anchor the composer or primary action region. Let activity, goals, terminal output, and review expand around persistent anchors.
- Use system sans typography. Reserve monospaced type for code, diffs, commands, paths, and terminal output.
- Use regular and medium weights for most text; reserve semibold for window titles, thread titles, and decisive actions.
- Keep icons simple, optically balanced, and mostly monochrome. Provide 28–40 point hit targets even when the glyph is smaller.
- Use color sparsely for links, focus, semantic state, diffs, and installed-app identity. Prefer tint and opacity over saturated fills.
- Make light and dark themes structurally identical. Rebuild elevation and contrast per theme instead of mechanically inverting colors.
- Treat text truncation as a layout decision: preserve the title, collapse the summary next, then hide nonessential metadata.
- Prefer sentence case, direct labels, and calm status copy.

## Build thread and agent lists

- Use a stable row grid: identity glyph, title and optional summary, type or capability, execution state, updated time.
- Keep dense desktop rows around 44–52 points high unless the content truly needs a second line.
- Distinguish selection with a soft neutral fill and optional 2-point leading rail.
- Keep the selection rail neutral or focus-colored; never reuse Running, warning, or failure color for selection.
- Place runtime state in one consistent slot with icon plus accessible label: Running, Complete, Needs attention, Failed, Paused.
- Treat labels such as Goal, Voice, Review, or Automation as type chips, not runtime states.
- Use inset dividers beginning after the identity glyph. Show a bottom fade only when content actually scrolls.
- Keep avatars and monograms mostly neutral; do not repeat a status color in the glyph, border, badge, chip, and text.
- When a dedicated state slot exists, keep identity tiles identity-only and do not attach overlapping runtime badges to them.

## Apply motion

- Preserve spatial continuity. Change state inside an existing row, composer, drawer, side panel, or modal.
- Use short fades and small 4–6 point translations; avoid bounce, elastic overshoot, dramatic scale, or simultaneous ambient motion.
- Reuse the existing action slot for send, stop, progress, and success states.
- Keep continuous animation rare: one spinner, shimmer, waveform, or progress affordance per active region.
- Provide a reduced-motion state that replaces translation, zoom, and pulsing with short crossfades and static status marks.

The numeric timing values in [references/motion.md](references/motion.md) are implementation recommendations inferred from official recordings, not published OpenAI specifications.

## Avoid common drift

- Avoid neon cyberpunk styling, glossy gradients inside controls, glassmorphism everywhere, heavy shadows, or ornamental lighting.
- Avoid oversized typography, excessive whitespace inside dense tools, and consumer-dashboard card soup.
- Avoid pure decorative orbs, pulses, and glows that do not communicate state.
- Avoid using bright green as a generic brand color; keep it semantic unless the selected official theme shows otherwise.
- Avoid cloning the OpenAI knot, Codex name, ChatGPT name, or official wallpaper into an unrelated product.
- Avoid presenting inferred colors, radii, or timings as official design tokens.

## Deliver design work

For a design or implementation, include:

- the selected reference files and their visual vintage;
- a compact token block for color, type, spacing, radius, and motion;
- the component and state map, including empty, hover, selected, running, complete, warning, failed, and disabled states as relevant;
- light/dark and reduced-motion behavior when the surface is interactive;
- a note separating directly observed patterns from implementation inference.

## Validate

- Does one region clearly lead the hierarchy?
- Are navigation, content, support panes, and composer spatially stable?
- Are selection, type, execution, and urgency encoded separately?
- Is secondary text readable without competing with the title?
- Are borders, shadows, radii, and colors restrained?
- Does every continuous animation communicate live state?
- Does reduced motion preserve all information?
- Does the result feel native to its platform without copying OpenAI branding?
- Does it resemble the chosen official references at a glance and under close comparison?

## Resource map

- [references/design-system.md](references/design-system.md): inferred tokens, layout grammar, and component recipes.
- [references/motion.md](references/motion.md): observed motion language and recommended timing contract.
- [references/imagegen-prompt.md](references/imagegen-prompt.md): prompt scaffolding for generated or edited UI mockups.
- [references/source-catalog.md](references/source-catalog.md): provenance, dimensions, vintage, and routing for every source.
- `assets/references/official/`: bundled official still images.
