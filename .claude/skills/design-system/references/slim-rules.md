# Slim rules that matter for design-system work

Each of these has produced a `Malformed indentation` or an `undefined local variable` error at least once.

1. **No multi-line Ruby on a `-` line.** `- code = <<~SLIM … SLIM` is a syntax error. Several statements go in a `ruby:` block at the top of the template (see `app/views/ui/_theme_toggle.html.slim`); anything longer belongs in a helper.
2. **Dot shorthand only for plain class names.** `.flex.items-center` is fine; `hover:bg-surface`, `sm:grid-cols-2`, `bg-accent/90`, `max-w-[20rem]`, `[&_ul]:list-disc` must go in `class="…"`. Both forms can be combined on one tag; Slim merges the class attribute.
3. **Text that starts with `* # . = - | / < :` or a quote** is parsed as syntax. Write `| *-faded` or `code = "*-faded"`.
4. **Leading space in text:** `|  two spaces` keeps one. Inline code followed by text:
   ```slim
   li
     code variant:
     |  primary (default), secondary.
   ```
5. **Boolean attribute values** render as boolean attributes (`data-x` with no value). For Stimulus values and data attributes that need `"true"` / `"false"`, use `.to_s`.
6. **Helpers that take blocks** use `=`, not `-`: `= ui_button variant: :ghost do`, `= render "ui/callout", tone: :signal do`.
7. **A partial always gets a block from Rails**, so `block_given?` is always true inside one. To make a slot optional, capture it (`- actions = yield`) and test the result for `present?` (see `app/views/ui/_page_header.html.slim`).
8. **Stimulus scopes targets to the nearest controller element.** Two instances of the same component on one page each need their own `data-controller` wrapper, and unique `id`s where they have any.
9. **Comments:** `/` is a silent comment, `/!` renders an HTML comment. Use `/`.
10. **No inline scripts or styles.** `javascript:` and `css:` blocks, `style=` and `on…=` attributes are blocked by the Content Security Policy. The one exception is the theme boot script in `app/views/layouts/_head.html.slim`, which carries the nonce.
