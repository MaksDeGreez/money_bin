// Chart.js through Chartkick, themed from the design tokens (app/assets/tailwind/design-system.css).
// Loaded by charts_controller.js on pages that draw charts. docs/decisions/0013-dashboard-charts.md
//
// - Colours, text and grid lines come from the CSS custom properties of the current theme, and every
//   chart is redrawn when the theme changes (the `dark` class on <html>, set by theme_controller.js or by
//   the system setting).
// - The series colours are --color-chart-1 and --color-chart-2: a blue and an orange that stay apart for
//   colour-blind readers.
// - A tooltip shows the figure the server formatted from the exact decimal (the dataset's `exact` list,
//   passed as the series' `library` option), never the number the chart drew. Axis ticks are only scale
//   marks, written by Chartkick with a space between thousands.
// - No animation: a chart is ready as soon as it is drawn, for screenshots and print.
import "Chart.bundle"
import "chartkick"

const { Chart, Chartkick } = window

function token(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim()
}

// "#0072b2" -> "rgb(0, 114, 178)". Chartkick fades a hex colour to half opacity for bars; any other
// notation it leaves as it is, so the bars stay solid and readable in print.
function solid(hex) {
  const match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex)
  return match ? `rgb(${parseInt(match[1], 16)}, ${parseInt(match[2], 16)}, ${parseInt(match[3], 16)})` : hex
}

function palette() {
  return [solid(token("--color-chart-1")), solid(token("--color-chart-2"))]
}

function exactLabel(context) {
  const exact = context.dataset.exact
  const text = Array.isArray(exact) && exact[context.dataIndex] !== undefined ? exact[context.dataIndex] : context.formattedValue
  return context.dataset.label ? `${context.dataset.label}: ${text}` : text
}

function applyTheme() {
  Chart.defaults.color = token("--color-ink-muted")
  Chart.defaults.borderColor = token("--color-hairline")
  Chart.defaults.font.family = token("--font-sans")
  Chart.defaults.font.size = 12
  Chartkick.options.colors = palette()
}

Chartkick.setDefaultOptions({
  thousands: " ",
  library: {
    animation: false,
    plugins: { tooltip: { callbacks: { label: exactLabel } } }
  }
})
applyTheme()

let dark = document.documentElement.classList.contains("dark")
new MutationObserver(() => {
  const now = document.documentElement.classList.contains("dark")
  if (now === dark) return
  dark = now
  applyTheme()
  Chartkick.eachChart((chart) => {
    chart.options.colors = Chartkick.options.colors
    chart.redraw()
  })
}).observe(document.documentElement, { attributes: true, attributeFilter: ["class"] })
