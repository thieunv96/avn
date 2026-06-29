---
paths:
  - "**/*.{tsx,jsx,vue,svelte,css,scss}"
  - "**/components/**"
---

# UI work

- Reuse existing components, design tokens, and patterns first. Do not invent a new visual style unless asked.
- If the request is vague, clarify the target user, the page goal, and the main action before implementing.

For Asilla/security products, prioritize operators under load:

- Large readable text, clear hierarchy, simple layout, high contrast, low cognitive load.
- An obvious primary action per screen.
- Real empty, loading, and error states — not just the happy path.
- Realistic long-text handling (truncation, wrapping, overflow).

## Verifying UI changes

- Test the change through a real browser automation tool (Playwright, Puppeteer, or Cypress) — not by inspection alone.
- When given a design, take a screenshot of the result, compare it to the design, list the differences, and fix them.
