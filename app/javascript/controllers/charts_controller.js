import { Controller } from "@hotwired/stimulus"

// Loads Chart.js, Chartkick and the app's chart theme (charts.js) on a page that draws charts, so other
// pages never download them. Each chart's inline script (from Chartkick's Rails helper, with the page's
// CSP nonce) waits for Chartkick's "chartkick:load" event, which Chartkick sends once it has loaded.
//
//   div data-controller="charts"
//     = column_chart ...
export default class extends Controller {
  connect() {
    import("charts")
  }
}
