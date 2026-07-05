---
paths:
  - "**/*.{tsx,jsx,vue,svelte,css,scss}"
  - "**/components/**"
---

# UI work

- Reuse existing components, design tokens, and patterns first. Do not invent a new visual style unless asked.
- If the request is vague, clarify the target user, the page goal, and the main action before implementing.

For security products, prioritize operators under load:

- Large readable text, clear hierarchy, simple layout, high contrast, low cognitive load.
- An obvious primary action per screen.
- Real empty, loading, and error states — not just the happy path.
- Realistic long-text handling (truncation, wrapping, overflow).

## Inventory before creating anything new

Before writing a new component, style, or token:

- List the existing components and design tokens (colors, spacing, typography) relevant to this screen — check the component directory, theme/token files, and 1–2 similar existing screens.
- Reuse or extend one of them. Only create new if none fits, and state why each candidate was rejected.
- New values (colors, spacing, font sizes) must come from existing tokens, not hardcoded literals.

## Verifying UI changes

- Test the change through a real browser automation tool (Playwright, Puppeteer, or Cypress) — not by inspection alone.
- When given a design, take a screenshot of the result, compare it to the design, list the differences, and fix them.
