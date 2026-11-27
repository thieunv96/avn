---
name: report
description: Writes a report for people (model or experiment results, progress, a technical investigation) as a visual summary plus a detail file. Use when the user asks for a report, a summary for a manager or customer, or a comparison of results. Not for the end-of-task summary in chat.
argument-hint: [what to report, for whom]
---

# Report: results first, visual, sized to the reader

## 1. Brief

Settle four things before writing: the reader, the goal (the decision or question the report
serves), the language (default: the conversation's) and the formats. Take them from the request
and the conversation; ask only for the ones still missing, in one AskUserQuestion call. Go deeper
for a complex task or a technical reader, shorter for a routine one.

| Reader | Give them | Summary length |
| --- | --- | --- |
| The user | results, comparisons, next actions, method in brief | as long as the task needs |
| Manager | conclusion, three key numbers, the one chart that decides, risks, the ask | one screen |
| Customer or partner | outcome and benefit, one chart or table, formal tone, no internals | one screen |

## 2. Data first

Put every number in `data/*.csv` before writing. The report states no number that is not there.

## 3. Outputs

Always two, under `reports/<yyyy-mm-dd>-<slug>/` in the repository:

- `summary.html`: one self-contained page (inline CSS and inline SVG, nothing loaded from the
  network), written for the reader in the brief.
- `report.md` with `data/*.csv`: the detail, for whoever checks or continues the work.

PowerPoint, Word or Excel only when asked; use the matching skill when the session has one.

## 4. Rules

- Conclusion first: answer the goal in one or two sentences, then give the evidence.
- Report results and their meaning, not the steps taken; end with risks and the next action.
- Three or more comparable values become a table or a chart, never a sentence.
- Chart by data shape: items compared → bar; several measures per item → grouped bar; change
  over time or epochs → line; two measures related → scatter; class-by-class errors → heatmap
  table; before and after → two charts side by side on the same scale.
- Architecture or data flow → block diagram, boxes left to right with labelled arrows, nine
  boxes at most (inline SVG in the page, a `mermaid` block in `report.md`).
- Chart: the title states the takeaway; axes carry units; values are labelled directly; one
  accent colour for the item that matters, grey for the rest; a series keeps its colour in every
  chart; bars start at zero.
- Table: numbers right-aligned with the same decimals, units in the header, the best value in
  bold, seven columns at most.
- Page: one column up to about 900px wide, system font, light background, generous spacing, no
  decoration.
- Terms follow `.claude/rules/profile.md`; for another reader explain each term where it is used.

## 5. Check before delivering

- The first screen answers the goal for the reader in the brief. A one-screen summary shows only
  what its row lists, without scrolling; the full table and any glossary go to `report.md`.
- Every number traces to `data/`; every group of comparable numbers is a table or a chart.
- `summary.html` opens offline; at laptop width no text is cut off or overlaps. Report both paths.
