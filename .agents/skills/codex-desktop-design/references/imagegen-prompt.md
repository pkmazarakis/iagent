# Image-generation prompt guide

Use this guide with an image-generation or image-editing tool to create Codex-like desktop UI mockups. Keep image roles explicit and use the smallest relevant reference set.

## Choose the mode

- Use `ui-mockup` when generating a new interface from a written brief.
- Use `style-transfer` when redesigning a supplied screen while preserving its function, content hierarchy, and overall frame.
- Use `precise-object-edit` when changing only a named component or state.

Treat a supplied UI screenshot as the **edit target** unless the user says it is only inspiration. Treat files from `assets/references/official/` as **style and structure references**.

## Select references

Choose three to five references from [source-catalog.md](source-catalog.md):

1. One overall shell or theme reference.
2. One reference for the primary component type.
3. One reference for the relevant state or workflow.
4. Optionally, one platform or light/dark reference.

Do not combine marketing art, launch-era geometry, current shell geometry, and several custom themes without explaining which source controls which decision.

## Prompt scaffold

```text
Use case: <ui-mockup|style-transfer|precise-object-edit>
Asset type: polished desktop product UI mockup
Primary request: <screen or component to design>
Input images:
- Image 1: <edit target or structural reference>
- Image 2: <overall Codex shell/style reference>
- Image 3: <component reference>
- Image 4: <state/motion reference>
Style/medium: realistic shippable desktop application UI, not concept art
Composition/framing: <window, panel, widget, or split-pane dimensions and hierarchy>
Theme: <light|dark|system>; restrained layered neutrals
Typography: platform system sans; medium titles; regular secondary text; mono only for code or terminal
Interaction state: <idle|hover|selected|running|complete|paused|failed>
Text (verbatim): "<only text that must be exact>"
Constraints: preserve <functional invariants>; separate selection, type, execution state, and urgency; use hairline dividers; stable alignment; sparse semantic color; no OpenAI logo or product name
Avoid: neon, glossy gradients, glassmorphism everywhere, heavy shadows, card soup, oversized type, decorative orbs, invented branding, extra controls, watermark
```

## Editing invariants

For a redesign, repeat these constraints:

- Preserve the canvas aspect ratio unless a new size is requested.
- Preserve the product function and content order.
- Preserve meaningful labels the user asks to keep.
- Change the visual system and component geometry, not the information architecture, unless the user requests a UX change.
- Keep one primary focal region.
- Do not add brand marks, logos, or unrelated navigation.

If the source screenshot contains private or incidental text and exact wording is not important, replace it with concise representative labels rather than reproducing sensitive content.

## Codex-specific visual cues

- Calm native desktop utility rather than a dashboard.
- Graphite or off-white layered surfaces with thin contrast steps.
- Large quiet container radii and smaller compact control radii.
- Stable trailing actions and anchored composer or status region.
- Soft neutral selection fill.
- Small semantic state icon plus label.
- Restrained cool tint in a sidebar or outer desktop backdrop, not across every control.
- Sparse blue, mint, amber, coral, and diff colors only where semantically useful.
- Strong legibility for secondary text.

## Validate the output

- Confirm text accuracy for every required label.
- Confirm the chosen theme and platform are internally consistent.
- Confirm no status color is repeated unnecessarily across avatar, border, badge, and label.
- Confirm identity tiles carry no overlapping runtime badges when the layout already has a state column.
- Confirm selection does not reuse Running, warning, or failure color.
- Confirm titles survive truncation before summaries.
- Confirm icons share one weight and optical size.
- Confirm the result has no extra logos, slogans, watermarks, decorative glows, or invented controls.
- Compare directly against the selected references, not against memory.

Iterate with one targeted change at a time and restate invariants on every edit.
