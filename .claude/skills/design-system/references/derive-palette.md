# Palette derivation

The palette is fifteen tokens in two modes, all in `app/assets/tailwind/design-system.css`: the light values in `@theme`, the dark ones in `.dark`. This file records the values as shipped and the rule behind each, so the palette can be derived again when the brand colours change.

Inputs:

- `accent`: Tailwind cyan (cyan-500 in light mode, cyan-400 in dark mode)
- `signal`: `#fcd34d` (Tailwind amber-300), the same shade in both modes
- `danger`: a red at hue 25 (light) / 22 (dark)
- `neutral`: Tailwind slate in light mode; a plain grey ramp in dark mode

## Surfaces and text, driven by `neutral`

| Token         | Light                 | Dark      |
|---------------|-----------------------|-----------|
| `page`        | `#ffffff`             | `#121212` |
| `surface`     | `#f8fafc` (slate-50)  | `#1c1c1c` |
| `hairline`    | `#e2e8f0` (slate-200) | `#2e2e2e` |
| `ink-body`    | `#334155` (slate-700) | `#e4e4e4` |
| `ink-display` | `#0f172a` (slate-900) | `#f5f5f5` |
| `ink-muted`   | `#64748b` (slate-500) | `#a1a1a1` |

Rules: `page` is pure white in light mode; `surface` is one step off the page and `hairline` two; `ink-display` is the strongest text, `ink-body` one step softer, `ink-muted` the mid grey. Dark mode is a neutral grey ramp without the blue tint of slate, with the page near black, not black. With another neutral scale, take the same steps (50, 200, 500, 700, 900 for light).

## Accent, signal and danger

Each colour has three tokens: the base (fills: `bg-accent`), `-faded` (a tinted background: `bg-accent-faded`) and `-display` (text and icons on the page or on the faded background: `text-accent-display`).

| Token            | Light                           | Dark                           |
|------------------|---------------------------------|--------------------------------|
| `accent`         | `oklch(71.5% 0.143 215.221)`    | `oklch(78.9% 0.154 211.53)`    |
| `accent-faded`   | `oklch(96% 0.025 215.221)`      | `oklch(22% 0.045 211.53)`      |
| `accent-display` | `oklch(62% 0.135 215.221)`      | `oklch(86% 0.135 211.53)`      |
| `signal`         | `#fcd34d`                       | `#fcd34d`                      |
| `signal-faded`   | `#fffaea`                       | `#2f2b21`                      |
| `signal-display` | `oklch(76% 0.165 82)`           | `oklch(93% 0.13 95)`           |
| `danger`         | `oklch(64% 0.22 25)`            | `oklch(72% 0.20 22)`           |
| `danger-faded`   | `oklch(96% 0.025 25)`           | `oklch(22% 0.05 22)`           |
| `danger-display` | `oklch(55% 0.20 25)`            | `oklch(82% 0.18 22)`           |

Rules, for a base colour given as `oklch(L C H)`:

- **Base.** Light mode uses the brand shade; dark mode uses one step lighter on the same scale (cyan-500 → cyan-400), so a fill keeps its weight on a dark page. `signal` is the exception: it is pinned to one light tint in both modes, so badges and callouts read the same.
- **`-faded`.** Keep the hue. Light: lightness 96%, chroma about 0.025. Dark: lightness 22%, chroma about 0.045 to 0.05.
- **`-display`.** Keep the hue. Light: about 9 points darker than the base at slightly less chroma (it must reach 4.5:1 on `page` and on `-faded`). Dark: about 7 to 10 points lighter than the base.
- **`signal-faded`** was mixed by hand, not taken from oklch: the signal at 12% on `#ffffff` (light) and at 18% on `#020617` (dark). The formula, for a foreground `F` at share `p` on a background `B`, per channel: `round(F * p + B * (1 - p))`.

After a change, check the contrast of every `-display` token on `page`, `surface` and its own `-faded` background in both modes, and of `text-page` on the `accent` and `danger` fills (the primary and danger buttons).
