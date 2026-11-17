---
name: design-system
description: Maintain and extend this app's design system (tokens, base element styles, component classes, UI helpers and partials, the form builder). Use when adding a UI element, changing colours or fonts, moving ad-hoc markup onto the system, auditing views for markup that bypasses it, or when asked to "add X to the design system".
---

# Design system (Rails / Slim / Tailwind v4 / Hotwire)

Adapted from [buildermethods/bm-skills](https://github.com/buildermethods/bm-skills) `bm-design-system` (MIT, see `references/LICENSE-bm-skills`). The original targets React + shadcn; this version is Rails-native: Slim partials, view helpers, a form builder and Stimulus controllers. No Node, no React.

The system is already in place. This skill is for **extending** it (a new primitive, a new token), **rebranding** it (colours, fonts) and **migrating** markup that was written outside it. There is no reference page in the app: the source files below, their comments and their tests are the reference. Read them before deciding that something is missing.

## Where everything lives

| Piece | Path |
|---|---|
| Tokens, dark mode, base element styles, component classes | `app/assets/tailwind/design-system.css` (imported by `app/assets/tailwind/application.css`) |
| Helpers | `app/helpers/ui_helper.rb`: `ui_button`, `ui_link_button`, `ui_button_to`, `ui_button_classes`, `ui_badge`, `ui_icon`, `ui_flash_tone`, `ui_classes`; variant maps `BUTTON_VARIANTS`, `BUTTON_SIZES`, `BADGE_TONES`, `CALLOUT_TONES`, `ICON_SIZES` |
| Partials | `app/views/ui/_page_header`, `_callout`, `_flash`, `_theme_toggle` |
| Forms | `app/form_builders/ui_form_builder.rb`, the default builder of `form_with` (set in `ApplicationController`) |
| Behaviour | `app/javascript/controllers/theme_controller.js`, `clipboard_controller.js` |
| CSS-only components | `.listing` / `.listing-item`, `.data-table` / `.data-row` (definition list), `.data-grid-wrapper > table.data-grid` with `.data-grid-num`, `.data-grid-link`, `.data-grid-actions`, `.data-grid-group`, `.data-grid-sub`, `.body-content` (long prose) |
| Fonts and the theme boot script | `app/views/layouts/_head.html.slim` |
| Logo and favicons | `design/favicon/source.png`, `bin/favicon`, `app/assets/images/logo.png` (see `README.md`, "Logo and favicons") |
| Rules for agents | `CLAUDE.md`, the "Views" and "Tailwind utilities" bullets under "Conventions"; `.claude/agents/implementer.md` and `reviewer.md` repeat the short form |
| Tests | `test/helpers/ui_helper_test.rb`, `test/views/ui_partials_test.rb`, `test/form_builders/ui_form_builder_test.rb` |

## Principles

1. Decisions with discrete options go to the owner through `AskUserQuestion`, recommended option first; free-form input through chat. One decision at a time.
2. The system is opinionated, not exhaustive. Add a primitive only when a real screen needs it.
3. **Bare semantic HTML is already styled.** `h1`–`h6`, `p`, `a`, `strong`, `label`, `legend`, `ul`/`ol`/`li`, `blockquote`, `hr`, `pre` get size, weight, colour and font from `@layer base`. Never add `text-2xl`, `font-semibold`, `text-ink-display` and the like to them. Layout utilities (`mt-4`, `flex`, `max-w-md`) are fine.
4. **Tokens, never palette colours.** `bg-page`, `bg-surface`, `border-hairline`, `text-ink-body`, `text-ink-display`, `text-ink-muted`, and `accent`, `signal`, `danger` with their `-faded` and `-display` variants. No `bg-gray-100`, no hex in views.
5. **Utilities must appear literally** in a scanned file (`app/views`, `app/helpers`, `app/form_builders`, `app/javascript`). Never build `"bg-#{x}"`. Component classes (`btn-*`, `badge-*`, `callout-*`) are plain CSS and may be looked up from a hash; keep those maps in `UiHelper` constants.
6. **The Content Security Policy blocks inline scripts and styles** (`config/initializers/content_security_policy.rb`): no `style=` attribute, no `on…=` attribute, no inline `<script>` besides the theme boot script. A width or a colour that depends on data needs a class, not a `style`.

## Step 0: detect the state

Check silently before anything else:

- `Gemfile.lock` has `tailwindcss-ruby (4.` (Tailwind v4). If not, stop and say so.
- `app/assets/tailwind/design-system.css` exists and has a `@theme` block.
- `app/helpers/ui_helper.rb` and `app/form_builders/ui_form_builder.rb` exist.

Anything missing means something was deleted: tell the owner what, and offer to restore it from git history before continuing.

## Step 1: scope

If the request does not already say, ask with `AskUserQuestion`: "What do you want to do?"

- `Add a primitive`
- `Change colours or fonts`
- `Migrate existing markup to the system`
- `Audit: find markup that bypasses the system`

Then follow the matching section. One task per run.

## Add a primitive

1. **Decide the shape.** A helper in `UiHelper` for inline things that take a label and options (buttons, badges, icons). A partial under `app/views/ui/` for anything with a body or slots (`= render "ui/x" do`). A form builder method for anything bound to a model attribute. A Stimulus controller for behaviour; never inline JS.
2. **CSS first.** Add component classes to `@layer components` in `design-system.css`, built from tokens with `@apply`. Variants are separate classes (`.thing`, `.thing-small`, `.thing-accent`).
3. **Ruby second.** Variant maps are frozen hashes of complete class strings; use `fetch` so an unknown variant raises. Merge caller classes with `ui_classes` (tailwind_merge resolves conflicts).
4. **Document it where it lives.** A partial starts with a `/` comment that says what it is for and shows one call (see `app/views/ui/_page_header.html.slim`); a helper has the same above its method.
5. **Test.** Add a test next to the existing ones (helper, partial or form builder), then `bin/rails test test/helpers test/views test/form_builders` and `bin/slim-lint app/views`.
6. **Keep the docs current.** Add the new name to the "Views" bullet of `CLAUDE.md` and to the table above.
7. **Slim rules**: `references/slim-rules.md`.

## Change colours or fonts

Colours and fonts are locked defaults, not per-feature decisions. For a rebrand:

1. Ask for the new accent, signal (optional) and neutral scale, or the new font names. Say in one line what each drives.
2. Derive the whole palette with `references/derive-palette.md` (fifteen tokens in two modes; the `danger` trio stays unless asked).
3. Write the values into `@theme` and `.dark` in `design-system.css`.
4. Fonts: change `--font-display` / `--font-sans` in the CSS and the Google Fonts `<link>` in `app/views/layouts/_head.html.slim`. A new font host also needs an entry in the Content Security Policy and in `test/integration/content_security_policy_test.rb`.
5. If the artwork changes too: replace `design/favicon/source.png`, run `bin/favicon`, and redo the logo with the `sips` command in `README.md`.
6. `bin/rails tailwindcss:build`, then look at the app running (`bin/dev`) in light and dark.

## Migrate existing markup

1. **Scan** `app/views/**/*.slim` and `app/helpers/**` (skip `app/views/ui/**`) for:
   - raw `button` / `input` / `select` / `textarea` with ad-hoc classes instead of `ui_button*` or the form builder;
   - `link_to … class: "… bg-… "` styled as a button;
   - palette utilities (`bg-white`, `bg-gray-*`, `text-slate-*`, `border-zinc-*`), raw hex, `style=`;
   - headings or labels carrying text-size, weight or colour utilities;
   - hand-rolled headers, callouts, cards, tables.
2. **Summarise** the findings in buckets (pages, layouts, navigation, forms, buttons, listings and tables) with counts and one or two example paths. If there is nothing meaningful, say so and stop.
3. **Ask** with `AskUserQuestion`: migrate everything / only one bucket / not now. Never migrate without an explicit yes.
4. **Migrate** with this mapping: `bg-white` → `bg-page`, `bg-gray-50` → `bg-surface`, `text-gray-900` → `text-ink-display`, `text-gray-500` → `text-ink-muted`, `border-gray-200` → `border-hairline`, `bg-blue-600` → `bg-accent`, `text-red-600` → `text-danger-display`; raw buttons → `ui_button` / `ui_link_button` / `ui_button_to`; raw fields → the form builder; prose blocks → `.body-content`. Behaviour and copy stay untouched. If a needed primitive is missing, add it first ("Add a primitive").

## Audit only

Run the scan of "Migrate existing markup" and report; change nothing.

## Wrap up

Report what was added or changed (files), where to look at it in the running app, and the test results. The theme switch is in the page header and its choice is stored in `localStorage["theme"]`.
