---
paths:
  - "**/*.{tsx,jsx,vue,svelte,css,scss}"
  - "**/components/**"
---

# UI rules: design and test checklist

Target users: operators under time pressure, often on 1080p monitors in dim rooms. Every screen
has to work for a stressed, non-technical user on their first shift. These rules complement
`CLAUDE.md` §3 (reuse) and §10 (verification).

## 1. Reuse before creating

- List the existing components and design tokens (colors, spacing, typography) relevant to the
  screen (component directory, theme/token files, 1–2 similar screens) and reuse or extend one.
  Create something new only when nothing fits, and say why each candidate was rejected.
- New values (colors, spacing, font sizes) come from existing tokens, never literals.
- If the screen goal or primary action is unclear, ask before implementing (CLAUDE.md §1). For
  minor ambiguities, proceed and state the assumption inline.

## 2. Design requirements

Apply every item when designing a screen; verify every item when testing it (§4).

### Visual and design conformance

- Layout & alignment: position, spacing (margin/padding), and sizes follow the design spec
  (Figma) when one exists, otherwise the existing screens; grid and block alignment hold. Keep
  the hierarchy shallow: at most 2 levels of visual nesting per panel.
- Colors & imagery: colors come from the brand palette/tokens; images and icons are crisp, not
  distorted, and at the right ratio.
- Typography: font family, size, weight, and line height come from the type scale. Body text
  ≥ 14px (16px preferred); critical status (alarms, incidents) readable at a glance from ~1 m.
- Component states: default, hover/active/focus, disabled, loading, empty, and error each render
  correctly. Every data view ships real loading/empty/error states; an empty state says what the
  screen is for and what to do next; a disabled control shows why (tooltip/help text).
- Responsive: no text overflow or broken layout at HD (1366×768) and FHD (1920×1080).

### UX and usability

- Usability: the user reaches the screen's goal quickly. One obvious primary action per screen;
  secondary actions are visually subordinate (ghost/text buttons); advanced settings sit behind
  an expander or secondary view.
- User flow: no redundant, confusing, or broken steps; frequent flows within 2 clicks of the main
  screen; keyboard shortcuts for repeat actions, documented in a `?` overlay.
- Visual hierarchy: the most important information is seen first; the primary CTA stands out and
  leads to the next step.
- Feedback: every action gets visible feedback within ~100 ms (pending state, toast, inline
  status, navigation). Operations over 1 s show progress; over 10 s offer cancel.
- Consistency: one palette, one type scale, one icon set, all from tokens; the same control does
  the same thing everywhere (✕ always closes, never deletes); one term per concept across the
  product, using the domain's vocabulary rather than developer terms.
- Accessibility (WCAG 2.1 AA): contrast ≥ 4.5:1 for text and 3:1 for large text and icons; full
  keyboard operability with visible focus states (no `outline: none` without a replacement); hit
  targets ≥ 44×44 px on touch-capable screens; semantic HTML/ARIA with `role="alert"` or live
  regions for status; never color alone, always paired with icon and label.
- Cognitive load: plain wording the user already knows, so they never have to guess what to do
  next. Prefer pick-lists, recent items, and autocomplete over free text; prefill sensible,
  editable defaults (today, current shift, current user); keep the object's ID and title on
  screen throughout a flow.
- Error prevention & recovery: destructive or irreversible actions confirm by naming the object
  (or offer undo); error messages say what happened and what to do next in plain language, with
  no stack traces or bare error codes.

## 3. Text and locale

- UI text comes from the project's i18n/locale setup, in the product's language; no hardcoded
  strings in another language.
- Numbers, dates, and times go through the project's locale formatting.
- Long text is handled explicitly: test every label and cell with a realistic long string and
  define truncation (with tooltip) or wrapping, so nothing clips silently.
- Sample data is realistic and in the product's language; never lorem ipsum.

## 4. Verifying UI changes

The mechanics (browser automation, e2e scoping, the fallback when no browser can run) are in
`CLAUDE.md` §10 and `.claude/rules/testing.md`. On top of that:

- Layout, visual, or state changes are verified in a real browser, not by inspection alone.
  Copy-only changes need no new browser run (the full suite still runs).
- With a design: screenshot the result, compare against the design, list the differences, fix
  them, re-screenshot.
- Walk both groups of §2 for every screen the change touches, at both resolutions, with realistic
  long data loaded and each of loading/empty/error triggered at least once.
- Report both groups under `## Verified`: item by item for anything that failed or was fixed, and
  "n/a" with the reason for items that do not apply (e.g. no design spec).
