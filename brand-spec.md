# MLX Studio Brand Specification

This document is required by the swiftui-design-skill (templates/brand-spec.md + Brand Protocol): the cinematic dark glass visual language is the protected brand asset for this app. Do not replace the deep navy + cyan/violet accents with generic iOS dark system colors or other templates.

## Brand Name
MLX Studio

## Philosophy
Expressive cinematic workstation (dense, technical, sci-fi glass). Fast resident models, direct-from-disk, LM-Studio-like 3-pane control. Every element supports speed + observability + the "run the same way" CLI fidelity.

## Colors (exact cinematic glass palette - protected)

### Primary Accent
- **Color**: Electric blue action
- **Value**: Color(red: 0.10, green: 0.42, blue: 1.00)  // blueAction
- **Usage**: Primary buttons (Load, Send), links, active states, gear accent

### Accent Highlights
- **Cyan Core**: Color(red: 0.00, green: 0.82, blue: 1.00)  // cyanCore
- **Violet Glow**: Color(red: 0.55, green: 0.25, blue: 1.00)  // violetGlow
- **Usage**: ReactorCoreIndicator rings/core, stop button, streaming accents, subtle energy

### Neutrals (deep cinematic darks)
| Token           | Value                          | Usage                          |
| --------------- | ------------------------------ | ------------------------------ |
| bgDeep          | Color(red: 0.025, green: 0.030, blue: 0.045) | Main background + ignoresSafeArea |
| panelGlass      | Color.white.opacity(0.055)     | Card / surface glass fill      |
| borderSoft      | Color.white.opacity(0.10)      | Subtle strokes on glass        |
| textPrimary     | Color.white.opacity(0.92)      | Primary labels, content        |
| textMuted       | Color.white.opacity(0.55)      | Secondary, captions, log       |

### Semantic
- Error / failure lines in Activity Log: violetGlow (no bright red per palette)

## Typography
Maximum 4 sizes/levels per the design skill. Prefer system Dynamic Type where possible (.title3, .headline, .callout, .caption). Monospaced used only for paths, logs, stats via .monospaced() / .monospacedDigit().

- Title / brand: .title3.bold()
- Section / headline: .headline or .caption.bold()
- Body / fields: .callout
- Captions / log / metadata: .caption (or .caption.monospaced() for log)
- Avoid: .caption2, hard .system(size: N) except for the 4 levels above.

## Spacing (8pt grid - mandatory)
All values from Spacing enum (see MLXStudioApp.swift). Never random or odd numbers.

- xxs: 2, xs: 4, s: 8, m: 16, l: 24, xl: 32
- Horizontal padding on screens/sidebars: Spacing.m
- Inter-section: Spacing.l
- Tight element gaps: Spacing.xs / s
- Minimum touch target: 44pt (buttons use horizontal m + vertical xs or equivalent padding to meet)

## Corner Radius (brand-tuned, consistent)
- Radius.s (6): tight fields, pills, log inset, input capsules
- Radius.m (10): GlassCard surfaces, message bubbles, main cards
- Always: .clipShape(.rect(cornerRadius: Radius.xxx)) — never .cornerRadius() or deprecated overlay tricks.

## Glass / Cards
- Canonical: GlassCard (or .glass() extension) using ZStack fill + stroke inside background, then clipShape(.rect)
- Repeated inline glass patterns are banned (anti-ai-slop + craft rule). Use the component or tokenised equivalent.
- The exact panelGlass + borderSoft + shadow is the signature "cinematic glass" look. Preserve it.

## Motion
- Subtle infinite shimmers and reactor pulse are brand energy.
- Respect Reduce Motion: reactor falls back to static low-opacity; no large repeating scales.
- Use .task over .onAppear for startup work where possible.

## Layout Principles (from skill)
- Content-driven sizing: log area uses minHeight + maxHeight .infinity so it extends down the left sidebar when space allows (per original "extend that down the entire left sliding window" request).
- Sidebar: resizable via HSplitView drag; min 300 / max 380 tokens.
- Window: min 920x640 via NSWindow.minSize + view frame.
- 3-pane HSplit preserved exactly.

## Notes
- This spec + the tokens in MLXStudioApp.swift ensure the UI will never regress to arbitrary numbers, random spacing, or >4 font sizes.
- The "run the same way" (prebuilt release binary + protocol + direct disk ModelConfiguration) and all loading observability / failure paths are non-negotiable and untouched by design work.
- If redesigning, re-run the 5-dimension review (Craft must stay >=8).

## Implementation Reference
See MLXStudioApp.swift:
- enum Spacing, Radius, Layout
- GlassCard
- ReactorCoreIndicator (with reduceMotion guard)
- All call sites now use tokens
- NSWindow minSize + .frame mins

Created per explicit user instruction to load + follow swiftui-design-skill + swiftui-agent-skill exactly.