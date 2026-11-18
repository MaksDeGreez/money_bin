# 0013. Dashboard charts: Chartkick under the Content Security Policy, figures from the query objects

Status: accepted, with the dashboard.

## Context

The home page becomes a dashboard: spending by month, by category (or group), top payees and the receipt
pipeline, plus a few headline figures. It must not disagree with the REST API or the MCP server, and its
screenshots go into a thesis, so it must be readable in both themes, at laptop width and in print.

Three constraints shape how the charts are drawn:

- JavaScript arrives through importmap; there is no Node and no bundler (0001);
- the Content Security Policy (`config/initializers/content_security_policy.rb`) runs an inline script
  only with the page's nonce, has no `'unsafe-inline'` for styles (a nonce never covers a `style=`
  attribute) and no `'unsafe-eval'`;
- money is exact: a float sum must never be a figure a person reads.

The owner preferred the `chartkick` gem (with `groupdate`).

## Decision

### Chartkick 5.3, which meets the policy without weakening it

What the installed gem does, read from its source:

- `column_chart` / `bar_chart` emit a container `<div>` and an inline `<script>` that creates the chart.
  The helper puts `nonce="…"` on that script itself, from `content_security_policy_nonce`, so the script
  runs under the policy. The nonce is the session id (unchanged by Turbo visits), and Turbo copies it onto
  the scripts it runs after a visit.
- Its default container carries an inline `style` attribute. `Chartkick.options[:html]`
  (`config/initializers/chartkick.rb`) replaces it with classes: `chart` and `chart-<height>`
  (`height: "md"` gives `chart-md`, sized in `design-system.css`). The tests fail on any element with a
  `style` attribute.
- `chartkick.js` 5.0.1 and Chart.js 4.6.1 (`Chart.bundle.js`) ship in the gem's `vendor/assets`;
  Propshaft serves them, and `config/importmap.rb` pins both with `preload: false`. Neither uses `eval`
  or `new Function`, and neither injects a `<style>` element; what they set through `element.style` is
  the CSS object model, which the policy does not govern.
- `charts_controller.js` imports `app/javascript/charts.js` (and through it the two libraries) only on a
  page with a chart, so the 860 kB of Chart.js is never loaded elsewhere. A chart's script waits for
  Chartkick's `chartkick:load` event, which Chartkick sends one tick after it loads, after `charts.js`
  has set the defaults.

So the policy is untouched: no new host, no `'unsafe-inline'`, no hash. A Stimulus controller over a
vendored Chart.js was the fallback had any of this failed.

### Exact figures, server-side

- Every money figure comes from `SpendingSummaryQuery` (months, categories, groups, headline figures)
  or the new `TopPayeesQuery` (payees), with the summary's rules: booked rows only, transfer legs left
  out, lines per category, one currency at a time. `ReceiptCountsQuery` counts the receipts. `Dashboard`
  (`app/models/dashboard.rb`) picks the period and currency from the URL, fills empty months with zero and
  sums the categories beyond the top ten as "Other", in BigDecimal. A test compares the page with
  `GET /api/v1/summary` for the same range.
- Periods are whole calendar months (the last 12 months to the last day of this month, a year to
  31 December), so a booked row dated ahead is counted as the API counts it for the same range.
- "Uncategorised spending" is the taxonomy's Uncategorised category (where the history import puts what it
  could not map) plus the lines with no category. In the category chart the two stay apart, as in the
  summary: the category under its own name, the lines without one as "No category".
- Chartkick gets money as exact decimal strings (`JsonFormat.money`) and Integers for counts; the helper
  refuses a Float. Chart.js parses the strings only to draw. Each series also carries, per point, the
  text its tooltip shows (`library: { exact: [...] }`), formatted on the server; `charts.js` uses it as
  the tooltip label. Axis ticks are only scale marks, written by Chartkick with a space between thousands.
- Each chart has the same figures as a table in a `<details>` disclosure; the canvas is `aria-hidden`.
  The tests read the tables.

### Themes, palette, print

`charts.js` reads the design tokens (`--color-ink-muted` for text, `--color-hairline` for grid lines,
`--font-sans`, and two new series tokens `--color-chart-1` / `--color-chart-2`: the Okabe-Ito blue and
orange, apart for colour-blind readers, lighter blue in dark mode) and redraws every chart when the `dark`
class on `<html>` changes. Colours are hex in the CSS and turned into `rgb()` for Chart.js, so Chartkick
leaves bars solid instead of fading them to half opacity. Animation is off, so a chart is complete the
moment it is drawn (screenshots, print).

### No groupdate, no cache

`SpendingSummaryQuery` already groups by calendar month of the `occurred_on` date in SQL, and the
dashboard zero-fills months in Ruby in a few lines; groupdate would add a second grouping path that the
REST summary does not share. It is not added.

The page issues a fixed number of queries (8 for the last 12 months, 11 for a calendar year, plus the
session lookups); a test checks the count does not grow with the ledger. Measured on the development
database (about 25,000 transactions over 12 years): the dashboard's queries take about 20 ms for the
last 12 months and about 40 ms for a calendar year, and the page renders in 45 to 65 ms. No cache is
added; if one is ever needed, the key must change with every write to `transactions`,
`transaction_lines`, `receipts` and `receipt_ground_truths`.

## Alternatives considered

- **A Stimulus controller drawing Chart.js from JSON in a data attribute.** No inline scripts at all and
  full control, but more code of our own for the same result; Chartkick meets the policy, and the owner
  preferred it.
- **Relaxing the policy** (`'unsafe-inline'`, or script hashes per chart): rejected outright.
- **A JavaScript-free chart (server-rendered SVG).** Exact and static, but more drawing code to keep, no
  tooltips, and the owner asked for Chartkick.
- **Percentages in the headline figures.** This month so far against a whole month reads "-100%" on the
  first of the month; amounts side by side are shown instead.

## Consequences

- A new chart is a Chartkick helper call in a view with `discrete: true`, an `id`, a height class
  (`sm`, `md`, `lg`), data from a query object through a `DashboardHelper` series (exact strings and
  tooltip texts), and a table of the same figures beside it.
- Upgrading the chartkick gem upgrades Chart.js; re-check the two library files for `eval`, injected
  styles and the helper's nonce when it does.
- The top payees and receipt counts are query objects, so the REST API and the MCP server can expose
  them later without new reading logic.
