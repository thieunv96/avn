---
paths:
  - "**/*.{tsx,jsx,vue,svelte,css,scss}"
  - "**/components/**"
---

# UI rules — security-ops products for the Japanese market

These complement `CLAUDE.md` (§3 inspect/reuse, §10 verification) with UI-specific standards.
Target users: security guards and shift leaders operating under time pressure, often on 1080p
monitors in dim control rooms. The interface must be usable by a stressed, non-technical
operator on their first shift.

## 1. Inventory before creating anything new

Before writing a new component, style, or token (per CLAUDE.md §3, with UI specifics):

- List existing components and design tokens (colors, spacing, typography) relevant to this
  screen — check the component directory, theme/token files, and 1–2 similar existing screens.
- Reuse or extend one of them. Create new only if none fits, and state why each candidate was
  rejected. Do not invent a new visual style unless explicitly asked.
- New values (colors, spacing, font sizes) must come from existing tokens, never hardcoded
  literals.
- If a request is vague on the **screen goal or primary action**, ask before implementing
  (CLAUDE.md §1). For minor ambiguities, proceed and state your assumption inline — do not
  stall on small details.

## 2. Operators under load (core priorities)

- One obvious primary action per screen. Secondary actions are visually subordinate
  (ghost/text buttons).
- Measurable readability, not vibes:
  - Body text ≥ 14px (16px preferred for operator-facing screens).
  - Contrast ≥ WCAG AA: 4.5:1 for text, 3:1 for large text and UI icons.
  - Critical status (alarms, incidents) readable at a glance from ~1m.
- Simple layout, shallow hierarchy: max 2 levels of visual nesting per panel.
- Progressive disclosure: show core info by default; advanced settings go behind an
  expander/secondary view, never crowd the main screen.

## 3. System status & feedback (Nielsen #1)

- Every action gets immediate visible feedback: button pending state, toast, or inline
  status — within 100ms perceived.
- Long operations (>1s) show progress; >10s show cancel.
- Implement real **empty, loading, and error states** for every data view — not just the
  happy path. Empty states say what the screen is for and what to do next.

## 4. Error prevention & recovery (Nielsen #3, #5, #9)

- Destructive or irreversible actions (close incident, delete record, end shift handover)
  require confirmation that names the object (e.g. 「インシデント #1042 をクローズしますか？」),
  or provide undo.
- Never rely on color alone to signal state — pair with icon and label.
- Error messages: plain Japanese, state what happened + what to do next. No stack traces,
  no error codes alone, no blame ("入力が不正です" → say which field and what format is
  expected).
- Disable-and-explain over silent failure: if an action is unavailable, show why
  (tooltip/help text), don't just gray it out.

## 5. Recognition over recall (Nielsen #6)

- Prefer pick-lists, recent items, and autocomplete over free-text entry.
- Smart defaults: prefill today's date, current shift, current user, the most common option.
  Every prefill must remain editable.
- Keep context visible: when acting on an incident/report, its ID and title stay on screen
  throughout the flow.

## 6. Flexibility & efficiency (Nielsen #7)

- Mouse/touch path for novices; keyboard shortcuts for repeat actions used by shift leaders
  (document them in a `?` shortcut overlay).
- Frequent flows reachable in ≤ 2 clicks from the main screen.

## 7. Consistency (Nielsen #4)

- Visual: one palette, one type scale, one icon set — all from tokens.
- Behavioral: the same control does the same thing everywhere (e.g. "✕" always closes,
  never deletes).
- Terminology: one term per concept across the whole product. Decide JA-first wording once
  (e.g. ログイン, not サインイン elsewhere) and keep a glossary. Use the domain's real
  vocabulary — 警備員, 巡回, 発報, 引継ぎ — not developer terms (Nielsen #2).

## 8. Japanese text & locale rules

- Font stack: `"Noto Sans JP", "Hiragino Kaku Gothic ProN", "Yu Gothic", sans-serif`
  (or the project's existing JA token). Never a Latin-only stack.
- Japanese body text: `line-height ≥ 1.7`. Headings ≥ 1.4.
- Do **not** use italic for Japanese. Emphasize with weight, size, or color.
- CJK wrapping: set `overflow-wrap: anywhere` (or `line-break: strict`) where long JA
  strings appear; verify no mid-word overflow of half-width runs (IDs, URLs).
- Numbers and IDs: half-width (半角). Dates: `YYYY/MM/DD`, time: 24h `HH:mm`. If 和暦 is
  required, show it alongside, never instead.
- Long-text handling is mandatory: test every label/cell with a realistic long Japanese
  string (e.g. a 40+ char facility name), define truncation with tooltip or wrapping —
  never let it clip silently.
- Never use lorem ipsum; use realistic Japanese sample data.

## 9. Accessibility (JIS X 8341-3 / WCAG 2.1 AA)

- Full keyboard operability; visible focus states on all interactive elements
  (no `outline: none` without replacement).
- Hit targets ≥ 44×44px for touch-capable screens.
- Semantic HTML / ARIA roles for status regions (alarms use `role="alert"` / live regions).

## 10. Verifying UI changes

The mechanics — real browser automation (Playwright/Puppeteer/Cypress), e2e scoping, and the
fallback when the environment cannot run a browser — are defined in CLAUDE.md §10 and
`.claude/rules/testing.md`. UI-specific requirements on top:

- Layout, visual, or state changes: verify in a real browser, not inspection alone.
  Copy-only changes don't need a new browser run (the full test suite per CLAUDE.md §10
  still runs).
- When given a design: screenshot the result, compare against the design, list the
  differences, fix them, re-screenshot.
- Verify the screens the change touches at 1920×1080 and 1366×768, with realistic long JA
  data loaded, and with each of empty/loading/error states triggered at least once.
